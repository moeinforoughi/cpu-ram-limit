#!/bin/bash
set -e

SCRIPT_DIR="$(dirname \"$(realpath "$0")")"
API_URL="http://your.api.endpoint"  # <-- UPDATE THIS URL
SCRIPT_SOURCE="$SCRIPT_DIR/apply_user_limits.sh"
SCRIPT_TARGET="/usr/local/bin/apply_user_limits.sh"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/user_limit_sync.log"
LOGROTATE_FILE="/etc/logrotate.d/user-limiter"

# Step 1: Dependencies
echo "🔧 Installing required packages..."
apt-get update -qq
apt-get install -y curl jq cron cgroup-tools > /dev/null 2>&1 || true

# Step 2: Setup log directory
echo "🛠️ Creating log directory..."
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
chown root:root "$LOG_FILE"

# Step 3: Copy script (backup if exists)
echo "📂 Copying main sync script to: $SCRIPT_TARGET"
if [[ -f "$SCRIPT_TARGET" ]]; then
  cp "$SCRIPT_TARGET" "$SCRIPT_TARGET.bak.$(date +%s)"
fi
cp "$SCRIPT_SOURCE" "$SCRIPT_TARGET"
chmod +x "$SCRIPT_TARGET"

# Step 4: systemd service + timer
echo "⚙️ Creating systemd unit files..."
cat <<EOF > /etc/systemd/system/user-limiter.service
[Unit]
Description=Apply user CPU and RAM limits
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_TARGET
EOF

cat <<EOF > /etc/systemd/system/user-limiter.timer
[Unit]
Description=Run user-limiter every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=60
Unit=user-limiter.service

[Install]
WantedBy=timers.target
EOF

# Step 5: Enable and start
echo "🔄 Enabling systemd timer..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now user-limiter.timer

# Step 6: Add logrotate config (optional but helpful)
echo "📅 Setting up log rotation..."
cat <<EOF > "$LOGROTATE_FILE"
$LOG_FILE {
  weekly
  rotate 4
  compress
  missingok
  notifempty
  create 644 root root
}
EOF

echo "✅ Setup complete. Limits will sync every minute."
echo "📄 Logs available at: $LOG_FILE"
