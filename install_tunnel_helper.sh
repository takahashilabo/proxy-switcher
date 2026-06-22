#!/bin/bash
#
# One-time setup for Proxy Switcher's "Full tunnel" (TUN) mode.
#
# Installs a small root helper and a sudoers rule so the menu bar app can
# start/stop the sing-box tunnel WITHOUT prompting for a password each time.
#
# Usage:  sudo ./install_tunnel_helper.sh
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo:  sudo ./install_tunnel_helper.sh" >&2
  exit 1
fi

# The user who will control the tunnel (the one who ran sudo).
REAL_USER="${SUDO_USER:-$(logname)}"
USER_HOME="$(eval echo "~${REAL_USER}")"
SINGBOX_BIN="$(command -v sing-box || echo /opt/homebrew/bin/sing-box)"
CONF="${USER_HOME}/.config/sing-box/proxy-switcher.json"
HELPER="/usr/local/bin/proxy-tunnel"
SUDOERS="/etc/sudoers.d/proxy-switcher-tunnel"

if [ ! -x "$SINGBOX_BIN" ]; then
  echo "sing-box not found. Install it first:  brew install sing-box" >&2
  exit 1
fi

echo "==> Installing helper: ${HELPER}"
mkdir -p /usr/local/bin
cat > "$HELPER" <<EOF
#!/bin/bash
# Managed by Proxy Switcher. Starts/stops the sing-box TUN tunnel.
set -euo pipefail
BIN="${SINGBOX_BIN}"
CONF="${CONF}"
LOG="/var/log/proxy-tunnel.log"
PIDFILE="/var/run/proxy-tunnel.pid"

stop() {
  pkill -f "\${BIN} run -c \${CONF}" 2>/dev/null || true
  rm -f "\${PIDFILE}"
}

case "\${1:-}" in
  start)
    stop
    [ -f "\${CONF}" ] || { echo "config not found: \${CONF}" >&2; exit 1; }
    nohup "\${BIN}" run -c "\${CONF}" >"\${LOG}" 2>&1 &
    echo \$! > "\${PIDFILE}"
    echo "tunnel started (pid \$!)"
    ;;
  stop)
    stop
    echo "tunnel stopped"
    ;;
  status)
    if pgrep -f "\${BIN} run -c \${CONF}" >/dev/null; then echo running; else echo stopped; fi
    ;;
  *)
    echo "usage: proxy-tunnel {start|stop|status}" >&2; exit 2 ;;
esac
EOF
chmod 755 "$HELPER"

echo "==> Installing sudoers rule: ${SUDOERS}"
cat > "$SUDOERS" <<EOF
# Allow ${REAL_USER} to control the Proxy Switcher tunnel without a password.
${REAL_USER} ALL=(root) NOPASSWD: ${HELPER} start, ${HELPER} stop, ${HELPER} status
EOF
chmod 440 "$SUDOERS"

# Validate sudoers syntax; remove the file if invalid to avoid breaking sudo.
if ! visudo -cf "$SUDOERS" >/dev/null; then
  echo "sudoers validation failed — removing ${SUDOERS}" >&2
  rm -f "$SUDOERS"
  exit 1
fi

echo ""
echo "Done. Enable 'Route ALL apps through proxy (TUN tunnel)' on a SOCKS/HTTP rule"
echo "in Proxy Switcher → Settings. The tunnel will start/stop automatically."
echo ""
echo "To uninstall:  sudo rm ${HELPER} ${SUDOERS}"
