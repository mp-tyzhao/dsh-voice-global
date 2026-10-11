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
import { windowScore } from './phonetic.mjs';

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
  let gap = { raw: [], out: [], rawIndexes: [], outIndexes: [] };
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (sameToken(raw[i], out[j])) {
      // 匹配上 = 锚点，当前段结束
      if (gap.raw.length || gap.out.length) gaps.push(gap);
      gap = { raw: [], out: [], rawIndexes: [], outIndexes: [] };
      i += 1;
      j += 1;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      gap.raw.push(raw[i]);
      gap.rawIndexes.push(i);
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

    // 在插入段里**滑动查找**词表词，而不是要求整段恰好等于它。
    //
    // 原先写的是 `tokens.join('') === gap.out.join('')` —— 只有模型恰好
    // 只插了这一个词、前后不多不少任何字时才成立。实际模型插入的是
    // 「加了 Milvus」这种带上下文的片段，整段比对永远不相等，
    // 于是守卫几乎从不触发。这是真 bug，不是保守。
    for (const { term, tokens } of termTokens) {
      const length = tokens.length;
      for (let start = 0; start + length <= gap.out.length; start += 1) {
        let matched = true;
        for (let k = 0; k < length; k += 1) {
          if (lower(gap.out[start + k]) !== tokens[k]) { matched = false; break; }
        }
        if (!matched) continue;
        removed.push(term);
        // 用对齐时记下的下标删除，避免 findIndex 删错位置
        for (let k = 0; k < length; k += 1) dropIndexes.add(gap.outIndexes[start + k]);
      }
    }
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
 * 把「LLM 硬套词表」的地方改回原文。
 *
 * ## 为什么需要（实测 2026-10-11）
 *
 * 用户报："很多类似于奇绩创坛的输入都会被自动修正为奇绩创坛"。
 * 日志里的真实案例：
 *
 *   raw 其迹算里  → out 奇绩创坛   hits ["llm"]
 *   raw 奇迹三力  → out 奇绩创坛   hits ["llm"]
 *
 * 用户说的是「奇绩**算力**」，LLM 因为词表里有「奇绩创坛」，看到前半段
 * 读音对得上就把**整个词**套了上去。
 *
 * ## 判据：这个词在原文里有没有"读音痕迹"
 *
 * 在原文上滑一个等长窗口，取最高相似度：
 *
 *   其迹算里 → 奇绩创坛   0.500   ← 没痕迹 = 硬套
 *   奇迹三力 → 奇绩创坛   0.500   ← 没痕迹 = 硬套
 *   奇迹创谈 → 奇绩创坛   1.000   ← 有痕迹 = 正常的同音纠正，放行
 *   用户测自净化 → 用户侧自进化 0.933 ← 有痕迹，放行
 *
 * 阈值 0.6：离硬套（≤0.5）和已知最低的合法案例（0.933）都有余量。
 *
 * ## 为什么**只处理中文词**
 *
 * `tys → Typeless` 这类西文缩写还原，相似度只有 0.25，本来就"没痕迹" ——
 * 而那正是最需要 LLM 补的一类。所以西文词一律豁免，只拦中文词：
 * 中文的读音纠正交给本地拼音层（阈值 0.85，有校准），
 * 不需要 LLM 在这里自由发挥。
 *
 * @param {string} raw ASR 原文
 * @param {string} polished LLM 输出
 * @param {string[]} terms 词表
 * @param {{threshold?: number}} [options]
 * @returns {{text: string, reverted: string[]}}
 */
export function revertUnanchoredTerms(raw, polished, terms, options = {}) {
  const threshold = options.threshold ?? 0.6;
  if (!terms?.length || !polished || !raw) return { text: polished, reverted: [] };

  const hasCJK = (text) => /[\u4e00-\u9fff]/u.test(text);
  let text = polished;
  const reverted = [];

  for (const term of terms) {
    if (!hasCJK(term)) continue;            // 西文词豁免（见上）
    if (!text.includes(term)) continue;     // 输出里根本没出现，不用管

    const best = bestAnchor(raw, term);
    if (best.score >= threshold) continue;  // 原文里有读音痕迹 → 正常的同音纠正

    reverted.push(term);
    // 换回原文里最像的那一段 —— 那才是用户实际说的东西。
    // 原文里连等长窗口都没有（说明原文更短）就删掉，
    // 因为"原文里没有这个词"是确定的。
    text = text.split(term).join(best.window);
  }

  return { text, reverted };
}

/**
 * 在 raw 上滑一个和 term 等长的窗口，取相似度最高的那个。
 * @returns {{score: number, window: string}}
 */
function bestAnchor(raw, term) {
  const rawChars = Array.from(raw);
  const length = Array.from(term).length;
  let best = { score: 0, window: '' };
  for (let i = 0; i + length <= rawChars.length; i += 1) {
    const window = rawChars.slice(i, i + length).join('');
    const score = windowScore(window, term);
    if (score > best.score) best = { score, window };
  }
  return best;
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
    '用户专有名词表（这些是正确写法）：',
    clean.join('、'),
    '',
    '**只在整段读音都对得上时才替换。** 反例：识别结果里是「奇绩算力」，',
    '不要因为表里有「奇绩创坛」就改过去 —— 前半段读音一样、后半段是另一个词。',
    '中文的读音纠正本地已经有一层在做了，你的重点是英文/缩写（如 tys → Typeless）。',
    '宁可不改，也不要改错。',
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
    if (!Array.isArray(terms)) return [];
    // 只收字符串。用 String(t) 强转会把 null 变成 "null"、对象变成
    // "[object Object]" —— 这些垃圾词会被注入提示、也会进匹配器。
    // 词表是用户能直接编辑的文件，schema 写错时应该少收而不是收垃圾。
    return terms
      .filter((t) => typeof t === 'string')
      .map((t) => t.trim())
      .filter(Boolean);
  } catch {
    return [];
  }
}

/**
 * 纠正对子：**原文里那个误听** → **用户改成的东西**。
 *
 * ## 为什么要有这一层（2026-10-11，调研市面产品之后的结论）
 *
 * 我们原来只存"正确的词"。superwhisper 的官方文档给的做法更精确：
 *
 *   > 如果一个词被反复听错成好几种样子，就为每一种变形各加一条替换，
 *   > 都指向正确结果。
 *
 * 它是让用户**手工枚举变形**的。而每次观测修订时，两边都在我们手里 ——
 * 变形是白捡的。VoiceInk 的 Dictionary Auto Learn 也是这个结构：
 * Vocabulary（词）和 Word Replacement（对子）是两个独立的东西。
 *
 * ## 对子层为什么能解决"过度套用"
 *
 * 它只在**原文精确出现那个误听**时才触发。
 * `最佳时间部署 → 最佳实践部署` 不会去动「最佳算力部署」，
 * 而"词表 + LLM"那条路会（用户实测报过：奇绩算力 被改成 奇绩创坛）。
 *
 * 精确匹配是这一层的全部价值 —— 所以应用时**不做任何相似度判断**。
 *
 * @param {string} path
 * @returns {Array<{from: string, to: string}>}
 */
export function loadReplacements(path) {
  try {
    const parsed = JSON.parse(fs.readFileSync(path, 'utf8'));
    const pairs = Array.isArray(parsed) ? parsed : parsed?.pairs;
    if (!pairs || typeof pairs !== 'object') return [];
    return Object.entries(pairs)
      .map(([from, meta]) => ({ from: String(from), to: String(meta?.to ?? '') }))
      .filter((pair) => pair.from && pair.to && pair.from !== pair.to);
  } catch { return []; }
}

/**
 * 应用纠正对子。**精确匹配**，长对优先（避免短对子先吃掉长对子的一部分）。
 *
 * 不做相似度判断是有意的：这一层的可信度来自"原文确实这么错过"，
 * 而不是来自"读起来像"。加判断反而会把它的确定性优势抹掉。
 *
 * @param {string} text
 * @param {Array<{from: string, to: string}>} pairs
 * @returns {{text: string, applied: Array<{from: string, to: string}>}}
 */
export function applyReplacements(text, pairs) {
  if (!text || !pairs?.length) return { text, applied: [] };
  let out = String(text);
  const applied = [];
  const sorted = [...pairs].sort(
    (a, b) => Array.from(b.from).length - Array.from(a.from).length,
  );
  for (const pair of sorted) {
    if (!out.includes(pair.from)) continue;
    out = out.split(pair.from).join(pair.to);
    applied.push({ from: pair.from, to: pair.to });
  }
  return { text: out, applied };
}
