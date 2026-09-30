#!/usr/bin/env node
/**
 * 成本复现脚本
 * ============
 *
 * 复现 README 里的成本结论：连续跑若干次真实润色请求，打印 token 用量、延迟，
 * 并按 DeepSeek 官方定价换算成钱。
 *
 * 密钥来源（按顺序）：--api-key 参数 → 环境变量 → ~/.voice-global/.env
 *
 * 用法：
 *   node bench/cost.mjs                    # 默认 flash，5 次
 *   node bench/cost.mjs --rounds 10
 *   node bench/cost.mjs --model deepseek-v4-pro
 *   node bench/cost.mjs --compare          # flash 与 pro 各跑一遍对比
 */
import fs from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { polish } from '../sidecar/llm.mjs';

/** 官方价（USD / 1M tokens）。高峰 = 非高峰 ×2；高峰为 UTC 01-04、06-10 的工作日。 */
const PRICE = {
  'deepseek-flash': { hit: 0.003, miss: 0.15, out: 0.6 },
  'deepseek-v4-pro': { hit: 0.022, miss: 0.66, out: 1.98 },
};
const USD_TO_CNY = 7.1;

const args = process.argv.slice(2);
const value = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : fallback;
};
const has = (name) => args.includes(name);

/** 典型的听写原文：没标点、带口头禅、偶尔有口头修正。 */
const SAMPLES = [
  '我们下周三下午三点开个评审会你记得把上回那个原型图带上另外就是如果时间来得及我们顺便把预算过一下',
  '这个方案我觉得可以但是有个问题是接口那边的字段还没定下来所以前端可能要先做假数据',
  '那我们先按这个方向推进吧有问题随时同步我这边也会盯着测试环境的部署情况',
  '帮我订一下明天下午两点的会议室大概一个小时然后通知一下产品那边的人',
  '这个功能先上一个最小版本吧不对应该是先做用户调研再说',
];

function resolveKey() {
  const inline = value('--api-key');
  if (inline) return inline;
  if (process.env.DEEPSEEK_API_KEY) return process.env.DEEPSEEK_API_KEY;
  const envFile = path.join(homedir(), '.voice-global', '.env');
  if (fs.existsSync(envFile)) {
    const match = fs.readFileSync(envFile, 'utf8').match(/^(?:export\s+)?DEEPSEEK_API_KEY=(.+)$/m);
    if (match) return match[1].trim().replace(/^["']|["']$/g, '');
  }
  return undefined;
}

const apiKey = resolveKey();
if (!apiKey) {
  console.error('没有找到 API 密钥。用 --api-key 传入，或写入 ~/.voice-global/.env');
  process.exit(1);
}

/** 跑 n 次并汇总。 */
async function bench(model, rounds) {
  const price = PRICE[model];
  if (!price) {
    console.error(`未知模型 ${model}，已知：${Object.keys(PRICE).join(', ')}`);
    process.exit(1);
  }

  const rows = [];
  for (let i = 0; i < rounds; i++) {
    const text = SAMPLES[i % SAMPLES.length];
    let usage;
    const started = Date.now();
    const output = await polish({
      baseURL: 'https://api.deepseek.com/v1',
      apiKey,
      model,
      text,
      timeoutMs: 30000,
      onUsage: (u) => { usage = u; },
    });
    rows.push({ ms: Date.now() - started, usage, output, text });
  }

  let peakCost = 0;
  let offPeakCost = 0;
  for (const row of rows) {
    const hit = row.usage.prompt_cache_hit_tokens ?? 0;
    const miss = row.usage.prompt_cache_miss_tokens ?? row.usage.prompt_tokens;
    const out = row.usage.completion_tokens;
    offPeakCost += (hit * price.hit + miss * price.miss + out * price.out) / 1e6;
    peakCost += (hit * price.hit * 2 + miss * price.miss * 2 + out * price.out * 2) / 1e6;
  }

  const count = rows.length;
  console.log(`\n### ${model}（${count} 次）`);
  rows.forEach((row, i) => {
    const hit = row.usage.prompt_cache_hit_tokens ?? 0;
    console.log(
      `  ${String(i + 1).padStart(2)}. 输入 ${row.usage.prompt_tokens}` +
      `（缓存命中 ${hit} / 未命中 ${row.usage.prompt_tokens - hit}）` +
      ` 输出 ${row.usage.completion_tokens} · ${row.ms}ms`,
    );
  });

  const avgMs = Math.round(rows.reduce((sum, row) => sum + row.ms, 0) / count);
  const avgPeak = peakCost / count;
  const avgOffPeak = offPeakCost / count;
  console.log(`  平均延迟 ${avgMs}ms`);
  console.log(`  单次成本：非高峰 $${avgOffPeak.toFixed(6)}（¥${(avgOffPeak * USD_TO_CNY).toFixed(5)}）｜高峰 $${avgPeak.toFixed(6)}（¥${(avgPeak * USD_TO_CNY).toFixed(5)}）`);
  console.log(`  每千次：非高峰 ¥${(avgOffPeak * 1000 * USD_TO_CNY).toFixed(2)}｜高峰 ¥${(avgPeak * 1000 * USD_TO_CNY).toFixed(2)}`);
  console.log(`  每天 100 次：约 ¥${(avgPeak * 100 * 30 * USD_TO_CNY).toFixed(2)}/月（按高峰价）`);
  return { avgMs, avgPeak, avgOffPeak };
}

console.log('样本：');
SAMPLES.forEach((sample, i) => console.log(`  ${i + 1}. ${sample}`));

if (has('--compare')) {
  const flash = await bench('deepseek-flash', Number(value('--rounds', 5)));
  const pro = await bench('deepseek-v4-pro', Number(value('--rounds', 3)));
  console.log('\n### 结论');
  console.log(`  flash 更快更便宜：${flash.avgMs}ms / ¥${(flash.avgPeak * USD_TO_CNY).toFixed(5)} 一次`);
  console.log(`  pro   更慢更贵  ：${pro.avgMs}ms / ¥${(pro.avgPeak * USD_TO_CNY).toFixed(5)} 一次`);
  console.log('  清理文本属于格式化任务，flash 已经够用。');
} else {
  await bench(value('--model', 'deepseek-flash'), Number(value('--rounds', 5)));
}
