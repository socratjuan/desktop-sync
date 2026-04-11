# =============================================================================
# setup-windows.ps1 — Run this on your desktop while booted into Windows 10
#
# What it does:
#   1. Installs Tailscale (mesh VPN)
#   2. Enables & starts OpenSSH Server
#   3. Enables Remote Desktop (RDP)
#   4. Disables sleep and hibernation
#   5. Configures Windows Firewall for Tailscale
#
# Usage:
#   Run PowerShell as Administrator, then:
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\setup-windows.ps1
#
# After running:
#   1. Open Tailscale from the system tray and sign in
#   2. Note your Tailscale IP (shown in Tailscale UI or: tailscale ip -4)
#   3. Update tailscale-ips.env with the IP
#   4. Test SSH from laptop: ssh adamh@<tailscale-ip>
#   5. Test RDP from laptop: mstsc /v:<tailscale-ip>
# =============================================================================

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

function Write-Info  { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }

Write-Info "Starting Windows remote access setup..."

# ---------------------------------------------------------------------------
# 1. Install Tailscale
# ---------------------------------------------------------------------------
Write-Info "Checking for Tailscale..."
$tailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"
if (Test-Path $tailscaleExe) {
    Write-Info "Tailscale already installed"
} else {
    Write-Info "Installing Tailscale via winget..."
    try {
        winget install --id Tailscale.Tailscale --accept-source-agreements --accept-package-agreements
        Write-Info "Tailscale installed — sign in from the system tray icon"
    } catch {
        Write-Warn "winget install failed. Please download Tailscale manually from https://tailscale.com/download"
    }
}

# ---------------------------------------------------------------------------
# 2. Enable OpenSSH Server
# ---------------------------------------------------------------------------
Write-Info "Setting up OpenSSH Server..."

# Check if OpenSSH Server is installed
$sshCapability = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'
if ($sshCapability.State -ne 'Installed') {
    Write-Info "Installing OpenSSH Server..."
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
} else {
    Write-Info "OpenSSH Server already installed"
}

# Start and enable the service
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
Write-Info "OpenSSH Server started and set to auto-start"

# Set default shell to PowerShell (better than cmd for remote use)
$regPath = "HKLM:\SOFTWARE\OpenSSH"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
New-ItemProperty -Path $regPath -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null
Write-Info "Default SSH shell set to PowerShell"

# Firewall rule for SSH
$sshRule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
if (-not $sshRule) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
    Write-Info "Firewall rule added for SSH (port 22)"
} else {
    Write-Info "SSH firewall rule already exists"
}

# ---------------------------------------------------------------------------
# 3. Enable Remote Desktop
# ---------------------------------------------------------------------------
Write-Info "Enabling Remote Desktop..."

# Enable RDP
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
    -Name "fDenyTSConnections" -Value 0

# Allow RDP through firewall
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

# Disable Network Level Authentication requirement (simpler connection)
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
    -Name "UserAuthentication" -Value 0

Write-Info "Remote Desktop enabled"

# ---------------------------------------------------------------------------
# 4. Disable sleep and hibernation
# ---------------------------------------------------------------------------
Write-Info "Disabling sleep and hibernation..."

# Set all power plans to never sleep
powercfg -change -standby-timeout-ac 0
powercfg -change -standby-timeout-dc 0
powercfg -change -monitor-timeout-ac 0
powercfg -change -monitor-timeout-dc 0

# Disable hibernation
powercfg -h off

Write-Info "Sleep and hibernation disabled"

# ---------------------------------------------------------------------------
# 5. Configure Windows Firewall for Tailscale
# ---------------------------------------------------------------------------
Write-Info "Configuring firewall for Tailscale..."

# Tailscale manages its own firewall rules, but ensure the Tailscale
# network profile is set to Private (allows more traffic)
$tailscaleAdapter = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*Tailscale*" }
if ($tailscaleAdapter) {
    try {
        Set-NetConnectionProfile -InterfaceIndex $tailscaleAdapter.ifIndex -NetworkCategory Private
        Write-Info "Tailscale adapter set to Private network profile"
    } catch {
        Write-Warn "Could not set Tailscale network profile — may need manual configuration"
    }
} else {
    Write-Warn "Tailscale adapter not found — configure after Tailscale is connected"
}

# ---------------------------------------------------------------------------
# Done!
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Info "Setup complete! Next steps:"
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Sign in to Tailscale (system tray icon)"
Write-Host ""
Write-Host "  2. Get your Tailscale IP:"
Write-Host "       tailscale ip -4"
Write-Host ""
Write-Host "  3. From your laptop, test SSH:"
Write-Host "       ssh $env:USERNAME@<tailscale-ip>"
Write-Host ""
Write-Host "  4. From your laptop, test RDP:"
Write-Host "       mstsc /v:<tailscale-ip>"
Write-Host ""
Write-Host "  5. IMPORTANT: Also do BIOS setup (restart and enter BIOS):"
Write-Host "       - Enable Wake-on-LAN"
Write-Host "       - Set 'Restore on AC Power Loss' to 'Power On'"
Write-Host ""
