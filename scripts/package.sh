#!/usr/bin/env bash
#
# 打一个"发出去就能用"的分发包
# ==============================
#
#   ./scripts/package.sh                 打包（App + 自带 Node + 自带识别模型）
#   ./scripts/package.sh --no-model      不内置 231MB 模型，包更小（首次要自己下）
#   ./scripts/package.sh --adhoc         强制 ad-hoc 签名（默认优先用本机签名证书）
#
# 产物：dist/DSH Voice.zip —— 直接发给用户，解压后按包里的《README.md》走。
#
# 和 build.sh 的区别：
#   * 编译到 dist/ 而不是 build/，不会动到正在运行的 App
#   * 把官方 Node 运行时塞进包内（目标机器不用自己装 Node）
#   * 可选把识别模型也塞进去（目标机器不用首次下载 231MB）
#   * 先签内层再签外层（--deep 已不推荐用于分发）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/staging/DSH Voice.app"
ZIP="$ROOT/dist/DSH Voice.zip"
CACHE="$ROOT/dist/.cache"
BINARY="DSHVoice"

NODE_VERSION="22.11.0"
NODE_MIRRORS=(
  "https://registry.npmmirror.com/-/binary/node"
  "https://nodejs.org/dist"
)
NODE_TARBALL="node-v${NODE_VERSION}-darwin-arm64.tar.gz"

WITH_MODEL=1
FORCE_ADHOC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-model) WITH_MODEL=0; shift ;;
    --adhoc) FORCE_ADHOC=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '  \033[36m·\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1"; exit 1; }

echo
echo "打包 Voice Global 分发包"
echo "========================"

# ── 1. 编译 ────────────────────────────────────────────────────────────────
echo
echo "[1/6] 编译 Swift → dist/"
rm -rf "$ROOT/dist/staging"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
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
ok "已编译 dist/staging/DSH Voice.app"

# ── 2. 资源 ────────────────────────────────────────────────────────────────
echo
echo "[2/6] 打包 sidecar 与依赖"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources/sidecar"
cp "$ROOT/sidecar/server.mjs" "$ROOT/sidecar/cleanup.mjs" "$ROOT/sidecar/llm.mjs" \
   "$APP/Contents/Resources/sidecar/"
# 模型下载脚本也随包带上：万一没内置模型，目标机器的 Agent 可以直接跑它
mkdir -p "$APP/Contents/Resources/setup"
cp "$ROOT/scripts/fetch-models.mjs" "$APP/Contents/Resources/setup/"
# 配置脚本也带上：开启云端润色时用它写配置，比让 Agent 手改 JSON 可靠
cp "$ROOT/scripts/configure.mjs" "$APP/Contents/Resources/setup/"
[ -d "$ROOT/sidecar/node_modules" ] || die "缺少 sidecar/node_modules，先跑 ./scripts/setup.sh"
cp -R "$ROOT/sidecar/node_modules" "$APP/Contents/Resources/sidecar/node_modules"
ok "sidecar + sherpa-onnx 原生库已就位"

# ── 3. 内置 Node 运行时 ────────────────────────────────────────────────────
echo
echo "[3/6] 内置 Node 运行时 v${NODE_VERSION}（目标机器无需安装 Node）"
mkdir -p "$CACHE"
if [ ! -f "$CACHE/$NODE_TARBALL" ]; then
  downloaded=0
  for base in "${NODE_MIRRORS[@]}"; do
    # 两个镜像的目录结构一致：<base>/v<版本>/<tarball>
    url="$base/v${NODE_VERSION}/$NODE_TARBALL"
    info "下载 $url"
    if curl -fsSL -m 300 -o "$CACHE/$NODE_TARBALL.part" "$url"; then
      mv "$CACHE/$NODE_TARBALL.part" "$CACHE/$NODE_TARBALL"
      downloaded=1
      break
    fi
    rm -f "$CACHE/$NODE_TARBALL.part"
  done
  [ "$downloaded" -eq 1 ] || die "Node 运行时下载失败"
else
  info "使用缓存 $CACHE/$NODE_TARBALL"
fi

mkdir -p "$APP/Contents/Resources/node/bin"
tar xzf "$CACHE/$NODE_TARBALL" -C "$CACHE" \
  "node-v${NODE_VERSION}-darwin-arm64/bin/node" \
  "node-v${NODE_VERSION}-darwin-arm64/LICENSE"
cp "$CACHE/node-v${NODE_VERSION}-darwin-arm64/bin/node" "$APP/Contents/Resources/node/bin/node"
cp "$CACHE/node-v${NODE_VERSION}-darwin-arm64/LICENSE" "$APP/Contents/Resources/node/LICENSE"
chmod +x "$APP/Contents/Resources/node/bin/node"
ok "Node $(du -h "$APP/Contents/Resources/node/bin/node" | cut -f1) 已内置（仅依赖系统库，可直接搬进 bundle）"

# ── 4. 识别模型（可选） ────────────────────────────────────────────────────
echo
echo "[4/6] 识别模型"
if [ "$WITH_MODEL" -eq 1 ]; then
  SRC=""
  for candidate in "$HOME/.voice-global/models" \
                   "$HOME/.dsh/speech-to-text/sensevoice/models"; do
    [ -f "$candidate/sensevoice-onnx/model.int8.onnx" ] && SRC="$candidate" && break
  done
  [ -n "$SRC" ] || die "本机找不到现成模型；先跑 node scripts/fetch-models.mjs"
  info "来源：$SRC"
  mkdir -p "$APP/Contents/Resources/models/sensevoice-onnx" "$APP/Contents/Resources/models/silero"
  cp "$SRC/sensevoice-onnx/model.int8.onnx" "$APP/Contents/Resources/models/sensevoice-onnx/"
  cp "$SRC/sensevoice-onnx/tokens.txt"       "$APP/Contents/Resources/models/sensevoice-onnx/"
  cp "$SRC/silero/silero_vad.onnx"           "$APP/Contents/Resources/models/silero/"
  ok "模型已内置（首次启动零等待）"
else
  info "未内置。目标机器首次按 Fn 时会自动下载约 231MB（hf-mirror，实测约 8 分钟）"
fi

# ── 5. 签名（先内层后外层） ────────────────────────────────────────────────
echo
echo "[5/6] 代码签名"
SIGN_IDENTITY="-"
if [ "$FORCE_ADHOC" -eq 0 ]; then
  KEYCHAIN="$(security default-keychain -d user 2>/dev/null | tr -d ' \"' || true)"
  [ -n "$KEYCHAIN" ] && [ -f "$KEYCHAIN" ] || KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
  if [ -f "$KEYCHAIN" ] && security find-certificate -c "DSH Voice Local Signing" "$KEYCHAIN" >/dev/null 2>&1; then
    SIGN_IDENTITY="DSH Voice Local Signing"
  fi
fi

sign() { codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$1" >/dev/null 2>&1; }

# 内层：Node 运行时、原生库、Node 插件
sign "$APP/Contents/Resources/node/bin/node"
for lib in "$APP/Contents/Resources/sidecar/node_modules/sherpa-onnx-darwin-arm64/"*.dylib \
           "$APP/Contents/Resources/sidecar/node_modules/sherpa-onnx-darwin-arm64/"*.node; do
  [ -e "$lib" ] && sign "$lib"
done

# 外层：主程序 + bundle
if codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1; then
  ok "已签名（$([ "$SIGN_IDENTITY" = "-" ] && echo ad-hoc || echo "$SIGN_IDENTITY")）"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  ok "已签名（ad-hoc 兜底）"
fi

# ── 6. 打包 zip ────────────────────────────────────────────────────────────
echo
echo "[6/6] 生成压缩包"
# 说明文件用 README.md 这个名字：Agent 拿到一个压缩包时，默认就会去找它。
# 内容是中文的，人类打开也照样看得懂。
cp "$ROOT/scripts/dist-readme.md" "$ROOT/dist/staging/README.md"
rm -f "$ZIP"
# --norsrc --noextattr 很关键：否则 ditto 会为带扩展属性的文件生成 AppleDouble（._*）条目，
# 而 `unzip` 会把它们当成真实文件写回包内 —— 多出来的文件会破坏代码签名封条
# （实测：unzip 解压后 49 个 ._ 文件，codesign 报 "a sealed resource is missing or invalid"）。
# 去掉之后，unzip 和 ditto（Finder 双击）解压都能得到签名完好的 App。
( cd "$ROOT/dist/staging" \
  && ditto -c -k --norsrc --noextattr --keepParent "DSH Voice.app" "$ZIP" \
  && zip -q -X "$ZIP" "README.md" )

# 自检：两种解压方式都必须得到签名完好的包
verify_zip() {
  local tool="$1" dir="$2"
  rm -rf "$dir"; mkdir -p "$dir"
  case "$tool" in
    unzip) ( cd "$dir" && unzip -q "$ZIP" ) ;;
    ditto) ( cd "$dir" && ditto -x -k "$ZIP" . ) ;;
  esac
  local strays; strays=$(find "$dir/DSH Voice.app" -name "._*" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$strays" != "0" ]; then
    die "用 $tool 解压后有 $strays 个 ._* 残留文件，会破坏签名"
  fi
  codesign --verify --deep --strict "$dir/DSH Voice.app" >/dev/null 2>&1 \
    || die "用 $tool 解压后签名校验失败"
  ok "$tool 解压 → 无残留、签名完好"
}
verify_zip unzip "$ROOT/dist/.verify-unzip"
verify_zip ditto "$ROOT/dist/.verify-ditto"
rm -rf "$ROOT/dist/.verify-unzip" "$ROOT/dist/.verify-ditto"

[ -f "$ZIP" ] || die "压缩包生成失败"
ok "$(basename "$ZIP")（$(du -h "$ZIP" | cut -f1)）"

echo
echo "✅ 打包完成"
echo
echo "  $ZIP"
echo
echo "  发给用户时，连同这句一起发："
echo "  ─────────────────────────────────────────────"
echo "  解压后把「DSH Voice.app」拖进「应用程序」，"
echo "  然后按包里的《README.md》走（或直接让 Agent 读它）。"
echo "  ─────────────────────────────────────────────"
echo
