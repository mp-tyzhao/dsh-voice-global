/**
 * 坏输入的优雅降级测试
 * ====================
 * 跑法：node sidecar/robustness.test.mjs
 *
 * 词表、待定区、语料都是**用户可以直接编辑、也可能被别的东西写坏**的文件。
 * 它们损坏时不应该是"程序崩了"，而应该是"退回到没有个性化的状态，继续能用"。
 *
 * 这些场景在正常使用中很罕见，但一旦发生就是"整个工具打不开"级别的事故。
 * 所以逐个写下来，防止以后改代码时不小心破坏降级路径。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { loadTerms, renderVocabularyPrompt, stripFabricatedTerms } from './dictionary.mjs';
import { extractTerms, learn, describeTerms, removeTerms, mergeTerms } from './learning.mjs';
import { applyTerms, selectRelevantTerms } from './phonetic.mjs';

let failures = 0;
function check(label, ok, detail) {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}`);
  if (!ok && detail) console.log(`      ${detail}`);
  if (!ok) failures += 1;
}

/** 把一段内容写进临时词表，返回路径 */
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vg-robust-'));
let counter = 0;
function writeDictionary(content) {
  counter += 1;
  const file = path.join(dir, `dict-${counter}.json`);
  fs.writeFileSync(file, content);
  return file;
}

console.log('— 词表损坏 —');
{
  check('文件不存在 → 空词表', loadTerms(path.join(dir, '不存在.json')).length === 0);
  check('坏 JSON → 空词表', loadTerms(writeDictionary('{ 这不是 JSON')).length === 0);
  check('空文件 → 空词表', loadTerms(writeDictionary('')).length === 0);
  check('terms 不是数组 → 空词表', loadTerms(writeDictionary('{"terms":"字符串"}')).length === 0);
  check('terms 里有 null/数字/对象 → 只留字符串', (() => {
    const terms = loadTerms(writeDictionary('{"terms":["Milvus",123,null,{"a":1},"Kubernetes"]}'));
    return terms.length === 2 && terms.includes('Milvus') && terms.includes('Kubernetes');
  })());
  check('顶层是数组（老格式）→ 仍能读', (() => {
    const terms = loadTerms(writeDictionary('["Milvus","Kubernetes"]'));
    return terms.length === 2;
  })());
  check('词表为空 → 提示文本为空', renderVocabularyPrompt([]) === '');
}

console.log('\n— 词表异常但不该崩的运算 —');
{
  const weird = ['', '   ', 'a'.repeat(500), '带\n换行', '带\t制表', '🙂emoji'];
  for (const term of weird) {
    let ok = true;
    try {
      applyTerms('测试一下这句话', [term]);
      selectRelevantTerms('测试一下这句话', [term]);
      renderVocabularyPrompt([term]);
    } catch (error) {
      ok = false;
      check(`词表含异常项 ${JSON.stringify(term.slice(0, 12))} 不崩`, false, String(error));
    }
    if (ok) check(`词表含异常项 ${JSON.stringify(term.slice(0, 12))} 不崩`, true);
  }
}

console.log('\n— 待定区损坏 —');
{
  const dict = path.join(dir, 'learn-dict.json');
  const pending = path.join(dir, 'pending.json');
  const candidate = [{ term: '聚水潭', confidence: 0.6, kind: 'cjk-guessed' }];

  fs.writeFileSync(pending, 'garbage');
  const first = learn(dict, pending, candidate);
  check('待定区是坏 JSON → 当作空的重来，不崩', first.pending.includes('聚水潭'), JSON.stringify(first));

  fs.writeFileSync(pending, '{"聚水潭":{"count":1,"confidence":0.6}}');
  const second = learn(dict, pending, candidate);
  check('待定区正常时能提升', second.added.includes('聚水潭'), JSON.stringify(second));
}

console.log('\n— 词表不可写 —');
{
  // 目录只读：写不进去也该返回结果而不是抛错（用户可能把词表放在只读位置）
  const readOnlyDir = path.join(dir, 'readonly');
  fs.mkdirSync(readOnlyDir, { recursive: true });
  fs.chmodSync(readOnlyDir, 0o500);
  const target = path.join(readOnlyDir, 'dictionary.json');
  let threw = null;
  try {
    mergeTerms(target, ['测试词']);
  } catch (error) {
    threw = error;
  }
  check('往只读目录写词表不抛错', threw === null, String(threw));
  fs.chmodSync(readOnlyDir, 0o700);
}

console.log('\n— 列表 / 删除 / 合并 面对坏文件 —');
{
  const broken = writeDictionary('不是 JSON');
  check('describeTerms 面对坏文件返回空', describeTerms(broken).length === 0);
  check('removeTerms 面对坏文件不崩', (() => {
    try { removeTerms(broken, ['任意']); return true; } catch { return false; }
  })());
}

console.log('\n— 抽取面对极端输入 —');
{
  const cases = [
    ['', '', '两个空串'],
    ['只有原文没有改正', '只有原文没有改正', '完全相同'],
    ['a', 'b', '单字符'],
    ['很长的原文'.repeat(200), '很长的改正'.repeat(200), '超长文本'],
    ['带 emoji 🙂 的句子', '带 emoji 😀 的句子', '含 emoji'],
  ];
  for (const [raw, corrected, label] of cases) {
    let ok = true;
    let detail = '';
    try {
      extractTerms(raw, corrected);
    } catch (error) {
      ok = false;
      detail = String(error);
    }
    check(`抽取面对「${label}」不崩`, ok, detail);
  }
}

console.log('\n— 伪造检测面对坏词表 —');
{
  const result = stripFabricatedTerms('原文', '原文加了 Milvus', ['Milvus']);
  check('正常词表能撤销编造', result.removed.includes('Milvus'), JSON.stringify(result));

  let ok = true;
  try {
    stripFabricatedTerms('文本', '文本', []);
    stripFabricatedTerms('', '', ['Milvus']);
    stripFabricatedTerms('文本', '文本', ['', '   ']);
  } catch { ok = false; }
  check('空词表 / 空文本不崩', ok);
}

fs.rmSync(dir, { recursive: true, force: true });
console.log();
if (failures === 0) {
  console.log('ALL PASS');
  process.exit(0);
}
console.log(`${failures} 项失败`);
process.exit(1);
