#!/usr/bin/env bash
#
# 构建 DSH Voice Global
# =====================
#
#   ./build.sh            编译 + 打包 .app（含 sidecar 与依赖）
#   ./build.sh --run      构建后启动
#
# 依赖：Xcode Command Line Tools（swiftc）。识别模型复用 DSH 已下载的缓存，
# 不重复占空间；sherpa-onnx 运行库从 DSH.app 里取出，见 scripts/stage-deps.mjs。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/DSH Voice.app"
BINARY="DSHVoice"

echo "==> 准备目录"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ ! -d "$ROOT/sidecar/node_modules/sherpa-onnx-node" ]; then
  if [ -d "/Applications/DeepSeek Harness.app" ]; then
    echo "==> 从本机 DSH 提取 sherpa-onnx 依赖（首次构建）"
    node "$ROOT/scripts/stage-deps.mjs"
  else
    echo "缺少识别运行库。先运行一次完整安装：./scripts/setup.sh" >&2
    exit 1
  fi
fi

echo "==> 编译 Swift"
swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreGraphics \
  -framework ApplicationServices \
  -o "$APP/Contents/MacOS/$BINARY" \
  "$ROOT"/Sources/*.swift

echo "==> 打包资源"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/sidecar"
cp "$ROOT/sidecar/server.mjs" "$ROOT/sidecar/cleanup.mjs" "$ROOT/sidecar/llm.mjs" "$APP/Contents/Resources/sidecar/"
cp -R "$ROOT/sidecar/node_modules" "$APP/Contents/Resources/sidecar/node_modules"

echo "==> 代码签名"
# 优先用本地自签名身份：指定要求是「identifier + 证书」，跨构建稳定，
# 授权（辅助功能/麦克风）不会因为重新构建而失效。没有证书才退回 ad-hoc。
SIGN_IDENTITY="DSH Voice Local Signing"
KEYCHAIN="$(security default-keychain -d user 2>/dev/null | tr -d ' \"' || true)"
[ -n "$KEYCHAIN" ] && [ -f "$KEYCHAIN" ] || KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if [ -f "$KEYCHAIN" ] && security find-certificate -c "$SIGN_IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
  if codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "   ✓ 已用「${SIGN_IDENTITY}」签名（权限可跨构建保留）"
  else
    echo "   ⚠️ 签名失败，退回 ad-hoc"
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  fi
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  echo "   ⚠️ 未找到本地签名证书，使用 ad-hoc —— 每次重新构建都需要重新授权。"
  echo "      执行一次 scripts/setup-signing.sh 可解决。"
fi

echo
echo "✅ 构建完成：$APP"
echo
echo "首次使用："
echo "  1. 启动：open \"$APP\""
echo "  2. 授权：系统设置 → 隐私与安全性 → 辅助功能 / 麦克风 里勾选 DSH Voice"
echo "  3. 关键：系统设置 → 键盘 → 按下 🌐 键时 → 「不执行任何操作」"
echo "  4. 任意输入框里单击 Fn 开始说话，再单击 Fn 结束并转写"
echo
echo "自检：\"$APP/Contents/MacOS/$BINARY\" --check"

if [ "${1:-}" = "--run" ]; then
  echo "==> 启动"
  open "$APP"
fi
