#!/usr/bin/env node
/**
 * 全量回归对比
 * ============
 *
 * 拿**语料里的每一条录音**跑一遍流水线，存下结果；改代码之后再跑一次对比。
 *
 * ## 为什么必须有这个
 *
 * `bench/accuracy.mjs` 只能算**有标注**的那几条（现在 25 条）。
 * 改一条规则、调一个阈值，看那 25 条"没变差"就以为没事 ——
 * 但真实语料有 134 条，剩下 109 条上发生了什么，完全不知道。
 *
 * 实测过一次：改断句规则时只对了两个例子，全量一跑 CER 从 7.2% 涨到 10.1%。
 * 只看例子就会把这种改动放进去。
 *
 * ## 它测什么
 *
 * 不需要标准答案 —— 它做的是**差分**：
 * 同一个输入，改代码前后输出只要有变化，就列出来让你逐条判断
 * "这是我想要的变化吗"。
 *
 * 跑法：
 *   node bench/regression.mjs --save baseline.json    # 改之前存基线
 *   （改代码）
 *   node bench/regression.mjs --compare baseline.json # 改之后对比
 *
 *   --cleanup rules|llm|off   走哪条清理路径（默认 llm）
 *   --limit N                 只跑前 N 条（快速检查用）
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(path.dirname(fileURLToPath(import.meta.url)));

const argv = process.argv.slice(2);
const value = (flag, fallback = '') => {
  const index = argv.indexOf(flag);
  return index >= 0 && index + 1 < argv.length ? argv[index + 1] : fallback;
};
const SAVE = value('--save');
const COMPARE = value('--compare');
const CLEANUP = value('--cleanup', 'llm');
const LIMIT = Number(value('--limit', '0')) || 0;

const CORPUS_DIR = path.join(os.homedir(), '.voice-global', 'recordings');
const INDEX = path.join(CORPUS_DIR, 'index.jsonl');

function loadEntries() {
  let entries = [];
  try {
    entries = fs.readFileSync(INDEX, 'utf8').split('\n')
      .filter((line) => line.trim())
      .map((line) => { try { return JSON.parse(line); } catch { return null; } })
      .filter(Boolean);
  } catch { /* 没有语料 */ }
  return entries.filter((entry) => entry.audio);
}

function runOne(audioPath) {
  return new Promise((resolve) => {
    const child = spawn('node', [path.join(ROOT, 'sidecar', 'server.mjs'), '--once', audioPath, '--cleanup', CLEANUP], {
      env: process.env, stdio: ['ignore', 'pipe', 'ignore'],
    });
    let out = '';
    child.stdout.on('data', (chunk) => { out += chunk; });
    child.on('error', () => resolve(null));
    child.on('close', () => {
      const line = out.trim().split('\n').pop();
      try { resolve(JSON.parse(line)); } catch { resolve(null); }
    });
  });
}

const entries = loadEntries();
const targets = LIMIT > 0 ? entries.slice(-LIMIT) : entries;

if (!targets.length) {
  console.log('语料里没有可跑的录音（需要 index.jsonl 里有 audio 字段）');
  process.exit(0);
}

if (COMPARE) {
  // ── 对比模式：跑一遍，和基线逐条比 ────────────────────────────────────
  let baseline;
  try {
    baseline = JSON.parse(fs.readFileSync(COMPARE, 'utf8'));
  } catch (error) {
    console.error(`读不到基线 ${COMPARE}：${error.message}`);
    process.exit(1);
  }
  const baseMap = new Map(baseline.results.map((r) => [r.ts, r]));

  console.log(`回归对比：${targets.length} 条录音 · cleanup=${CLEANUP}`);
  console.log('='.repeat(72));

  const changed = [];
  let same = 0;
  let failed = 0;

  for (const entry of targets) {
    const result = await runOne(path.join(CORPUS_DIR, entry.audio));
    if (!result?.ok) { failed += 1; continue; }
    const before = baseMap.get(entry.ts);
    if (!before) continue;
    if (before.text === result.text) { same += 1; continue; }
    changed.push({ ts: entry.ts, before: before.text, after: result.text, raw: result.raw });
  }

  console.log(`  未变  ${same}`);
  console.log(`  变了  ${changed.length}`);
  if (failed) console.log(`  失败  ${failed}`);
  console.log();

  for (const item of changed) {
    console.log(`  ${item.ts}`);
    console.log(`    原: ${item.before}`);
    console.log(`    新: ${item.after}`);
    if (item.raw) console.log(`    raw: ${item.raw}`);
    console.log();
  }

  if (changed.length === 0) {
    console.log('  没有任何输出变化 ✅');
  } else {
    console.log(`  ⚠️ ${changed.length} 条输出变了 —— 逐条确认是不是你想要的变化。`);
    console.log('     不确定就不要合。用户的要求：改了必须全量回归通过。');
  }
  process.exit(changed.length === 0 ? 0 : 1);
}

// ── 存基线 ──────────────────────────────────────────────────────────────────
console.log(`全量跑一遍存基线：${targets.length} 条录音 · cleanup=${CLEANUP}`);
console.log('='.repeat(72));

const results = [];
let done = 0;
for (const entry of targets) {
  const result = await runOne(path.join(CORPUS_DIR, entry.audio));
  done += 1;
  process.stdout.write(`\r  进度 ${done}/${targets.length}`);
  if (!result?.ok) continue;
  results.push({ ts: entry.ts, raw: result.raw ?? '', text: result.text ?? '' });
}
process.stdout.write('\n');

const payload = {
  savedAt: new Date().toISOString(),
  cleanup: CLEANUP,
  count: results.length,
  results,
};

if (SAVE) {
  fs.writeFileSync(SAVE, `${JSON.stringify(payload, null, 2)}\n`);
  console.log(`  已存到 ${SAVE}（${results.length} 条）`);
} else {
  console.log(`  跑完 ${results.length} 条。加 --save <文件> 可以把结果存下来做基线。`);
}
