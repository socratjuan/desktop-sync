#!/usr/bin/env bash
# =============================================================================
# connect.sh — Run this from your LAPTOP to connect to your desktop
#
# Usage:
#   ./connect.sh              # Interactive menu
#   ./connect.sh ssh ubuntu   # SSH directly to Ubuntu
#   ./connect.sh ssh windows  # SSH directly to Windows
#   ./connect.sh rdp ubuntu   # RDP to Ubuntu
#   ./connect.sh rdp windows  # RDP to Windows
#   ./connect.sh claude       # SSH to Ubuntu + auto-attach tmux claude session
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/tailscale-ips.env"

# Load IPs from env file
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: $ENV_FILE not found. Copy tailscale-ips.env and fill in your IPs."
    exit 1
fi
source "$ENV_FILE"

# Validate IPs are set
validate_ip() {
    local ip="$1" name="$2"
    if [[ "$ip" == "100.x.x.x" || -z "$ip" ]]; then
        echo "Error: $name is not set in $ENV_FILE"
        echo "Run 'tailscale ip -4' on that machine and update the file."
        exit 1
    fi
}

ssh_ubuntu() {
    validate_ip "$DESKTOP_UBUNTU_IP" "DESKTOP_UBUNTU_IP"
    echo "Connecting to Ubuntu via SSH ($DESKTOP_UBUNTU_IP)..."
    ssh "${UBUNTU_USER}@${DESKTOP_UBUNTU_IP}"
}

ssh_windows() {
    validate_ip "$DESKTOP_WINDOWS_IP" "DESKTOP_WINDOWS_IP"
    echo "Connecting to Windows via SSH ($DESKTOP_WINDOWS_IP)..."
    ssh "${WINDOWS_USER}@${DESKTOP_WINDOWS_IP}"
}

rdp_ubuntu() {
    validate_ip "$DESKTOP_UBUNTU_IP" "DESKTOP_UBUNTU_IP"
    echo "Launching RDP to Ubuntu ($DESKTOP_UBUNTU_IP)..."
    if command -v mstsc.exe &>/dev/null; then
        mstsc.exe /v:"${DESKTOP_UBUNTU_IP}"
    elif command -v xfreerdp &>/dev/null; then
        xfreerdp /v:"${DESKTOP_UBUNTU_IP}" /u:"${UBUNTU_USER}" /dynamic-resolution
    else
        echo "No RDP client found. Install freerdp or use Windows Remote Desktop Connection."
        echo "Connect to: ${DESKTOP_UBUNTU_IP}"
    fi
}

rdp_windows() {
    validate_ip "$DESKTOP_WINDOWS_IP" "DESKTOP_WINDOWS_IP"
    echo "Launching RDP to Windows ($DESKTOP_WINDOWS_IP)..."
    if command -v mstsc.exe &>/dev/null; then
        mstsc.exe /v:"${DESKTOP_WINDOWS_IP}"
    elif command -v xfreerdp &>/dev/null; then
        xfreerdp /v:"${DESKTOP_WINDOWS_IP}" /u:"${WINDOWS_USER}" /dynamic-resolution
    else
        echo "No RDP client found. Use Windows Remote Desktop Connection."
        echo "Connect to: ${DESKTOP_WINDOWS_IP}"
    fi
}

claude_session() {
    validate_ip "$DESKTOP_UBUNTU_IP" "DESKTOP_UBUNTU_IP"
    echo "Connecting to Claude Code session on Ubuntu..."
    echo "(Will create or reattach to tmux session 'claude')"
    ssh -t "${UBUNTU_USER}@${DESKTOP_UBUNTU_IP}" \
        "tmux new-session -A -s claude"
}

# Handle direct command-line arguments
if [[ $# -ge 1 ]]; then
    case "$1" in
        claude)
            claude_session
            exit 0
            ;;
        ssh)
            case "${2:-}" in
                ubuntu|linux) ssh_ubuntu ;;
                windows|win)  ssh_windows ;;
                *) echo "Usage: $0 ssh [ubuntu|windows]"; exit 1 ;;
            esac
            exit 0
            ;;
        rdp)
            case "${2:-}" in
                ubuntu|linux) rdp_ubuntu ;;
                windows|win)  rdp_windows ;;
                *) echo "Usage: $0 rdp [ubuntu|windows]"; exit 1 ;;
            esac
            exit 0
            ;;
    esac
fi

# Interactive menu
echo "=== Desktop Remote Connect ==="
echo ""
echo "  1) SSH → Ubuntu"
echo "  2) SSH → Windows"
echo "  3) RDP → Ubuntu (GUI)"
echo "  4) RDP → Windows (GUI)"
echo "  5) Claude Code session (Ubuntu + tmux)"
echo ""
read -rp "Choose [1-5]: " choice

case "$choice" in
    1) ssh_ubuntu ;;
    2) ssh_windows ;;
    3) rdp_ubuntu ;;
    4) rdp_windows ;;
    5) claude_session ;;
    *) echo "Invalid choice"; exit 1 ;;
esac
