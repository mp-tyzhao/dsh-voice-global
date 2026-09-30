/**
 * 拼音匹配器的单元测试
 * 跑法：node sidecar/phonetic.test.mjs
 *
 * 用例全部来自真实听写记录与已知的同音字错误。
 * 这个组件判错会**主动改坏本来正确的文字**，所以误伤用例比命中用例更重要。
 */

import { syllableOf, syllableDistance, phonemeDistance, latinSimilarity, windowScore, applyTerms, selectRelevantTerms } from './phonetic.mjs';

let failures = 0;
function check(label, ok, detail) {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}`);
  if (!ok && detail) console.log(`      ${detail}`);
  if (!ok) failures += 1;
}

console.log('— 音节拆解 —');
{
  const s = syllableOf('赵');
  check('声母韵母声调都能拿到', s && s.initial === 'zh' && s.final === 'ao' && s.tone === 4, JSON.stringify(s));
}
check('非汉字返回 null', syllableOf('A') === null);

console.log('\n— 音节距离 —');
{
  const a = syllableOf('赵');
  const b = syllableOf('赵');
  check('同一音节距离 0', syllableDistance(a, b) === 0);
  const c = syllableOf('找');   // zhao3，与赵(zhao4)只差声调
  check('只有声调不同 → 距离很小', syllableDistance(a, c) < 0.2, String(syllableDistance(a, c)));
  const z = syllableOf('资');   // z vs zh 模糊音
  const zh = syllableOf('知');
  check('模糊音（z/zh）算半个距离', syllableDistance(z, zh) > 0 && syllableDistance(z, zh) <= 0.7,
    String(syllableDistance(z, zh)));
}

console.log('\n— 拼音距离：同音字必须判为 0 —');
{
  const pairs = [
    ['赵天义', '赵天翊'],       // 真实错误：义→翊
    ['奇迹创谈', '奇绩创坛'],   // 真实错误：迹→绩、谈→坛
  ];
  for (const [wrong, right] of pairs) {
    const a = Array.from(wrong).map(syllableOf);
    const b = Array.from(right).map(syllableOf);
    const d = phonemeDistance(a, b);
    check(`${wrong} 与 ${right} 同音（距离 ${d.toFixed(2)}）`, d < 0.2, `实际 ${d}`);
  }
  const x = Array.from('今天天气').map(syllableOf);
  const y = Array.from('明天天气').map(syllableOf);
  check('不同音的词距离明显更大', phonemeDistance(x, y) > 0.2, String(phonemeDistance(x, y)));
}

console.log('\n— 西文相似度 —');
{
  check('完全相同 → 1', latinSimilarity('Milvus', 'milvus') === 1);
  check('相邻换位（mve/mev）算一次编辑', latinSimilarity('mve', 'mev') > 0.6, String(latinSimilarity('mve', 'mev')));
  check('毫不相干 → 低分', latinSimilarity('the', 'Milvus') < 0.4, String(latinSimilarity('the', 'Milvus')));
}

console.log('\n— 该改的：中文同音字 —');
{
  const cases = [
    ['这个需求由赵天义负责', ['赵天翊'], '赵天翊'],
    ['下周同步给奇迹创谈', ['奇绩创坛'], '奇绩创坛'],
    ['奇迹创谈下周同步', ['奇绩创坛'], '奇绩创坛'],
  ];
  for (const [text, terms, expected] of cases) {
    const r = applyTerms(text, terms);
    check(`改对：${text} → ${r.text}`, r.text.includes(expected), JSON.stringify(r.applied));
  }
}

console.log('\n— 真实案例（用户 2026-10-01 实际遇到的）—');
{
  // 说"用户侧自进化"，识别成"用户测自净化"。
  // 测/侧 完全同音（ce4）；净/进 是 in/ing 模糊音对。
  const r = applyTerms('你看用户测自净化这两个词都识别错了', ['用户侧自进化']);
  check('真实案例：用户测自净化 → 用户侧自进化', r.text.includes('用户侧自进化'), r.text);
  check('相似度 0.933（同音字 1.0 + 模糊音 0.4 平均）',
    r.applied[0] && r.applied[0].score > 0.9, JSON.stringify(r.applied));
}

console.log('\n— 该改的：西文整词 —');
{
  const r = applyTerms('我们用 kubernetess 部署', ['Kubernetes']);
  check('拼写接近的西文词会被纠正', r.text.includes('Kubernetes'), JSON.stringify(r.applied));
}

console.log('\n— 不该动的（误伤比漏改严重得多）—');
{
  const noop = [
    ['今天天气不错', ['Milvus', '奇绩创坛', '赵天翊']],
    ['我们用 Milvus 做检索', ['Milvus']],
    ['我们去吃饭吧', ['奇绩创坛']],
    ['the quick brown fox', ['Milvus']],
    ['', ['Milvus']],
    ['有内容但没词表', []],
  ];
  for (const [text, terms] of noop) {
    const r = applyTerms(text, terms);
    check(`不动：${JSON.stringify(text).slice(0, 30)}`, r.text === text, `变成了 ${r.text}`);
  }
}
{
  // 短西文词不能去匹配长词内部（`de` 不该在 `deploy` 里被匹配）
  const r = applyTerms('把代码 deploy 到环境', ['de']);
  check('西文词要求整词对齐（de 不匹配 deploy）', r.applied.length === 0, JSON.stringify(r.applied));
}

console.log('\n— 按句检索词表 —');
{
  const terms = ['Typeless', 'LLM', 'prompt', 'DSH Voice', 'SenseVoice', 'Kubernetes', 'Milvus', '赵天翊', '奇绩创坛', '用户侧自进化'];

  // 该选中的
  const a = selectRelevantTerms('我们想一想怎么样能像tys那样', terms).map((t) => t.term);
  check('前缀重合能捞回大跨度错误（tys → Typeless）', a.includes('Typeless'), JSON.stringify(a));

  const b = selectRelevantTerms('这个需求由赵天义负责', terms).map((t) => t.term);
  check('同音字能捞回（赵天义 → 赵天翊）', b.includes('赵天翊'), JSON.stringify(b));

  const c = selectRelevantTerms('你看用户测自净化这两个词', terms).map((t) => t.term);
  check('模糊音也能捞回（用户测自净化 → 用户侧自进化）', c.includes('用户侧自进化'), JSON.stringify(c));

  // 不该选中的：跟这句毫无关系的词注入进去只会让模型乱挑
  const d = selectRelevantTerms('今天天气不错我们下午三点开会', terms);
  check('无关句子一条都不选', d.length === 0, JSON.stringify(d.map((t) => t.term)));

  // 边界
  check('空原文不崩', selectRelevantTerms('', terms).length === 0);
  check('空词表不崩', selectRelevantTerms('随便说点什么', []).length === 0);
  check('结果按相关度降序', (() => {
    const r = selectRelevantTerms('我们用 Milvus 和 Typeless', terms);
    return r.every((item, i) => i === 0 || r[i - 1].score >= item.score);
  })());
  check('limit 生效', selectRelevantTerms('我们用 Milvus 和 Typeless', terms, { limit: 1 }).length <= 1);
  // 已经写对的词要认出来（reason=literal），不该被当成"可疑"
  const literal = selectRelevantTerms('我们用 Milvus 做检索', terms).find((t) => t.term === 'Milvus');
  check('已写对的词标记为 literal', literal?.reason === 'literal', JSON.stringify(literal));
}

console.log('\n— 幂等性与多词 —');
{
  const once = applyTerms('赵天义和奇迹创谈', ['赵天翊', '奇绩创坛']).text;
  const twice = applyTerms(once, ['赵天翊', '奇绩创坛']).text;
  check('改完再跑一次结果不变（幂等）', once === twice, `${once} vs ${twice}`);
  check('一次改对多个词', once.includes('赵天翊') && once.includes('奇绩创坛'), once);
}
{
  // 长词优先：有「奇绩创坛」时不能被更短的「奇绩」抢走
  const r = applyTerms('奇迹创谈', ['奇绩', '奇绩创坛']);
  check('长词优先', r.text === '奇绩创坛', r.text);
}

console.log();
if (failures === 0) {
  console.log('ALL PASS');
  process.exit(0);
}
console.log(`${failures} 项失败`);
process.exit(1);
