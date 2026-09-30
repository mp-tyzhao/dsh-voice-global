/**
 * 模型档案
 * ========
 *
 * 把"用哪个语音模型"从代码里挪到配置里。
 *
 * 为什么值得单独抽一层：不同模型在不同场景下差别很大 ——
 * 中文闲聊、中英混杂、专业术语、方言，各自的最优选择不一样；
 * 而 sherpa-onnx 每类模型的配置字段完全不同（senseVoice / whisper /
 * transducer / paraformer 各有一套），散在加载代码里改起来容易出错。
 *
 * ## 向后兼容是硬要求
 *
 * 没有 profile.json 时，行为必须和以前**完全一样** ——
 * 用户已经装好的环境不能因为这次改动出问题。所以档案是可选的，
 * 缺失时回退到默认的 SenseVoice 配置。
 *
 * ## 关于热词
 *
 * sherpa-onnx 里只有 transducer 系模型支持热词（且必须用
 * modified_beam_search 解码）；SenseVoice 这类非自回归模型**没有**
 * 预识别偏置手段。所以 supportsHotwords 是档案的一部分 ——
 * 将来换成 transducer 时，词表可以真正作用到解码阶段，
 * 而不是像现在这样只在后处理里补救。
 */

import fs from 'node:fs';
import { join, isAbsolute } from 'node:path';

/** 支持热词的模型类型（对应 sherpa-onnx 的能力边界）。 */
const HOTWORD_CAPABLE = new Set(['transducer', 'zipformer', 'zipformer2']);

/**
 * 默认档案：和接入档案机制之前的行为逐字一致。
 * 改动这里等于改变所有既有用户的行为，务必谨慎。
 */
export const DEFAULT_PROFILE = {
  id: 'sensevoice-small-int8',
  label: 'SenseVoice-Small int8（中英日韩粤）',
  type: 'senseVoice',
  languages: ['zh', 'en', 'ja', 'ko', 'yue'],
  supportsHotwords: false,
  model: 'model.int8.onnx',
  tokens: 'tokens.txt',
  decoding: { method: 'greedy_search' },
  // 注意：这里**不能**放 senseVoice / whisper 这类类型专属字段。
  // loadProfile 用 { ...DEFAULT_PROFILE, ...parsed } 合并，放进来就会泄漏到
  // 每一个档案上 —— Whisper 档案因此拿到了 senseVoice.language='auto'，
  // 而 Whisper 不认 auto，直接报 Invalid language。
  // 类型专属的默认值放在 buildModelConfig 里，那里才是按类型分派的地方。
};

/**
 * 读模型档案。找不到就用默认档案 —— 不报错。
 *
 * @param {string} modelRoot 模型目录
 * @param {(msg: string) => void} [log]
 * @returns {object} 档案
 */
export function loadProfile(modelRoot, log = () => {}) {
  if (!modelRoot) return { ...DEFAULT_PROFILE };
  const file = `${modelRoot}/profile.json`;
  try {
    const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
    const profile = { ...DEFAULT_PROFILE, ...parsed };
    if (!profile.type) profile.type = DEFAULT_PROFILE.type;
    log(`模型档案：${profile.label ?? profile.id}（${profile.type}）`);
    return profile;
  } catch {
    return { ...DEFAULT_PROFILE };
  }
}

/**
 * 按档案构造 sherpa-onnx 的 modelConfig。
 *
 * 每类模型的字段名都不一样，这里集中处理，加载代码不用管分支。
 *
 * @param {object} profile
 * @param {{model: string, tokens: string, threads: number}} paths
 * @returns {object} 可直接塞进 nativeConfig.modelConfig
 */
export function buildModelConfig(profile, paths) {
  // 档案里的文件名写成相对的（可移植），这里解析成绝对路径 ——
  // sherpa-onnx 的原生层不认相对路径，会直接报 "does not exist"。
  const dir = paths.dir ?? (paths.model ? join(paths.model, '..') : '.');
  const resolve = (p) => {
    if (!p) return p;
    return isAbsolute(p) ? p : join(dir, p);
  };
  const base = {
    tokens: paths.tokens,
    numThreads: paths.threads,
    provider: 'cpu',
    debug: 0,
  };
  const decoding = { ...(profile.decoding ?? { method: 'greedy_search' }) };

  switch (profile.type) {
    case 'senseVoice':
      return {
        ...base,
        senseVoice: {
          model: resolve(paths.model),
          language: profile.senseVoice?.language ?? 'auto',
          useInverseTextNormalization: profile.senseVoice?.useInverseTextNormalization ?? 1,
        },
      };

    case 'whisper':
      return {
        ...base,
        whisper: {
          encoder: resolve(profile.whisper?.encoder ?? paths.model),
          decoder: resolve(profile.whisper?.decoder ?? ''),
          language: profile.whisper?.language ?? 'auto',
          task: profile.whisper?.task ?? 'transcribe',
        },
      };

    case 'paraformer':
      return { ...base, paraformer: { model: resolve(paths.model) } };

    case 'transducer':
    case 'zipformer':
    case 'zipformer2':
      return {
        ...base,
        transducer: {
          encoder: resolve(profile.transducer?.encoder ?? paths.model),
          decoder: resolve(profile.transducer?.decoder ?? ''),
          joiner: resolve(profile.transducer?.joiner ?? ''),
        },
        // transducer 只有配 modified_beam_search 才吃热词表
        ...(profile.hotwords ? { hotwordsFile: resolve(profile.hotwords) } : {}),
      };

    case 'nemoCtc':
      return { ...base, nemoCtc: { model: resolve(paths.model) } };

    case 'wenetCtc':
      return { ...base, wenetCtc: { model: resolve(paths.model) } };

    default:
      // 不认识的类型不要静默降级 —— 那会让人以为换了模型其实没换
      throw new Error(`未知的模型类型：${profile.type}（档案 ${profile.id}）`);
  }
}

/** 解码方法：部分模型支持改，部分只能贪心。 */
export function decodingMethod(profile) {
  const method = profile.decoding?.method ?? 'greedy_search';
  if (profile.hotwords && HOTWORD_CAPABLE.has(profile.type) && method === 'greedy_search') {
    // 配了热词却用贪心，等于热词不生效 —— 这类"配了没效果"最难查，直接纠正
    return 'modified_beam_search';
  }
  return method;
}

/** 这个档案能不能吃热词（决定词表要不要走解码期偏置）。 */
export function supportsHotwords(profile) {
  return HOTWORD_CAPABLE.has(profile.type);
}

/** 列出所有可发现的档案（扫描模型根目录下的子目录）。 */
export function discoverProfiles(modelRoots, fsModule = fs) {
  const found = [];
  for (const root of modelRoots.filter(Boolean)) {
    let entries = [];
    try {
      entries = fsModule.readdirSync(root, { withFileTypes: true });
    } catch { continue; }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const dir = `${root}/${entry.name}`;
      try {
        const parsed = JSON.parse(fsModule.readFileSync(`${dir}/profile.json`, 'utf8'));
        found.push({ ...DEFAULT_PROFILE, ...parsed, dir });
      } catch {
        // 没有档案的目录：只要能找到模型文件，也算一个可用的默认档案
        try {
          const files = fsModule.readdirSync(dir);
          const model = files.find((f) => f.endsWith('.onnx'));
          const tokens = files.find((f) => f === 'tokens.txt');
          if (model && tokens) {
            found.push({ ...DEFAULT_PROFILE, id: entry.name, label: entry.name, dir, model, tokens });
          }
        } catch { /* 读不了就跳过 */ }
      }
    }
  }
  return found;
}
