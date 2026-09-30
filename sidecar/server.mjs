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
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { clean, trimEndPunctuation } from './cleanup.mjs';
import { polish, isPlausible } from './llm.mjs';
import { loadTerms, renderVocabularyPrompt, stripFabricatedTerms } from './dictionary.mjs';

const require = createRequire(import.meta.url);

const MODEL_ROOT = process.env.VOICE_GLOBAL_MODEL_ROOT
  || join(homedir(), '.voice-global', 'models');
const MODEL = process.env.VOICE_GLOBAL_MODEL || join(MODEL_ROOT, 'sensevoice-onnx', 'model.int8.onnx');
const TOKENS = process.env.VOICE_GLOBAL_TOKENS || join(MODEL_ROOT, 'sensevoice-onnx', 'tokens.txt');
const VAD = process.env.VOICE_GLOBAL_VAD || join(MODEL_ROOT, 'silero', 'silero_vad.onnx');
const THREADS = Number(process.env.VOICE_GLOBAL_THREADS || 2);
/** 末尾不留标点。听写多是「半句话」，自动补上的句号反而要手动删。设 0 可关掉。 */
const TRIM_END_PUNCT = (process.env.VOICE_GLOBAL_TRIM_END_PUNCT ?? '1') !== '0';

/**
 * 用户词表：`~/.voice-global/dictionary.json`。
 * 每次请求按 mtime 判断要不要重读，所以用户（或学习模块）改完立刻生效，
 * 不需要重启 sidecar。读不到就是空表，功能降级但不影响听写。
 */
const DICTIONARY_PATH = process.env.VOICE_GLOBAL_DICTIONARY
  || join(homedir(), '.voice-global', 'dictionary.json');
let termsCache = { mtimeMs: -1, terms: [], prompt: '' };

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

/** 加载模型；失败时抛错，由宿主决定如何提示。 */
function loadModels() {
  const sherpa = require('sherpa-onnx-node');
  const nativeConfig = {
    featConfig: { sampleRate: 16000, featureDim: 80 },
    modelConfig: {
      senseVoice: { model: MODEL, language: 'auto', useInverseTextNormalization: 1 },
      tokens: TOKENS,
      numThreads: THREADS,
      provider: 'cpu',
      debug: 0,
    },
  };
  const started = performance.now();
  recognizer = new sherpa.OfflineRecognizer(nativeConfig);
  detector = new sherpa.Vad({
    sileroVad: {
      model: VAD,
      threshold: 0.5,
      minSilenceDuration: 0.5,
      minSpeechDuration: 0.25,
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
 * 用 VAD 分段后逐段解码；VAD 未切出任何语音时回退整段解码。
 * @param {Float32Array} samples
 * @param {string} language
 * @returns {string}
 */
function transcribeSamples(samples, language) {
  nativeConfigRef.modelConfig.senseVoice.language = language || 'auto';
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
async function handle({ wavPath, language = 'auto', cleanup = 'rules' }) {
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
    // 规则层始终跑一遍：既是 llm 失败时的兜底，也用于对比诊断
    const t1 = performance.now();
    const ruled = clean(raw, { spaceCJK: false });
    rulesText = ruled.text;
    timings.cleanup = Math.round(performance.now() - t1);
    text = ruled.text;
    hits = ruled.hits;

    if (cleanup === 'llm' && LLM.baseURL && LLM.model && meaningful.length >= 4) {
      const t2 = performance.now();
      const vocabulary = currentVocabulary();
      try {
        // 直接把原始转写交给模型：规则层删改过的文本会丢掉上下文
        // （比如把"呃那个我们"里的"呃"留下、却让模型看不到原句结构）
        const refined = await polish({
          baseURL: LLM.baseURL,
          apiKey: LLM.apiKey,
          model: LLM.model,
          text: raw,
          vocabularyText: vocabulary.prompt,
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
          const guarded = stripFabricatedTerms(raw, text, vocabulary.terms);
          if (guarded.removed.length) {
            log(`撤销凭空插入的词表词：${guarded.removed.join('、')}`);
            // 重建文本会丢标点，跑一次规则层补回来
            text = clean(guarded.text, { spaceCJK: false }).text;
            hits = [...hits, ...guarded.removed.map((term) => `fabricated:${term}`)];
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
  emit({ event: 'ready', model: MODEL, loadMs, llm: Boolean(LLM.baseURL && LLM.model), threads: THREADS });

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

if (argv.includes('--once')) {
  // 单次模式：node server.mjs --once /path/a.wav [--cleanup rules|llm|off] [--language zh]
  const wavPath = argValue('--once');
  if (!wavPath) {
    emit({ ok: false, error: '--once 需要 WAV 路径' });
    process.exit(1);
  }
  const cleanup = argValue('--cleanup') ?? 'rules';
  const language = argValue('--language') ?? 'auto';
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
