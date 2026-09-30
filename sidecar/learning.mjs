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
import { applyTerms } from './phonetic.mjs';

/**
 * 候选词的置信度。
 *
 * 自动生效的线是 0.8 —— 低于它的先进待定区，同样的词再见一次才提升。
 * 分档依据：边界有多确定。
 *   - 西文词：词边界天然清楚，且整词被听错很常见        → 0.90
 *   - 中文整段新词（插入型）：改正侧多出来的完整片段      → 0.85
 *   - 中文单字替换 + 猜上文：只确定"这个字改了"，
 *     术语边界靠上下文推，可能推出 `奇绩` 这种碎片        → 0.60，需要再次确认
 */
const CONFIDENCE_LATIN = 0.90;
const CONFIDENCE_CJK_DIRECT = 0.85;
const CONFIDENCE_CJK_GUESSED = 0.60;

/**
 * 词表上限。
 *
 * 借鉴 macOS 语音控制的词汇表上限（1000 条）—— 那是个经过验证的爆炸半径上限。
 * 我们这边除了提示长度，更重要的是：词表越长，一个错词能造成的误伤面越大。
 */
export const MAX_TERMS = 1000;

/**
 * 明显不是术语的形态，直接丢。
 *
 * 这三条来自 Gboard 官方论文里公布的过滤器（他们做 OOV 学习时踩过的坑）：
 * 重复模式（hahaha / 好好好）、含数字、纯符号。
 * 论文里还提到"长度 ≤ 2 的一律丢"，但那条对中文不适用 ——
 * 中文两字词（奇绩、创坛）是常态，照搬会把正常的词也丢掉。
 */
function looksLikeJunk(term) {
  const chars = [...term];
  if (chars.length > 2) {
    const unique = new Set(chars);
    if (unique.size === 1) return true;                       // 好好好、aaa
    if (unique.size <= 2 && chars.length >= 5) return true;    // hahaha、yesyes
    // 单个字符占了一半以上 → yesss、nooo。长度门槛不能少：
    // LLM 只有 3 个字符、L 占 2/3，但它是个正经术语。
    if (chars.length >= 4) {
      const counts = new Map();
      for (const c of chars) counts.set(c, (counts.get(c) ?? 0) + 1);
      if (Math.max(...counts.values()) / chars.length > 0.5) return true;
    }
  }
  if (/\d/.test(term)) return true;                           // 含数字
  if (!/[\u4e00-\u9fffA-Za-z]/.test(term)) return true;      // 无中文也无字母
  return false;
}

/** 达到这个置信度就直接进词表，低于它先攒着。 */
export const AUTO_APPLY_CONFIDENCE = 0.8;

/** 待定候选再见几次才提升。 */
const PENDING_PROMOTE_COUNT = 2;

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
      let confidence = 0;
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
        // 首字是虚词的片段不是术语（`把一些`、`在这个` 这种碎片）
        if (isFunctionChar(text[0])) { run = null; return; }
        if (text.length >= MIN_CJK_RUN) {
          // 整段是新词（插入型）比"单字替换 + 猜上文"可靠得多
          confidence = originalLength >= MIN_CJK_RUN ? CONFIDENCE_CJK_DIRECT : CONFIDENCE_CJK_GUESSED;
          candidates.push({ term: text, confidence, kind: originalLength >= MIN_CJK_RUN ? 'cjk' : 'cjk-guessed' });
        }
      } else if (text.length >= MIN_LATIN_LEN) {
        // 西文词边界天然清楚，拼错也很可能整词被听错，置信度最高
        candidates.push({ term: text, confidence: CONFIDENCE_LATIN, kind: 'latin' });
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

  // 3. 过滤 + 去重
  const rawLower = raw.toLowerCase();
  const best = new Map();
  for (const candidate of candidates) {
    const lower = candidate.term.toLowerCase();
    if (rawLower.includes(lower)) continue;
    // 纯大小写差异不是识别错误（api → API），学它没有意义
    if (rawLower.includes(lower) && candidate.term !== lower) continue;
    // 纯数字/符号的变化属于"改事实"，不是术语
    if (!/[\u4e00-\u9fffA-Za-z]/.test(candidate.term)) continue;
    // 与原文只差大小写的整词（GitHub → github）同样跳过
    if (rawLower.split(/[^a-z0-9]+/u).includes(lower)) continue;
    // 重复模式、含数字等明显不是术语的形态
    if (looksLikeJunk(candidate.term)) continue;
    const existing = best.get(lower);
    if (!existing || candidate.confidence > existing.confidence) best.set(lower, candidate);
  }
  return [...best.values()];
}

/**
 * 读用户认可过的历史文本，供反事实回放用。
 * 优先用 corrected（用户明确改成的样子），否则用它当时收到的 text。
 */
export function loadAccepted(limit = 200) {
  const path = process.env.VOICE_GLOBAL_CORPUS
    || path.join(os.homedir(), '.voice-global', 'recordings', 'index.jsonl');
  try {
    return fs.readFileSync(path, 'utf8').split('\n')
      .filter((line) => line.trim())
      .slice(-limit)
      .map((line) => { try { const e = JSON.parse(line); return e.corrected || e.text || ''; } catch { return ''; } })
      .filter(Boolean);
  } catch {
    return [];
  }
}

/** 只取词面，供调用方按老接口使用。 */
export function extractTermNames(raw, corrected) {
  return extractTerms(raw, corrected).map((c) => c.term);
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
  const names = newTerms.map((t) => (typeof t === 'string' ? t : t.term));
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
  const existingCount = existing.length;
  let dropped = 0;
  for (const term of names) {
    if (existingCount + added.length >= MAX_TERMS) { dropped += 1; continue; }
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

  const pendingPath = value('--pending')
    || path.join(os.homedir(), '.voice-global', 'learning-pending.json');
  const candidates = extractTerms(raw, corrected);
  if (argv.includes('--dry')) {
    process.stdout.write(`${JSON.stringify({ added: [], pending: [], candidates })}\n`);
  } else {
    const { added, pending, promoted, rejected } = learn(dictPath, pendingPath, candidates, loadAccepted());
    process.stdout.write(`${JSON.stringify({ added, pending, promoted, rejected, candidates })}\n`);
  }
}

/**
 * 完整的学习动作：高置信度直接进词表，低置信度先攒着。
 *
 * 为什么不一律直接进：中文单字替换的术语边界是**猜**出来的（见 CONFIDENCE_CJK_GUESSED），
 * 一次就写进词表，猜错了会污染之后每一句话的提示。攒够两次再见，误判概率大幅下降。
 *
 * @param {string} dictionaryPath
 * @param {string} pendingPath
 * @param {{term: string, confidence: number, kind: string}[]} candidates
 * @returns {{added: string[], pending: string[], promoted: string[]}}
 */
export function learn(dictionaryPath, pendingPath, candidates, acceptedTexts = []) {
  let pending = {};
  try {
    pending = JSON.parse(fs.readFileSync(pendingPath, 'utf8'));
  } catch { /* 首次或坏文件，从空开始 */ }

  const added = [];
  const promoted = [];
  const stillPending = [];
  const rejected = [];
  const toApply = [];

  for (const candidate of candidates) {
    const term = String(candidate.term ?? candidate).trim();
    if (!term) continue;
    const confidence = candidate.confidence ?? 1;

    if (confidence >= AUTO_APPLY_CONFIDENCE) {
      const radius = acceptedTexts.length ? blastRadius(term, acceptedTexts) : null;
      if (radius && !radius.safe) {
        // 影响面过大：这个词会到处命中，先别让它生效
        rejected.push({ term, ratio: Number(radius.ratio.toFixed(2)), samples: radius.samples });
        continue;
      }
      toApply.push(term);
      continue;
    }
    const record = pending[term] ?? { count: 0, confidence };
    record.count += 1;
    record.confidence = Math.max(record.confidence ?? 0, confidence);
    record.lastSeen = new Date().toISOString();
    pending[term] = record;

    if (record.count >= PENDING_PROMOTE_COUNT) {
      toApply.push(term);
      promoted.push(term);
      delete pending[term];
    } else {
      stillPending.push(term);
    }
  }

  if (toApply.length) {
    const result = mergeTerms(dictionaryPath, toApply);
    added.push(...result.added);
  }
  try {
    fs.writeFileSync(pendingPath, `${JSON.stringify(pending, null, 2)}\n`);
  } catch { /* 写不了就算了，不影响主流程 */ }

  return { added, pending: stillPending, promoted, rejected };
}

/**
 * 反事实回放：把候选词拿到用户**已经认可过**的历史文本上跑一遍，看它会改动多少。
 *
 * 调研里给的做法是"只要会改动任何一条就不自动生效"。但对**用户词表**来说这个判据太严：
 * 历史文本里本来就留着识别错的写法，把它改对恰恰是我们想要的。
 *
 * 真正的风险是另一种：词太宽泛，会命中**本来完全正确**的无关文本
 * （比如一个两字词，拼音足够常见，到处都能匹配上）。
 * 那种情况下影响面会明显偏高。所以这里看的是**比例**，不是有没有。
 *
 * @param {string} term
 * @param {string[]} accepted - 用户认可过的文本（语料里的 corrected 或 text）
 * @param {number} limit - 最高可接受的影响比例
 * @returns {{ratio: number, samples: string[], safe: boolean}}
 */
export function blastRadius(term, accepted, limit = 0.2) {
  const samples = [];
  let changed = 0;
  for (const text of accepted) {
    if (!text) continue;
    const result = applyTerms(text, [term]);
    if (result.applied.length) {
      changed += 1;
      if (samples.length < 3) samples.push(result.applied[0].from);
    }
  }
  const total = accepted.filter(Boolean).length;
  const ratio = total ? changed / total : 0;
  return { ratio, samples, safe: total === 0 || ratio <= limit };
}
