#!/bin/bash
# Study 滚动/空白 — 在真机（iPad Air 1 等）上跑与 Mac 相同的 harness，并抓取 syslog。
#
# 前置：iPad USB 连接本机，已信任；ios-deploy / libimobiledevice 已安装。
#
# 用法：
#   ./Scripts/run-scroll-stress-study-device.sh
#   ./Scripts/run-scroll-stress-study-device.sh f6a34b5a6fe9c80adb43527ed86227477bd2fd25
#   DEVICE_UDID=... ./Scripts/run-scroll-stress-study-device.sh
#
# 日志：~/Downloads/connects-device-stress-<timestamp>.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${DERIVED_DATA_PATH:-/tmp/Connects-ipad-Derived}"
APP="$DERIVED/Build/Products/Debug-iphoneos/Connects.app"
LOG_DIR="${HOME}/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${LOG_DIR}/connects-device-stress-${STAMP}.log"

{
  echo "=== Connects device stress $STAMP ==="
} > "$LOG"

UDID="${1:-${DEVICE_UDID:-}}"
if [[ -z "$UDID" ]]; then
  UDID="$(ios-deploy --detect 2>/dev/null | awk '/Found/{f=1} f && /iPad/{print $NF; exit}')"
fi
if [[ -z "$UDID" ]]; then
  echo "No iPad detected. Pass UDID: $0 <udid>" >&2
  exit 1
fi

echo "==> Build Debug (iPad)"
"$ROOT/Scripts/build-device.sh" ipad Debug

ARGS=(
  -ScrollStressStudyFixture
  -ScrollStressStudy
  -ScrollStressSlow
)

echo "==> Deploy + launch on $UDID"
echo "    args: ${ARGS[*]}"
echo "    log:  $LOG"

idevicesyslog -u "$UDID" 2>&1 | tee -a "$LOG" | grep --line-buffered -E '\[ConnectsScrollStress\]|ConnectsScroll' &
SYSLOG_PID=$!
cleanup() { kill "$SYSLOG_PID" 2>/dev/null || true; }
trap cleanup EXIT

ios-deploy --id "$UDID" --bundle "$APP" --no-wifi

ios-deploy \
  --id "$UDID" \
  --bundle "$APP" \
  --no-wifi \
  --debug \
  --justlaunch \
  --args "-ScrollStressStudyFixture -ScrollStressStudy -ScrollStressSlow" \
  2>&1 | tee -a "$LOG" || true

# Harness runs ~60–90s on Air 1; wait for verdict in syslog.
for _ in $(seq 1 120); do
  if grep -q '\[ConnectsScrollStress\] PASS study stress' "$LOG" 2>/dev/null; then
    echo ""
    echo "PASS (see $LOG)"
    exit 0
  fi
  if grep -q '\[ConnectsScrollStress\] FAIL' "$LOG" 2>/dev/null; then
    echo ""
    echo "FAIL (see $LOG)"
    grep '\[ConnectsScrollStress\]' "$LOG" || true
    exit 1
  fi
  sleep 1
done

echo ""
echo "Timeout — no harness verdict (check $LOG; app may need foreground on iOS 12)"
exit 2
