#!/bin/bash
# apply_user_limits.sh — Fetch user limits from API and apply them via cgroups (v1 or v2)
# Author: You 😎

API_URL=""
LOG_FILE="/var/log/user-limiter/user_limit_sync.log"
TMP_JSON="/tmp/user_limits.json"
PERIOD=100000

echo "[$(date)] 🔄 Syncing user resource limits from API..." >> "$LOG_FILE"

# Check for required tools
command -v curl >/dev/null || { echo "❌ curl not found" >> "$LOG_FILE"; exit 1; }
command -v jq >/dev/null || { echo "❌ jq not found" >> "$LOG_FILE"; exit 1; }

# Fetch JSON from API
if ! curl -s --fail "$API_URL" -o "$TMP_JSON"; then
  echo "❌ Failed to fetch data from API" >> "$LOG_FILE"
  exit 1
fi

# Detect cgroup version
CGROUP_VERSION=1
mount | grep -q "cgroup2 on /sys/fs/cgroup" && CGROUP_VERSION=2
TOTAL_CPUS=$(nproc)

jq -c '.[]' "$TMP_JSON" | while read -r item; do
  USER=$(echo "$item" | jq -r '.user')
  MEM_MB=$(echo "$item" | jq -r '.mem // empty')
  CPU_CORES=$(echo "$item" | jq -r '.cpu // empty')

  if [[ -z "$USER" || -z "$MEM_MB" || -z "$CPU_CORES" ]]; then
    echo "⚠️ Skipping invalid entry: $item" >> "$LOG_FILE"
    continue
  fi

  id "$USER" &>/dev/null || {
    echo "⚠️ Skipping: user '$USER' does not exist" >> "$LOG_FILE"
    continue
  }

  CGROUP_NAME="limit_$USER"
  echo "➡️ Applying limits for $USER (CPU: $CPU_CORES cores, RAM: ${MEM_MB}MB)" >> "$LOG_FILE"

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

  echo "✅ Limits applied to $USER" >> "$LOG_FILE"
done

echo "[$(date)] ✅ Sync complete" >> "$LOG_FILE"
