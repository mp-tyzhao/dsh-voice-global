#!/usr/bin/env node
/**
 * DSH Voice Global —— 转写 sidecar
 * ================================
 *
 * 常驻进程：启动时一次性加载 SenseVoice-small ONNX + Silero VAD（复用 DSH 已下载的模型），
 * 之后每段录音只需几十到几百毫秒。
 *
 * 协议（stdin/stdout，逐行 JSON）：
 *   就绪     {"event":"ready","model":"...","llm":false}
 *   请求     {"id":1,"wav":"/tmp/a.wav","language":"auto","cleanup":"rules"}
 *   成功     {"id":1,"ok":true,"raw":"...","text":"...","hits":[],"ms":{"asr":110,"cleanup":1}}
 *   失败     {"id":1,"ok":false,"error":"..."}
 *
 * 清理模式 cleanup：off | rules | llm
 *   rules —— 纯规则（离线、瞬时）
 *   llm   —— 规则打底 + 模型润色（失败自动退回 rules）
 *
 * 环境变量：
 *   VOICE_GLOBAL_MODEL_ROOT                              模型根目录（默认 ~/.voice-global/models）
 *   VOICE_GLOBAL_MODEL / VOICE_GLOBAL_TOKENS / VOICE_GLOBAL_VAD   单文件路径覆盖
 *   VOICE_GLOBAL_THREADS                                 推理线程数（默认 2）
 *   VOICE_GLOBAL_LLM_BASE / VOICE_GLOBAL_LLM_KEY / VOICE_GLOBAL_LLM_MODEL   LLM 润色端点
 *   VOICE_GLOBAL_LLM_TIMEOUT_MS
 */
import { readFileSync, statSync } from 'node:fs';
import { createRequire } from 'node:module';
import { homedir } from 'node:os';
import { join, dirname } from 'node:path';
import { existsSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { clean, trimEndPunctuation } from './cleanup.mjs';
import { polish, isPlausible } from './llm.mjs';
import { loadTerms, renderVocabularyPrompt, stripFabricatedTerms } from './dictionary.mjs';
import { applyTerms, selectRelevantTerms } from './phonetic.mjs';
import { loadProfile, buildModelConfig, decodingMethod, supportsHotwords, discoverProfiles } from './profiles.mjs';

const require = createRequire(import.meta.url);

const MODEL_ROOT = process.env.VOICE_GLOBAL_MODEL_ROOT
  || join(homedir(), '.voice-global', 'models');
// 模型目录先定下来，档案和权重文件都相对它解析。
// 原先这里硬编码了 sensevoice-onnx 子目录，等于换模型必须改代码。
const MODEL_DIR = process.env.VOICE_GLOBAL_MODEL_DIR || join(MODEL_ROOT, 'sensevoice-onnx');
const PROFILE = loadProfile(MODEL_DIR);
const MODEL = process.env.VOICE_GLOBAL_MODEL || join(MODEL_DIR, PROFILE.model || 'model.int8.onnx');
const TOKENS = process.env.VOICE_GLOBAL_TOKENS || join(MODEL_DIR, PROFILE.tokens || 'tokens.txt');
// VAD 与语音模型是两回事：换模型不该把 VAD 一起换掉。
// 所以它不跟着 MODEL_DIR 走，而是按几个常见位置依次找。
const VAD = process.env.VOICE_GLOBAL_VAD || (() => {
  const candidates = [
    join(MODEL_ROOT, 'silero', 'silero_vad.onnx'),
    join(MODEL_DIR, 'silero_vad.onnx'),
    join(MODEL_DIR, '..', 'silero', 'silero_vad.onnx'),
    join(homedir(), '.voice-global', 'models', 'silero', 'silero_vad.onnx'),
    join(homedir(), '.dsh', 'speech-to-text', 'sensevoice', 'models', 'silero', 'silero_vad.onnx'),
  ];
  return candidates.find((candidate) => existsSync(candidate)) || candidates[0];
})();
const THREADS = Number(process.env.VOICE_GLOBAL_THREADS || 2);
/** 末尾不留标点。听写多是「半句话」，自动补上的句号反而要手动删。设 0 可关掉。 */
const TRIM_END_PUNCT = (process.env.VOICE_GLOBAL_TRIM_END_PUNCT ?? '1') !== '0';
/**
 * 默认识别语言。
 * SenseVoice 认 'auto'，Whisper 不认（会报 Invalid language）——
 * 它的自动检测要传空字符串。所以默认值必须来自档案，不能写死。
 */
const DEFAULT_LANGUAGE = PROFILE.senseVoice?.language ?? PROFILE.whisper?.language ?? 'auto';

/**
 * 用户词表：`~/.voice-global/dictionary.json`。
 * 每次请求按 mtime 判断要不要重读，所以用户（或学习模块）改完立刻生效，
 * 不需要重启 sidecar。读不到就是空表，功能降级但不影响听写。
 */
const DICTIONARY_PATH = process.env.VOICE_GLOBAL_DICTIONARY
  || join(homedir(), '.voice-global', 'dictionary.json');
let termsCache = { mtimeMs: -1, terms: [], prompt: '' };

/** 词表小的时候全量注入，大了才按句检索。 */
const FULL_INJECT_LIMIT = Number(process.env.VOICE_GLOBAL_FULL_INJECT ?? 50);

/**
 * 给这一句挑要注入提示的词。
 *
 * 为什么不一律按句检索：检索靠"原文里有发音痕迹"，而 `tys → Typeless`
 * 这类大跨度错误恰恰**没有痕迹**（前缀只重合两个字母，相似度也低）。
 * 一律检索会把这一类词漏掉，而它们正是最需要 LLM 补的。
 *
 * 所以小词表全量注入（召回优先，反正没几个 token）；词表长大后
 * （> FULL_INJECT_LIMIT）才检索 —— 那时全量的代价开始显现：
 * prompt 变长，而且模型更容易从长列表里挑一个词凭空插进去。
 *
 * @param {string} raw ASR 原文
 * @param {{terms: string[], prompt: string}} vocabulary
 * @returns {string} 注入提示的词表文本
 */
function promptFor(raw, vocabulary) {
  if (!vocabulary.terms.length) return '';
  if (vocabulary.terms.length <= FULL_INJECT_LIMIT) return vocabulary.prompt;

  const picked = selectRelevantTerms(raw, vocabulary.terms);
  if (!picked.length) return '';
  log(`词表检索：${vocabulary.terms.length} 条里选中 ${picked.length} 条`);
  return renderVocabularyPrompt(picked.map((entry) => entry.term));
}


function currentVocabulary() {
  try {
    const stat = statSync(DICTIONARY_PATH);
    if (stat.mtimeMs !== termsCache.mtimeMs) {
      const terms = loadTerms(DICTIONARY_PATH);
      termsCache = { mtimeMs: stat.mtimeMs, terms, prompt: renderVocabularyPrompt(terms) };
      if (terms.length) log(`词表已加载：${terms.length} 条`);
    }
  } catch {
    if (termsCache.mtimeMs !== -1) termsCache = { mtimeMs: -1, terms: [], prompt: '' };
  }
  return termsCache;
}

const LLM = {
  baseURL: process.env.VOICE_GLOBAL_LLM_BASE || '',
  apiKey: process.env.VOICE_GLOBAL_LLM_KEY || '',
  model: process.env.VOICE_GLOBAL_LLM_MODEL || '',
  timeoutMs: Number(process.env.VOICE_GLOBAL_LLM_TIMEOUT_MS || 4500),
};

/** 写一行 JSON 到 stdout（协议通道，日志一律走 stderr）。 */
function emit(payload) {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}

/** 诊断日志走 stderr，由宿主进程转发到日志文件。 */
function log(...args) {
  process.stderr.write(`[sidecar] ${args.join(' ')}\n`);
}

let recognizer;
let detector;
/** 当前生效的模型档案，ready 事件里报给宿主 */
let ACTIVE_PROFILE = null;

/** 加载模型；失败时抛错，由宿主决定如何提示。 */
function loadModels() {
  const sherpa = require('sherpa-onnx-node');
  // 模型档案可选：没有 profile.json 时回退到默认配置，行为与接入前逐字一致
  // 档案就放在模型文件旁边（不是 MODEL_ROOT）—— MODEL_ROOT 下面可能
  // 有多个模型目录，档案是每个模型一份
  const profile = loadProfile(dirname(MODEL), log);
  ACTIVE_PROFILE = profile;
  if (supportsHotwords(profile)) log(`该模型支持解码期热词：${profile.id}`);
  const nativeConfig = {
    featConfig: { sampleRate: 16000, featureDim: 80 },
    decodingMethod: decodingMethod(profile),
    modelConfig: buildModelConfig(profile, { model: MODEL, tokens: TOKENS, threads: THREADS, dir: MODEL_DIR }),
  };
  const started = performance.now();
  recognizer = new sherpa.OfflineRecognizer(nativeConfig);
  detector = new sherpa.Vad({
    sileroVad: {
      model: VAD,
      threshold: 0.5,
      // 0.5 → 1.0：一句话被从中间切开，尾部会被单独解码。
      // 实测（用户录音 16:19:44，"…SenseVoice 对吧"）：
      //   minSilence=0.5 → 尾部「对吧」前有 0.78s 停顿，被切成第二段；
      //                    单独解码时模型把这一小段猜成了日文「でば」，
      //                    而主段也受损（「所，现在」）。
      //   minSilence=1.0 → 合成一段、覆盖到 4.86s，完整识别出
      //                    「…sense voice，对吧？」。
      // 听写本来就是短句，停顿合并比切分更有利：上下文更完整，
      // 短片段猜错语言的问题也一并消失。上限仍由 maxSpeechDuration=30s 兜着。
      minSilenceDuration: 1.0,
      // 0.25 → 0.1：轻声的短句会被整段漏掉。
      // 实测（用户录音 16:19:44）：说"…SenseVoice 对吧"，尾部「对吧」
      // 只有 -29dB 左右，minSpeech=0.25 时 VAD 完全没检出 —— 段数 1、
      // 只覆盖到 3.34s / 4.88s，识别结果里就没有「对吧」。
      // 同一段音频绕过 VAD 整段解码能正确识别出「对吧」，说明模型听得见，
      // 是分段把它切掉的。降到 0.1 后段数变 2、覆盖到 4.86s，「对吧」回来了。
      minSpeechDuration: 0.1,
      maxSpeechDuration: 30,
      windowSize: 512,
    },
    sampleRate: 16000,
    numThreads: THREADS,
    provider: 'cpu',
    debug: 0,
  }, 31);
  // nativeConfig 在每次解码前会被 setConfig 复用，必须留引用
  sherpaRef = sherpa;
  nativeConfigRef = nativeConfig;
  return { sherpa, nativeConfig, loadMs: Math.round(performance.now() - started) };
}

let sherpaRef = null;
let nativeConfigRef = null;

/**
 * 读取 16 kHz 单声道 PCM16 WAV，返回 Float32 采样。
 * @param {string} path
 * @returns {Float32Array}
 */
function readWav(path) {
  const wav = readFileSync(path);
  if (wav.byteLength < 46) throw new Error('音频过短或不是 WAV');
  if (wav.toString('ascii', 0, 4) !== 'RIFF' || wav.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error('音频不是 RIFF/WAVE 格式');
  }
  const channels = wav.readUInt16LE(22);
  const rate = wav.readUInt32LE(24);
  const bits = wav.readUInt16LE(34);
  if (channels !== 1 || rate !== 16000 || bits !== 16) {
    throw new Error(`音频必须为 16kHz 单声道 PCM16（收到 ${rate}Hz/${channels}ch/${bits}bit）`);
  }
  const offset = 44;
  const pcm = new DataView(wav.buffer, wav.byteOffset + offset, wav.byteLength - offset);
  return Float32Array.from({ length: pcm.byteLength / 2 }, (_, i) => pcm.getInt16(i * 2, true) / 32768);
}

/**
 * 自适应音量
 * ==========
 *
 * 不同电脑、不同麦克风、不同环境、不同说话音量，录进来的电平能差 30dB 以上。
 * 目标是让**送进语音模型的电平大体一致**，而不是越大越好。
 *
 * 做法：
 *   1. 分帧（20ms）算每帧 RMS
 *   2. 取分位数：噪声底 = 10%，语音电平 = 90%
 *      —— 用分位数而不是峰值：峰值会被一声咳嗽、一个爆破音带偏
 *   3. **正常区间内不动**。实测把正常音量的录音统一抬到 -20dB 反而变差
 *      （16.6% → 19.1%，超过测量噪声）：那点电平本来模型就认得，
 *      抬上去只会把底噪一起放大。所以只救**真的偏轻或偏响**的录音。
 *   4. 超出区间就向最近的边缘靠，提升上限按信噪比放开（干净的多提，嘈杂的少提）
 *
 * 死区是 ±6dB（-26dB 中心）：覆盖"正常说话"的常见范围，
 * 又能在换麦克风、离得远、环境吵的时候把电平拉回来。
 */
const GAIN_CENTER_DB = -26;   // 正常工作电平
const GAIN_DEAD_ZONE_DB = 6;  // 这个范围内认为电平已经合适
const GAIN_MAX_CUT_DB = 20;
const GAIN_FRAME = 320;      // 20ms @16kHz

function percentile(sorted, ratio) {
  if (!sorted.length) return 0;
  const index = Math.min(sorted.length - 1, Math.max(0, Math.round((sorted.length - 1) * ratio)));
  return sorted[index];
}

function normalizeGain(samples, verbose = true) {
  // 消融用：设 VOICE_GLOBAL_NO_GAIN=1 可关掉，方便量出它到底贡献了多少
  if (process.env.VOICE_GLOBAL_NO_GAIN === '1') return { samples, gain: 1 };

  // 1. 分帧 RMS（dBFS）
  const frames = [];
  for (let offset = 0; offset + GAIN_FRAME <= samples.length; offset += GAIN_FRAME) {
    let energy = 0;
    for (let i = offset; i < offset + GAIN_FRAME; i += 1) energy += samples[i] * samples[i];
    const rms = Math.sqrt(energy / GAIN_FRAME);
    if (rms > 1e-7) frames.push(20 * Math.log10(rms));
  }
  if (!frames.length) return { samples, gain: 1 };

  frames.sort((a, b) => a - b);
  const noiseDb = percentile(frames, 0.1);
  const speechDb = percentile(frames, 0.9);
  const snrDb = speechDb - noiseDb;

  // 2. 整段几乎无声：放大只会出幻觉
  if (speechDb < -55) return { samples, gain: 1 };

  // 3. 落在正常区间就不动 —— 实测把正常音量统一抬到某个目标反而变差，
  //    那点电平模型本来就认得，抬上去只是把底噪一起放大。
  const lower = GAIN_CENTER_DB - GAIN_DEAD_ZONE_DB;   // -32dB：比这更轻才算"偏轻"
  const upper = GAIN_CENTER_DB + GAIN_DEAD_ZONE_DB;   // -20dB：比这更响才算"偏响"
  if (speechDb >= lower && speechDb <= upper) return { samples, gain: 1, speechDb, noiseDb, snrDb };

  // 4. 超出区间：朝最近的边缘靠，不是一律拉到一个点
  const targetDb = speechDb < lower ? GAIN_CENTER_DB : upper;
  let gainDb = targetDb - speechDb;
  // 提升上限按信噪比放开：录音干净（只是轻）就敢多提；底噪大的少提，别把噪声喂给模型
  const ceilingDb = snrDb >= 25 ? 33 : snrDb >= 15 ? 24 : snrDb >= 6 ? 12 : 6;
  gainDb = Math.max(-GAIN_MAX_CUT_DB, Math.min(ceilingDb, gainDb));
  if (Math.abs(gainDb) < 1) return { samples, gain: 1, speechDb, noiseDb, snrDb };

  const gain = Math.pow(10, gainDb / 20);
  const out = new Float32Array(samples.length);
  for (let i = 0; i < samples.length; i += 1) {
    out[i] = Math.max(-1, Math.min(1, samples[i] * gain));
  }
  if (verbose) {
    log(`音量自适应：语音 ${speechDb.toFixed(0)}dB / 噪声 ${noiseDb.toFixed(0)}dB` +
        `（信噪比 ${snrDb.toFixed(0)}dB）→ 增益 ${gainDb >= 0 ? '+' : ''}${gainDb.toFixed(1)}dB`);
  }
  return { samples: out, gain };
}

/**
 * 用 VAD 分段后逐段解码；VAD 未切出任何语音时回退整段解码。
 * @param {Float32Array} samples
 * @param {string} language
 * @returns {string}
 */
function transcribeSamples(input, language) {
  const { samples, gain } = normalizeGain(input);
  if (gain > 1.2) log(`音频较轻，已增益 ${(20 * Math.log10(gain)).toFixed(1)}dB`);

  // 语言字段在不同模型里位置不同（senseVoice / whisper 各一套），
  // 不能假设一定是 senseVoice —— 换模型时会直接抛 "Cannot set properties of undefined"。
  const modelConfig = nativeConfigRef?.modelConfig ?? {};
  const wanted = language || DEFAULT_LANGUAGE;
  if (modelConfig.senseVoice) modelConfig.senseVoice.language = wanted;
  else if (modelConfig.whisper) modelConfig.whisper.language = wanted;
  recognizer.setConfig(nativeConfigRef);
  detector.reset();

  const texts = [];
  const decodeSegment = (segment) => {
    const stream = recognizer.createStream();
    stream.acceptWaveform({ sampleRate: 16000, samples: segment.samples });
    recognizer.decode(stream);
    const text = recognizer.getResult(stream).text.trim();
    if (text) texts.push(text);
  };
  const drain = () => {
    while (!detector.isEmpty()) {
      decodeSegment(detector.front(false));
      detector.pop();
    }
  };

  for (let offset = 0; offset < samples.length; offset += 512) {
    detector.acceptWaveform(samples.subarray(offset, offset + 512));
    drain();
  }
  detector.flush();
  drain();

  if (texts.length > 0) return texts.join('');

  // 回退：VAD 没认为有语音（短促、轻声、或整段低于阈值），直接整段解码
  const stream = recognizer.createStream();
  stream.acceptWaveform({ sampleRate: 16000, samples });
  recognizer.decode(stream);
  return recognizer.getResult(stream).text.trim();
}

/**
 * 完整流水线：WAV → 原始文本 → 清理文本。
 * @param {string} wavPath
 * @param {{language?: string, cleanup?: string}} options
 */
async function handle({ wavPath, language = DEFAULT_LANGUAGE, cleanup = 'rules' }) {
  const timings = {};
  const t0 = performance.now();
  const samples = readWav(wavPath);
  const raw = transcribeSamples(samples, language);
  timings.asr = Math.round(performance.now() - t0);

  let text = raw;
  let hits = [];
  let rulesText = raw;
  let polishError;
  let usageStats;

  // 识别结果只有标点或空白（静音、气声、误触）时直接判空：
  // 这种输入绝不能喂给模型——模型会把它当成"用户问了一句话"然后开始回答。
  // 另外，长录音只出 1 个字基本都是噪声幻觉（"我."），一并丢掉。
  const meaningful = raw.replace(/[\s\p{P}\p{S}]/gu, '');
  const seconds = samples.length / 16000;
  if (cleanup !== 'off' && (meaningful.length === 0 || (meaningful.length <= 1 && seconds >= 1.5))) {
    return {
      raw,
      text: '',
      rulesText: '',
      hits: ['empty-transcript'],
      timings,
      seconds,
    };
  }

  if (cleanup !== 'off' && raw) {
    const vocabulary = currentVocabulary();

    // 拼音层最先跑：本地、确定性、零成本，把同音字改对（`奇迹创谈`→`奇绩创坛`）。
    // 不放在 LLM 分支里 —— 它是本地纠正，rules 模式同样该生效；也不该因为
    // 没配 LLM 就失效。
    let base = raw;
    let phoneticHits = [];
    if (vocabulary.terms.length) {
      const fixed = applyTerms(raw, vocabulary.terms);
      if (fixed.applied.length) {
        log(`拼音层纠正：${fixed.applied.map((a) => `${a.from}→${a.to}`).join('、')}`);
        base = fixed.text;
        phoneticHits = fixed.applied.map((a) => `phonetic:${a.to}`);
      }
    }

    // 规则层始终跑一遍：既是 llm 失败时的兜底，也用于对比诊断
    const t1 = performance.now();
    const ruled = clean(base, { spaceCJK: false });
    rulesText = ruled.text;
    timings.cleanup = Math.round(performance.now() - t1);
    text = ruled.text;
    hits = ruled.hits;
    if (base !== raw) hits = [...hits, ...phoneticHits];

    if (cleanup === 'llm' && LLM.baseURL && LLM.model && meaningful.length >= 4) {
      const t2 = performance.now();
      try {
        // 直接把（拼音层纠正过的）原始转写交给模型：规则层删改过的文本会丢掉上下文
        // （比如把"呃那个我们"里的"呃"留下、却让模型看不到原句结构）
        const refined = await polish({
          baseURL: LLM.baseURL,
          apiKey: LLM.apiKey,
          model: LLM.model,
          text: base,
          vocabularyText: promptFor(base, vocabulary),
          timeoutMs: LLM.timeoutMs,
          onUsage: (usage) => {
            // 记到日志里，方便随时核算成本
            log(
              `tokens 输入=${usage.prompt_tokens ?? '?'}` +
              `（缓存命中 ${usage.prompt_cache_hit_tokens ?? 0}）` +
              ` 输出=${usage.completion_tokens ?? '?'}`,
            );
            usageStats = usage;
          },
        });
        timings.llm = Math.round(performance.now() - t2);
        if (isPlausible(raw, refined)) {
          text = refined;
          hits = [...hits, 'llm'];

          // 确定性校验：词表能把 mve 还原成 Milvus，但模型有时会从词表里
          // 挑一个词凭空插进去（实测，且 prompt 里明文禁止也拦不住）。
          // 这里按"这一段原文有没有被换掉的东西"判定，把编造的词撤掉。
          // 消融开关：守卫到底是在防编造还是在误删正确补全，靠 A/B 量出来
          const guarded = process.env.VOICE_GLOBAL_NO_FABRICATION_GUARD === '1'
            ? { text, removed: [] }
            : stripFabricatedTerms(raw, text, vocabulary.terms);
          if (guarded.removed.length) {
            log(`撤销凭空插入的词表词：${guarded.removed.join('、')}`);
            // 重建文本会丢标点，跑一次规则层补回来
            text = clean(guarded.text, { spaceCJK: false }).text;
            hits = [...hits, ...guarded.removed.map((term) => `fabricated:${term}`)];
          }

          // 最后再兜一次拼音层：模型可能把已经改对的词又写回去了
          if (vocabulary.terms.length) {
            const afterLLM = applyTerms(text, vocabulary.terms);
            if (afterLLM.applied.length) {
              log(`拼音层兜底：${afterLLM.applied.map((a) => `${a.from}→${a.to}`).join('、')}`);
              text = afterLLM.text;
            }
          }
        } else {
          polishError = 'llm 结果偏离原文，已退回规则清理';
        }
      } catch (error) {
        timings.llm = Math.round(performance.now() - t2);
        polishError = String(error?.message ?? error);
      }
    }
  }

  // 末尾标点统一在这里剥：不管走规则层还是 LLM 层、也不管 LLM 是不是自己补了句号，
  // 都要在最后过一道，否则 LLM 补的句号会漏网。
  if (TRIM_END_PUNCT) {
    const trimmed = trimEndPunctuation(text);
    if (trimmed !== text) {
      text = trimmed;
      if (rulesText) rulesText = trimEndPunctuation(rulesText);
    }
  }

  return { raw, text, rulesText, hits, timings, seconds, ...(usageStats ? { usage: usageStats } : {}), ...(polishError ? { polishError } : {}) };
}

/** 常驻模式：逐行读取请求。 */
async function serve() {
  const { loadMs } = loadModels();
  emit({
    event: 'ready', model: MODEL, loadMs, threads: THREADS,
    profile: ACTIVE_PROFILE
      ? { id: ACTIVE_PROFILE.id, label: ACTIVE_PROFILE.label, type: ACTIVE_PROFILE.type }
      : null,
    llm: Boolean(LLM.baseURL && LLM.model),
  });

  let buffer = '';
  process.stdin.setEncoding('utf8');
  let queue = Promise.resolve();

  process.stdin.on('data', (chunk) => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, index).trim();
      buffer = buffer.slice(index + 1);
      if (!line) continue;
      let request;
      try {
        request = JSON.parse(line);
      } catch {
        log('忽略无法解析的请求行');
        continue;
      }
      // 串行执行：native 推理不是线程安全的
      queue = queue.then(async () => {
        try {
          const result = await handle({ wavPath: request.wav, language: request.language, cleanup: request.cleanup });
          emit({ id: request.id, ok: true, ...result });
        } catch (error) {
          emit({ id: request.id, ok: false, error: String(error?.message ?? error) });
        }
      });
    }
  });
  process.stdin.on('end', () => process.exit(0));
}

const argv = process.argv.slice(2);

/** 取出 --name value 形式的参数；未提供时返回 undefined。 */
function argValue(name) {
  const index = argv.indexOf(name);
  return index >= 0 && index + 1 < argv.length ? argv[index + 1] : undefined;
}

// 列出可用的模型档案。换模型时先跑这个看有哪些可选。
if (argv.includes('--list-profiles')) {
  // 扫两处：配置的模型根目录，以及 ~/.voice-global/models。
  // 只看前者的话，用户自己下到默认目录的模型不会出现在菜单里 ——
  // 那这个"可切换"就是假的。
  const roots = [...new Set([
    MODEL_ROOT,
    join(homedir(), '.voice-global', 'models'),
    MODEL_DIR,
  ].filter(Boolean))];
  const found = discoverProfiles(roots);
  const active = PROFILE;
  process.stdout.write(`${JSON.stringify({
    active: { id: active.id, label: active.label, type: active.type, model: MODEL },
    available: found.map((p) => ({
      id: p.id, label: p.label, type: p.type, dir: p.dir,
      supportsHotwords: supportsHotwords(p),
      active: p.dir === dirname(MODEL),
    })),
  }, null, 2)}\n`);
  process.exit(0);
}

if (argv.includes('--once')) {
  // 单次模式：node server.mjs --once /path/a.wav [--cleanup rules|llm|off] [--language zh]
  const wavPath = argValue('--once');
  if (!wavPath) {
    emit({ ok: false, error: '--once 需要 WAV 路径' });
    process.exit(1);
  }
  const cleanup = argValue('--cleanup') ?? 'rules';
  const language = argValue('--language') ?? DEFAULT_LANGUAGE;
  loadModels();
  handle({ wavPath, language, cleanup })
    .then((result) => emit({ ok: true, ...result }))
    .catch((error) => {
      emit({ ok: false, error: String(error?.message ?? error) });
      process.exitCode = 1;
    });
} else {
  serve().catch((error) => {
    emit({ event: 'fatal', error: String(error?.message ?? error) });
    process.exit(1);
  });
}
