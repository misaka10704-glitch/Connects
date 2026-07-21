#!/bin/bash
# Study 横屏专项：走真实 StudyShell（PDF + 右侧 AI 面板），模拟 iPad 横/竖屏切换与滚动。
# 与 -ScrollStressStudy / -ScrollStressMatrix 不同：后者只改 ChatVC table 宽度，不经 Shell 布局。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressStudyLandscape -ScrollStressSlow "$@"
