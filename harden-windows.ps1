# =============================================================================
# harden-windows.ps1 — Run on the desktop (Windows) before leaving on a trip
#
# Makes the desktop less likely to go offline, and more likely to come back
# on its own (signed in, on the tailnet, Claude Remote Control serving) if it does.
#
# What it does (all idempotent, safe to re-run):
#   1. Windows Update: no auto-restart while signed in, wide active hours,
#      optional pause (-PauseUpdatesDays)
#   2. Network adapters: stop Windows powering them off (keeps Wake-on-LAN)
#   3. Tailscale: unattended mode (connects before sign-in), warns on key expiry
#   4. Checks power settings (sleep/hibernate) and auto sign-in status
#   5. Installs a Claude Code SessionStart hook that warns resumed sessions
#      their background tasks may be gone
#   6. Registers the ClaudeRCWatchdog logon task (see claude-rc-watchdog.ps1)
#
# Usage (PowerShell as Administrator):
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\harden-windows.ps1                       # everything
#   .\harden-windows.ps1 -PauseUpdatesDays 21  # also pause updates for the trip
#   .\harden-windows.ps1 -SkipWatchdog         # don't register the watchdog task
#
# Things a script can't do — see TRAVEL-RUNBOOK.md:
#   - BIOS: "Restore on AC Power Loss" = Power On
#   - Auto sign-in: run Sysinternals Autologon yourself (it asks for your password)
#   - Dual boot: make Windows the default boot entry
# =============================================================================

#Requires -RunAsAdministrator

param(
    [int]$PauseUpdatesDays = 0,
    [switch]$SkipWatchdog
)

$ErrorActionPreference = "Stop"

function Write-Info  { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

$todo = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# 1. Windows Update restarts
# ---------------------------------------------------------------------------
Write-Info "Configuring Windows Update restart behavior..."

$auPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (-not (Test-Path $auPath)) { New-Item -Path $auPath -Force | Out-Null }
# Don't auto-restart for scheduled installs while a user is signed in.
# Honored on Pro/Enterprise; Home may ignore it, which is why active hours
# and the pause below exist too.
New-ItemProperty -Path $auPath -Name NoAutoRebootWithLoggedOnUsers -Value 1 -PropertyType DWord -Force | Out-Null

# Active hours: 18 hours is the maximum span Windows allows.
$uxPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
if (-not (Test-Path $uxPath)) { New-Item -Path $uxPath -Force | Out-Null }
New-ItemProperty -Path $uxPath -Name SmartActiveHoursState -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uxPath -Name ActiveHoursStart -Value 6 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uxPath -Name ActiveHoursEnd -Value 0 -PropertyType DWord -Force | Out-Null
Write-Info "No auto-restart while signed in; active hours 06:00-00:00"

if ($PauseUpdatesDays -gt 0) {
    if ($PauseUpdatesDays -gt 35) {
        Write-Warn "Windows caps a pause at 35 days; using 35"
        $PauseUpdatesDays = 35
    }
    $start = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $end   = (Get-Date).AddDays($PauseUpdatesDays).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    foreach ($name in "PauseFeatureUpdatesStartTime", "PauseQualityUpdatesStartTime", "PauseUpdatesStartTime") {
        New-ItemProperty -Path $uxPath -Name $name -Value $start -PropertyType String -Force | Out-Null
    }
    foreach ($name in "PauseFeatureUpdatesEndTime", "PauseQualityUpdatesEndTime", "PauseUpdatesExpiryTime") {
        New-ItemProperty -Path $uxPath -Name $name -Value $end -PropertyType String -Force | Out-Null
    }
    Write-Info "Updates paused until $end (check Settings > Windows Update shows it)"
}

# A pending restart means Windows will force one soon regardless.
$rebootPending = (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") -or
                 (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending")
if ($rebootPending) {
    Write-Warn "A Windows Update restart is pending"
    $todo.Add("Restart now, while you're home, so Windows doesn't do it while you're away")
}

# ---------------------------------------------------------------------------
# 2. Network adapter power management
# ---------------------------------------------------------------------------
Write-Info "Stopping Windows from powering off network adapters..."
foreach ($nic in Get-NetAdapter -Physical -ErrorAction SilentlyContinue) {
    try {
        # Only this one setting: Disable-NetAdapterPowerManagement would also turn off Wake-on-LAN.
        Set-NetAdapterPowerManagement -Name $nic.Name -AllowComputerToTurnOffDevice Disabled -NoRestart -ErrorAction Stop
        Write-Info "  $($nic.Name): power-off disabled"
    } catch {
        Write-Warn "  $($nic.Name): couldn't change power management ($($_.Exception.Message))"
    }
}
if (-not (Get-NetAdapter -Physical | Where-Object { $_.Status -eq "Up" -and $_.MediaType -eq "802.3" })) {
    $todo.Add("No wired Ethernet is connected; a cable is much more reliable than Wi-Fi for an unattended machine")
}

# ---------------------------------------------------------------------------
# 3. Tailscale
# ---------------------------------------------------------------------------
$tailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
if (Test-Path $tailscaleExe) {
    Write-Info "Configuring Tailscale..."
    Set-Service -Name Tailscale -StartupType Automatic -ErrorAction SilentlyContinue
    # Unattended: stays connected with nobody signed in, so you can reach the
    # machine after a reboot even if auto sign-in fails.
    & $tailscaleExe set --unattended=true
    if ($LASTEXITCODE -eq 0) { Write-Info "Tailscale unattended mode on" }
    else { Write-Warn "tailscale set --unattended failed; turn on 'Run unattended' in the tray menu" }

    try {
        $self = (& $tailscaleExe status --json | ConvertFrom-Json).Self
        if ($self.KeyExpiry) {
            $expiry = [datetime]$self.KeyExpiry
            if ($expiry -lt (Get-Date).AddDays(45)) {
                Write-Warn "Tailscale key expires $expiry"
                $todo.Add("Disable key expiry for this machine in the Tailscale admin console (Machines > ... > Disable key expiry)")
            }
        } else {
            Write-Info "Tailscale key expiry is disabled"
        }
    } catch {
        Write-Warn "Couldn't read Tailscale status"
    }
} else {
    Write-Err "Tailscale isn't installed; run setup-windows.ps1 first"
}

# ---------------------------------------------------------------------------
# 4. Power and sign-in checks (setup-windows.ps1 sets these; verify nothing undid them)
# ---------------------------------------------------------------------------
Write-Info "Checking power settings..."
powercfg -change -standby-timeout-ac 0
powercfg -change -hibernate-timeout-ac 0
powercfg -h off
Write-Info "Sleep and hibernate off (AC)"

$winlogon = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
if ($winlogon.AutoAdminLogon -eq "1") {
    Write-Info "Auto sign-in is on (user: $($winlogon.DefaultUserName))"
} else {
    Write-Warn "Auto sign-in is off: after a reboot, nothing of yours runs until someone signs in"
    $todo.Add("Turn on auto sign-in with Sysinternals Autologon (see TRAVEL-RUNBOOK.md)")
}

# ---------------------------------------------------------------------------
# 5. Claude Code SessionStart hook
# ---------------------------------------------------------------------------
Write-Info "Installing the Claude Code resume hook..."
$hookScript = Join-Path $PSScriptRoot "claude-resume-hook.ps1"
$hookCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$hookScript`""
$settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"

if (Test-Path $settingsPath) {
    $raw = Get-Content $settingsPath -Raw
    if ($raw -match [regex]::Escape("claude-resume-hook.ps1")) {
        Write-Info "Resume hook already in $settingsPath"
    } else {
        Copy-Item $settingsPath "$settingsPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        $settings = $raw | ConvertFrom-Json
        $entry = [pscustomobject]@{
            matcher = "resume"
            hooks   = @([pscustomobject]@{ type = "command"; command = $hookCommand; timeout = 10 })
        }
        if (-not $settings.PSObject.Properties["hooks"]) {
            $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
        }
        if ($settings.hooks.PSObject.Properties["SessionStart"]) {
            $settings.hooks.SessionStart = @($settings.hooks.SessionStart) + $entry
        } else {
            $settings.hooks | Add-Member -NotePropertyName SessionStart -NotePropertyValue @($entry)
        }
        # No BOM: Windows PowerShell's -Encoding UTF8 adds one, which JSON parsers reject.
        [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 32), (New-Object Text.UTF8Encoding $false))
        Write-Info "Resume hook added to $settingsPath (backup saved next to it)"
    }
} else {
    New-Item -ItemType Directory -Force (Split-Path $settingsPath) | Out-Null
    $json = @{ hooks = @{ SessionStart = @(@{ matcher = "resume"; hooks = @(@{ type = "command"; command = $hookCommand; timeout = 10 }) }) } } |
        ConvertTo-Json -Depth 32
    [IO.File]::WriteAllText($settingsPath, $json, (New-Object Text.UTF8Encoding $false))
    Write-Info "Created $settingsPath with the resume hook"
}

# ---------------------------------------------------------------------------
# 6. Remote Control watchdog
# ---------------------------------------------------------------------------
if (-not $SkipWatchdog) {
    & (Join-Path $PSScriptRoot "register-rc-watchdog-task.ps1")
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Info "Hardening done."
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Still to do by hand:"
foreach ($item in $todo) { Write-Host "    - $item" -ForegroundColor Yellow }
Write-Host "    - BIOS: 'Restore on AC Power Loss' = Power On (if not done already)"
Write-Host "    - Dual boot: make Windows the default boot entry"
Write-Host "    - Then do a test reboot while you're home (TRAVEL-RUNBOOK.md, 'Test before you leave')"
Write-Host ""
