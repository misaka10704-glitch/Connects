#!/bin/bash
# 手动复现移位时：边操作 iPad 边抓 Connects 相关 syslog，供 Agent 读日志分析。
#
# 用法：
#   ./Scripts/capture-ipad-syslog.sh
#   ./Scripts/capture-ipad-syslog.sh f6a34b5a6fe9c80adb43527ed86227477bd2fd25
#
# 操作 iPad 复现问题后 Ctrl+C；日志在 ~/Downloads/connects-ipad-syslog-<timestamp>.log
set -euo pipefail

LOG_DIR="${HOME}/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${LOG_DIR}/connects-ipad-syslog-${STAMP}.log"
UDID="${1:-${DEVICE_UDID:-}}"

echo "Writing to $LOG"
echo "Reproduce on iPad, then Ctrl+C."
echo ""

if [[ -n "$UDID" ]]; then
  exec idevicesyslog -u "$UDID" 2>&1 | tee "$LOG" | grep --line-buffered -E 'Connects|ScrollStress|ConnectsScroll'
else
  exec idevicesyslog 2>&1 | tee "$LOG" | grep --line-buffered -E 'Connects|ScrollStress|ConnectsScroll'
fi
