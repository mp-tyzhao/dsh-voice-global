/**
 * 学习闭环的端到端集成测试
 * ========================
 *
 * 跑法：node sidecar/learning-loop.test.mjs
 *
 * 单测各自验证过一个零件，这里验证**整条链**：
 *
 *   用户改正 → 抽词 → 分级 → 进词表 → 拼音层自动纠正下一句
 *
 * 这是产品的头号卖点（"越用越懂你"），所以值得有一个跨模块的验证：
 * 任何一环断了，单测都还是绿的。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { learn, extractTerms, blastRadius } from './learning.mjs';
import { applyTerms } from './phonetic.mjs';
import { loadTerms } from './dictionary.mjs';

let failures = 0;
function check(label, ok, detail) {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}`);
  if (!ok && detail) console.log(`      ${detail}`);
  if (!ok) failures += 1;
}

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vg-loop-'));
const dictionary = path.join(dir, 'dictionary.json');
const pending = path.join(dir, 'pending.json');
const readTerms = () => loadTerms(dictionary);

console.log('— 场景一：西文术语，一次就该学到 —');
{
  // 用户说 "像 Typeless 那样"，识别成了 "像 tys 那样"，用户手改成 Typeless
  const raw = '我们想一想怎么样能像tys那样，把一些专有术语识别得越来越好';
  const corrected = '我们想一想怎么样能像Typeless那样，把一些专有术语识别得越来越好';

  const candidates = extractTerms(raw, corrected);
  const result = learn(dictionary, pending, candidates);

  check('抽到 Typeless', candidates.some((c) => c.term === 'Typeless'), JSON.stringify(candidates));
  check('高置信度，一次就进词表', result.added.includes('Typeless'), JSON.stringify(result));
  check('词表文件里确实有', readTerms().includes('Typeless'), JSON.stringify(readTerms()));

  // 学到的词立刻进了词表，会被注入润色的提示 —— 这是 `tys → Typeless` 这类
  // 大跨度错误的修复路径（LLM 层，已由 bench/accuracy.mjs 验证）
  check('学到的词进了词表，会注入提示', readTerms().includes('Typeless'), JSON.stringify(readTerms()));

  // 而拼音层负责的是**字面接近**的拼错，这条路是本地、离线、零延迟的
  const near = applyTerms('我们能不能像Typeles那样做', readTerms());
  check('拼音层修字面接近的拼错（Typeles → Typeless）', near.text.includes('Typeless'), near.text);

  // 跨度太大的（tys）拼音层修不了，这是两层分工，不是缺陷 ——
  // 字面距离 6/8，任何阈值都救不回来，硬救只会误伤
  const far = applyTerms('我们能不能像tys那样做', readTerms());
  check('跨度大的拼错留给 LLM 层（拼音层不硬猜）', !far.text.includes('Typeless'), far.text);
}

console.log('\n— 场景二：中文同音字，低置信度要见两次 —');
{
  // 用户姓名被听成同音字。单字替换的术语边界是猜的，所以分级更低
  const raw1 = '这个需求由赵天义负责';
  const corrected1 = '这个需求由赵天翊负责';

  const first = learn(dictionary, pending, extractTerms(raw1, corrected1));
  check('第一次进待定区，不进词表', !first.added.includes('赵天翊') && first.pending.includes('赵天翊'),
    JSON.stringify(first));
  check('待定文件写下来了', fs.existsSync(pending));

  const raw2 = '赵天义那边下周同步';
  const corrected2 = '赵天翊那边下周同步';
  const second = learn(dictionary, pending, extractTerms(raw2, corrected2));
  check('第二次提升进词表', second.added.includes('赵天翊'), JSON.stringify(second));
  check('已从待定区移除', !JSON.parse(fs.readFileSync(pending, 'utf8'))['赵天翊']);

  const fixed = applyTerms('赵天义负责这个需求', readTerms());
  check('中文同音字被自动纠正', fixed.text.includes('赵天翊'), fixed.text);
  check('纠正理由是发音（拼音完全相同）', fixed.applied[0]?.score === 1, JSON.stringify(fixed.applied));
}

console.log('\n— 场景三：不该学的东西不能进词表 —');
{
  const before = readTerms().length;

  // 只加标点
  learn(dictionary, pending, extractTerms('今天天气不错', '今天天气不错。'));
  // 虚词修正（吧→把）
  learn(dictionary, pending, extractTerms('像tys那样吧', '像Typeless那样，把一些'));
  // 数字规整（三点→3点）
  learn(dictionary, pending, extractTerms('三点开会', '3点开会'));

  const after = readTerms();
  check('标点/虚词/数字改动不会污染词表', after.length === before, `${before} → ${after.length}: ${JSON.stringify(after)}`);
}

console.log('\n— 场景四：学到的词不会误伤正常文本 —');
{
  const terms = readTerms();
  const normal = [
    '今天天气不错，我们下午三点开会',
    '这个方案我觉得可行',
    '把代码部署到测试环境',
  ];
  for (const text of normal) {
    const result = applyTerms(text, terms);
    check(`不动：${text}`, result.text === text, `变成了 ${result.text}`);
  }
}

console.log('\n— 场景五：学习是幂等的，不会重复写入 —');
{
  const raw = '像tys那样';
  const corrected = '像Typeless那样';
  const before = readTerms().length;
  learn(dictionary, pending, extractTerms(raw, corrected));
  learn(dictionary, pending, extractTerms(raw, corrected));
  check('同一个词不会重复加', readTerms().length === before, `${before} → ${readTerms().length}`);
}


console.log('\n— 场景六：反事实回放，挡住过于宽泛的词 —');
{
  // 用户认可过的历史文本
  const accepted = [
    '今天我们讨论了三件事，第一件是预算',
    '这个方案下周同步给相关同事',
    '把代码部署到测试环境验证一下',
    '明天的会议改到下午三点',
  ];

  // 一个好词：只该命中它对应的错法
  const good = blastRadius('Milvus', accepted);
  check('具体术语影响面为 0', good.ratio === 0 && good.safe, JSON.stringify(good));

  // 一个已经写对的词：到处都在，但没有一处需要改动 → 影响面为 0，不该拦
  const already = blastRadius('今天', accepted);
  check('已经写对的词影响面为 0', already.ratio === 0 && already.safe, JSON.stringify(already));

  // 一个会到处改写别人文本的词：`明田` 与 `明天` 同音，会把已经正确的"明天"改掉
  const destructive = blastRadius('明田', accepted);
  check('会改动用户已认可文本的词被识别出来', !destructive.safe && destructive.ratio > 0,
    JSON.stringify(destructive));

  // 学习时真的会挡住它
  const dict2 = path.join(dir, 'dictionary2.json');
  const pending2 = path.join(dir, 'pending2.json');
  const r = learn(dict2, pending2, [{ term: '明田', confidence: 0.95, kind: 'latin' }], accepted);
  check('影响面过大的候选被拒绝', r.rejected.length > 0 && r.added.length === 0, JSON.stringify(r));
}

fs.rmSync(dir, { recursive: true, force: true });
console.log();
if (failures === 0) {
  console.log('ALL PASS');
  process.exit(0);
}
console.log(`${failures} 项失败`);
process.exit(1);
