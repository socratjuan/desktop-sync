# Keeps WSL Ubuntu alive AND keeps the port proxy fresh.
# The port proxy from Windows -> WSL gets stale across distro suspend/resume,
# so we delete & re-add it each tick. This is cheap.

while ($true) {
    try {
        # Touch WSL so it doesn't suspend
        $wslIp = (wsl.exe -d Ubuntu hostname -I 2>&1).Trim().Split(" ")[0]

        if ($wslIp -and $wslIp -match "^\d+\.\d+\.\d+\.\d+$") {
            # Refresh port proxy in case WSL IP changed or proxy went stale
            netsh interface portproxy delete v4tov4 listenport=2222 listenaddress=0.0.0.0 2>$null | Out-Null
            netsh interface portproxy add v4tov4 listenport=2222 listenaddress=0.0.0.0 connectport=2222 connectaddress=$wslIp 2>$null | Out-Null

            # Make sure sshd is running inside WSL (idempotent)
            wsl.exe -d Ubuntu -u root bash -c "pgrep -f 'sshd.*-f /etc/ssh/sshd_config' >/dev/null || (mkdir -p /run/sshd && /usr/sbin/sshd -f /etc/ssh/sshd_config)" 2>&1 | Out-Null
        }
    } catch {
        # Ignore and continue
    }
    Start-Sleep -Seconds 15
}
