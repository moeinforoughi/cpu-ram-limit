#!/bin/bash
set -e

### CONFIG ###
API_URL="http://192.168.4.2:8081/core/node/directadmin/:token/config"
SCRIPT_PATH="/usr/local/bin/apply_user_limits.sh"
LOG_DIR="/var/log/user-limiter"
LOG_FILE="$LOG_DIR/user_limit_sync.log"
CRON_TAG="# USER RESOURCE LIMIT SYNC"

### Step 1: Install Dependencies ###
echo "🔧 Installing required packages..."
apt-get update -qq
apt-get install -y curl jq cron cgroup-tools >/dev/null 2>&1 || true

### Step 2: Create Script Directory and Log File ###
echo "🛠️ Creating script and log paths..."
mkdir -p "$(dirname "$SCRIPT_PATH")"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

### Step 3: Write Main Sync Script ###
cat <<EOF > "$SCRIPT_PATH"
#!/bin/bash
API_URL="$API_URL"
LOG_FILE="$LOG_FILE"
PERIOD=100000
TMP_JSON="/tmp/user_limits.json"

echo "[\$(date)] 🔄 Syncing user resource limits from API..." >> "\$LOG_FILE"

command -v curl >/dev/null || { echo "❌ curl not installed" >> "\$LOG_FILE"; exit 1; }
command -v jq >/dev/null || { echo "❌ jq not installed" >> "\$LOG_FILE"; exit 1; }

if ! curl -s --fail "\$API_URL" -o "\$TMP_JSON"; then
  echo "❌ Failed to fetch data from API" >> "\$LOG_FILE"
  exit 1
fi

CGROUP_VERSION=1
mount | grep -q "cgroup2 on /sys/fs/cgroup" && CGROUP_VERSION=2
TOTAL_CPUS=\$(nproc)

jq -c '.[]' "\$TMP_JSON" | while read -r item; do
  USER=\$(echo "\$item" | jq -r '.user')
  MEM_MB=\$(echo "\$item" | jq -r '.mem // empty')
  CPU_CORES=\$(echo "\$item" | jq -r '.cpu // empty')

  [[ -z "\$USER" || -z "\$MEM_MB" || -z "\$CPU_CORES" ]] && {
    echo "⚠️ Skipping invalid entry: \$item" >> "\$LOG_FILE"
    continue
  }

  id "\$USER" &>/dev/null || {
    echo "⚠️ Skipping non-existent user: \$USER" >> "\$LOG_FILE"
    continue
  }

  CGROUP_NAME="limit_\$USER"
  echo "➡️ Applying limits for \$USER (CPU: \$CPU_CORES, RAM: \$MEM_MB MB)" >> "\$LOG_FILE"

  if [[ "\$CGROUP_VERSION" == "1" ]]; then
    mkdir -p /sys/fs/cgroup/cpu /sys/fs/cgroup/memory
    mountpoint -q /sys/fs/cgroup/cpu || mount -t cgroup -o cpu cpu /sys/fs/cgroup/cpu
    mountpoint -q /sys/fs/cgroup/memory || mount -t cgroup -o memory memory /sys/fs/cgroup/memory
    cgcreate -g "cpu,memory:/\$CGROUP_NAME" 2>/dev/null || true

    QUOTA=\$(( CPU_CORES * PERIOD ))
    cgset -r memory.limit_in_bytes=\$((MEM_MB * 1024 * 1024)) \$CGROUP_NAME
    cgset -r cpu.cfs_period_us=\$PERIOD \$CGROUP_NAME
    cgset -r cpu.cfs_quota_us=\$QUOTA \$CGROUP_NAME

    for pid in \$(pgrep -u "\$USER"); do
      echo "\$pid" > /sys/fs/cgroup/cpu/\$CGROUP_NAME/tasks 2>/dev/null || true
      echo "\$pid" > /sys/fs/cgroup/memory/\$CGROUP_NAME/tasks 2>/dev/null || true
    done
  else
    CGROUP_PATH="/sys/fs/cgroup/\$CGROUP_NAME"
    mkdir -p "\$CGROUP_PATH"
    QUOTA=\$(( CPU_CORES * PERIOD ))
    echo "\$QUOTA \$PERIOD" > "\$CGROUP_PATH/cpu.max"
    echo \$(( MEM_MB * 1024 * 1024 )) > "\$CGROUP_PATH/memory.max"

    for pid in \$(pgrep -u "\$USER"); do
      echo "\$pid" > "\$CGROUP_PATH/cgroup.procs" 2>/dev/null || true
    done
  fi

  echo "✅ Applied limits to \$USER" >> "\$LOG_FILE"
done

echo "[\$(date)] ✅ Sync complete" >> "\$LOG_FILE"
EOF

chmod +x "$SCRIPT_PATH"

### Step 4: Set up systemd timer (recommended over cron) ###
echo "🧩 Setting up systemd service and timer..."
cat <<EOF > /etc/systemd/system/user-limiter.service
[Unit]
Description=Apply user CPU and RAM limits
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
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

# Reload systemd and enable
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now user-limiter.timer

echo "✅ All set! Limits will now auto-sync every minute."
echo "📄 Log file: $LOG_FILE"
