#!/usr/bin/env bash
#
# 开发模式：改 Swift 源码自动重建 + 重启
# =======================================
#
#   ./scripts/dev.sh            盯着 Sources/ 与 Resources/，改动即重建重启
#   ./scripts/dev.sh --once     只重建重启一次，不进入监听
#
# 只处理 Swift 侧。`sidecar/*.mjs` 不用走这里 —— App 自己盯着它们，
# 改完下次录音就生效（见 config 里的 devSidecarRoot / devAutoReload）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/DSH Voice.app"
BINARY="$APP/Contents/MacOS/DSHVoice"
WATCH_DIRS=("$ROOT/Sources" "$ROOT/Resources")

ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
dim() { printf '  \033[90m%s\033[0m\n' "$1"; }

# 源码指纹：修改时间 + 路径。比 fswatch 少一个依赖，够用。
fingerprint() {
  find "${WATCH_DIRS[@]}" -type f \( -name '*.swift' -o -name '*.plist' \) \
    -exec stat -f '%m %N' {} \; 2>/dev/null | sort | shasum | cut -d' ' -f1
}

rebuild() {
  echo
  echo "==> 重建 $(date '+%H:%M:%S')"

  # 先优雅退出正在运行的实例：build.sh 第一步是 rm -rf，不能对着运行中的 App 下手
  if pgrep -f "$BINARY" >/dev/null 2>&1; then
    pkill -f "$BINARY" || true
    for _ in $(seq 1 20); do
      pgrep -f "$BINARY" >/dev/null 2>&1 || break
      sleep 0.25
    done
    pgrep -f "$BINARY" >/dev/null 2>&1 && pkill -9 -f "$BINARY" || true
    dim "已退出旧实例"
  fi

  if ! "$ROOT/build.sh" >/tmp/voice-global-dev-build.log 2>&1; then
    echo "  ✗ 构建失败，日志尾部："
    tail -20 /tmp/voice-global-dev-build.log | sed 's/^/    /'
    echo "  （保持不启动，修好源码后会自动重试）"
    return 1
  fi
  ok "构建完成"

  open "$APP"
  ok "已启动"
}

if [ "${1:-}" = "--once" ]; then
  rebuild
  exit $?
fi

echo
echo "Voice Global 开发模式"
echo "======================"
dim "监听：${WATCH_DIRS[*]}"
dim "sidecar/*.mjs 由 App 自己热重载，不走这里"
dim "Ctrl-C 退出"
echo

# 首次不重建，只建立基线（想立刻重建就加 --once 先跑一次）
LAST="$(fingerprint)"
dim "已建立基线 $(echo "$LAST" | cut -c1-12)"

while true; do
  sleep 2
  CURRENT="$(fingerprint)"
  if [ "$CURRENT" != "$LAST" ]; then
    LAST="$CURRENT"
    # 编辑器保存常触发多次事件，等写入落定再动手
    sleep 0.6
    LAST="$(fingerprint)"
    rebuild || true
  fi
done
