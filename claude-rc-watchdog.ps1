# Keeps a `claude remote-control` server running for each project in
# rc-projects.json, so the desktop serves Remote Control again after a reboot
# or a long network outage without anyone touching it.
#
# - Waits for internet before starting anything.
# - Relaunching `claude remote-control` in the same folder within ~4 hours
#   brings back the sessions that server was serving (same claude.ai sessions).
# - Server mode exits after ~10 min without network; this restarts it.
# - Backs off if a project's server keeps dying.
# - Optional heartbeat URL (e.g. healthchecks.io) so you get an email when the
#   desktop goes quiet.
#
# Pause it (e.g. while you're stopping servers by hand): create the file
#   %LOCALAPPDATA%\claude-rc-watchdog\paused
# Log: %LOCALAPPDATA%\claude-rc-watchdog\watchdog.log
#
# Started at logon by register-rc-watchdog-task.ps1.

$configPath = Join-Path $PSScriptRoot "rc-projects.json"
$stateDir   = Join-Path $env:LOCALAPPDATA "claude-rc-watchdog"
$logPath    = Join-Path $stateDir "watchdog.log"
New-Item -ItemType Directory -Force $stateDir | Out-Null

function Log {
    param($msg)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg"
    Add-Content -Path $logPath -Value $line
    # Keep the log from growing forever.
    if ((Get-Item $logPath).Length -gt 1MB) {
        Get-Content $logPath -Tail 2000 | Set-Content "$logPath.tmp"
        Move-Item "$logPath.tmp" $logPath -Force
    }
}

function Test-Internet {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ok = $client.ConnectAsync("api.anthropic.com", 443).Wait(5000)
        $client.Close()
        return $ok
    } catch {
        return $false
    }
}

function Get-ClaudeExe {
    $cmd = Get-Command claude.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $native = Join-Path $env:USERPROFILE ".local\bin\claude.exe"
    if (Test-Path $native) { return $native }
    return $null
}

function Get-Slug {
    param($path)
    return ($path -replace '[^A-Za-z0-9]+', '-').Trim('-')
}

$restarts = @{}      # slug -> list of restart times
$warned   = @{}      # slug -> already logged the back-off
$lastHeartbeat = [datetime]::MinValue

Log "watchdog started (pid $PID)"

while ($true) {
    try {
        if (Test-Path (Join-Path $stateDir "paused")) {
            Start-Sleep -Seconds 30
            continue
        }

        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        $online = Test-Internet

        if ($online -and $config.heartbeatUrl -and ((Get-Date) - $lastHeartbeat).TotalMinutes -ge 5) {
            try {
                Invoke-WebRequest -Uri $config.heartbeatUrl -UseBasicParsing -TimeoutSec 10 | Out-Null
                $lastHeartbeat = Get-Date
            } catch {
                Log "heartbeat failed: $($_.Exception.Message)"
            }
        }

        if (-not $online) {
            Start-Sleep -Seconds 30
            continue
        }

        $claude = Get-ClaudeExe
        if (-not $claude) {
            Log "claude.exe not found; install the Claude Code CLI"
            Start-Sleep -Seconds 300
            continue
        }

        foreach ($project in $config.projects) {
            $slug    = Get-Slug $project.path
            $pidFile = Join-Path $stateDir "$slug.pid"

            if (Test-Path $pidFile) {
                $serverPid = [int](Get-Content $pidFile)
                $proc = Get-Process -Id $serverPid -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -like "claude*") { continue }
            }

            if (-not (Test-Path $project.path)) {
                Log "skipping missing folder $($project.path)"
                continue
            }

            # Back off if this server died 5+ times in the last 30 minutes.
            $recent = @($restarts[$slug] | Where-Object { $_ -gt (Get-Date).AddMinutes(-30) })
            if ($recent.Count -lt 5) { $warned[$slug] = $false }
            if ($recent.Count -ge 5) {
                if (-not $warned[$slug]) {
                    Log "$($project.path): restarted $($recent.Count) times in 30 min, backing off"
                    $warned[$slug] = $true
                }
                continue
            }

            $rcArgs = @("remote-control")
            if ($project.spawn)          { $rcArgs += @("--spawn", $project.spawn) }
            if ($project.permissionMode) { $rcArgs += @("--permission-mode", $project.permissionMode) }
            if ($project.name)           { $rcArgs += @("--name", "`"$($project.name)`"") }

            # Own console window: server mode wants a terminal, and running in
            # the signed-in desktop session keeps GUI automation working.
            $proc = Start-Process -FilePath $claude -ArgumentList $rcArgs -WorkingDirectory $project.path -PassThru
            Set-Content -Path $pidFile -Value $proc.Id
            $restarts[$slug] = @($recent) + (Get-Date)
            Log "started remote-control in $($project.path) (pid $($proc.Id)): $($rcArgs -join ' ')"
        }
    } catch {
        Log "error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 30
}
