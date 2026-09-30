#!/usr/bin/env bash
#
# Voice Global 一键安装
# =====================
#
# 设计原则：**先找现成的，再决定要不要从头搭**。
#   识别运行库：项目里已有 → npm 安装 → 从本机 DSH 提取
#   识别模型　：自带目录已有 → 复用 DSH 已下载的语音包 → 从 HuggingFace 下载
#   润色模型　：已有密钥 → 用参数/环境变量里的密钥 → 提示怎么申请
#
# 用法：
#   ./scripts/setup.sh                          # 交互式
#   ./scripts/setup.sh --api-key sk-xxxxxxxx    # 直接给 DeepSeek 密钥（Agent 用这个）
#   ./scripts/setup.sh --no-llm                 # 纯离线，不配置润色
#   ./scripts/setup.sh --model-root /path       # 复用指定模型目录
#   ./scripts/setup.sh --skip-build             # 只装依赖和模型
#   ./scripts/setup.sh --npm-registry <url>     # 指定 npm 源（默认官方源失败后回退 npmmirror）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP="$ROOT/build/DSH Voice.app"

API_KEY=""
USE_LLM=1
SKIP_BUILD=0
MODEL_ROOT=""
BASE_URL="https://api.deepseek.com/v1"
MODEL="deepseek-flash"
# npm 官方源在部分网络下不可达（ECONNREFUSED），默认回退到国内镜像
NPM_MIRROR="https://registry.npmmirror.com"

while [ $# -gt 0 ]; do
  case "$1" in
    --api-key) API_KEY="${2:-}"; shift 2 ;;
    --no-llm) USE_LLM=0; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --model-root) MODEL_ROOT="${2:-}"; shift 2 ;;
    --base-url) BASE_URL="${2:-}"; shift 2 ;;
    --model) MODEL="${2:-}"; shift 2 ;;
    --npm-registry) NPM_MIRROR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1"; exit 1; }

DSH_CACHE="$HOME/.dsh/speech-to-text/sensevoice/models"
OWN_MODELS="$HOME/.voice-global/models"
DSH_APP="/Applications/DeepSeek Harness.app"

echo
echo "Voice Global 安装程序"
echo "====================="

# ── 1. 环境 ────────────────────────────────────────────────────────────────
echo
echo "[1/6] 环境检查"
[ "$(uname -s)" = "Darwin" ] || die "目前只支持 macOS"
ok "macOS $(sw_vers -productVersion) / $(uname -m)"
[ "$(uname -m)" = "arm64" ] || warn "非 Apple Silicon：需要自行确认 sherpa-onnx 原生库架构"

command -v swiftc >/dev/null 2>&1 || die "缺少 swiftc，先装 Xcode Command Line Tools：xcode-select --install"
ok "swiftc $(swiftc --version 2>/dev/null | head -1 | awk '{print $4}')"

command -v node >/dev/null 2>&1 || die "缺少 node（需要 20+）：brew install node"
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
[ "$NODE_MAJOR" -ge 20 ] || die "node 版本过低（当前 $(node -v)），需要 20+"
ok "node $(node -v)"

# ── 2. 识别运行库 ──────────────────────────────────────────────────────────
echo
echo "[2/6] 识别运行库（sherpa-onnx-node）"
if [ -d "sidecar/node_modules/sherpa-onnx-node" ]; then
  ok "项目内已存在，跳过"
else
  INSTALLED=0
  if command -v npm >/dev/null 2>&1; then
    echo "  从 npm 安装…"
    if (cd sidecar && npm install --no-audit --no-fund >/tmp/voice-global-npm.log 2>&1); then
      ok "已从 npm 安装（官方源）"
      INSTALLED=1
    elif (cd sidecar && npm install --no-audit --no-fund --registry "$NPM_MIRROR" >>/tmp/voice-global-npm.log 2>&1); then
      # 官方源不可达是常见情况（ECONNREFUSED），镜像一般都能通
      ok "已从 npm 安装（镜像源 $(echo "$NPM_MIRROR" | sed 's|https\?://||')）"
      INSTALLED=1
    else
      warn "npm 安装失败（官方源与镜像都不通，见 /tmp/voice-global-npm.log），尝试其它来源"
    fi
  fi
  if [ "$INSTALLED" -eq 0 ] && [ -d "$DSH_APP" ]; then
    echo "  检测到本机 DSH，直接从它的运行时里提取原生库…"
    node scripts/stage-deps.mjs && INSTALLED=1
  fi
  [ "$INSTALLED" -eq 1 ] || die "无法准备 sherpa-onnx-node。可手动执行：cd sidecar && npm install sherpa-onnx-node"
fi

# ── 3. 识别模型 ────────────────────────────────────────────────────────────
echo
echo "[3/6] 识别模型（SenseVoice + Silero VAD）"
if [ -n "$MODEL_ROOT" ] && [ -f "$MODEL_ROOT/sensevoice-onnx/model.int8.onnx" ]; then
  ok "使用指定的模型目录（不下载）：$MODEL_ROOT"
elif node scripts/fetch-models.mjs --own-only >/dev/null 2>&1; then
  ok "自带目录已就绪（已校验大小与 SHA-256）：$OWN_MODELS"
elif node scripts/fetch-models.mjs --check >/dev/null 2>&1; then
  ok "发现本机已有的语音包（DSH 下载过），原地复用："
  echo "     $DSH_CACHE"
  echo "     不复制、不下载，省下 228MB 空间与流量"
else
  warn "本机没有可用的完整语音包，需要下载（int8 约 231MB）"
  node scripts/fetch-models.mjs || die "模型下载失败：可重跑本脚本续传，或手动下载后放到 $OWN_MODELS
     也可以用镜像：node scripts/fetch-models.mjs --source https://hf-mirror.com"
fi

# ── 4. 润色模型 ────────────────────────────────────────────────────────────
echo
echo "[4/6] 润色模型（把口语稿变成书面稿：补标点、修同音字、删语气词）"
if [ "$USE_LLM" -eq 0 ]; then
  node scripts/configure.mjs --cleanup rules >/dev/null
  ok "已选择纯离线模式（只做规则清理，不联网）"
else
  [ -n "$API_KEY" ] || API_KEY="${DEEPSEEK_API_KEY:-}"
  if [ -z "$API_KEY" ] && [ -f "$HOME/.voice-global/.env" ]; then
    API_KEY="$(sed -n 's/^DEEPSEEK_API_KEY=//p' "$HOME/.voice-global/.env" | head -1)"
    [ -n "$API_KEY" ] && ok "使用 ~/.voice-global/.env 里已有的密钥"
  fi

  if [ -n "$API_KEY" ]; then
    echo "  验证密钥…"
    if curl -s -m 20 -o /dev/null -w '%{http_code}' "$BASE_URL/models" \
        -H "authorization: Bearer $API_KEY" | grep -q '^200$'; then
      ok "密钥可用"
    else
      warn "密钥验证未通过（也可能只是网络问题），仍会写入配置"
    fi
    node scripts/configure.mjs --cleanup llm --base-url "$BASE_URL" --model "$MODEL" --api-key "$API_KEY" >/dev/null
    ok "润色已启用：$MODEL @ $BASE_URL"
  else
    node scripts/configure.mjs --cleanup rules >/dev/null
    warn "没有拿到 DeepSeek 密钥，先按纯离线模式配置"
    echo "     拿到密钥后执行：./scripts/setup.sh --api-key sk-xxxx"
    echo "     申请地址：https://platform.deepseek.com/api_keys"
  fi
fi

if [ -n "$MODEL_ROOT" ]; then
  node scripts/configure.mjs --model-root "$MODEL_ROOT" >/dev/null
  ok "模型目录已指向 $MODEL_ROOT"
fi

# ── 5. 构建 ────────────────────────────────────────────────────────────────
if [ "$SKIP_BUILD" -eq 0 ]; then
  echo
  echo "[5/6] 构建 App"
  if [ ! -f "$HOME/.voice-global/signing/sign-cert.pem" ]; then
    bash scripts/setup-signing.sh >/dev/null 2>&1 && ok "已生成本地签名证书（重建不再重复授权）" \
      || warn "签名证书生成失败，将用 ad-hoc 签名（每次重建都要重新授权）"
  fi
  ./build.sh >/tmp/voice-global-build.log 2>&1 || { tail -20 /tmp/voice-global-build.log; die "构建失败"; }
  ok "已生成 build/DSH Voice.app"

  # 装完立刻自检，把问题暴露在安装阶段而不是用户第一次按 Fn 时
  echo "  运行自检…"
  if "$APP/Contents/MacOS/DSHVoice" --check 2>/dev/null | grep -q "识别服务：就绪"; then
    ok "自检通过：识别服务可用"
  else
    warn "自检未通过，请查看上面的输出与 ~/.voice-global/log.txt"
  fi
else
  echo
  echo "[5/6] 跳过构建"
fi

# ── 6. 下一步 ──────────────────────────────────────────────────────────────
echo
echo "[6/6] 接下来"
cat <<EOF
  1) 启动：open "$APP"
  2) 授权（首次会自己弹窗引导，也可手动）：
       系统设置 → 隐私与安全性 → 麦克风      勾选 DSH Voice
       系统设置 → 隐私与安全性 → 辅助功能    勾选 DSH Voice
       系统设置 → 隐私与安全性 → 输入监控    勾选 DSH Voice（若按 Fn 没反应）
  3) 关键一步：系统设置 → 键盘 → 「按下 🌐 键时」→ 不执行任何操作
  4) 任意输入框里单击 Fn 开始说话，再单击 Fn 结束并自动粘贴

  自检：  "$APP/Contents/MacOS/DSHVoice" --check
  探测：  "$APP/Contents/MacOS/DSHVoice" --listen 15     # Fn 事件是否真的能收到
  日志：  ~/.voice-global/log.txt
EOF
echo
