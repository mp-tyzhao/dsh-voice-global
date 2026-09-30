/**
 * DSH Voice Global —— 可选 LLM 润色层
 * ====================================
 *
 * 规则层能删语气词、合并重复、处理"不对，我是说"这类口头修正；
 * 但同音字纠错、断句、书面化改写需要模型。这里走任意 OpenAI 兼容端点。
 *
 * 硬约束（对应 Typeless 的"听起来像你认真打出来的"）：
 *   - 只清理，不回答、不扩写、不解释
 *   - 保持原语言与说话人语气
 *   - 输出必须是纯文本，不能有引号包裹或前缀
 *
 * 任何失败（超时、网络、非 200、空结果、结果异常膨胀）都退回规则层结果。
 */

const DEFAULT_TIMEOUT_MS = 4500;

const SYSTEM_PROMPT = [
  '你是语音听写的后处理器。用户给你一段语音识别出的原始文本（没有标点、可能有同音字错误和口头禅），你输出清理后的文本。',
  '规则：',
  '1. 删除纯语气成分：嗯、呃、那个、就是说、然后（作口头禅时）、uh、um 等，以及无意义的重复。',
  '2. 修正语音识别的同音字错误、错别字、明显的用词错误。',
  '3. 补全并规范标点与断句，使文本像认真打出来的一样。',
  '4. 保留全部信息与说话人的语气：不要删掉有实义的指示词（"那个会议室"这类限定关系要保留），不要合并、不要扩写、不要总结。',
  '5. 保持原语言（中文说中文，中英混说保持混说），不要翻译。',
  '6. 不要回答文本中的问题，不要续写，不要解释，不要加引号、标题或任何前缀。',
  '7. 文本里若有口头自我修正（"不对，我是说……"），只保留修正后的内容。',
  '只输出处理后的文本本身。',
].join('\n');

/**
 * 调用 OpenAI 兼容的 /chat/completions。
 * @param {object} options
 * @param {string} options.baseURL - 形如 http://127.0.0.1:8788/v1
 * @param {string} options.apiKey
 * @param {string} options.model
 * @param {string} options.text - 待清理文本
 * @param {string} [options.vocabularyText] - 追加到 system prompt 的用户词表段落
 * @param {number} [options.timeoutMs]
 * @param {(usage: object) => void} [options.onUsage] - 回调 token 用量，便于统计成本
 * @returns {Promise<string>} 清理后的文本；调用方负责捕获异常
 */
export async function polish({ baseURL, apiKey, model, text, vocabularyText = '', timeoutMs = DEFAULT_TIMEOUT_MS, onUsage }) {
  if (!baseURL || !model) throw new Error('llm: baseURL 与 model 必填');
  const url = `${baseURL.replace(/\/+$/u, '')}/chat/completions`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(apiKey ? { authorization: `Bearer ${apiKey}` } : {}),
      },
      body: JSON.stringify({
        model,
        temperature: 0,
        stream: false,
        // DeepSeek-V4 系列默认开启思考模式且 effort=high；清理文本是格式化任务，
        // 不需要推理链：关掉后输出从数百 token 降到几十，延迟从 ~1.5s 降到 ~0.5s。
        thinking: { type: 'disabled' },
        messages: [
          { role: 'system', content: SYSTEM_PROMPT + vocabularyText },
          { role: 'user', content: text },
        ],
      }),
      signal: controller.signal,
    });
    if (!response.ok) {
      const detail = await response.text().catch(() => '');
      throw new Error(`llm: HTTP ${response.status} ${detail.slice(0, 200)}`);
    }
    const payload = await response.json();
    if (onUsage && payload?.usage) onUsage(payload.usage);
    const content = payload?.choices?.[0]?.message?.content;
    if (typeof content !== 'string' || !content.trim()) throw new Error('llm: 空结果');
    return content.trim();
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 结果合理性检查：模型发散时宁可不用。
 * 清理应当让文本变短或基本等长；超过 2.2 倍且增量 > 40 字视为发散。
 * @param {string} raw
 * @param {string} polished
 * @returns {boolean}
 */
export function isPlausible(raw, polished) {
  if (!polished.trim()) return false;
  // 极短输入（"好"、"OK"）不允许模型扩写成句子——这是幻觉回复的典型形态
  const rawMeaningful = raw.replace(/[\s\p{P}\p{S}]/gu, '');
  const polishedMeaningful = polished.replace(/[\s\p{P}\p{S}]/gu, '');
  if (rawMeaningful.length < 4 && polishedMeaningful.length > rawMeaningful.length + 2) return false;
  if (polished.length > raw.length * 2.2 && polished.length - raw.length > 40) return false;
  // 模型把原文当问题回答了：出现明显的自述式开头
  if (/^(好的|当然|以下是|这是清理后的|已为您|你发的|您发的|请提供|Sure|Here)/u.test(polished)) return false;
  return true;
}
