/**
 * DSH Voice Global —— 听写清理层（规则引擎）
 * ==========================================
 *
 * 目标：把语音转写的"口语稿"变成"书面稿"，不改变原意。
 *
 * 只做确定性的、可解释的清理，不做改写：
 *   1. 删除语气词 / 口头禅（中英文）
 *   2. 合并重复词（"我我我" → "我"）
 *   3. 处理口头自我修正（"……，不对，……" 保留后半句）
 *   4. 规整标点与空白
 *   5. 可选：中英文之间补空格
 *
 * 设计原则：
 *   - **保守**：宁可少删，不要误删。"这个/那个"当指示代词时必须保留。
 *   - **幂等**：clean(clean(x)) === clean(x)
 *   - **可解释**：返回命中的规则名，便于排查与调参。
 */

/** 单字语气词（可连用，如"嗯嗯""呃啊"）。只在独立成词时删除。 */
const ZH_FILLER_CHARS = '嗯呃额啊哦噢唔唉哎诶嘛呀呐';

/** 明确的口头禅：句首可直接删，后跟停顿也删。 */
const ZH_FILLER_STRICT = [
  '那个那个', '这个这个', '就是说', '也就是说', '怎么说呢', '你知道吧', '你懂我意思吧',
  '就是呢', '反正就是', '这么讲吧', '这么着吧', '我看看', '让我想想', '其实吧',
  '对吧', '是吧', '好不好', '对不对',
];

/** 有实义的连接/指示词：只有被停顿"孤立"出来时才当作口头禅删除。 */
const ZH_FILLER_PAUSED = ['那个', '这个', '然后', '就是'];

/** 英文填充词：无语义歧义，直接删。 */
const EN_FILLERS_PLAIN = ['um', 'uh', 'erm', 'err', 'hmm', 'mm'];

/** 英文填充短语：边界明确时删。 */
const EN_FILLERS_PHRASE = ['you know', 'i mean', 'sort of', 'kind of', 'basically', 'actually'];

/** `like` 太容易误伤（I like it），只在后面紧跟逗号时才算填充词。 */
const EN_FILLER_COMMA_ONLY = ['like'];

/** 口头自我修正的触发词：保留其后的内容。 */
const ZH_CORRECTION_MARKERS = ['不对', '不是', '我是说', '应该说', '重说', '重新说', '改成', '改一下', '纠正一下', '说错了'];

/** 句读边界（用于判断"是否句首/句尾"）。 */
const BOUNDARY = '，。！？；、,.!?;…\\s（）()《》""\'\'';
const BOUNDARY_RE = new RegExp(`[${BOUNDARY}]`);

/**
 * 重复词合并：折叠结巴式的连续重复。
 * 为保护汉语的动词重叠（看看、想想、试试），只处理两种情况：
 *   - 同一片段连续 3 次以上："我我我" → "我"
 *   - 2–3 字的片段连续 2 次以上："就是就是" → "就是"、"看一下看一下" → "看一下"
 * @param {string} text
 * @returns {{text: string, hits: string[]}}
 */
function collapseRepetitions(text) {
  const hits = [];
  let out = text.replace(/([\u4e00-\u9fff]{1,3})\1{2,}/gu, (match, unit) => {
    hits.push(`repeat:${unit}x${match.length / unit.length}`);
    return unit;
  });
  out = out.replace(/([\u4e00-\u9fff]{2,3})\1{1,}/gu, (match, unit) => {
    hits.push(`repeat:${unit}x${match.length / unit.length}`);
    return unit;
  });
  // 英文单词的整词重复："the the" → "the"
  out = out.replace(/\b([A-Za-z]+)(\s+\1\b)+/gi, (match, word) => {
    hits.push(`repeat:${word}`);
    return word;
  });
  return { text: out, hits };
}

/**
 * 删除中文语气词。
 * 单字语气词只在"独立成词"时删除（前后是边界）。
 * 明确口头禅可在句首删除；有实义的词必须被标点孤立才删除，
 * 因此"这个项目""那个进度"不会被误伤。
 * @param {string} text
 * @returns {{text: string, hits: string[]}}
 */
function stripChineseFillers(text) {
  const hits = [];
  let out = text;

  // 1) 单字语气词：独立成词（前后为边界/行首行尾）
  const singleRe = new RegExp(`(^|[${BOUNDARY}])[${ZH_FILLER_CHARS}]+(?=[${BOUNDARY}]|$)`, 'gu');
  out = out.replace(singleRe, (match, lead) => {
    hits.push(`filler:${match.slice(lead.length)}`);
    return lead;
  });

  // 2) 明确口头禅：句首删（停顿可选），句中删（前后为边界）
  for (const word of ZH_FILLER_STRICT) {
    out = out.replace(new RegExp(`^${word}[，,、]?`, 'gu'), () => {
      hits.push(`filler-head:${word}`);
      return '';
    });
    out = out.replace(new RegExp(`([${BOUNDARY}])${word}[，,、]?(?=[${BOUNDARY}]|$)`, 'gu'), (match, lead) => {
      hits.push(`filler-mid:${word}`);
      return lead;
    });
  }

  // 3) 有实义的词：必须被停顿孤立才删（前有标点，且自身后面紧跟逗号）
  for (const word of ZH_FILLER_PAUSED) {
    out = out.replace(new RegExp(`^${word}[，,、]`, 'gu'), () => {
      hits.push(`filler-head:${word}`);
      return '';
    });
    out = out.replace(new RegExp(`([${BOUNDARY}])${word}[，,、]`, 'gu'), (match, lead) => {
      hits.push(`filler-mid:${word}`);
      return lead;
    });
  }

  // 4) "那个/这个"后面直接跟人称代词时，几乎一定是口头禅——识别结果常常丢掉逗号，
  //    仅靠停顿判断会漏删（"那个我们明天开会"）。要求前面是句读边界，
  //    因此"他提到了那个我们都很熟悉的例子"不会被误伤。
  out = out.replace(
    new RegExp(`(^|[${BOUNDARY}])\\s*(?:那个|这个)(?=(?:我们|你们|他们|咱们|大家|各位|我|你|您|他|她|它))`, 'gu'),
    (match, lead) => {
      hits.push('filler-head-pronoun');
      return lead;
    },
  );
  return { text: out, hits };
}

/**
 * 删除英文填充词。删除时一并吃掉一个相邻逗号，避免留下 " , " 残渣。
 * @param {string} text
 * @returns {{text: string, hits: string[]}}
 */
function stripEnglishFillers(text) {
  const hits = [];
  let out = text;

  for (const filler of [...EN_FILLERS_PLAIN, ...EN_FILLERS_PHRASE]) {
    const pattern = filler.replace(/ /g, '\\s+');
    const re = new RegExp(`(^|[\\s,.;:!?，。；：！？])\\s*${pattern}\\s*,?(?=[\\s,.;:!?，。；：！？]|$)`, 'gi');
    out = out.replace(re, (match, lead) => {
      hits.push(`filler-en:${filler}`);
      return lead;
    });
  }
  for (const filler of EN_FILLER_COMMA_ONLY) {
    const re = new RegExp(`(^|[\\s,.;:!?，。；：！？])\\s*${filler}\\s*,`, 'gi');
    out = out.replace(re, (match, lead) => {
      hits.push(`filler-en:${filler}`);
      return lead;
    });
  }
  return { text: out, hits };
}

/**
 * 口头自我修正：保留修正标记之后的内容，丢弃之前的口误。
 * "明天三点开会，不对，是四点" → "是四点"
 * "发给我，我是说发给张总" → "发给张总"
 * @param {string} text
 * @returns {{text: string, hits: string[]}}
 */
function applySelfCorrection(text) {
  const hits = [];
  let out = text;
  const marker = ZH_CORRECTION_MARKERS.join('|');
  // 修正语紧跟在停顿之后，且修正标记前的内容属于同一句
  const re = new RegExp(`[^。！？!?]{0,60}?[，,]\\s*(?:${marker})[，,]?\\s*`, 'gu');
  out = out.replace(re, () => {
    hits.push('self-correction');
    return '';
  });
  return { text: out, hits };
}

/**
 * 规整标点与空白：省略号归一、合并重复标点、清除行首标点、压缩空格。
 * @param {string} text
 * @returns {{text: string, hits: string[]}}
 */
function normalizePunctuation(text) {
  const hits = [];
  let out = text;
  const before = out;

  out = out.replace(/\.{3,}/gu, '…');
  out = out.replace(/[，,]{2,}/gu, '，');
  out = out.replace(/[。]{2,}/gu, '。');
  out = out.replace(/[！!]{2,}/gu, '！');
  out = out.replace(/[？?]{2,}/gu, '？');
  // 句末标点后跟着逗号（删掉"呃，那个"这类插入语后的残渣）
  out = out.replace(/([。！？；])[，,、]\s*/gu, '$1');
  // 被空白隔开的重复标点（英文填充词删除后的残渣）；保留第一个标点
  out = out.replace(/([,.;:!?，。；：！？])\s+(?=[,.;:!?，。；：！？])/gu, '$1');
  // 中文标点前不留空格
  out = out.replace(/\s+([，。！？、；：])/gu, '$1');
  out = out.replace(/^[，。！？、；：,.!?;:\s]+/gu, '');
  out = out.replace(/[ \t]{2,}/gu, ' ');
  out = out.replace(/\s+$/gu, '');

  if (out !== before) hits.push('punctuation');
  return { text: out, hits };
}

/**
 * 中英文之间补空格（可选，默认关闭：聊天场景常常不需要）。
 * @param {string} text
 * @returns {{text: string, hits: string[]}}
 */
function spaceCJKLatin(text) {
  const hits = [];
  let out = text;
  const before = out;
  out = out.replace(/([\u4e00-\u9fff])([A-Za-z0-9])/gu, '$1 $2');
  out = out.replace(/([A-Za-z0-9])([\u4e00-\u9fff])/gu, '$1 $2');
  if (out !== before) hits.push('cjk-space');
  return { text: out, hits };
}

/**
 * 执行完整规则清理。
 * @param {string} raw - 原始转写文本
 * @param {{spaceCJK?: boolean}} [options]
 * @returns {{text: string, hits: string[], changed: boolean}}
 */
export function clean(raw, options = {}) {
  const input = String(raw ?? '');
  if (!input.trim()) return { text: '', hits: [], changed: false };
  const hits = [];
  let text = input;

  for (const step of [collapseRepetitions, stripChineseFillers, stripEnglishFillers, applySelfCorrection]) {
    const result = step(text);
    text = result.text;
    hits.push(...result.hits);
  }
  const punct = normalizePunctuation(text);
  text = punct.text;
  hits.push(...punct.hits);

  if (options.spaceCJK) {
    const spaced = spaceCJKLatin(text);
    text = spaced.text;
    hits.push(...spaced.hits);
  }

  text = text.trim();
  return { text, hits, changed: text !== input };
}

export const _internal = {
  ZH_FILLER_CHARS, ZH_FILLER_STRICT, ZH_FILLER_PAUSED,
  EN_FILLERS_PLAIN, EN_FILLERS_PHRASE, EN_FILLER_COMMA_ONLY,
  ZH_CORRECTION_MARKERS,
};
