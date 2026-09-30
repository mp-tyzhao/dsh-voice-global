/**
 * 拼音匹配器
 * ==========
 *
 * 用**发音**而不是字面，把识别错的词换成用户词表里的正确写法。
 *
 * 实测依据：
 *   `奇迹创谈` 与 `奇绩创坛` 的拼音完全相同（qi2 ji4 chuang4 tan2）
 *   `赵天义` 与 `赵天翊` 的拼音完全相同（zhao4 tian1 yi4）
 * 同音字错误在字面上毫无相似度，在拼音上却是零距离 —— 这是唯一可靠的判据。
 *
 * ## 为什么替换和防编造是同一件事
 *
 * 两者都在问同一个问题："这段文字里有没有一个**发音**对应得上词表某个词的片段？"
 *   - 有 → 那是被听错的词，换成正确写法（替换）
 *   - 没有 → 那模型是凭空插进来的（编造），撤掉
 * 所以这里只实现一次匹配，正反两个方向都用它。分开写迟早会不一致。
 *
 * ## 参考
 *
 * 中文侧的思路来自 CapsWriter-Offline 的 asr-hotword（MIT）：拼音音素编辑距离 +
 * 模糊音表 + 邻近黑名单。西文侧用 Damerau-Levenshtein 相似度。
 */

import { pinyin } from 'pinyin-pro';

/**
 * 模糊音表
 * ========
 *
 * **只收有依据的。** 调研核实：中文模糊音没有一份来自真实语音识别数据的
 * 混淆矩阵，流传的都是输入法功能菜单或手写模板。
 *
 * 唯一有出处的是 Rime 作者佛振的【朙月拼音】模糊音定製模板
 * （gist.github.com/lotem/2320943，2012 创建、2026 仍在更新）——
 * 而且作者自己写的是"樣例足夠了，其他請自己總結"，即它是模板不是标准。
 *
 * 所以这里只保留那份模板里明确写出的：
 *   zh/ch/sh → z/c/s、n↔l、en/eng、in/ing
 * 以及作者特别说明「寫法複雜一些，分情況討論」的 f↔h（只按具体音节对，不整体放开）。
 *
 * **没收进来的**（输入法里常见但查不到依据）：an/ang、ian/iang、uan/uang、
 * ai/ei、o/uo、e/ie、p/b、t/d、k/g。
 * 收进来会提高召回，但也会让"本来对的词"被改掉 —— 在这个功能里误伤比漏改严重。
 * 等自己的改正日志攒够了，用真实数据来校准，而不是照抄传闻。
 */
/** 声母层面易混（比的是 initial，不是整个音节） */
const FUZZY_INITIAL_PAIRS = [
  ['zh', 'z'], ['ch', 'c'], ['sh', 's'],   // 翘舌 ↔ 平舌
  ['n', 'l'],
  ['f', 'h'],                               // 只在音节对上时用，见下
];
/** 韵母层面易混 */
const FUZZY_FINAL_PAIRS = [['en', 'eng'], ['in', 'ing']];
/** f↔h 只在特定音节上成立：整体放开会造出非法音节（Rime 模板里特别注明） */
const FUZZY_SYLLABLE_PAIRS = [
  ['hu', 'fu'], ['hong', 'feng'], ['hui', 'fei'], ['hun', 'fen'], ['hua', 'fa'],
];

function toSet(pairs) {
  const set = new Set();
  for (const [a, b] of pairs) { set.add(`${a}|${b}`); set.add(`${b}|${a}`); }
  return set;
}
const FUZZY_INITIAL = toSet(FUZZY_INITIAL_PAIRS);
const FUZZY_FINAL = toSet(FUZZY_FINAL_PAIRS);
const FUZZY_SYLLABLE = toSet(FUZZY_SYLLABLE_PAIRS);

/** 把一个汉字拆成 (声母, 韵母, 声调)。非汉字返回 null。 */
export function syllableOf(char) {
  if (!/[\u4e00-\u9fff]/u.test(char)) return null;
  const withTone = pinyin(char, { toneType: 'num', type: 'array' })[0];
  if (!withTone) return null;
  const tone = Number(withTone.match(/\d$/u)?.[0] ?? 5);
  const bare = withTone.replace(/\d$/u, '');
  // 注意 toneType:'none' —— 默认会返回带调符的 'ào'，那样模糊音比较全对不上
  const initial = pinyin(char, { pattern: 'initial', type: 'array', toneType: 'none' })[0] ?? '';
  const final = pinyin(char, { pattern: 'final', type: 'array', toneType: 'none' })[0] ?? bare;
  return { initial, final, tone, bare, withTone };
}

/**
 * 两个音节的距离，0 = 完全相同。
 * 声调不同算 0.15（口语里声调最容易被带过），模糊音算 0.5。
 */
export function syllableDistance(a, b) {
  if (!a || !b) return 1;
  if (a.withTone === b.withTone) return 0;
  let cost = 0;
  if (a.bare !== b.bare) {
    if (FUZZY_SYLLABLE.has(`${a.bare}|${b.bare}`)) {
      cost += 0.4;
    } else {
      const initialNear = a.initial === b.initial || FUZZY_INITIAL.has(`${a.initial}|${b.initial}`);
      const finalNear = a.final === b.final || FUZZY_FINAL.has(`${a.final}|${b.final}`);
      // 声母韵母都接近 → 很可能就是口语混淆；只沾一边 → 弱信号
      cost += initialNear && finalNear ? 0.4 : (initialNear || finalNear ? 0.7 : 1);
    }
  }
  if (a.tone !== b.tone) cost += 0.15;
  return Math.min(cost, 1);
}

/** 音素序列的平均距离，0 = 完全同音。 */
export function phonemeDistance(a, b) {
  if (!a.length || !b.length || a.length !== b.length) return 1;
  let total = 0;
  for (let i = 0; i < a.length; i += 1) total += syllableDistance(a[i], b[i]);
  return total / a.length;
}

/** 归一化的 Damerau-Levenshtein 相似度，1 = 完全相同。西文词用这个。 */
export function latinSimilarity(a, b) {
  const x = a.toLowerCase();
  const y = b.toLowerCase();
  if (x === y) return 1;
  if (!x.length || !y.length) return 0;
  const rows = x.length + 1;
  const cols = y.length + 1;
  let prev = Array.from({ length: cols }, (_, j) => j);
  let prevPrev = null;
  for (let i = 1; i < rows; i += 1) {
    const current = [i];
    for (let j = 1; j < cols; j += 1) {
      const cost = x[i - 1] === y[j - 1] ? 0 : 1;
      let value = Math.min(prev[j] + 1, current[j - 1] + 1, prev[j - 1] + cost);
      // 相邻字符换位（mve / mev 这类）只算一次编辑
      if (prevPrev && i > 1 && j > 1 && x[i - 1] === y[j - 2] && x[i - 2] === y[j - 1]) {
        value = Math.min(value, prevPrev[j - 2] + 1);
      }
      current[j] = value;
    }
    prevPrev = prev;
    prev = current;
  }
  return 1 - prev[cols - 1] / Math.max(x.length, y.length);
}

/** 判断一段文本与一个词表词的发音/字面相似度，1 = 完全一致。 */
export function windowScore(text, term) {
  const latinTerm = /^[A-Za-z0-9]/.test(term);
  if (latinTerm) {
    if (!/^[A-Za-z0-9]+$/.test(text)) return 0;
    return latinSimilarity(text, term);
  }
  const windowChars = Array.from(text);
  const termChars = Array.from(term);
  if (windowChars.length !== termChars.length) return 0;
  const windowSyllables = windowChars.map(syllableOf);
  const termSyllables = termChars.map(syllableOf);
  if (windowSyllables.some((s) => !s) || termSyllables.some((s) => !s)) return 0;
  return 1 - phonemeDistance(windowSyllables, termSyllables);
}

/**
 * 按词表纠正文本。
 *
 * 一次扫完所有候选、标记占用、再从右往左替换 —— 边扫边改会让下标全部错位。
 * 长词优先，避免「奇绩」把「奇绩创坛」的前半截先吃掉。
 * 西文词要求整词对齐（前后不是字母数字），否则 `de` 会在 `deploy` 里乱匹配。
 *
 * @param {string} text
 * @param {string[]} terms
 * @param {{threshold?: number, latinThreshold?: number}} [options]
 * @returns {{text: string, applied: Array<{from: string, to: string, score: number}>}}
 */
export function applyTerms(text, terms, options = {}) {
  const cjkThreshold = options.threshold ?? 0.85;
  const latinThreshold = options.latinThreshold ?? 0.75;
  if (!terms?.length || !text) return { text, applied: [] };

  const chars = Array.from(text);
  const claimed = new Array(chars.length).fill(false);
  const matches = [];

  // 西文按"词"匹配。拼错常常改变长度（kubernetess 11 字 vs Kubernetes 10 字），
  // 用固定长度窗口永远匹配不上；按词切分才符合实际。
  const words = [];
  for (let i = 0; i < chars.length;) {
    if (/[A-Za-z0-9]/.test(chars[i])) {
      const start = i;
      while (i < chars.length && /[A-Za-z0-9]/.test(chars[i])) i += 1;
      words.push({ text: chars.slice(start, i).join(''), start, end: i - 1 });
    } else i += 1;
  }

  const ordered = [...terms].sort((a, b) => Array.from(b).length - Array.from(a).length);
  for (const term of ordered) {
    const length = Array.from(term).length;
    if (!length) continue;
    const latinTerm = /^[A-Za-z0-9]/.test(term);
    const threshold = latinTerm ? latinThreshold : cjkThreshold;

    if (latinTerm) {
      for (const word of words) {
        if (claimed[word.start]) continue;
        const score = latinSimilarity(word.text, term);
        if (score < threshold) continue;
        if (word.text.toLowerCase() === term.toLowerCase()) {
          for (let i = word.start; i <= word.end; i += 1) claimed[i] = true;
          continue;
        }
        for (let i = word.start; i <= word.end; i += 1) claimed[i] = true;
        matches.push({ start: word.start, end: word.end, from: word.text, to: term, score });
      }
      continue;
    }

    for (let start = 0; start + length <= chars.length; start += 1) {
      if (claimed.slice(start, start + length).some(Boolean)) continue;
      const window = chars.slice(start, start + length).join('');
      const score = windowScore(window, term);
      if (score < threshold) continue;

      if (window === term) {
        // 本来就是对的不动，但占住位置，免得被更短的词覆盖
        for (let i = start; i < start + length; i += 1) claimed[i] = true;
        continue;
      }
      for (let i = start; i < start + length; i += 1) claimed[i] = true;
      matches.push({ start, end: start + length - 1, from: window, to: term, score });
    }
  }

  // 从右往左替换，前面的下标就不会被影响
  for (const match of [...matches].sort((a, b) => b.start - a.start)) {
    chars.splice(match.start, match.end - match.start + 1, ...Array.from(match.to));
  }

  return {
    text: chars.join(''),
    applied: matches
      .sort((a, b) => a.start - b.start)
      .map(({ from, to, score }) => ({ from, to, score: Number(score.toFixed(3)) })),
  };
}
