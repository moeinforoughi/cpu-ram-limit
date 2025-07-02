#!/bin/bash
# main.sh — Syncs user CPU and RAM limits via API and cgroups (v1/v2)

### Configuration
API_URL=""
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
LOG_FILE="$SCRIPT_DIR/logs/user_limit_sync.log"
TMP_JSON="/tmp/user_limits.json"
PERIOD=100000
LOCKFILE="/tmp/apply_user_limits.lock"
### Make log directory and file 
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
### Lock to prevent concurrent execution
exec 9>"$LOCKFILE"
flock -n 9 || {
  echo "[$(date)] ⚠️ Another instance is running. Exiting." >> "$LOG_FILE"
  exit 1
}

### Must run as root
if [[ "$EUID" -ne 0 ]]; then
  echo "[$(date)] ❌ Script must be run as root." >> "$LOG_FILE"
  exit 1
fi

### Start log
echo "[$(date)] 🔄 Starting user limit sync..." >> "$LOG_FILE"

### Ensure dependencies
command -v curl >/dev/null || { echo "❌ curl not found" >> "$LOG_FILE"; exit 1; }
command -v jq >/dev/null || { echo "❌ jq not found" >> "$LOG_FILE"; exit 1; }

### Fetch data with retries
for i in {1..3}; do
  if curl -s --fail "$API_URL" -o "$TMP_JSON"; then break; fi
  sleep 2
done

if [[ ! -s "$TMP_JSON" ]]; then
  echo "❌ Failed to fetch or parse API response." >> "$LOG_FILE"
  exit 1
fi

### Detect cgroup version
CGROUP_VERSION=1
mount | grep -q "cgroup2 on /sys/fs/cgroup" && CGROUP_VERSION=2
TOTAL_CPUS=$(nproc)

### Parse and apply limits
jq -c '.[]' "$TMP_JSON" | while read -r item; do
  USER=$(echo "$item" | jq -r '.user')
  MEM_MB=$(echo "$item" | jq -r '.mem // empty')
  CPU_CORES=$(echo "$item" | jq -r '.cpu // empty')

  # Validate input
  if [[ -z "$USER" || -z "$MEM_MB" || -z "$CPU_CORES" ]]; then
    echo "⚠️ Skipping incomplete entry: $item" >> "$LOG_FILE"
    continue
  fi

  if ! [[ "$MEM_MB" =~ ^[0-9]+$ && "$CPU_CORES" =~ ^[0-9]+$ && "$MEM_MB" -gt 0 && "$CPU_CORES" -gt 0 ]]; then
    echo "⚠️ Skipping invalid limits for $USER" >> "$LOG_FILE"
    continue
  fi

  id "$USER" &>/dev/null || {
    echo "⚠️ Skipping non-existent user: $USER" >> "$LOG_FILE"
    continue
  }

  CGROUP_NAME="limit_$USER"
  echo "➡️ Applying limits for $USER (CPU: $CPU_CORES, RAM: ${MEM_MB}MB)" >> "$LOG_FILE"

  if [[ "$CGROUP_VERSION" == "1" ]]; then
    mkdir -p /sys/fs/cgroup/cpu /sys/fs/cgroup/memory
    mountpoint -q /sys/fs/cgroup/cpu || mount -t cgroup -o cpu cpu /sys/fs/cgroup/cpu
    mountpoint -q /sys/fs/cgroup/memory || mount -t cgroup -o memory memory /sys/fs/cgroup/memory

    cgcreate -g "cpu,memory:/$CGROUP_NAME" 2>/dev/null || true

    QUOTA=$(( CPU_CORES * PERIOD ))
    cgset -r memory.limit_in_bytes=$((MEM_MB * 1024 * 1024)) $CGROUP_NAME
    cgset -r cpu.cfs_period_us=$PERIOD $CGROUP_NAME
    cgset -r cpu.cfs_quota_us=$QUOTA $CGROUP_NAME

    for pid in $(pgrep -u "$USER"); do
      echo "$pid" > /sys/fs/cgroup/cpu/$CGROUP_NAME/tasks 2>/dev/null || true
      echo "$pid" > /sys/fs/cgroup/memory/$CGROUP_NAME/tasks 2>/dev/null || true
    done
  else
    CGROUP_PATH="/sys/fs/cgroup/$CGROUP_NAME"
    mkdir -p "$CGROUP_PATH"

    QUOTA=$(( CPU_CORES * PERIOD ))
    echo "$QUOTA $PERIOD" > "$CGROUP_PATH/cpu.max"
    echo $(( MEM_MB * 1024 * 1024 )) > "$CGROUP_PATH/memory.max"

    for pid in $(pgrep -u "$USER"); do
      echo "$pid" > "$CGROUP_PATH/cgroup.procs" 2>/dev/null || true
    done
  fi

  echo "✅ Limits applied: $USER | CPU=${CPU_CORES} | RAM=${MEM_MB}MB | CGv$CGROUP_VERSION" >> "$LOG_FILE"
done

echo "[$(date)] ✅ Sync finished." >> "$LOG_FILE"
