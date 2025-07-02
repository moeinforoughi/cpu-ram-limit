#!/bin/bash
set -e

SERVICE_NAME="user-limiter"
SCRIPT_PATH="/usr/local/bin/main.sh"
LOG_DIR="/var/log/user-limiter"
LOGROTATE_FILE="/etc/logrotate.d/user-limiter"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SYSTEMD_TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"
CRON_FILE_GLOB="/etc/cron.d/cgroup_*"

read -p "🔐 This will remove all user limiter components. Proceed? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
  echo "❌ Uninstall cancelled."
  exit 0
fi

# Stop and disable timer
echo "🔄 Disabling systemd timer..."
systemctl stop "$SERVICE_NAME.timer" || true
systemctl disable "$SERVICE_NAME.timer" || true

# Remove systemd files
echo "📂 Removing systemd service and timer files..."
rm -f "$SYSTEMD_SERVICE_FILE" "$SYSTEMD_TIMER_FILE"
systemctl daemon-reload

# Remove script
echo "🔧 Removing user-limiter script..."
rm -f "$SCRIPT_PATH"

# Remove logs and logrotate
echo "📄 Cleaning logs..."
rm -rf "$LOG_DIR"
rm -f "$LOGROTATE_FILE"

# Remove leftover cron rules (cgroup v1)
echo "🔢 Cleaning up any per-user cron entries..."
rm -f $CRON_FILE_GLOB

echo "✅ Uninstall complete. All user limiter files and services have been removed."
exit 0
