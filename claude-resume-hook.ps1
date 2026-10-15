# Claude Code SessionStart hook (matcher "resume"), installed by harden-windows.ps1.
#
# When a session is resumed after a gap (reboot, crash, outage), Claude still
# thinks its background commands and monitors are running. This tells it
# they may be gone, so it checks before waiting on them.

$ErrorActionPreference = "SilentlyContinue"

$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
$transcript = $payload.transcript_path
if (-not $transcript -or -not (Test-Path $transcript)) { exit 0 }

$lastActivity = (Get-Item $transcript).LastWriteTime
$gap = (Get-Date) - $lastActivity
if ($gap.TotalMinutes -lt 10) { exit 0 }

$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$rebooted = $boot -gt $lastActivity

$why = if ($rebooted) {
    "The computer restarted at $($boot.ToString('yyyy-MM-dd HH:mm')), after this session's last activity at $($lastActivity.ToString('yyyy-MM-dd HH:mm'))."
} else {
    "This session was idle or disconnected for $([int]$gap.TotalMinutes) minutes (last activity $($lastActivity.ToString('yyyy-MM-dd HH:mm'))); its Claude process may have been restarted."
}

$context = "$why Background commands, monitors and subagents started before then may no longer be running, and a step may have been cut off mid-way. Before waiting on any of them, check which are actually still running, check git status and git log (another session may have committed meanwhile), then redo the interrupted step."

@{
    hookSpecificOutput = @{
        hookEventName     = "SessionStart"
        additionalContext = $context
    }
} | ConvertTo-Json -Compress
