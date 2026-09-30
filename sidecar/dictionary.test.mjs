/**
 * 词表与防编造校验的单元测试
 * 跑法：node sidecar/dictionary.test.mjs
 *
 * 用例全部来自实测（docs/v0.2-personalization.md §9）和真实听写记录，
 * 不是编出来的假数据。
 */

import {
  tokenize, alignmentGaps, stripFabricatedTerms, renderVocabularyPrompt, loadTerms,
} from './dictionary.mjs';

let failures = 0;
function check(label, condition, detail) {
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${label}`);
  if (detail) console.log(`      ${detail}`);
  if (!condition) failures += 1;
}
function eq(label, actual, expected) {
  check(label, actual === expected, actual === expected ? '' : `期望 ${JSON.stringify(expected)}，实际 ${JSON.stringify(actual)}`);
}

console.log('— tokenize —');
eq('中文按字切', JSON.stringify(tokenize('我们用')), JSON.stringify(['我', '们', '用']));
eq('西文整词', JSON.stringify(tokenize('deploy 环境')), JSON.stringify(['deploy', '环', '境']));
eq('中英混排', JSON.stringify(tokenize('用Milvus做')), JSON.stringify(['用', 'Milvus', '做']));
eq('标点不参与', JSON.stringify(tokenize('好的，。！')), JSON.stringify(['好', '的']));
eq('空输入', JSON.stringify(tokenize('')), '[]');

console.log('\n— 对齐分段 —');
{
  const gaps = alignmentGaps(tokenize('我们用mve做向量检索'), tokenize('我们用 Milvus 做向量检索'));
  const useful = gaps.filter((g) => g.out.length || g.raw.length);
  check('mve→Milvus 落在同一段（原文有被换掉的 token）',
    useful.length === 1 && useful[0].raw.join('') === 'mve' && useful[0].out.join('') === 'Milvus',
    JSON.stringify(useful));
}
{
  const gaps = alignmentGaps(tokenize('顺便看看的召回率'), tokenize('顺便看看 DeepSeek 的召回率'));
  const inserted = gaps.filter((g) => g.out.length && !g.raw.length);
  check('凭空插入的 DeepSeek 所在段原文为空',
    inserted.length === 1 && inserted[0].out.join('') === 'DeepSeek',
    JSON.stringify(gaps));
}

console.log('\n— 防编造：必须保留的合法修正 —');
{
  const terms = ['Milvus', 'Pinecone', 'deploy', 'staging'];
  const cases = [
    ['mve→Milvus（实测，拼坏但位置对应）', '我们用mve做向量检索。', '我们用 Milvus 做向量检索。', 'Milvus'],
    ['piniccom→Pinecone（实测）', '我们用piniccom做向量检索。', '我们用 Pinecone 做向量检索。', 'Pinecone'],
    ['de→deploy（实测，截断还原）', '把代码de到stging环境。', '把代码 deploy 到 staging 环境。', 'deploy'],
    ['stging→staging（实测）', '把代码de到stging环境。', '把代码 deploy 到 staging 环境。', 'staging'],
  ];
  for (const [label, raw, polished, term] of cases) {
    const result = stripFabricatedTerms(raw, polished, terms);
    check(`保留：${label}`, result.removed.length === 0 && result.text.includes(term),
      `removed=${JSON.stringify(result.removed)}`);
  }
}

console.log('\n— 防编造：必须撤销的凭空插入 —');
{
  // 真实记录：原文里 Milvus 被整个漏掉，模型从词表里挑了别的词填进去
  const terms = ['Milvus', 'Pinecone', 'DeepSeek', 'SenseVoice', 'DSH Voice', 'recall'];
  const cases = [
    ['原文没有 Milvus 的位置，模型填了 DSH Voice',
      '这个需求由赵天义负责，顺便看看的召回率。',
      '这个需求由赵天义负责，顺便看看 DSH Voice 的召回率。',
      'DSH Voice'],
    ['模型填了 DeepSeek', '顺便看看的召回率。', '顺便看看 DeepSeek 的召回率。', 'DeepSeek'],
    ['模型填了 recall', '顺便看看的召回率。', '顺便看看 recall 的召回率。', 'recall'],
  ];
  for (const [label, raw, polished, term] of cases) {
    const result = stripFabricatedTerms(raw, polished, terms);
    check(`撤销：${label}`,
      result.removed.includes(term) && !result.text.includes(term),
      `removed=${JSON.stringify(result.removed)} → ${JSON.stringify(result.text)}`);
  }
}

console.log('\n— 防编造：不该误伤的 —');
{
  const terms = ['Milvus', 'DeepSeek'];
  const r1 = stripFabricatedTerms('今天天气不错。', '今天天气不错。', terms);
  eq('完全没改动 → 原样返回', r1.text, '今天天气不错。');
  const r2 = stripFabricatedTerms('我们用Milvus做检索。', '我们用 Milvus 做检索。', terms);
  eq('词表词本来就在原文里 → 不动', r2.removed.length, 0);
  const r3 = stripFabricatedTerms('', '', terms);
  eq('空输入不炸', r3.text, '');
  const r4 = stripFabricatedTerms('好的', '好的。', []);
  eq('没有词表时完全不动', r4.text, '好的。');
  const r5 = stripFabricatedTerms('三点开会', '3点开会', ['Milvus']);
  eq('数字规整（三点→3点）不受影响', r5.removed.length, 0);
}

console.log('\n— prompt 渲染 —');
{
  eq('空词表返回空串', renderVocabularyPrompt([]), '');
  eq('undefined 也返回空串', renderVocabularyPrompt(undefined), '');
  const p = renderVocabularyPrompt(['Milvus', '  ', 'Typeless']);
  check('词表进 prompt', p.includes('Milvus') && p.includes('Typeless'));
  check('空字符串被过滤', !p.includes('、 '));
  check('包含"保持英文不翻译"的指令', p.includes('不要翻译成中文'));
}

console.log('\n— 读文件容错 —');
{
  eq('文件不存在返回空表', JSON.stringify(loadTerms('/nonexistent/path/xyz.json')), '[]');
  eq('非 JSON 文件返回空表', JSON.stringify(loadTerms('./sidecar/cleanup.mjs')), '[]');
}

console.log();
if (failures === 0) {
  console.log('ALL PASS');
  process.exit(0);
}
console.log(`${failures} 项失败`);
process.exit(1);
