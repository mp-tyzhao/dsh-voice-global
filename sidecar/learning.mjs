/**
      // 机器本来就会写对的通用术语，自动学习跳过（见 PUBLIC_TERMS）
      if (isPublicTerm(candidate.term)) continue;
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
import { alignmentGaps, tokenize, removeReplacements } from './dictionary.mjs';
import { applyTerms, windowScore } from './phonetic.mjs';

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
// 西文词整体可信，但**短词要打折**：2-3 个字符的西文串太容易是
// 用户正在打拼音、缩写、或者随手敲的东西。实测（2026-10-07）用户
// 把「无层叠加」改成「tu层叠加」（在打拼音），系统就把 `tu` 学进了词表。
// 短词降到待定区，再见一次才生效 —— 误判的代价从"污染词表"降到"多等一次"。
const CONFIDENCE_LATIN = 0.90;
const CONFIDENCE_LATIN_SHORT = 0.65;
const LATIN_SHORT_LENGTH = 4;
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
/**
 * 通用公开术语 —— **自动学习时跳过它们**。
 *
 * ## 为什么
 *
 * 这些词机器本来就会写对。你偶尔手改一次，多半是笔误或者一次性的听错，
 * 学进来只会让词表变长、让提示变噪。VoiceInk 的 Auto Learn 有一模一样的
 * 策略（Apple、Google、Xcode、Markdown、React、PostgreSQL、GitHub），
 * 它的原话是这些"不是可复用的语音纠正"。
 *
 * ## 注意
 *
 * 只拦**自动学习**。你想加就手动加 —— 词表里现在就有 Kubernetes、Milvus，
 * 那是你主动带进来的，不受这张表影响。
 *
 * 西文按小写精确匹配整词；中文按包含匹配（"微信"要能拦住"用微信发"）。
 */
const PUBLIC_TERMS = new Set([
  // 大厂 / 品牌 / 产品
  'apple', 'google', 'microsoft', 'amazon', 'meta', 'facebook', 'instagram', 'whatsapp',
  'openai', 'anthropic', 'chatgpt', 'claude', 'gemini', 'copilot', 'nvidia', 'intel', 'amd',
  'github', 'gitlab', 'bitbucket', 'gitee', 'docker', 'kubernetes', 'jenkins', 'vercel',
  'netlify', 'heroku', 'aws', 'azure', 'gcp', 'cloudflare', 'nginx', 'redis', 'mongodb',
  'postgresql', 'postgres', 'mysql', 'sqlite', 'elasticsearch', 'kafka', 'rabbitmq',
  'slack', 'notion', 'figma', 'jira', 'confluence', 'zoom', 'dropbox', 'evernote',
  'iphone', 'ipad', 'macbook', 'airpods', 'macos', 'ios', 'android', 'windows', 'linux',
  'ubuntu', 'debian', 'chrome', 'safari', 'firefox', 'edge', 'telegram', 'discord',
  // 编程语言 / 框架 / 常见技术词
  'python', 'javascript', 'typescript', 'java', 'golang', 'rust', 'kotlin', 'swift',
  'react', 'vue', 'angular', 'svelte', 'nextjs', 'nuxt', 'django', 'flask', 'rails',
  'spring', 'laravel', 'express', 'nodejs', 'npm', 'yarn', 'pnpm', 'webpack', 'vite',
  'html', 'css', 'sass', 'tailwind', 'json', 'yaml', 'xml', 'sql', 'graphql', 'rest',
  'api', 'sdk', 'cli', 'http', 'https', 'tcp', 'udp', 'dns', 'cdn', 'jwt', 'oauth',
  'markdown', 'latex', 'regex', 'git', 'bash', 'zsh', 'shell', 'terminal', 'vim', 'emacs',
  'vscode', 'xcode', 'androidstudio', 'intellij', 'pycharm', 'postman', 'jupyter',
  // 中文里机器本来就写得对的常见词
  '微信', '支付宝', '淘宝', '天猫', '京东', '拼多多', '抖音', '快手', '小红书', '微博',
  '知乎', '哔哩哔哩', '百度', '腾讯', '阿里', '字节跳动', '美团', '滴滴', '网易',
  '苹果', '谷歌', '微软', '亚马逊', '华为', '小米', '钉钉', '飞书', '企业微信',
]);

/**
 * 是不是"机器本来就会写对"的通用术语。
 * 中文词要按包含匹配 —— 学到的往往是"用微信发"这种带上下文的片段。
 */
function isPublicTerm(term) {
  const lower = term.toLowerCase();
  if (PUBLIC_TERMS.has(lower)) return true;
  // 中文：术语里包含某个通用词（且那个通用词占了大半）→ 也跳过
  for (const known of PUBLIC_TERMS) {
    if (!/[\u4e00-\u9fff]/.test(known)) continue;
    if (lower.includes(known) && known.length >= term.length - 1) return true;
  }
  return false;
}


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
const MAX_CJK_TERM = 6;
/**
 * 「这次改动是识别错误，还是用户改主意」的读音阈值。
 *
 * 判据来自观察：识别错误会**保留读音**（你说的是同一句话，机器写错了），
 * 改主意会**改变读音**（你换了说法）。实测（2026-10-11，用户真实修订）：
 *
 *   路奇博士 → 陆奇博士   相似度 1.00  ← 识别错误，该学
 *   不错     → 很好       相似度 0.00  ← 改说法，不该学
 *
 * 取 0.7：同音/近音稳妥通过；换了说法的必然远低于此。
 */
const MISRECOGNITION_SIMILARITY = 0.7;

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
 * 这次改动像"识别错误"还是"改主意"。
 *
 * 识别错误**保留读音**（你说了同一句话，机器写错了）；改主意**改变读音**。
 * 只在长度相同时用读音判据 —— 长度不同说明是增删内容，
 * 那属于"改主意"的形态（实测 20 条真实修订里 12 条是纯删除）。
 *
 * @param {string} rawSpan 原文里被改掉的那一段（**连续**切片，见下面的合并逻辑）
 * @param {string} correctedRun 改后那一段
 * @returns {boolean}
 */
function looksLikeMisrecognition(rawSpan, correctedRun) {
  if (!rawSpan || !correctedRun) return false;
  const a = Array.from(rawSpan);
  const b = Array.from(correctedRun);
  if (a.length !== b.length) return false;   // 长度不同 = 增删内容，不是同音写错
  return windowScore(rawSpan, correctedRun) >= MISRECOGNITION_SIMILARITY;
}

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
    const rawStart = gap.rawIndexes[0];
    const rawEnd = gap.rawIndexes[gap.rawIndexes.length - 1];
    const last = merged[merged.length - 1];
    if (last && start - last.end <= MERGE_DISTANCE) {
      last.end = Math.max(last.end, end);
      last.rawCount += gap.raw.length;
      // 原文侧记**下标范围**，最后统一切片 —— 不能把各段的 raw 拼起来。
      //
      // 踩过的坑（2026-10-11）：用户测自净化 → 用户侧自进化 会被切成
      // 「测→侧」「净→进」两段，中间夹着没变的「自」。拼起来是「测净」，
      // 而改正侧是「侧自进」，两边错位 → 读音判据算出 0.000，
      // 把一个正确的学习信号整条丢掉。
      last.rawStart = Math.min(last.rawStart, rawStart);
      last.rawEnd = Math.max(last.rawEnd, rawEnd);
    } else {
      merged.push({ start, end, rawCount: gap.raw.length, rawStart, rawEnd });
    }
  }
  // 切原文：得到覆盖整段改动的**连续**文本
  for (const group of merged) {
    group.rawText = rawTokens.slice(group.rawStart, group.rawEnd + 1).join('');
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
      // 上下文扩展前的原样 —— 扩展会带上没变过的字，拿它比对会让相似度失真
      const runText = text;
      // 上下文往两边各扩了几个字。**原文侧要扩同样多** ——
      // 否则词只是对子的一半，另一半（误听成什么样）就丢了。
      let beforeCount = 0;
      let afterCount = 0;
      if (run.kind === 'cjk') {
        const originalLength = text.length;
        // **这次改动像"识别错误"吗？** 不像就当成用户改主意，不学 ——
        // 这是记忆被污染的主要来源（实测：改说法的编辑会被当成术语学进去）。
        if (!looksLikeMisrecognition(group.rawText, runText)) { run = null; return; }
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
          beforeCount = before.length;
        }
        // 往后带：仅当替换跨度不止一个字时才允许。
        //
        // 依据来自两个真实案例：
        //   赵天义 → 赵天翊（单字替换，替换处就是词尾）—— 右扩会带出"负责"，得到"赵天翊负责"
        //   用户测自净化 → 用户侧自进化（多字合并替换，后面还有匹配的"化"）—— 不右扩就丢掉"化"
        // 单字替换通常发生在词尾或整词替换；多字替换往往是词内部重构，后面还有内容。
        if (originalLength > 1) {
          const after = [];
          for (let k = group.end + 1; k < correctedTokens.length && after.length < CJK_CONTEXT; k += 1) {
            const token = correctedTokens[k];
            if (!/^[\u4e00-\u9fff]$/u.test(token) || isFunctionChar(token)) break;
            after.push(token);
          }
          text += after.join('');
          afterCount = after.length;
        }
        // 截断时原文侧要跟着往后挪，否则两边错位
        let dropped = 0;
        if (text.length > MAX_CJK_TERM) {
          dropped = text.length - MAX_CJK_TERM;
          text = text.slice(-MAX_CJK_TERM);
        }
        // 只替换了一个字、而且带上文后尾字仍是虚词 → `那样把`、`识别得`、`比如给`，丢掉
        if (originalLength === 1 && isFunctionChar(text[text.length - 1])) { run = null; return; }
        // 首字是虚词的片段不是术语（`把一些`、`在这个` 这种碎片）
        if (isFunctionChar(text[0])) { run = null; return; }
        if (text.length >= MIN_CJK_RUN) {
          // 整段是新词（插入型）比"单字替换 + 猜上文"可靠得多
          confidence = originalLength >= MIN_CJK_RUN ? CONFIDENCE_CJK_DIRECT : CONFIDENCE_CJK_GUESSED;
          // 原文侧：从同样的起点取同样多 —— 两边对齐才能当"对子"用
          const fromStart = group.rawStart - beforeCount + dropped;
          const fromEnd = group.rawEnd + afterCount;
          const from = rawTokens.slice(fromStart, fromEnd + 1).join('');
          candidates.push({ term: text, from, confidence, kind: originalLength >= MIN_CJK_RUN ? 'cjk' : 'cjk-guessed' });
        }
      } else if (text.length >= MIN_LATIN_LEN) {
        // 西文词边界天然清楚，拼错也很可能整词被听错，置信度最高；
        // 但短串（< 4 字符）打折，进待定区等一次确认
        const short = text.length < LATIN_SHORT_LENGTH;
        candidates.push({
          term: text,
          from: group.rawText,
          confidence: short ? CONFIDENCE_LATIN_SHORT : CONFIDENCE_LATIN,
          kind: short ? 'latin-short' : 'latin',
        });
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
  // 变量名不能叫 path —— 会遮蔽顶部导入的 path，触发 TDZ 报错，
  // 整个 learning.mjs 每次调用都崩。学习功能因此从来没跑起来过。
  const corpusPath = process.env.VOICE_GLOBAL_CORPUS
    || path.join(os.homedir(), '.voice-global', 'recordings', 'index.jsonl');
  try {
    return fs.readFileSync(corpusPath, 'utf8').split('\n')
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
/**
 * 往词表里加词，并记下**这个词是怎么来的**。
 *
 * 区分「我自己加的」和「系统学到的」是调研里反复出现的一条：
 * Typeless 用 Auto-added / Manually-added 两个桶，报告原文说
 * "One enum field; it is the entire trust solution."
 *
 * 用户要能一眼看出哪些是系统自作主张加的，才能放心让它继续学。
 * 字段放在 origin 里，terms 本身仍是纯字符串数组 —— 老代码读 terms 不受影响。
 *
 * @param {string} dictionaryPath
 * @param {Array<string|{term: string, confidence?: number, kind?: string}>} newTerms
 * @param {{addedBy?: string}} [options]
 */
export function mergeTerms(dictionaryPath, newTerms, options = {}) {
  const addedBy = options.addedBy ?? 'learned';
  const names = newTerms.map((t) => (typeof t === 'string' ? t : t.term));
  const meta = new Map(
    newTerms.filter((t) => typeof t !== 'string').map((t) => [t.term, t]),
  );
  let document = { terms: [] };
  try {
    const parsed = JSON.parse(fs.readFileSync(dictionaryPath, 'utf8'));
    document = Array.isArray(parsed) ? { terms: parsed } : parsed;
  } catch {
    // 文件不存在或坏了：重建一份，不覆盖用户其它字段之外的意图
  }
  const terms = Array.isArray(document.terms) ? document.terms.map(String) : [];
  const existing = new Set(terms.map((t) => t.toLowerCase()));
  const origin = (document.origin && typeof document.origin === 'object') ? document.origin : {};

  const added = [];
  const existingCount = existing.size;
  let dropped = 0;
  for (const term of names) {
    if (existingCount + added.length >= MAX_TERMS) { dropped += 1; continue; }
    const clean = String(term).trim();
    if (!clean || existing.has(clean.toLowerCase())) continue;
    existing.add(clean.toLowerCase());
    terms.push(clean);
    added.push(clean);
    const detail = meta.get(term);
    origin[clean] = {
      addedBy,
      at: new Date().toISOString(),
      ...(detail?.confidence !== undefined ? { confidence: detail.confidence } : {}),
    };
  }

  if (added.length) {
    // 写不进去不能抛错：词表可能放在只读位置、磁盘可能满。
    // 抛出去会让整个 learning.mjs 以非零码退出，宿主拿不到 JSON，
    // 用户看到的是"学习没反应"而不是"词表写不进去"。
    try {
      fs.mkdirSync(path.dirname(dictionaryPath), { recursive: true });
      document.terms = terms;
      document.origin = origin;
      document.updatedAt = new Date().toISOString();
      fs.writeFileSync(dictionaryPath, `${JSON.stringify(document, null, 2)}\n`);
    } catch (error) {
      return { added: [], total: terms.length - added.length, dropped, error: String(error.message ?? error) };
    }
  }
  return { added, total: terms.length, dropped };
}

/**
 * 读词表及其来源，给"审查/撤销"界面用。
 * @param {string} dictionaryPath
 * @returns {{term: string, addedBy: string, at?: string, confidence?: number}[]}
 */
export function describeTerms(dictionaryPath) {
  let document = { terms: [] };
  try {
    const parsed = JSON.parse(fs.readFileSync(dictionaryPath, 'utf8'));
    document = Array.isArray(parsed) ? { terms: parsed } : parsed;
  } catch { return []; }
  const origin = (document.origin && typeof document.origin === 'object') ? document.origin : {};
  return (Array.isArray(document.terms) ? document.terms : []).map((term) => ({
    term: String(term),
    // 没记来源的一律当手动加的 —— 宁可不误报"系统加的"
    addedBy: origin[term]?.addedBy ?? 'manual',
    at: origin[term]?.at,
    confidence: origin[term]?.confidence,
  }));
}

/**
 * 待定区的词（只见过一次、还没敢自动生效的）。
 * 标 addedBy: 'pending' 让它和正式词表一起返回，宿主菜单里显示成"待确认"。
 */
export function describePending(pendingPath) {
  let document = {};
  try { document = JSON.parse(fs.readFileSync(pendingPath, 'utf8')); } catch { return []; }
  if (!document || typeof document !== 'object') return [];
  return Object.entries(document).map(([term, meta]) => ({
    term: String(term),
    addedBy: 'pending',
    at: meta?.lastSeen,
    confidence: meta?.confidence,
    seen: meta?.count ?? 0,
  }));
}


/** 从词表里删词（撤销学到的词）。 */
export function removeTerms(dictionaryPath, terms) {
  let document = { terms: [] };
  try {
    const parsed = JSON.parse(fs.readFileSync(dictionaryPath, 'utf8'));
    document = Array.isArray(parsed) ? { terms: parsed } : parsed;
  } catch { return { removed: [] }; }
  const drop = new Set(terms.map((t) => String(t).toLowerCase()));
  const before = Array.isArray(document.terms) ? document.terms.map(String) : [];
  const kept = before.filter((t) => !drop.has(t.toLowerCase()));
  const origin = (document.origin && typeof document.origin === 'object') ? document.origin : {};
  for (const term of before) if (drop.has(term.toLowerCase())) delete origin[term];
  document.terms = kept;
  document.origin = origin;
  document.updatedAt = new Date().toISOString();
  fs.mkdirSync(path.dirname(dictionaryPath), { recursive: true });
  fs.writeFileSync(dictionaryPath, `${JSON.stringify(document, null, 2)}\n`);
  return { removed: before.filter((t) => drop.has(t.toLowerCase())) };
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

  // 回扫语料：把历史修订重新学一遍（幂等，可反复跑）
  if (argv.includes('--from-corpus')) {
    const base = path.join(os.homedir(), '.voice-global');
    const result = mineCorpus({
      dictionaryPath: value('--dict') || path.join(base, 'dictionary.json'),
      pendingPath: value('--pending') || path.join(base, 'learning-pending.json'),
      minedPath: value('--mined') || path.join(base, 'learning-mined.json'),
      corpusPath: process.env.VOICE_GLOBAL_CORPUS || path.join(base, 'recordings', 'index.jsonl'),
    });
    process.stdout.write(`${JSON.stringify(result)}\n`);
    process.exit(0);
  }

  // 词表管理：宿主用来做「审查 / 撤销」
  if (argv.includes('--list')) {
    const dictForList = value('--dict') || path.join(os.homedir(), '.voice-global', 'dictionary.json');
    const pendingForList = value('--pending')
      || path.join(os.homedir(), '.voice-global', 'learning-pending.json');
    // **待定区也要一起返回。**
    //
    // 踩过的坑（2026-10-11）：待定区的提升阈值是"见过 2 次"，
    // 而真实使用里同一个词很少被连改两次 —— 实测 5 条**全部**停在
    // "见过 1 次"，永远等不到提升；而菜单只读正式词表，用户根本看不见它们。
    // 于是待定区成了黑洞：进去就出不来。
    // 现在一起返回（标 addedBy: pending），菜单里可以一键确认。
    process.stdout.write(`${JSON.stringify({
      terms: [...describeTerms(dictForList), ...describePending(pendingForList)],
    })}\n`);
    process.exit(0);
  }
  if (argv.includes('--merge')) {
    const dictForMerge = value('--dict') || path.join(os.homedir(), '.voice-global', 'dictionary.json');
    const incoming = (value('--merge') || '').split('\n').map((t) => t.trim()).filter(Boolean);
    // 导入的词算手动添加 —— 是用户主动带进来的，不是系统猜的
    process.stdout.write(`${JSON.stringify(mergeTerms(dictForMerge, incoming, { addedBy: 'manual' }))}\n`);
    process.exit(0);
  }
  if (argv.includes('--remove')) {
    const dictForRemove = value('--dict') || path.join(os.homedir(), '.voice-global', 'dictionary.json');
    const targets = (value('--remove') || '').split(',').map((t) => t.trim()).filter(Boolean);
    process.stdout.write(`${JSON.stringify(removeTerms(dictForRemove, targets))}\n`);
    process.exit(0);
  }

  // 撤销"最近一次学到的词" —— 用户看到浮窗提示后反悔，或者点菜单。
  // 读上一段写的那份日志，把词和对子一起撤掉。
  if (argv.includes('--undo-last')) {
    const journalPath = value('--journal')
      || path.join(os.homedir(), '.voice-global', 'last-learned.json');
    const dictForUndo = value('--dict') || path.join(os.homedir(), '.voice-global', 'dictionary.json');
    const pairsForUndo = value('--replacements')
      || path.join(os.homedir(), '.voice-global', 'replacements.json');
    let journal = null;
    try { journal = JSON.parse(fs.readFileSync(journalPath, 'utf8')); } catch { /* 没有就没什么可撤 */ }
    const gone = journal?.added?.length ? removeTerms(dictForUndo, journal.added).removed : [];
    const gonePairs = journal?.pairs?.length ? removeReplacements(pairsForUndo, journal.pairs) : [];
    try { fs.unlinkSync(journalPath); } catch { /* 已经没了 */ }
    process.stdout.write(`${JSON.stringify({ removed: gone, pairs: gonePairs })}\n`);
    process.exit(0);
  }

  const pendingPath = value('--pending')
    || path.join(os.homedir(), '.voice-global', 'learning-pending.json');
  // 纠正对子（原文的误听 → 用户改成的东西）。见 dictionary.mjs 的 applyReplacements。
  const replacementsPath = value('--replacements')
    || path.join(os.homedir(), '.voice-global', 'replacements.json');
  const candidates = extractTerms(raw, corrected);
  if (argv.includes('--dry')) {
    process.stdout.write(`${JSON.stringify({ added: [], pending: [], candidates })}\n`);
  } else {
    const { added, pending, promoted, rejected, pairs: pairsOut } = learn(dictPath, pendingPath, candidates, loadAccepted(), { replacementsPath });
    // **记一份"最近一次学了什么"**，给「撤销上一次学到的词」用。
    //
    // 为什么不把这个信息通过 Swift 的通道传上去：撤销是低频动作，
    // 而通道每加一个字段就要改四处（sidecar → Sidecar.swift → 回调 → 菜单）。
    // 落一份小文件反而更简单，而且重启之后还能撤销。
    const journalPath = value('--journal')
      || path.join(os.homedir(), '.voice-global', 'last-learned.json');
    try {
      fs.writeFileSync(journalPath, JSON.stringify({
        at: new Date().toISOString(),
        added, pairs: pairsOut ?? [], pending,
      }, null, 2));
    } catch { /* 写不了不影响学习本身 */ }
    process.stdout.write(`${JSON.stringify({ added, pending, promoted, rejected, candidates, pairs: pairsOut })}\n`);
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
export function learn(dictionaryPath, pendingPath, candidates, acceptedTexts = [], options = {}) {
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

  // **把对子记下来。**
  //
  // 每次修订我们手里都有两边：原文怎么听错的、用户改成了什么。
  // 原来只用右边（词），左边扔掉 —— 那正是 superwhisper 让用户手工枚举的东西。
  // 对子层是精确匹配，所以这里不做置信度门槛（低置信度的"词"不该自动生效，
  // 但"这个词确实被这么听过"是个事实，不是猜测）。
  const recordedPairs = [];
  if (options.replacementsPath) {
    try {
      let document = {};
      try { document = JSON.parse(fs.readFileSync(options.replacementsPath, 'utf8')); } catch { /* 首次 */ }
      const pairs = (document && typeof document.pairs === 'object' && document.pairs) || {};
      for (const candidate of candidates) {
        const from = String(candidate.from ?? '').trim();
        const to = String(candidate.term ?? '').trim();
        if (!from || !to || from === to) continue;
        const existing = pairs[from];
        pairs[from] = { to, count: (existing?.count ?? 0) + 1, at: new Date().toISOString() };
        recordedPairs.push({ from, to });
      }
      if (recordedPairs.length) {
        // 对子数不设上限会无限增长；超出后按最近使用保留。
        const entries = Object.entries(pairs);
        const MAX_PAIRS = 500;
        const trimmed = entries.length > MAX_PAIRS
          ? Object.fromEntries(entries.sort((a, b) => String(b[1]?.at).localeCompare(String(a[1]?.at))).slice(0, MAX_PAIRS))
          : pairs;
        fs.writeFileSync(options.replacementsPath, JSON.stringify({ pairs: trimmed }, null, 2));
      }
    } catch { /* 对子写失败不影响学词 */ }
  }


  return { added, pending: stillPending, promoted, rejected, pairs: recordedPairs };
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

/**
 * 回扫语料，把**所有**历史修订重新学一遍。
 *
 * ## 为什么需要这个
 *
 * 实时学习有一个断点：某次修订发生时如果学习环节失效（sidecar 崩了、
 * 置信度不够、词表写不进去、或者代码本身有 bug），那条修订就永远留在
 * 语料里，再也不会被处理 —— 语料是"事实"，但学习是一次性的。
 *
 * 回扫把语料当成**可重复开采的矿**：每次跑都把没处理过的修订过一遍。
 * 这样：
 *   · 修好 bug 之后，之前丢掉的修订能补回来
 *   · 同一条修订不会被重复计入（用 ts 记账，不重复累加待定次数）
 *   · 随时可跑，幂等
 *
 * 这是"语音输入的 RSI"里最关键的一环：人工修订必须能**持续**进入循环，
 * 而不是只在发生的那一刻有机会。
 *
 * @param {object} options
 * @param {string} options.dictionaryPath
 * @param {string} options.pendingPath
 * @param {string} options.minedPath 已开采过的 ts 记账文件
 * @param {string} [options.corpusPath]
 * @returns {{scanned:number, mined:number, skipped:number, added:string[], pending:string[], rejected:object[]}}
 */
export function mineCorpus(options) {
  const {
    dictionaryPath,
    pendingPath,
    minedPath,
    corpusPath = path.join(os.homedir(), '.voice-global', 'recordings', 'index.jsonl'),
    replacementsPath = path.join(os.homedir(), '.voice-global', 'replacements.json'),
  } = options;

  let mined = {};
  try { mined = JSON.parse(fs.readFileSync(minedPath, 'utf8')); } catch { /* 首次 */ }

  let entries = [];
  try {
    entries = fs.readFileSync(corpusPath, 'utf8').split('\n')
      .filter((line) => line.trim())
      .map((line) => { try { return JSON.parse(line); } catch { return null; } })
      .filter(Boolean);
  } catch {
    return { scanned: 0, mined: 0, skipped: 0, added: [], pending: [], rejected: [] };
  }

  // 反事实回放要看用户认可过的历史文本，这里现取
  const accepted = entries.map((e) => e.corrected || e.text || '').filter(Boolean);

  const added = [];
  const pending = [];
  const promoted = [];
  const rejected = [];
  let minedCount = 0;
  let skipped = 0;

  for (const entry of entries) {
    const ts = entry.ts;
    const raw = entry.raw;
    const corrected = entry.corrected;   // 只有用户实际改过才有
    if (!ts || !raw || !corrected) { skipped += 1; continue; }
    if (mined[ts]) { skipped += 1; continue; }   // 开采过就不重复

    const candidates = extractTerms(raw, corrected);
    if (candidates.length) {
      const result = learn(dictionaryPath, pendingPath, candidates, accepted, { replacementsPath });
      added.push(...result.added);
      rejected.push(...result.rejected);
      // 注意：不进 pending 累积数组 —— 后面的条目可能把前面进的提升掉，
      // 累积会让报告显示一个已经生效的词还"待定"。最后统一读一次实际状态。
      pending.push(...result.pending);
      promoted.push(...result.promoted);
    }
    mined[ts] = { at: new Date().toISOString(), candidates: candidates.map((c) => c.term) };
    minedCount += 1;
  }

  if (minedCount) {
    try {
      fs.mkdirSync(path.dirname(minedPath), { recursive: true });
      fs.writeFileSync(minedPath, `${JSON.stringify(mined, null, 2)}\n`);
    } catch { /* 记不上就下次再来 */ }
  }

  // 待定区以磁盘上的最终状态为准 —— 过程累积会误导
  let finalPending = pending;
  try {
    finalPending = Object.keys(JSON.parse(fs.readFileSync(pendingPath, 'utf8')));
  } catch { /* 读不到就用过程值 */ }

  return { scanned: entries.length, mined: minedCount, skipped, added, promoted, pending: finalPending, rejected };
}
