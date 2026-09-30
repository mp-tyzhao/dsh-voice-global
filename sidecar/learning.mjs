/**
 * 从用户的改正中学习词表
 * ======================
 *
 * 用户改完一句话，我们拿 (raw, corrected) 对齐，把**改正侧多出来的**实词抽出来
 * 加进词表。下次同样的词再被听错，LLM 就有依据还原了。
 *
 * 为什么只抽"词"而不是记整句映射：
 *   - 整句映射换个句子就失效；词是可以跨句复用的
 *   - 词表注入 system prompt 是实测最有效的杠杆（正确率 1/4 → 3/4）
 *
 * 与防编造校验（dictionary.mjs 的 stripFabricatedTerms）用的是同一套对齐逻辑，
 * 所以两边对"什么算替换、什么算插入"的判断是一致的。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { alignmentGaps, tokenize } from './dictionary.mjs';

/** 太短的不收：单字多半是"的/了/在"这类，收进去只会造成误伤。 */
const MIN_CJK_RUN = 2;
const MIN_LATIN_LEN = 2;

/** 纯数字、纯符号的片段不是术语。 */
const isUsefulToken = (token) => /[\u4e00-\u9fffA-Za-z]/.test(token);

/** 单字中文替换时，往前带几个字当上下文（`赵天` + `翼` → `赵天翊`）。 */
const CJK_CONTEXT = 2;
/** 抽出来的中文术语最长多少字。 */
const MAX_CJK_TERM = 4;

/**
 * 常见虚词/功能字。
 *
 * 修正 `吧→把`、`的→得` 这类虚词时，如果也做上下文扩展，会抽出 `那样把`、`识别得`
 * 这种垃圾词进词表 —— 而词表是直接注入 prompt 的，垃圾词会污染提示。
 * 所以：**被替换的那个字是虚词就不收**。人名/术语（义→翼、迹→绩）不受影响。
 */
const FUNCTION_CHARS = new Set(
  '的得地吧把了吗呢啊哦呀么是在有和与就都也又还很太不没要会能可对被从到向为以及其之这那哪个们了过给里对跟让使于由往朝沿随按据并但却而则'.split(''),
);

const isFunctionChar = (char) => FUNCTION_CHARS.has(char);

/**
 * 相邻多近的替换点算同一个术语。
 * `奇迹创谈` → `奇绩创坛` 会切出两个替换点（迹→绩、谈→坛），中间隔着没变的"创"。
 * 不合并就只能抽出 `奇绩`、`创坛` 两个碎片，合起来才是完整术语。
 */
const MERGE_DISTANCE = 2;

/**
 * 从一次 (原文, 改正后) 里抽出候选术语。
 *
 * 覆盖三种情况：
 *   - **插入**：`看看的召回率` → `看看 Milvus 的召回率`，改正侧多出 `Milvus`
 *   - **西文替换**：`像tys那样` → `像Typeless那样`，改正侧多出 `Typeless`
 *   - **中文替换**：`赵天义` → `赵天翊`，单字被替换，往前带上没变的字构成术语
 *
 * 第三种可靠性低于前两种：单字替换只能确定"这个字改了"，术语边界靠上下文猜，
 * 所以既带上下文、又用虚词表过滤掉明显不是术语的；相邻替换点先合并再抽。
 *
 * @param {string} raw - ASR 原始输出
 * @param {string} corrected - 用户改正后的文本
 * @returns {string[]} 候选术语（已去重）
 */
export function extractTerms(raw, corrected) {
  const rawTokens = tokenize(raw);
  const correctedTokens = tokenize(corrected);
  if (!correctedTokens.length) return [];

  // 1. 合并相邻的替换点
  const merged = [];
  for (const gap of alignmentGaps(rawTokens, correctedTokens)) {
    if (!gap.out.length || !gap.outIndexes.length) continue;
    const start = gap.outIndexes[0];
    const end = gap.outIndexes[gap.outIndexes.length - 1];
    const last = merged[merged.length - 1];
    if (last && start - last.end <= MERGE_DISTANCE) {
      last.end = Math.max(last.end, end);
      last.rawCount += gap.raw.length;
    } else {
      merged.push({ start, end, rawCount: gap.raw.length });
    }
  }

  // 2. 每组取改正侧的完整跨度，切成中文/西文片段
  const candidates = [];
  for (const group of merged) {
    const span = correctedTokens.slice(group.start, group.end + 1);
    let run = null;
    const flush = () => {
      if (!run) return;
      let text = run.text;
      if (run.kind === 'cjk') {
        const originalLength = text.length;
        // 单字且本身就是虚词 → 这是 `吧→把` 那类虚词修正，不是术语
        if (originalLength === 1 && isFunctionChar(text)) { run = null; return; }
        // 往前带没变过的字当上下文（`绩创坛` → `奇绩创坛`、`翊` → `赵天翊`）。
        // 只在原文侧确实有东西被换掉时才带 —— 纯插入不该借上文。
        if (group.rawCount > 0 && !isFunctionChar(text[0])) {
          const before = [];
          for (let k = group.start - 1; k >= 0 && before.length < CJK_CONTEXT; k -= 1) {
            const token = correctedTokens[k];
            if (!/^[\u4e00-\u9fff]$/u.test(token) || isFunctionChar(token)) break;
            before.unshift(token);
          }
          text = before.join('') + text;
          if (text.length > MAX_CJK_TERM) text = text.slice(-MAX_CJK_TERM);
        }
        // 只替换了一个字、而且带上文后尾字仍是虚词 → `那样把`、`识别得`、`比如给`，丢掉
        if (originalLength === 1 && isFunctionChar(text[text.length - 1])) { run = null; return; }
        if (text.length >= MIN_CJK_RUN) candidates.push(text);
      } else if (text.length >= MIN_LATIN_LEN) {
        candidates.push(text);
      }
      run = null;
    };

    for (const token of span) {
      if (!isUsefulToken(token)) { flush(); continue; }
      const kind = /^[\u4e00-\u9fff]$/u.test(token) ? 'cjk' : 'latin';
      if (run && run.kind === kind) run.text += token;
      else { flush(); run = { kind, text: token }; }
    }
    flush();
  }

  // 3. 原文里已经有的词不算新术语
  const rawLower = raw.toLowerCase();
  const seen = new Set();
  return candidates.filter((term) => {
    const lower = term.toLowerCase();
    if (rawLower.includes(lower)) return false;
    if (seen.has(lower)) return false;
    seen.add(lower);
    return true;
  });
}

/**
 * 把新术语合并进词表文件；已存在的跳过。
 * 每次写入都更新 mtime，sidecar 靠它热加载，改完下一句就生效。
 *
 * @param {string} dictionaryPath
 * @param {string[]} newTerms
 * @returns {{added: string[], total: number}}
 */
export function mergeTerms(dictionaryPath, newTerms) {
  let document = { terms: [] };
  try {
    const parsed = JSON.parse(fs.readFileSync(dictionaryPath, 'utf8'));
    document = Array.isArray(parsed) ? { terms: parsed } : parsed;
  } catch {
    // 文件不存在或坏了：重建一份，不覆盖用户其它字段之外的意图
  }
  const terms = Array.isArray(document.terms) ? document.terms.map(String) : [];
  const existing = new Set(terms.map((t) => t.toLowerCase()));

  const added = [];
  for (const term of newTerms) {
    const clean = String(term).trim();
    if (!clean || existing.has(clean.toLowerCase())) continue;
    existing.add(clean.toLowerCase());
    terms.push(clean);
    added.push(clean);
  }

  if (added.length) {
    fs.mkdirSync(path.dirname(dictionaryPath), { recursive: true });
    document.terms = terms;
    document.updatedAt = new Date().toISOString();
    fs.writeFileSync(dictionaryPath, `${JSON.stringify(document, null, 2)}\n`);
  }
  return { added, total: terms.length };
}

/**
 * CLI 入口：宿主（Swift）学到一次改正后调用它。
 *
 *   node learning.mjs --raw "<原文>" --corrected "<改正后>" [--dict <路径>] [--dry]
 *
 * 输出一行 JSON：{"added":[...],"total":N,"candidates":[...]}
 * 只在 --dry 时不写文件。
 */
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const argv = process.argv.slice(2);
  const value = (name) => {
    const i = argv.indexOf(name);
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : undefined;
  };
  const raw = value('--raw') ?? '';
  const corrected = value('--corrected') ?? '';
  const dictPath = value('--dict')
    || path.join(os.homedir(), '.voice-global', 'dictionary.json');

  const candidates = extractTerms(raw, corrected);
  if (argv.includes('--dry')) {
    process.stdout.write(`${JSON.stringify({ added: [], total: 0, candidates })}\n`);
  } else {
    const { added, total } = mergeTerms(dictPath, candidates);
    process.stdout.write(`${JSON.stringify({ added, total, candidates })}\n`);
  }
}
