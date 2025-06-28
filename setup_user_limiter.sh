#!/bin/bash
set -e

API_URL=""
SCRIPT_SOURCE="./apply_user_limits.sh"
SCRIPT_TARGET="/usr/local/bin/apply_user_limits.sh"
LOG_DIR="/var/log/user-limiter"
LOG_FILE="$LOG_DIR/user_limit_sync.log"

# Step 1: Dependencies
echo "🔧 Installing required packages..."
apt-get update -qq
apt-get install -y curl jq cron cgroup-tools > /dev/null 2>&1 || true

# Step 2: Setup log directory
echo "🛠️ Creating log directory..."
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Step 3: Copy script
echo "📂 Copying main sync script to: $SCRIPT_TARGET"
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

echo "✅ Setup complete. Limits will sync every minute."
echo "📄 Logs available at: $LOG_FILE"
