#!/usr/bin/env bash
# 稳定性冒烟：把语料里所有录音连续跑一遍
# ======================================
#
# 单元测试验的是逻辑，这里验的是"连续用会不会坏"：进程起不来、
# 某条音频让模型崩、延迟突然飙高 —— 这些只有真跑一遍才知道。
#
# 跑法：./scripts/soak.sh
#
# 每条都用独立进程（和真实使用一致：每次听写起一个短命 sidecar），
# 所以也能暴露启动路径的问题（模块缺失、原生库加载失败等）。

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="${VOICE_GLOBAL_CORPUS_DIR:-$HOME/.voice-global/recordings/audio}"
MODEL_ROOT="${VOICE_GLOBAL_MODEL_ROOT:-$HOME/.dsh/speech-to-text/sensevoice/models}"

[ -d "$CORPUS" ] || { echo "没有语料目录：$CORPUS"; exit 1; }

# 不用 mapfile —— macOS 自带的是 bash 3.2，没有这个内建
FILES=()
for candidate in "$CORPUS"/*.wav; do
  [ -e "$candidate" ] && FILES+=("$candidate")
done
[ "${#FILES[@]}" -gt 0 ] || { echo "语料目录里没有 wav：$CORPUS"; exit 1; }

echo "稳定性冒烟：${#FILES[@]} 条录音"
echo "────────────────────────────────────────"

OK=0; FAIL=0; TOTAL_MS=0; MAX_MS=0; FAILED_FILES=()

for file in "${FILES[@]}"; do
  OUT=$(VOICE_GLOBAL_MODEL_ROOT="$MODEL_ROOT" timeout 90 \
        node "$ROOT/sidecar/server.mjs" --once "$file" --cleanup llm 2>/dev/null | tail -1 || echo '')
  if echo "$OUT" | grep -q '"ok":true'; then
    OK=$((OK + 1))
    MS=$(echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const t=JSON.parse(s).timings||{};console.log(Object.values(t).reduce((a,b)=>a+b,0))}catch{console.log(0)}})' 2>/dev/null || echo 0)
    TOTAL_MS=$((TOTAL_MS + MS))
    [ "$MS" -gt "$MAX_MS" ] && MAX_MS=$MS
  else
    FAIL=$((FAIL + 1))
    FAILED_FILES+=("$(basename "$file")")
    echo "  ✗ $(basename "$file")"
  fi
done

echo
echo "  成功 $OK / 失败 $FAIL"
if [ "$OK" -gt 0 ]; then
  echo "  平均耗时 $((TOTAL_MS / OK))ms   最慢 ${MAX_MS}ms"
fi
if [ "$FAIL" -gt 0 ]; then
  printf '  失败文件：%s\n' "${FAILED_FILES[*]}"
  exit 1
fi
echo "  ALL PASS"
