#!/usr/bin/env bash
# 学习闭环端到端自测
# ==================
#
# 头号功能最容易"看起来没坏、其实从来没工作过" —— 它依赖别的 App、真输入框、
# 真粘贴、真修改，纯单元测试覆盖不到。这个脚本造一个受控输入框，
# 把真实的观测代码整条跑一遍。
#
# 跑法：./scripts/selftest.sh
#
# 用临时 HOME，不碰你自己的词表。

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/DSH Voice.app"

[ -x "$APP/Contents/MacOS/DSHVoice" ] || { echo "先构建：./build.sh"; exit 1; }

# 常驻的 App 会和自测窗口抢焦点，导致辅助功能读到别的地方 —— 结果偶发失败。
# 这不是产品问题，但会让自测结果不可信，所以先提醒。
RUNNING=$(pgrep -f "MacOS/DSHVoice" | wc -l | tr -d ' ')
if [ "$RUNNING" -gt 0 ]; then
  echo "提示：检测到 $RUNNING 个 DSH Voice 实例在运行。"
  echo "      它可能和自测窗口抢焦点，导致偶发失败。建议先退出：pkill -f 'MacOS/DSHVoice'"
  echo
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.voice-global"
echo '{"terms":[]}' > "$SANDBOX/.voice-global/dictionary.json"

# 模型目录沿用开发机上那份
MODEL_ROOT="${VOICE_GLOBAL_MODEL_ROOT:-$HOME/.dsh/speech-to-text/sensevoice/models}"

echo "学习闭环自测（隔离 HOME: ${SANDBOX}）"
echo "────────────────────────────────────────"
set +e
HOME="$SANDBOX" VOICE_GLOBAL_MODEL_ROOT="$MODEL_ROOT" \
  "$APP/Contents/MacOS/DSHVoice" --learn-selftest 2>&1 | grep -v "^20[0-9][0-9]-"
STATUS=${PIPESTATUS[0]}
set -e

echo
case "$STATUS" in
  0) : ;;
  2) echo "  结果：无法判定（焦点被别的 App 抢走，不是产品问题）。重跑一次即可。" ;;
  *) echo "  结果：真的有失败，看上面的 FAIL 行。" ;;
esac
echo
echo "落盘检查："
echo "  词表   $(cat "${SANDBOX}/.voice-global/dictionary.json" 2>/dev/null | tr -d '\n' | head -c 160)"
echo "  待定区 $(cat "${SANDBOX}/.voice-global/learning-pending.json" 2>/dev/null | tr -d '\n' | head -c 80)"
exit "$STATUS"
