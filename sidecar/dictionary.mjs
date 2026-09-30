/**
 * 用户词表：读取、注入 prompt、以及防编造校验
 * ============================================
 *
 * 为什么需要这一层（实测结论，见 docs/v0.2-personalization.md §9）：
 *
 *   现状（无注入）        正确 1/4
 *   只加词表              正确 3/4      ← 最大杠杆
 *   人设 + 词表           正确 4/4      ← 但会编造原文没有的词
 *
 * 词表能把 `mve` 还原成 `Milvus`、`奇迹创谈` 修成 `奇绩创坛`；代价是模型有时会
 * **从词表里挑一个词凭空插进去**。实测在 prompt 里明文写"绝不新增"也拦不住，
 * 所以必须有这一层确定性校验。
 *
 * ## 判据是"这一段原文有没有东西被换掉"，不是相似度
 *
 * 把 LLM 输出与 ASR 原文对齐，切成一段段（以匹配上的 token 为锚点）。
 * 对每个输出多出来、原文没有的片段：
 *
 *   同一段里原文**有**被丢弃的 token  → 那是被改写的原文，属于**替换**，放行
 *   同一段里原文**空**                → 凭空插入，属于**编造**，撤销
 *
 * 为什么不能用相似度：`mve` 和 `Milvus` 的字面相似度很低，但它们在句中的位置是对应的；
 * `DeepSeek` 在原文里连位置都没有。相似度分不开这两种情况，分段可以。
 */

import fs from 'node:fs';

/** 有意义的最小单元：一个汉字，或一段连续的西文/数字。 */
const TOKEN_RE = /[\u4e00-\u9fff]|[A-Za-z0-9][A-Za-z0-9'’._-]*/gu;

/** 把文本切成 token 序列。标点与空白不参与对齐。 */
export function tokenize(text) {
  return String(text ?? '').match(TOKEN_RE) ?? [];
}

const isLatin = (token) => /^[A-Za-z0-9]/.test(token);
const lower = (token) => token.toLowerCase();

/**
 * 两个 token 是否算"同一个东西"（对齐时的锚点）。
 * 中文按字面；西文忽略大小写，并容忍一个词是另一个的前缀
 * （`deploy` vs `deploying`）。
 */
function sameToken(a, b) {
  if (a === b) return true;
  if (isLatin(a) && isLatin(b)) {
    const x = lower(a);
    const y = lower(b);
    if (x === y) return true;
    const [short, long] = x.length <= y.length ? [x, y] : [y, x];
    return short.length >= 4 && long.startsWith(short);
  }
  return false;
}

/**
 * 对齐原文与输出，按锚点切成若干"段"。
 * @returns {Array<{raw: string[], out: string[], outIndexes: number[]}>}
 *         每段里是未被匹配的 token；outIndexes 是它们在输出 token 序列里的下标
 */
export function alignmentGaps(raw, out) {
  const n = raw.length;
  const m = out.length;
  const dp = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      dp[i][j] = sameToken(raw[i], out[j])
        ? dp[i + 1][j + 1] + 1
        : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  const gaps = [];
  let gap = { raw: [], out: [], outIndexes: [] };
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (sameToken(raw[i], out[j])) {
      // 匹配上 = 锚点，当前段结束
      if (gap.raw.length || gap.out.length) gaps.push(gap);
      gap = { raw: [], out: [], outIndexes: [] };
      i += 1;
      j += 1;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      gap.raw.push(raw[i]);
      i += 1;
    } else {
      gap.out.push(out[j]);
      gap.outIndexes.push(j);
      j += 1;
    }
  }
  while (i < n) { gap.raw.push(raw[i]); i += 1; }
  while (j < m) { gap.out.push(out[j]); gap.outIndexes.push(j); j += 1; }
  if (gap.raw.length || gap.out.length) gaps.push(gap);
  // outStart：这一段在输出 token 序列里的起点，供调用方取上文
  return gaps.map((g) => ({ ...g, outStart: g.outIndexes.length ? g.outIndexes[0] : -1 }));
}

/**
 * 找出输出里**凭空插入**的词表词。
 *
 * 只检查词表里的词：它们才是模型有动机去插的（prompt 里刚给过），
 * 也避免把断句、补字这类正常改动误判成编造。
 *
 * @param {string} raw - ASR 原始输出
 * @param {string} polished - LLM 输出
 * @param {string[]} terms - 用户词表
 * @returns {{text: string, removed: string[]}} 去掉编造词之后的文本，以及被移除的词
 */
export function stripFabricatedTerms(raw, polished, terms) {
  if (!terms?.length || !polished) return { text: polished, removed: [] };
  const rawTokens = tokenize(raw);
  const outTokens = tokenize(polished);
  if (!outTokens.length || !rawTokens.length) return { text: polished, removed: [] };

  const termTokens = terms
    .map((term) => ({ term, tokens: tokenize(term).map(lower) }))
    .filter((entry) => entry.tokens.length > 0);

  const removed = [];
  const dropIndexes = new Set();

  for (const gap of alignmentGaps(rawTokens, outTokens)) {
    // 原文在这段里什么都没有被换掉 → 这段多出来的内容全是凭空插入
    if (gap.raw.length > 0 || gap.out.length === 0) continue;
    const joined = gap.out.map(lower).join('');
    const hit = termTokens.find(({ tokens }) => tokens.join('') === joined);
    if (!hit) continue;
    removed.push(hit.term);
    // 用对齐时记下的下标删除，避免 findIndex 删错位置
    gap.outIndexes.forEach((index) => dropIndexes.add(index));
  }

  if (!removed.length) return { text: polished, removed: [] };

  const kept = outTokens.filter((_, k) => !dropIndexes.has(k));
  // 用剩下的 token 重建：中文直接拼，西文之间补空格。标点会丢，
  // 所以调用方要再跑一次规则层把标点补回来。
  let rebuilt = '';
  for (let k = 0; k < kept.length; k += 1) {
    if (k > 0 && isLatin(kept[k - 1]) && isLatin(kept[k])) rebuilt += ' ';
    rebuilt += kept[k];
  }
  return { text: rebuilt, removed };
}

/**
 * 把词表渲染成要追加到 system prompt 的段落。
 * 没有词表时返回空串 —— 完全不影响现有行为。
 * @param {string[]} terms
 */
export function renderVocabularyPrompt(terms) {
  const clean = (terms ?? []).map((t) => String(t).trim()).filter(Boolean);
  if (!clean.length) return '';
  return [
    '',
    '用户专有名词表（这些是正确写法。识别结果里出现**发音相近**的错误写法时，改成本表里的写法）：',
    clean.join('、'),
    '',
    '关于中英混说：用户经常在中文里夹英文单词或短语（如 prompt、deploy、staging）。',
    '**他说英文的地方必须保持英文，不要翻译成中文**；英文拼错时按语境还原成正确拼写。',
  ].join('\n');
}

/**
 * 读取词表文件。文件不存在或格式错误时返回空表，绝不抛错 ——
 * 这个功能坏掉不应该影响听写。
 * @param {string} path
 * @returns {string[]}
 */
export function loadTerms(path) {
  try {
    const parsed = JSON.parse(fs.readFileSync(path, 'utf8'));
    const terms = Array.isArray(parsed) ? parsed : parsed?.terms;
    return (terms ?? []).map((t) => String(t).trim()).filter(Boolean);
  } catch {
    return [];
  }
}
