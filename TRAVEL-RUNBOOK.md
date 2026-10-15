# Travel runbook: keeping the desktop's Claude sessions alive

The desktop runs Claude Code sessions that automate GUI apps on it, driven
from the laptop or phone over Remote Control. Here's how a session goes
offline, and what keeps that from happening or brings it back:

| What happens | What prevents it | What brings it back |
|---|---|---|
| Windows Update restarts | `harden-windows.ps1`: no auto-restart, active hours, `-PauseUpdatesDays` | Auto sign-in + watchdog |
| Power cut | UPS (optional) | BIOS "Restore on AC Power Loss" + auto sign-in + watchdog |
| Network drop under ~10 min | Ethernet, NIC power-off disabled | Remote Control reconnects on its own |
| Network drop over ~10 min | — | Server mode exits; watchdog restarts it when the internet is back |
| Restart boots into Ubuntu | Windows as the default boot entry | Nothing: Ubuntu isn't on the tailnet |
| Tailscale key expires | Key expiry disabled (it is, for DESKTOP-AGH04LJ) | — |
| Claude process crashes | — | Watchdog (server) or a message from a device (crashed session in server mode) |

## One-time setup (at the desktop)

1. **BIOS**: "Restore on AC Power Loss" = Power On. Make Windows the default
   boot entry (GRUB `GRUB_DEFAULT`, or the firmware boot order).
2. **Auto sign-in**: download Sysinternals Autologon from Microsoft, run it,
   and enter your password into it. It stores the password encrypted, not in
   plain text. GUI automation needs an unlocked, signed-in desktop, so this is
   what makes recovery work. The tradeoff: anyone at the keyboard after a
   reboot is signed in as you.
   If you sign in with a Microsoft account and Windows Hello only, first turn off
   "For improved security, only allow Windows Hello sign-in" in Settings > Accounts > Sign-in options.
3. **Claude Code CLI** on Windows (the watchdog uses `claude.exe`, not the
   desktop app). Check with `claude --version`.
4. Copy `rc-projects.example.json` to `rc-projects.json` and list the project
   folders the watchdog should serve. Per project:
   - `spawn`: `worktree` gives each session from your phone its own git
     worktree, so two sessions can't commit under each other. Use `same-dir`
     for folders that aren't git repos.
   - `permissionMode`: optional, e.g. `acceptEdits`.
   - `heartbeatUrl` (top level, optional): a healthchecks.io ping URL. The
     watchdog pings it every 5 minutes while online, and healthchecks.io emails
     you when the pings stop. That's how you learn the desktop is down before
     you need it.
5. **Answer the first-run prompts by hand.** In each folder listed in
   `rc-projects.json`, run `claude remote-control` once, answer `y` to
   `Trust <directory>?` and `Enable Remote Control?`, then Ctrl+C. The
   watchdog can't answer these prompts. A server stuck waiting at one looks
   healthy to it, so nothing gets served.
6. In an admin PowerShell in this folder:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   .\harden-windows.ps1
   ```
   It prints what's left to do by hand.

## Desktop app vs. CLI server mode

Sessions you start in the **Claude desktop app** reconnect by themselves after
a network drop. After a reboot, though, someone has to open the app and click
the session, which can only happen over RustDesk.

Sessions served by the **watchdog** (`claude remote-control` in a console
window per project) come back after a reboot with nobody touching anything,
as long as auto sign-in works. Within about 4 hours of going down, they come
back as the same session on claude.ai. Start them from claude.ai/code or the
Claude app: pick the desktop's server in the session list and start a new session.

**For long or overnight work while you're away, start it from the watchdog's
server, not the desktop app**, as long as your GUI tools work there (see test
step 6).

## Before you leave

```powershell
.\harden-windows.ps1 -PauseUpdatesDays 21
```
If it says a restart is pending, restart now while you're home.

### Test before you leave
1. Restart the desktop and don't touch it.
2. From the laptop, check that it's back: `tailscale status` shows it online and
   SSH works.
3. On your phone, check that claude.ai/code lists the desktop's sessions with a
   green dot.
4. Read the log: `%LOCALAPPDATA%\claude-rc-watchdog\watchdog.log`. It should
   show one `started remote-control` line per project, not a new one every
   30 seconds.
5. About a minute after sign-in, check that each tracked server is still
   the process the watchdog started, and that there's only one per folder:
   ```powershell
   Get-ChildItem $env:LOCALAPPDATA\claude-rc-watchdog\*.pid | ForEach-Object { Get-Process -Id (Get-Content $_) }
   ```
   If those PIDs are gone while claude windows are still open, `claude.exe`
   is handing off to a child process. The watchdog would then keep starting
   duplicate servers, so stop it (create the `paused` file) and tell Claude.
6. In a session started from the watchdog's server, confirm your GUI
   automation tools still work (MCP servers, computer use, anything
   configured only in the desktop app). If they don't, keep that work in the
   desktop app and rely on auto sign-in plus RustDesk to reopen it.
7. Resume a session that's been idle for 10+ minutes and check that Claude
   mentions the resume note. If it doesn't, the hook isn't firing on
   resume. That's harmless, but then you have to give the reminder yourself.

## When a session goes offline anyway

1. `tailscale status` on the laptop. If the desktop shows offline, it's
   powered off, stuck at boot, or in Ubuntu. You can't fix that remotely;
   ask someone at home to power-cycle it.
2. If it's online but the session isn't: SSH or RustDesk in and read
   `watchdog.log`. To restart one server by hand, in its project folder:
   `claude remote-control` (restores all its sessions) or
   `claude remote-control --session-id <id>` (one session). The id is the part
   of the claude.ai/code URL after `/code/`.
3. A desktop-app session: open the Claude app on the desktop and click it.
4. When the session is back, the resume hook (`claude-resume-hook.ps1`) tells
   Claude its background tasks may be gone. Still say what it was doing:
   > You were interrupted mid-"<step>". Background tasks and monitors are gone.
   > Check git status/log, redo that step, and don't rerun long suites that already finished.

## Stopping the watchdog

- Pause: create `%LOCALAPPDATA%\claude-rc-watchdog\paused` (delete it to resume).
- Remove: `Unregister-ScheduledTask ClaudeRCWatchdog`
