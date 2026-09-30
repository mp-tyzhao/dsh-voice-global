#!/usr/bin/env node
/**
 * 准确率评测
 * ==========
 *
 * 拿语料里的 (音频, ASR 原始输出, 正确答案) 跑完整流程，量出真实准确率。
 * **没有这个，"改动有没有变准"只能靠感觉。**
 *
 * 正确答案从两个地方来：
 *   1. 语料里用户手工改过的记录（`corrected` 字段，由输入框观测自动写入）
 *   2. `bench/labels.jsonl` 手工标注 —— 一行一条 `{"ts":"...","truth":"..."}`
 *
 * 用法：
 *   node bench/accuracy.mjs                 # 用现存语料里的 raw/text，不重跑模型（快）
 *   node bench/accuracy.mjs --rerun         # 真的重新跑一遍 ASR + 润色（慢，但反映当前代码）
 *   node bench/accuracy.mjs --rerun --no-dict   # 关掉词表跑，用来量词表的贡献
 *
 * 指标是 **CER（字错率）**：编辑距离 / 正确答案长度。中文场景比词错率更稳。
 */

import { readFileSync, writeFileSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { homedir, tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const HOME = homedir();
const CORPUS = join(HOME, '.voice-global', 'recordings', 'index.jsonl');
const LABELS = join(ROOT, 'bench', 'labels.jsonl');
const DICTIONARY = join(HOME, '.voice-global', 'dictionary.json');

const argv = process.argv.slice(2);
const RERUN = argv.includes('--rerun');
const NO_DICT = argv.includes('--no-dict');
const NO_GAIN = argv.includes('--no-gain');
// 同一配置重复跑几次取均值。实测单跑噪声约 1.1 个点 ——
// 不比这个小得多的差异就下结论，等于在噪声里找信号。
const REPEAT = Math.max(1, Number(argv[argv.indexOf('--repeat') + 1]) || 1);

// ── 指标 ────────────────────────────────────────────────────────────────────

/** 字符级编辑距离（Levenshtein）。中文按字算，英文按字符算。 */
export function editDistance(a, b) {
  const x = Array.from(a);
  const y = Array.from(b);
  if (!x.length) return y.length;
  if (!y.length) return x.length;
  let prev = Array.from({ length: y.length + 1 }, (_, i) => i);
  for (let i = 1; i <= x.length; i += 1) {
    const current = [i];
    for (let j = 1; j <= y.length; j += 1) {
      current[j] = Math.min(
        prev[j] + 1,
        current[j - 1] + 1,
        prev[j - 1] + (x[i - 1] === y[j - 1] ? 0 : 1),
      );
    }
    prev = current;
  }
  return prev[y.length];
}

/** CER = 编辑距离 / 参考文本长度。 */
export function cer(hypothesis, reference) {
  const ref = Array.from(reference ?? '');
  if (!ref.length) return hypothesis ? 1 : 0;
  return editDistance(hypothesis ?? '', reference) / ref.length;
}

// ── 语料 ────────────────────────────────────────────────────────────────────

function loadCorpus() {
  if (!existsSync(CORPUS)) return [];
  return readFileSync(CORPUS, 'utf8').split('\n')
    .filter((line) => line.trim())
    .map((line) => { try { return JSON.parse(line); } catch { return null; } })
    .filter(Boolean);
}

function loadManualLabels() {
  if (!existsSync(LABELS)) return new Map();
  const map = new Map();
  for (const line of readFileSync(LABELS, 'utf8').split('\n')) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line);
      if (entry.ts && entry.truth) map.set(entry.ts, entry.truth);
    } catch { /* 坏行跳过 */ }
  }
  return map;
}

/** 跑一遍完整流水线，返回输出文本。 */
function runPipeline(wavPath, dictionaryPath) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env };
    if (dictionaryPath) env.VOICE_GLOBAL_DICTIONARY = dictionaryPath;
    if (NO_GAIN) env.VOICE_GLOBAL_NO_GAIN = '1';
    const child = spawn('node', [join(ROOT, 'sidecar', 'server.mjs'), '--once', wavPath, '--cleanup', 'llm'], {
      env, stdio: ['ignore', 'pipe', 'ignore'],
    });
    let out = '';
    child.stdout.on('data', (chunk) => { out += chunk; });
    child.on('error', reject);
    child.on('close', () => {
      const line = out.trim().split('\n').pop();
      try { resolve(JSON.parse(line)); } catch { resolve({ ok: false, error: '无法解析输出' }); }
    });
  });
}

// ── 主流程 ──────────────────────────────────────────────────────────────────

const corpus = loadCorpus();
const manual = loadManualLabels();

const cases = [];
for (const entry of corpus) {
  const truth = manual.get(entry.ts) ?? entry.corrected;
  if (!truth) continue;                       // 没有正确答案就没法算
  cases.push({ ...entry, truth });
}
// 手工标注可以覆盖语料里没有的条目
for (const [ts, truth] of manual) {
  if (!cases.some((c) => c.ts === ts)) cases.push({ ts, truth, raw: '', text: '' });
}

console.log('准确率评测');
console.log('='.repeat(78));
console.log(`  语料条目    ${corpus.length}`);
console.log(`  有正确答案  ${cases.length}${cases.length === 0 ? '   ← 先攒一些带标注的语料' : ''}`);
console.log(`  模式        ${RERUN ? `重跑流水线 ×${REPEAT}` : '用语料里存的输出'}${NO_DICT ? '（关掉词表）' : ''}${NO_GAIN ? '（关掉增益）' : ''}`);
console.log();

if (cases.length === 0) {
  console.log('没有可用于评测的样本。两种攒法：');
  console.log('  1. 正常使用 —— 在输入框里改掉识别错的字，改动会自动记进 corrected');
  console.log('  2. 手工补 —— 往 bench/labels.jsonl 写 {"ts":"<时间戳>","truth":"<你实际说的>"}');
  process.exit(0);
}

let tempDir = null;
let dictionaryPath = DICTIONARY;
if (NO_DICT) {
  tempDir = mkdtempSync(join(tmpdir(), 'vg-nodict-'));
  dictionaryPath = join(tempDir, 'empty-dictionary.json');
  writeFileSync(dictionaryPath, '{"terms":[]}');
}

const rows = [];
for (const item of cases) {
  let output = item.text ?? '';
  let raw = item.raw ?? '';
  let note = '';

  if (RERUN) {
    const audio = item.audio ? join(HOME, '.voice-global', 'recordings', item.audio) : null;
    if (!audio || !existsSync(audio)) { note = '缺音频，跳过重跑'; }
    else {
      // 重复时取"编辑距离最小"的那次：模型输出有抖动，用最好的一次代表这个配置的能力上限，
      // 否则同一配置两次都能差出一个点
      let best = null;
      for (let round = 0; round < REPEAT; round += 1) {
        const result = await runPipeline(audio, dictionaryPath);
        if (!result.ok) { note = `运行失败：${result.error}`; continue; }
        const candidate = { output: result.text ?? '', raw: result.raw ?? '' };
        const distance = editDistance(candidate.output, item.truth);
        if (!best || distance < best.distance) best = { ...candidate, distance };
      }
      if (best) { output = best.output; raw = best.raw; }
    }
  }

  rows.push({
    ts: item.ts,
    truth: item.truth,
    raw,
    output,
    rawCer: cer(raw, item.truth),
    outCer: cer(output, item.truth),
    note,
  });
}

if (tempDir) rmSync(tempDir, { recursive: true, force: true });

// ── 报告 ────────────────────────────────────────────────────────────────────

const pct = (value) => `${(value * 100).toFixed(1)}%`;
const bar = (value) => '█'.repeat(Math.round((1 - Math.min(value, 1)) * 20)).padEnd(20, '·');

console.log('逐条：');
console.log('-'.repeat(78));
for (const row of rows.sort((a, b) => b.outCer - a.outCer)) {
  console.log(`  ${bar(row.outCer)} ASR ${pct(row.rawCer).padStart(6)}  最终 ${pct(row.outCer).padStart(6)}  ${row.note}`);
  console.log(`      正确：${row.truth}`);
  console.log(`      输出：${row.output}`);
  if (row.raw && row.raw !== row.output) console.log(`      原始：${row.raw}`);
}

const mean = (pick) => rows.reduce((sum, row) => sum + pick(row), 0) / rows.length;
const asrCer = mean((r) => r.rawCer);
const finalCer = mean((r) => r.outCer);

console.log();
console.log('='.repeat(78));
console.log(`  样本数        ${rows.length}`);
console.log(`  ASR 原始 CER  ${pct(asrCer)}`);
console.log(`  最终输出 CER  ${pct(finalCer)}`);
console.log(`  流程贡献      ${finalCer <= asrCer ? '↓' : '↑'} ${pct(Math.abs(asrCer - finalCer))}`);
console.log();
console.log('  CER 越低越好。0% = 与正确答案逐字一致。');
