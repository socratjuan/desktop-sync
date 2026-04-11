#!/usr/bin/env bash
# =============================================================================
# setup-ubuntu.sh — Run this on your desktop while booted into Ubuntu
#
# What it does:
#   1. Installs Tailscale (mesh VPN — no port forwarding needed)
#   2. Installs & enables OpenSSH server
#   3. Installs & configures xRDP (remote GUI via RDP client)
#   4. Installs tmux (persistent terminal sessions for Claude Code)
#   5. Disables sleep/suspend/hibernate
#   6. Configures UFW firewall to allow Tailscale traffic
#
# Usage:
#   chmod +x setup-ubuntu.sh
#   sudo ./setup-ubuntu.sh
#
# After running:
#   1. Run `tailscale up` and authenticate in your browser
#   2. Note your Tailscale IP: `tailscale ip -4`
#   3. Update tailscale-ips.env with the IP
#   4. Test SSH from your laptop: ssh adamh@<tailscale-ip>
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Must run as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root. Use: sudo ./setup-ubuntu.sh"
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

info "Setting up remote access for user: $REAL_USER"

# ---------------------------------------------------------------------------
# 1. Install Tailscale
# ---------------------------------------------------------------------------
info "Installing Tailscale..."
if command -v tailscale &>/dev/null; then
    info "Tailscale already installed, skipping"
else
    curl -fsSL https://tailscale.com/install.sh | sh
    info "Tailscale installed"
fi

systemctl enable --now tailscaled
info "Tailscale daemon enabled and started"
echo ""
info ">>> Run 'sudo tailscale up' after this script finishes to authenticate <<<"
echo ""

# ---------------------------------------------------------------------------
# 2. Install & enable OpenSSH server
# ---------------------------------------------------------------------------
info "Installing OpenSSH server..."
apt-get update -qq
apt-get install -y openssh-server

systemctl enable --now ssh
info "SSH server enabled and running"

# Harden SSH: disable password auth if key exists, keep it if not
SSH_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$REAL_HOME/.ssh/authorized_keys" ]] && [[ -s "$REAL_HOME/.ssh/authorized_keys" ]]; then
    info "Found authorized_keys — disabling password authentication for security"
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    systemctl reload ssh
else
    warn "No authorized_keys found — keeping password auth enabled for now"
    warn "Copy your laptop's SSH key later: ssh-copy-id $REAL_USER@<tailscale-ip>"
fi

# ---------------------------------------------------------------------------
# 3. Install & configure xRDP (for GUI remote access)
# ---------------------------------------------------------------------------
info "Installing xRDP for remote desktop..."
apt-get install -y xrdp

# Add xrdp user to ssl-cert group (needed for TLS)
usermod -aG ssl-cert xrdp

# Configure GNOME session for xRDP
XSESSION_FILE="$REAL_HOME/.xsessionrc"
cat > "$XSESSION_FILE" << 'XSESSION'
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
export XDG_SESSION_DESKTOP=ubuntu
export XDG_CONFIG_DIRS=/etc/xdg/xdg-ubuntu:/etc/xdg
XSESSION
chown "$REAL_USER:$REAL_USER" "$XSESSION_FILE"

# Fix the polkit authentication prompt issue with xRDP + GNOME
POLKIT_FILE="/etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla"
mkdir -p "$(dirname "$POLKIT_FILE")"
cat > "$POLKIT_FILE" << 'POLKIT'
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
POLKIT

systemctl enable --now xrdp
info "xRDP enabled and running (port 3389)"

# ---------------------------------------------------------------------------
# 4. Install tmux (persistent sessions for Claude Code)
# ---------------------------------------------------------------------------
info "Installing tmux..."
apt-get install -y tmux

# Create a nice tmux config for the user
TMUX_CONF="$REAL_HOME/.tmux.conf"
if [[ ! -f "$TMUX_CONF" ]]; then
    cat > "$TMUX_CONF" << 'TMUX'
# Keep plenty of scrollback
set -g history-limit 50000

# Mouse support (useful over RDP)
set -g mouse on

# Start window numbering at 1
set -g base-index 1

# Reduce escape time (better for SSH)
set -sg escape-time 10

# Status bar
set -g status-style 'bg=#333333 fg=#ffffff'
set -g status-right '#H | %Y-%m-%d %H:%M'
TMUX
    chown "$REAL_USER:$REAL_USER" "$TMUX_CONF"
    info "Created tmux config at $TMUX_CONF"
fi

# ---------------------------------------------------------------------------
# 5. Disable sleep/suspend/hibernate
# ---------------------------------------------------------------------------
info "Disabling sleep, suspend, and hibernate..."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
info "Sleep/suspend/hibernate disabled"

# ---------------------------------------------------------------------------
# 6. Configure UFW firewall
# ---------------------------------------------------------------------------
if command -v ufw &>/dev/null; then
    info "Configuring UFW firewall..."
    # Allow all traffic from Tailscale interface
    ufw allow in on tailscale0
    # Allow SSH and RDP explicitly as well
    ufw allow 22/tcp comment "SSH"
    ufw allow 3389/tcp comment "xRDP"
    # Enable UFW if not already
    ufw --force enable
    info "Firewall configured — Tailscale, SSH, and RDP allowed"
else
    warn "UFW not found — skipping firewall configuration"
fi

# ---------------------------------------------------------------------------
# Done!
# ---------------------------------------------------------------------------
echo ""
echo "============================================="
info "Setup complete! Next steps:"
echo "============================================="
echo ""
echo "  1. Authenticate Tailscale:"
echo "       sudo tailscale up"
echo ""
echo "  2. Get your Tailscale IP:"
echo "       tailscale ip -4"
echo ""
echo "  3. From your laptop, test SSH:"
echo "       ssh $REAL_USER@<tailscale-ip>"
echo ""
echo "  4. From your laptop, test RDP:"
echo "       Open Remote Desktop Connection → enter <tailscale-ip>"
echo ""
echo "  5. Start a persistent Claude Code session:"
echo "       tmux new -s claude"
echo "       claude"
echo "       # Detach: Ctrl+B, then D"
echo "       # Reattach: tmux attach -t claude"
echo ""
