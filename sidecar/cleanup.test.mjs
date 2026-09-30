/**
 * 清理规则测试：node cleanup.test.mjs
 *
 * 覆盖：语气词删除、重复合并、口头自我修正、标点规整、幂等性、误删防护。
 */
import { clean } from './cleanup.mjs';

const cases = [
  // [输入, 期望输出, 说明]
  ['嗯，那个，我们明天下午三点开会。', '我们明天下午三点开会。', '句首语气词与口头禅'],
  ['我我我觉得这个方案可以。', '我觉得这个方案可以。', '重复词合并'],
  ['这个项目那个进度怎么样？', '这个项目那个进度怎么样？', '指示代词不可误删（句中无停顿）'],
  ['我想说的是，就是说，我们需要更多时间。', '我想说的是，我们需要更多时间。', '句首口头禅'],
  ['明天三点开会，不对，是四点。', '是四点。', '口头自我修正'],
  ['发给张三，我是说发给李四。', '发给李四。', '口头自我修正（我是说）'],
  ['呃，uh, so we should, um, ship it tomorrow.', 'so we should, ship it tomorrow.', '英文填充词'],
  ['好的，，，我知道了。。', '好的，我知道了。', '重复标点'],
  ['，先做最小闭环。', '先做最小闭环。', '行首标点'],
  ['这个东西呢，其实吧，还挺好用的。', '这个东西呢，还挺好用的。', '句中口头禅'],
  ['嗯。', '', '纯语气词清空'],
  ['这个功能, like, 很关键。', '这个功能, 很关键。', 'like 作填充词（后跟逗号）'],
  ['I like this design.', 'I like this design.', 'like 作动词不可误删'],
  ['等一下... 我再想想。', '等一下… 我再想想。', '省略号归一'],
  ['然后，我们开始吧。', '我们开始吧。', '被停顿孤立的连接词'],
  ['然后我们开始吧。', '然后我们开始吧。', '连接词后有实义内容时保留'],
  ['呃，那个我们下周再讨论细节。', '我们下周再讨论细节。', '句中"那个"+人称代词（无逗号）'],
  ['他提到了那个我们都很熟悉的例子。', '他提到了那个我们都很熟悉的例子。', '"那个"作限定语时不可误删'],
  ['这个方案可行。呃，那个我们下周再讨论。', '这个方案可行。我们下周再讨论。', '句末标点后的插入语残渣'],
];

let failed = 0;
for (const [input, expected, label] of cases) {
  const { text, hits } = clean(input);
  const ok = text === expected;
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}`);
  if (!ok) {
    console.log(`      输入: ${JSON.stringify(input)}`);
    console.log(`      期望: ${JSON.stringify(expected)}`);
    console.log(`      实际: ${JSON.stringify(text)}`);
  }
  if (hits.length) console.log(`      hits: ${hits.join(', ')}`);
}

// 幂等性：清理两次结果必须一致
const idempotentSources = ['嗯，那个，我我我觉得这个方案可以，不对，是可行。', '呃 uh we should um ship it.'];
for (const source of idempotentSources) {
  const once = clean(source).text;
  const twice = clean(once).text;
  const ok = once === twice;
  if (!ok) failed++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  幂等性: ${JSON.stringify(source)}`);
  if (!ok) console.log(`      once=${JSON.stringify(once)} twice=${JSON.stringify(twice)}`);
}

// 空输入
const empty = clean('   ');
const emptyOk = empty.text === '' && empty.changed === false;
if (!emptyOk) failed++;
console.log(`${emptyOk ? 'PASS' : 'FAIL'}  空输入`);

console.log(`\n${failed === 0 ? 'ALL PASS' : `${failed} FAILED`} (${cases.length + idempotentSources.length + 1} 项)`);
process.exit(failed === 0 ? 0 : 1);
