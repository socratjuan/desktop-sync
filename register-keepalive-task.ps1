# Register a scheduled task that runs the WSL keepalive at user logon
# Replaces the old StartWSLSSH task

# Stop and unregister existing tasks
Unregister-ScheduledTask -TaskName "StartWSLSSH" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "WSLKeepalive" -Confirm:$false -ErrorAction SilentlyContinue

# Get current user (so the task runs as the logged-in user, not SYSTEM)
# Use COMPUTERNAME\USER format which is what Task Scheduler expects on workgroup machines
$currentUser = "$env:COMPUTERNAME\$env:USERNAME"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Users\adamh\wsl-keepalive.ps1"

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser

$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 365)

Register-ScheduledTask -TaskName "WSLKeepalive" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force

# Start it now
Start-ScheduledTask -TaskName "WSLKeepalive"

Start-Sleep -Seconds 3
Write-Host "Task state:"
Get-ScheduledTask -TaskName "WSLKeepalive" | Select-Object TaskName, State

Write-Host ""
Write-Host "Keepalive processes running:"
$procs = Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*wsl-keepalive*" }
if ($procs) {
    $procs | ForEach-Object { Write-Host "  PID $($_.ProcessId)" }
} else {
    Write-Host "  NONE"
}
