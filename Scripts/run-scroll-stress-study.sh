#!/bin/bash
# Study 专项压测：全宽行高 → 窄分屏 → 冲激/卷积多公式上滑（对准空白与移位 bug）。
# 不要与 -ScrollStressMathHeavy 混用。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec "$ROOT/Scripts/run-mac.sh" -ScrollStressStudyFixture -ScrollStressStudy "$@"
