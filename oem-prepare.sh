#!/usr/bin/env bash
# =====================================================================
#  oem-prepare.sh  —  Prepare Ubuntu Desktop for end-user delivery
#
#  1) Fully updates the system (apt + snap + flatpak)
#  2) Makes sure gnome-initial-setup (Welcome wizard) is installed/enabled
#  3) Installs a ONE-SHOT boot service that, on the next boot and
#     BEFORE the login screen appears, deletes the "oem" user and
#     cleans up. Then the Welcome screen appears so the customer
#     creates their own account.
#
#  No more GRUB editing / init=/bin/bash needed.
#
#  Usage (logged in as oem):
#      sudo bash oem-prepare.sh
#  Options:
#      --user NAME     temporary user to remove (default: oem)
#      --clone         also reset machine-id & SSH host keys
#                      (use if this disk will be cloned to other PCs)
#      --no-reboot     don't reboot automatically at the end
#      --version       print script version
# =====================================================================
set -euo pipefail

VERSION="1.0.0"
OEM_USER="oem"
CLONE=0
DO_REBOOT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) OEM_USER="$2"; shift 2 ;;
    --clone) CLONE=1; shift ;;
    --no-reboot) DO_REBOOT=0; shift ;;
    --version) echo "oem-prepare.sh $VERSION"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

log()  { echo -e "\e[1;32m[+]\e[0m $*"; }
warn() { echo -e "\e[1;33m[!]\e[0m $*"; }
die()  { echo -e "\e[1;31m[x]\e[0m $*"; exit 1; }

# ---------------------------------------------------------------- checks
[[ $EUID -eq 0 ]] || die "Run with sudo:  sudo bash $0"
[[ "$OEM_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid user name: '$OEM_USER'"
id "$OEM_USER" &>/dev/null || die "User '$OEM_USER' does not exist."
OEM_UID=$(id -u "$OEM_USER")
[[ $OEM_UID -ge 1000 && $OEM_UID -lt 65000 ]] || die "'$OEM_USER' (uid $OEM_UID) is not a regular user — refusing to delete it."

OTHER_USERS=$(awk -F: -v u="$OEM_USER" '$3>=1000 && $3<65000 && $1!=u {print $1}' /etc/passwd)
[[ -z "$OTHER_USERS" ]] || die "Other regular users exist: $OTHER_USERS
The Welcome wizard only runs when NO regular users exist. Remove them first."

dpkg -s gdm3 &>/dev/null || die "gdm3 is not installed (this script is for Ubuntu Desktop / GNOME)."

APT="apt-get -y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------- updates
log "Updating package lists..."
$APT update

log "Upgrading all packages (full-upgrade)..."
$APT full-upgrade

log "Installing gnome-initial-setup..."
$APT install gnome-initial-setup

if command -v snap &>/dev/null; then
  log "Refreshing snaps..."
  snap refresh || warn "snap refresh failed (continuing)"
fi
if command -v flatpak &>/dev/null; then
  log "Updating flatpaks..."
  flatpak update -y --noninteractive || warn "flatpak update failed (continuing)"
fi
if command -v fwupdmgr &>/dev/null; then
  log "Checking firmware updates (non-fatal)..."
  fwupdmgr refresh --force &>/dev/null || true
  fwupdmgr update -y --no-reboot-check &>/dev/null || true
fi

log "Removing unused packages..."
$APT autoremove --purge

# ---------------------------------------------------------------- GDM config
log "Setting graphical target..."
systemctl set-default graphical.target >/dev/null

CONF=/etc/gdm3/custom.conf
if [[ -f $CONF ]]; then
  cp -a "$CONF" "$CONF.bak-oem"
  # remove auto-login and anything that disables initial setup
  sed -i -E '/^[[:space:]]*(AutomaticLoginEnable|AutomaticLogin|TimedLoginEnable|TimedLogin|TimedLoginDelay|InitialSetupEnable)[[:space:]]*=/d' "$CONF"
  log "Cleaned $CONF (backup: $CONF.bak-oem)"
fi

# ---------------------------------------------------------------- first-boot job
log "Installing one-shot cleanup service..."
cat > /usr/local/sbin/oem-finalize.sh <<EOF
#!/usr/bin/env bash
# Runs once at boot (before GDM): removes the OEM user, then disables itself.
exec >>/var/log/oem-finalize.log 2>&1
echo "==== \$(date) oem-finalize start ===="
U="$OEM_USER"
CLONE=$CLONE

pkill -KILL -u "\$U" 2>/dev/null || true
loginctl terminate-user "\$U" 2>/dev/null || true
sleep 1

userdel -r "\$U" 2>&1 || userdel -f -r "\$U" 2>&1 || echo "userdel failed"
rm -rf "/home/\$U" "/var/lib/AccountsService/users/\$U" "/var/lib/AccountsService/icons/\$U" \\
       "/var/mail/\$U" "/var/spool/cron/crontabs/\$U" "/etc/sudoers.d/\$U" 2>/dev/null || true

# make sure the Welcome wizard is allowed to run again
rm -f /var/lib/gdm3/.config/gnome-initial-setup-done 2>/dev/null || true

if [[ \$CLONE -eq 1 && -d /etc/ssh ]]; then
  echo "Regenerating SSH host keys"
  rm -f /etc/ssh/ssh_host_*
  ssh-keygen -A
fi

echo "Remaining regular users:"
awk -F: '\$3>=1000 && \$3<65000 {print \$1}' /etc/passwd
ls -la /home

# no daemon-reload here (risky from inside a running unit during boot);
# ConditionPathExists already prevents it from ever running again.
systemctl disable oem-finalize.service
rm -f /etc/systemd/system/oem-finalize.service /usr/local/sbin/oem-finalize.sh
sync
echo "==== \$(date) oem-finalize done ===="
EOF
chmod 700 /usr/local/sbin/oem-finalize.sh

cat > /etc/systemd/system/oem-finalize.service <<'EOF'
[Unit]
Description=Remove OEM user before first customer login
After=local-fs.target systemd-user-sessions.service
Before=display-manager.service gdm.service
ConditionPathExists=/usr/local/sbin/oem-finalize.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/oem-finalize.sh
RemainAfterExit=no
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable oem-finalize.service >/dev/null

# ---------------------------------------------------------------- cleanup
log "Cleaning caches and logs..."
$APT clean
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
journalctl --rotate &>/dev/null || true
journalctl --vacuum-time=1s &>/dev/null || true
rm -f "/home/$OEM_USER/.bash_history" /root/.bash_history 2>/dev/null || true

if [[ $CLONE -eq 1 ]]; then
  # empty machine-id => systemd generates a fresh one on the first boot of each clone
  log "Clearing machine-id (a new one is generated on first boot)..."
  : > /etc/machine-id
  rm -f /var/lib/dbus/machine-id
  ln -sf /etc/machine-id /var/lib/dbus/machine-id
fi

if compgen -G "/etc/NetworkManager/system-connections/*" >/dev/null; then
  warn "Saved network connections (incl. Wi-Fi passwords) will remain for the customer:"
  ls /etc/NetworkManager/system-connections/
  warn "Remove them if needed:  sudo rm /etc/NetworkManager/system-connections/*"
fi

echo
log "Done. On next boot the '$OEM_USER' user is deleted automatically,"
log "then the Ubuntu Welcome screen will ask the customer to create an account."
log "Log of that step: /var/log/oem-finalize.log"
echo

if [[ $DO_REBOOT -eq 1 ]]; then
  read -r -p "Reboot now? [Y/n] " a </dev/tty || a=Y
  [[ "${a:-Y}" =~ ^[Nn]$ ]] || { sync; systemctl reboot; }
else
  warn "Reboot manually when ready:  sudo reboot"
fi
