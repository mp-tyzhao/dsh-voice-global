/**
 * 学习模块的单元测试
 * 跑法：node sidecar/learning.test.mjs
 *
 * 用例全部来自真实听写记录（用户口述后的实际改写），不是编造的假数据。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { extractTerms, extractTermNames, mergeTerms, learn } from './learning.mjs';

let failures = 0;
function check(label, condition, detail) {
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${label}`);
  if (detail) console.log(`      ${detail}`);
  if (!condition) failures += 1;
}
const has = (list, term) => list.some((t) => t.toLowerCase() === term.toLowerCase());

console.log('— 从真实改正中抽词 —');
{
  // 真实记录：ASR 输出 "tys"，用户改成了 "Typeless"
  const terms = extractTermNames(
    '我们想一想怎么样能像tys那样吧。一些专有术语识别的越来越好。',
    '我们想一想，怎么样能像Typeless那样，把一些专有术语识别得越来越好。',
  );
  check('抽出 Typeless', has(terms, 'Typeless'), JSON.stringify(terms));
}
{
  // 真实记录：ASR 漏掉了整个英文短语，用户补上
  const terms = extractTermNames(
    '比如 forggy do you seek the promptly.给我一个人设。',
    '比如给 LLM 的 prompt 里给我一个人设',
  );
  check('抽出英文词（LLM / prompt）', has(terms, 'LLM') || has(terms, 'prompt'), JSON.stringify(terms));
}
{
  // 中文专有名词：同音字改正
  const terms = extractTermNames(
    '这个需求由赵天义负责，下周同步给奇迹创谈。',
    '这个需求由赵天翊负责，下周同步给奇绩创坛。',
  );
  check('抽出中文人名/机构名', has(terms, '赵天翊') && has(terms, '奇绩创坛'), JSON.stringify(terms));
}
{
  // 插入型：原文里整个词被漏掉
  const terms = extractTermNames(
    '顺便看看的召回率。',
    '顺便看看 Milvus 的召回率。',
  );
  check('抽出被漏掉的插入词 Milvus', has(terms, 'Milvus'), JSON.stringify(terms));
}

console.log('\n— 不该抽的 —');
{
  const terms = extractTermNames('今天天气不错。', '今天天气不错。');
  check('没改动 → 不抽任何词', terms.length === 0, JSON.stringify(terms));
}
{
  const terms = extractTermNames('好的', '好的。');
  check('只加标点 → 不抽词', terms.length === 0, JSON.stringify(terms));
}
{
  const terms = extractTermNames('三点开会', '3点开会');
  check('数字规整（三点→3点）不抽词', !has(terms, '3'), JSON.stringify(terms));
}
{
  const terms = extractTermNames('我用Milvus做检索', '我用 Milvus 做检索');
  check('原文已有的词不再抽（只是补空格）', terms.length === 0, JSON.stringify(terms));
}
{
  const terms = extractTermNames('我觉得这个可以', '我觉得这个行');
  check('单字改动不算术语（长度不足）', !has(terms, '行'), JSON.stringify(terms));
}

console.log('\n— 合并进词表 —');
{
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vg-learn-'));
  const file = path.join(dir, 'dictionary.json');

  const first = mergeTerms(file, ['Typeless', 'Milvus']);
  check('首次写入建文件', first.added.length === 2 && first.total === 2, JSON.stringify(first));
  check('文件是合法 JSON', (() => {
    try { JSON.parse(fs.readFileSync(file, 'utf8')); return true; } catch { return false; }
  })());

  const second = mergeTerms(file, ['Typeless', 'SenseVoice']);
  check('重复的不再加', second.added.length === 1 && second.added[0] === 'SenseVoice', JSON.stringify(second));
  check('大小写不同视为重复', mergeTerms(file, ['typeless']).added.length === 0);

  const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
  check('原有词条保留', doc.terms.includes('Milvus') && doc.terms.includes('Typeless'));
  check('写入 updatedAt', typeof doc.updatedAt === 'string');

  // 坏文件不应该让学习崩掉
  fs.writeFileSync(file, '{ 这不是 JSON');
  const recovered = mergeTerms(file, ['Recovered']);
  check('文件损坏时能重建', recovered.added.length === 1, JSON.stringify(recovered));

  fs.rmSync(dir, { recursive: true, force: true });
}


console.log('\n— 术语边界（全部来自真实使用）—');
{
  // 边界判错比漏抽更糟：抽成"用户侧自进"，下次就会把正确的"化"截掉
  const cases = [
    ['你看用户测自净化这两个词都识别错了', '你看用户侧自进化这两个词都识别错了', '用户侧自进化'],
    ['这个需求由赵天义负责', '这个需求由赵天翊负责', '赵天翊'],
    ['下周同步给奇迹创谈', '下周同步给奇绩创坛', '奇绩创坛'],
    ['我们想一想怎么样能像tys那样吧', '我们想一想怎么样能像Typeless那样', 'Typeless'],
  ];
  for (const [raw, corrected, want] of cases) {
    const got = extractTermNames(raw, corrected);
    check(`边界正确：${want}`, got.includes(want), `抽到 ${JSON.stringify(got)}`);
  }
}

console.log('\n— 明显不是术语的形态（Gboard 过滤器）—');
{
  const junk = ['hahaha', 'yesss', 'nooo', '好好好', 'abc123'];
  for (const term of junk) {
    const got = extractTermNames('原始文本', `原始文本 ${term}`);
    check(`丢弃 ${term}`, got.length === 0, JSON.stringify(got));
  }
  // 误伤检查：这三个都容易被"重复字符"规则误杀
  for (const term of ['LLM', 'prompt', 'Alibaba', 'Kubernetes']) {
    const got = extractTermNames('原始文本', `原始文本 ${term}`);
    check(`保留 ${term}`, got.includes(term), JSON.stringify(got));
  }
}

console.log('\n— 置信度分级与待定区 —');
{
  const latin = extractTerms('我们想想像tys那样', '我们想想像Typeless那样');
  check('西文词置信度高（直接生效）', latin[0]?.confidence >= 0.8, JSON.stringify(latin));

  const guessed = extractTerms('这个需求由赵天义负责', '这个需求由赵天翊负责');
  check('中文单字替换置信度低（需要再见一次）',
    guessed[0]?.confidence < 0.8 && guessed[0]?.kind === 'cjk-guessed', JSON.stringify(guessed));

  const junk = extractTerms('像tys那样吧', '像Typeless那样，把一些');
  check('首字是虚词的碎片被过滤掉', !junk.some((c) => c.term.startsWith('把')), JSON.stringify(junk));
}
{
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vg-tier-'));
  const dict = path.join(dir, 'dictionary.json');
  const pending = path.join(dir, 'pending.json');
  const low = [{ term: '赵天翊', confidence: 0.6, kind: 'cjk-guessed' }];

  const first = learn(dict, pending, low);
  check('低置信度第一次不进词表', first.added.length === 0 && first.pending.includes('赵天翊'), JSON.stringify(first));

  const second = learn(dict, pending, low);
  check('第二次提升进词表', second.added.includes('赵天翊') && second.promoted.includes('赵天翊'), JSON.stringify(second));

  const high = learn(dict, pending, [{ term: 'Milvus', confidence: 0.9, kind: 'latin' }]);
  check('高置信度一次生效', high.added.includes('Milvus'), JSON.stringify(high));

  fs.rmSync(dir, { recursive: true, force: true });
}

console.log();
if (failures === 0) {
  console.log('ALL PASS');
  process.exit(0);
}
console.log(`${failures} 项失败`);
process.exit(1);
