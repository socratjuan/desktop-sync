# Register a scheduled task that runs the Claude Remote Control watchdog at user logon.
# Copy rc-projects.example.json to rc-projects.json and edit it first.

$configPath = Join-Path $PSScriptRoot "rc-projects.json"
if (-not (Test-Path $configPath)) {
    Copy-Item (Join-Path $PSScriptRoot "rc-projects.example.json") $configPath
    Write-Host "Created $configPath from the example; edit the project list, then re-run this script." -ForegroundColor Yellow
    return
}

Unregister-ScheduledTask -TaskName "ClaudeRCWatchdog" -Confirm:$false -ErrorAction SilentlyContinue

# Run as the signed-in user (not SYSTEM) so the servers it starts can drive the GUI.
$currentUser = "$env:COMPUTERNAME\$env:USERNAME"
$watchdog = Join-Path $PSScriptRoot "claude-rc-watchdog.ps1"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdog`""

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser

# Limited, not Highest: an elevated parent would make every Claude session elevated.
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 365)

Register-ScheduledTask -TaskName "ClaudeRCWatchdog" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

Start-ScheduledTask -TaskName "ClaudeRCWatchdog"

Start-Sleep -Seconds 3
Write-Host "Task state:"
Get-ScheduledTask -TaskName "ClaudeRCWatchdog" | Select-Object TaskName, State
Write-Host ""
Write-Host "Log: $env:LOCALAPPDATA\claude-rc-watchdog\watchdog.log"
