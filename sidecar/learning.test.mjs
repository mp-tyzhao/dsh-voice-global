/**
 * 学习模块的单元测试
 * 跑法：node sidecar/learning.test.mjs
 *
 * 用例全部来自真实听写记录（用户口述后的实际改写），不是编造的假数据。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { extractTerms, mergeTerms } from './learning.mjs';

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
  const terms = extractTerms(
    '我们想一想怎么样能像tys那样吧。一些专有术语识别的越来越好。',
    '我们想一想，怎么样能像Typeless那样，把一些专有术语识别得越来越好。',
  );
  check('抽出 Typeless', has(terms, 'Typeless'), JSON.stringify(terms));
}
{
  // 真实记录：ASR 漏掉了整个英文短语，用户补上
  const terms = extractTerms(
    '比如 forggy do you seek the promptly.给我一个人设。',
    '比如给 LLM 的 prompt 里给我一个人设',
  );
  check('抽出英文词（LLM / prompt）', has(terms, 'LLM') || has(terms, 'prompt'), JSON.stringify(terms));
}
{
  // 中文专有名词：同音字改正
  const terms = extractTerms(
    '这个需求由赵天义负责，下周同步给奇迹创谈。',
    '这个需求由赵天翊负责，下周同步给奇绩创坛。',
  );
  check('抽出中文人名/机构名', has(terms, '赵天翊') && has(terms, '奇绩创坛'), JSON.stringify(terms));
}
{
  // 插入型：原文里整个词被漏掉
  const terms = extractTerms(
    '顺便看看的召回率。',
    '顺便看看 Milvus 的召回率。',
  );
  check('抽出被漏掉的插入词 Milvus', has(terms, 'Milvus'), JSON.stringify(terms));
}

console.log('\n— 不该抽的 —');
{
  const terms = extractTerms('今天天气不错。', '今天天气不错。');
  check('没改动 → 不抽任何词', terms.length === 0, JSON.stringify(terms));
}
{
  const terms = extractTerms('好的', '好的。');
  check('只加标点 → 不抽词', terms.length === 0, JSON.stringify(terms));
}
{
  const terms = extractTerms('三点开会', '3点开会');
  check('数字规整（三点→3点）不抽词', !has(terms, '3'), JSON.stringify(terms));
}
{
  const terms = extractTerms('我用Milvus做检索', '我用 Milvus 做检索');
  check('原文已有的词不再抽（只是补空格）', terms.length === 0, JSON.stringify(terms));
}
{
  const terms = extractTerms('我觉得这个可以', '我觉得这个行');
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

console.log();
if (failures === 0) {
  console.log('ALL PASS');
  process.exit(0);
}
console.log(`${failures} 项失败`);
process.exit(1);
