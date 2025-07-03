#!/bin/bash
set -e

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
API_URL="http://your.api.endpoint"  # <-- UPDATE THIS URL
SCRIPT_SOURCE="$SCRIPT_DIR/main.sh"
SCRIPT_TARGET="/usr/local/bin/main.sh"
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

# Step 3: Prepare and patch main script
echo "📂 Preparing main sync script..."
if [[ -f "$SCRIPT_TARGET" ]]; then
  cp "$SCRIPT_TARGET" "$SCRIPT_TARGET.bak.$(date +%s)"
fi

# Patch the log path in main.sh before copying
PATCHED_MAIN="$SCRIPT_DIR/main.tmp.sh"
cp "$SCRIPT_SOURCE" "$PATCHED_MAIN"

ABS_LOG_FILE="$LOG_FILE"
sed -i "s|^LOG_FILE=.*|LOG_FILE=\"$ABS_LOG_FILE\"|" "$PATCHED_MAIN"

cp "$PATCHED_MAIN" "$SCRIPT_TARGET"
chmod +x "$SCRIPT_TARGET"
rm "$PATCHED_MAIN"

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

# Step 2.5: Setup cron cleanup (truncate log at 2:00 AM daily)
echo "🧹 Setting up daily log cleanup at 2:00 AM..."
CRON_CLEAN_LINE="0 2 * * * root truncate -s 0 \"$LOG_FILE\""
CRON_CLEAN_FILE="/etc/cron.d/user-limiter-log-cleanup"
echo "$CRON_CLEAN_LINE" > "$CRON_CLEAN_FILE"
chmod 644 "$CRON_CLEAN_FILE"

echo "✅ Setup complete. Limits will sync every minute."
echo "📄 Logs available at: $LOG_FILE"
