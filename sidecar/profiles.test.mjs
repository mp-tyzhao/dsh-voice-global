/**
 * 模型档案的单元测试
 * 跑法：node sidecar/profiles.test.mjs
 *
 * 这一层最容易出的事是**静默降级** —— 用户换了模型，配置没生效，
 * 但程序照跑不误，于是以为"换了模型没区别"。所以用例重点在
 * "配错了要报错，而不是悄悄用默认值"。
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  DEFAULT_PROFILE, loadProfile, buildModelConfig, decodingMethod,
  supportsHotwords, discoverProfiles,
} from './profiles.mjs';

let failures = 0;
function check(label, ok, detail) {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}`);
  if (!ok && detail) console.log(`      ${detail}`);
  if (!ok) failures += 1;
}

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'vg-profile-'));
const paths = { model: '/m/model.onnx', tokens: '/m/tokens.txt', threads: 4 };

console.log('— 向后兼容（最重要）—');
{
  // 没有 profile.json 时必须和以前完全一样，否则老用户会受影响
  const profile = loadProfile(path.join(dir, '不存在的目录'));
  check('缺档案时回退到默认', profile.type === 'senseVoice' && profile.id === DEFAULT_PROFILE.id,
    JSON.stringify(profile));

  const config = buildModelConfig(profile, paths);
  check('默认配置就是原来那套 senseVoice 字段',
    config.senseVoice?.model === paths.model
    && config.senseVoice?.language === 'auto'
    && config.senseVoice?.useInverseTextNormalization === 1
    && config.tokens === paths.tokens
    && config.numThreads === 4
    && config.provider === 'cpu',
    JSON.stringify(config));
}

console.log('\n— 读档案 —');
{
  const root = path.join(dir, 'with-profile');
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(path.join(root, 'profile.json'), JSON.stringify({
    id: 'test-model', label: '测试模型', type: 'whisper',
    whisper: { encoder: 'enc.onnx', decoder: 'dec.onnx', language: 'zh' },
  }));
  const profile = loadProfile(root);
  check('读到自定义档案', profile.id === 'test-model' && profile.type === 'whisper', JSON.stringify(profile));

  const config = buildModelConfig(profile, paths);
  // 档案里写的是相对文件名，构造配置时要解析成绝对路径
  // （sherpa-onnx 原生层不认相对路径，会直接报 "does not exist"）
  check('whisper 配置字段正确（相对路径已解析）',
    config.whisper?.encoder.endsWith('/enc.onnx') && config.whisper?.decoder.endsWith('/dec.onnx'),
    JSON.stringify(config));
}
{
  // 坏档案不能把程序带崩，但也不能假装什么都没发生
  const root = path.join(dir, 'broken');
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(path.join(root, 'profile.json'), '{ 这不是 JSON');
  const profile = loadProfile(root);
  check('坏档案回退到默认而不是崩溃', profile.type === 'senseVoice');
}

console.log('\n— 默认档案不能泄漏类型专属字段（真 bug）—');
{
  // 曾经的写法：DEFAULT_PROFILE 里带 senseVoice: { language: 'auto' }，
  // loadProfile 用 {...DEFAULT_PROFILE, ...parsed} 合并，于是每个档案都拿到了
  // senseVoice.language='auto'。Whisper 不认 auto，直接报 Invalid language。
  check('默认档案不含 senseVoice 字段', DEFAULT_PROFILE.senseVoice === undefined,
    JSON.stringify(DEFAULT_PROFILE.senseVoice));

  const root = path.join(dir, 'leak-check');
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(path.join(root, 'profile.json'), JSON.stringify({
    id: 'w', type: 'whisper', whisper: { encoder: 'e.onnx', decoder: 'd.onnx', language: 'zh' },
  }));
  const profile = loadProfile(root);
  check('Whisper 档案里没有混进 senseVoice', profile.senseVoice === undefined,
    JSON.stringify(profile.senseVoice));
}

console.log('\n— 相对路径要解析成绝对路径 —');
{
  // sherpa-onnx 原生层不认相对路径，会直接报 "does not exist"
  const root = path.join(dir, 'relpath');
  fs.mkdirSync(root, { recursive: true });
  fs.writeFileSync(path.join(root, 'profile.json'), JSON.stringify({
    id: 'w2', type: 'whisper', whisper: { encoder: 'enc.onnx', decoder: 'dec.onnx' },
  }));
  const profile = loadProfile(root);
  const config = buildModelConfig(profile, { model: 'model.onnx', tokens: 'tok.txt', threads: 2, dir: root });
  check('whisper.encoder 是绝对路径', config.whisper.encoder.startsWith('/'), config.whisper.encoder);
  check('whisper.decoder 是绝对路径', config.whisper.decoder.startsWith('/'), config.whisper.decoder);
  check('绝对路径原样保留', buildModelConfig(
    { type: 'paraformer' }, { model: '/abs/model.onnx', tokens: 't', threads: 1, dir: root },
  ).paraformer.model === '/abs/model.onnx');
}

console.log('\n— 不认识就报错，不静默降级 —');
{
  let threw = false;
  try {
    buildModelConfig({ id: 'x', type: '我编的类型' }, paths);
  } catch (error) {
    threw = /未知的模型类型/.test(error.message);
  }
  check('未知类型抛错（避免"换了模型其实没换"）', threw);
}

console.log('\n— 热词能力边界 —');
{
  check('SenseVoice 不支持热词（事实如此，不是缺陷）', !supportsHotwords(DEFAULT_PROFILE));
  check('transducer 支持热词', supportsHotwords({ type: 'transducer' }));
  check('zipformer2 支持热词', supportsHotwords({ type: 'zipformer2' }));
  check('whisper 不支持', !supportsHotwords({ type: 'whisper' }));
}
{
  // 配了热词却用贪心解码 = 热词不生效，这类"配了没效果"最难查
  const withHotwords = { type: 'transducer', hotwords: '/h.txt', decoding: { method: 'greedy_search' } };
  check('配了热词会自动改用 modified_beam_search',
    decodingMethod(withHotwords) === 'modified_beam_search', decodingMethod(withHotwords));

  const withoutHotwords = { type: 'transducer', decoding: { method: 'greedy_search' } };
  check('没配热词就保持贪心', decodingMethod(withoutHotwords) === 'greedy_search');

  const senseVoice = { ...DEFAULT_PROFILE, hotwords: '/h.txt' };
  check('SenseVoice 配了热词也不会假装支持',
    decodingMethod(senseVoice) === 'greedy_search', decodingMethod(senseVoice));
}

console.log('\n— 发现可用档案 —');
{
  const root = path.join(dir, 'models');
  // 带档案的目录
  fs.mkdirSync(path.join(root, 'a'), { recursive: true });
  fs.writeFileSync(path.join(root, 'a', 'profile.json'), JSON.stringify({ id: 'a', type: 'paraformer' }));
  // 不带档案但有模型文件的目录（老用户的目录结构就是这样）
  fs.mkdirSync(path.join(root, 'b'), { recursive: true });
  fs.writeFileSync(path.join(root, 'b', 'model.int8.onnx'), 'x');
  fs.writeFileSync(path.join(root, 'b', 'tokens.txt'), 'x');
  // 什么都没有的目录
  fs.mkdirSync(path.join(root, 'c'), { recursive: true });

  const found = discoverProfiles([root]);
  const ids = found.map((f) => f.id).sort();
  check('能发现带档案的目录', ids.includes('a'), JSON.stringify(ids));
  check('也能发现没有档案但有模型文件的老目录', ids.includes('b'), JSON.stringify(ids));
  check('空目录不算档案', !ids.includes('c'), JSON.stringify(ids));
  check('不存在的根目录不崩', discoverProfiles(['/根本不存在']).length === 0);
}

fs.rmSync(dir, { recursive: true, force: true });
console.log();
if (failures === 0) {
  console.log('ALL PASS');
  process.exit(0);
}
console.log(`${failures} 项失败`);
process.exit(1);
