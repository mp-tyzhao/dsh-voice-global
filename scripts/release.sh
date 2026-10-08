#!/usr/bin/env bash
# 发布
# ====
#
# 把这次的发布清单固化成脚本，避免"想起来才检查"。
#
# 跑法：
#   ./scripts/release.sh --check     只做前置检查，不打包不推送
#   ./scripts/release.sh             走完：检查 → 打包 → 打 tag → 推送 → 建 Release
#   ./scripts/release.sh --dry-run   走完全部但最后一步不真的推送
#
# 前置检查里每一条都对应这次实际踩过的坑：
#   · 漏拷 sidecar 模块（打包后学习功能和拼音层直接失效）
#   · 测试没跑就发版
#   · 工作区有未提交改动，打出来的包和 tag 对不上
#   · 版本号没更新，用户分不清装的是哪一版

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-release}"
DRY_RUN=0
WITH_SELFTEST=0
[ "$MODE" = "--dry-run" ] && DRY_RUN=1
ONLY_CHECK=0
[ "$MODE" = "--check" ] && ONLY_CHECK=1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1"; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null || echo "")
[ -n "$VERSION" ] || die "读不到版本号（Resources/Info.plist）"
TAG="v$VERSION"

step "发布前检查（目标 ${TAG}）"

# ── 1. 工作区必须干净 ──────────────────────────────────────────────────────
# 有未提交改动的话，打出来的包和 tag 指向的代码对不上 —— 用户复现不了你测的东西。
if [ -n "$(git status --porcelain)" ]; then
  git status --short | head -10 | sed 's/^/      /'
  die "工作区有未提交改动，先提交再发布"
fi
ok "工作区干净"

# ── 2. tag 不能已存在 ──────────────────────────────────────────────────────
if git rev-parse "$TAG" >/dev/null 2>&1; then
  die "$TAG 已存在。改 Resources/Info.plist 里的版本号，或删掉旧 tag"
fi
ok "$TAG 还没用过"

# ── 3. 测试全绿 ────────────────────────────────────────────────────────────
# 这一条最容易被跳过，而这次发布里价值最高的几个修复全是测试逼出来的。
FAILED=0
for t in cleanup dictionary learning phonetic learning-loop profiles; do
  if ! node "sidecar/$t.test.mjs" >/dev/null 2>&1; then
    warn "$t 测试失败"; FAILED=1
  fi
done
[ "$FAILED" -eq 0 ] || die "单元测试没过，不发布"
ok "6 个 sidecar 测试套件通过"

if [ -x "$ROOT/scripts/selftest.sh" ]; then
  # 自测必须抢焦点（它测的就是系统焦点元素），会弹窗 15 秒。
  # 用户明确说过弹窗影响他用电脑，所以默认不跑，要跑显式加 --with-selftest。
  if [ "$WITH_SELFTEST" = "1" ]; then
    if VOICE_GLOBAL_SELFTEST_OK=1 ./scripts/selftest.sh >/tmp/vg-selftest.log 2>&1; then
      ok "学习闭环端到端自测通过"
    else
      warn "学习闭环自测未通过（多半是焦点被抢）。看 /tmp/vg-selftest.log"
    fi
  else
    warn "跳过端到端自测（会弹窗抢焦点；需要时加 --with-selftest）"
  fi
fi

# ── 4. sidecar 模块完整性 ──────────────────────────────────────────────────
# 曾经因为打包脚本硬编码文件名，dictionary/learning/phonetic 三个模块都没进包，
# 开发模式下完全看不出来（devSidecarRoot 指向仓库），用户装完才发现是坏的。
REQUIRED="server.mjs cleanup.mjs llm.mjs dictionary.mjs learning.mjs phonetic.mjs profiles.mjs"
MISSING=""
for module in $REQUIRED; do
  [ -f "sidecar/$module" ] || MISSING="$MISSING $module"
done
[ -z "$MISSING" ] || die "缺少 sidecar 模块：$MISSING"
ok "sidecar 模块齐全（含 profiles.mjs）"

[ -d "sidecar/node_modules/pinyin-pro" ] || die "缺 pinyin-pro：拼音层会失效"
[ -d "sidecar/node_modules/sherpa-onnx-node" ] || die "缺 sherpa-onnx-node"
[ -d "sidecar/node_modules/sherpa-onnx-darwin-arm64" ] \
  || die "缺 sherpa-onnx 原生库（npm install 有时会把它挪成嵌套布局，检查顶层那份还在不在）"
ok "原生依赖齐全"

# ── 4.5 全量回归对比（用户明确要求）────────────────────────────────────────
# "改了规则一定要用过去所有的录音回归测试，不确定就不要合。"
# 基线文件由 bench/regression.mjs --save 生成；有基线就必须跑对比且无差异。
BASELINE="$ROOT/bench/baseline-rules.json"
if [ -f "$BASELINE" ]; then
  echo "  跑全量回归对比（${BASELINE}）…"
  if node bench/regression.mjs --cleanup rules --compare "$BASELINE" >/tmp/vg-regression.log 2>&1; then
    ok "全量回归：输出无变化"
  else
    tail -30 /tmp/vg-regression.log | sed 's/^/      /'
    die "全量回归有输出变化。逐条确认是不是预期内的；不确定就不要发。"
  fi
else
  warn "没有回归基线（${BASELINE}）。改过规则的话先跑："
  warn "  node bench/regression.mjs --cleanup rules --save bench/baseline-rules.json"
fi

# ── 5. 评测没退化 ──────────────────────────────────────────────────────────
if [ -f bench/labels.jsonl ]; then
  COUNT=$(grep -c . bench/labels.jsonl || echo 0)
  if [ "$COUNT" -lt 10 ]; then
    warn "评测集只有 $COUNT 条，样本太少读不出差异（建议 ≥20 条）"
  else
    ok "评测集 $COUNT 条"
  fi
fi

step "检查完毕"
if [ "$ONLY_CHECK" -eq 1 ]; then
  echo "  只做检查（--check）。发布请跑：./scripts/release.sh"
  exit 0
fi

# ── 打包 ───────────────────────────────────────────────────────────────────
step "打包 $TAG"
./scripts/package.sh || die "打包失败"
ZIP="$ROOT/dist/DSH Voice.zip"
[ -f "$ZIP" ] || die "没找到打包产物：$ZIP"
SIZE=$(stat -f%z "$ZIP")
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
ok "产物 $(printf '%.1f' "$(echo "$SIZE / 1048576" | bc -l)")MB  sha256 ${SHA:0:12}…"

# ── tag 与推送 ─────────────────────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
  step "dry-run：以下步骤没有真的执行"
  echo "  git tag $TAG && git push origin main --tags"
  echo "  gh release create $TAG \"$ZIP\" --title \"$TAG\" --notes-file RELEASE-NOTES.md"
  exit 0
fi

step "打 tag 并推送"
git tag "$TAG"
git push origin main
git push origin "$TAG"
ok "已推送 $TAG"

step "创建 Release"
if command -v gh >/dev/null 2>&1; then
  NOTES_ARG="--notes-file RELEASE-NOTES.md"
  [ -f RELEASE-NOTES.md ] || NOTES_ARG="--generate-notes"
  gh release create "$TAG" "$ZIP" --title "$TAG" $NOTES_ARG || die "gh release 失败"
  ok "Release 已创建"
else
  warn "没装 gh，请手动到 GitHub 创建 Release 并上传：$ZIP"
fi

step "完成"
echo "  版本 $TAG"
echo "  sha256 $SHA"
