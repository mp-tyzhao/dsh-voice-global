#!/usr/bin/env node
/**
 * 使用记录
 * ========
 *
 * 把所有听写记录汇总成一份可读的报告：用了多少、改了多少、学到了什么、
 * 快不快。数据全部来自本机 `~/.voice-global/recordings/index.jsonl`，不联网。
 *
 * 跑法：
 *   node scripts/report.mjs            # 最近 30 天
 *   node scripts/report.mjs --days 7   # 最近 7 天
 *   node scripts/report.mjs --all      # 全部
 *   node scripts/report.mjs --json     # 给脚本用
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const argv = process.argv.slice(2);
const ALL = argv.includes('--all');
const DAYS = argv.includes('--days') ? Number(argv[argv.indexOf('--days') + 1]) : 30;
const AS_JSON = argv.includes('--json');

const HOME = os.homedir();
const CORPUS = process.env.VOICE_GLOBAL_CORPUS
  || path.join(HOME, '.voice-global', 'recordings', 'index.jsonl');
const DICTIONARY = path.join(HOME, '.voice-global', 'dictionary.json');

function loadCorpus() {
  try {
    return fs.readFileSync(CORPUS, 'utf8').split('\n')
      .filter((line) => line.trim())
      .map((line) => { try { return JSON.parse(line); } catch { return null; } })
      .filter(Boolean);
  } catch {
    return [];
  }
}

function loadDictionary() {
  try {
    const parsed = JSON.parse(fs.readFileSync(DICTIONARY, 'utf8'));
    const terms = Array.isArray(parsed) ? parsed : (parsed.terms ?? []);
    const origin = parsed.origin ?? {};
    return terms
      .filter((t) => typeof t === 'string')
      .map((term) => ({ term, addedBy: origin[term]?.addedBy ?? 'manual', at: origin[term]?.at }));
  } catch {
    return [];
  }
}

const all = loadCorpus();
let rows = all;
if (!ALL) {
  const cutoff = new Date(Date.now() - DAYS * 86400_000).toISOString().slice(0, 10);
  rows = all.filter((entry) => (entry.ts ?? '') >= cutoff);
}

// ── 汇总 ────────────────────────────────────────────────────────────────────

const byDay = new Map();
for (const entry of rows) {
  const day = (entry.ts ?? '').slice(0, 10);
  if (!day) continue;
  const bucket = byDay.get(day) ?? { count: 0, seconds: 0, fixes: 0, trims: 0 };
  bucket.count += 1;
  bucket.seconds += Number(entry.seconds) || 0;
  if (entry.corrected) {
    if (entry.editKind === 'trim') bucket.trims += 1;
    else bucket.fixes += 1;
  }
  byDay.set(day, bucket);
}

const fixes = rows.filter((e) => e.corrected && e.editKind !== 'trim').length;
const trims = rows.filter((e) => e.editKind === 'trim').length;
const seconds = rows.reduce((sum, e) => sum + (Number(e.seconds) || 0), 0);

// 端到端耗时：从日志里取更全（语料里只存了分段耗时）
const durations = [];
try {
  const log = fs.readFileSync(path.join(HOME, '.voice-global', 'log.txt'), 'utf8');
  for (const match of log.matchAll(/端到端=(\d+)ms/g)) durations.push(Number(match[1]));
} catch { /* 没有日志就算了 */ }
durations.sort((a, b) => a - b);
const median = durations.length ? durations[Math.floor(durations.length / 2)] : 0;
const p90 = durations.length ? durations[Math.floor(durations.length * 0.9)] : 0;

const learned = loadDictionary().filter((t) => t.addedBy === 'learned');
const manual = loadDictionary().filter((t) => t.addedBy !== 'learned');

const report = {
  window: ALL ? '全部' : `最近 ${DAYS} 天`,
  total: rows.length,
  allTime: all.length,
  seconds: Math.round(seconds),
  fixes,
  trims,
  fixRate: rows.length ? fixes / rows.length : 0,
  byDay: [...byDay.entries()].sort((a, b) => a[0].localeCompare(b[0])),
  learned: learned.map((t) => t.term),
  manualCount: manual.length,
  latency: { samples: durations.length, median, p90, max: durations[durations.length - 1] ?? 0 },
};

if (AS_JSON) {
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  process.exit(0);
}

// ── 输出 ────────────────────────────────────────────────────────────────────

const minutes = Math.round(seconds / 60);
const fmtSeconds = seconds >= 3600
  ? `${(seconds / 3600).toFixed(1)} 小时`
  : `${minutes} 分钟`;

console.log(`使用记录（${report.window}）`);
console.log('='.repeat(64));
console.log();
console.log(`  听写次数    ${report.total} 条${ALL ? '' : `（累计 ${report.allTime} 条）`}`);
console.log(`  说话时长    ${fmtSeconds}`);
if (report.total) console.log(`  平均每条    ${(seconds / report.total).toFixed(1)} 秒`);

console.log();
console.log('  识别质量');
console.log(`    手动修正    ${fixes} 条  ${report.total ? `(${(report.fixRate * 100).toFixed(1)}%)` : ''}`);
if (trims) console.log(`    改主意删减  ${trims} 条  （不算识别错误）`);
if (report.total) {
  const accuracy = 1 - report.fixRate;
  console.log(`    一次通过率  ${(accuracy * 100).toFixed(1)}%`);
}

if (durations.length) {
  console.log();
  console.log('  速度（端到端，含云端润色）');
  console.log(`    中位数      ${median}ms`);
  console.log(`    P90         ${p90}ms`);
}

console.log();
console.log('  词表');
console.log(`    共 ${learned.length + manual.length} 条：手动 ${manual.length}，系统学到 ${learned.length}`);
if (report.learned.length) console.log(`    学到的      ${report.learned.join('、')}`);

if (report.byDay.length) {
  console.log();
  console.log('  按天');
  const max = Math.max(...report.byDay.map(([, b]) => b.count));
  for (const [day, bucket] of report.byDay) {
    const bar = '█'.repeat(Math.max(1, Math.round((bucket.count / max) * 24)));
    const extra = bucket.fixes ? `  改了 ${bucket.fixes}` : '';
    console.log(`    ${day}  ${String(bucket.count).padStart(3)}  ${bar}${extra}`);
  }
}

console.log();
console.log('  数据都在本机：~/.voice-global/recordings/index.jsonl');
