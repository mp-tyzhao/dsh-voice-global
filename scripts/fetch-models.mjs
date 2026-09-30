#!/usr/bin/env node
/**
 * 下载本地识别模型
 * ================
 *
 * 需要的三个文件（SenseVoice 多语言识别 + Silero VAD 断句），
 * 全部带固定 revision 与 SHA-256 校验，下载完必须逐字节对得上才会使用。
 *
 * 顺序：自带目录已有 → 复用本机 DSH 已下载的语音包（原地复用，不复制、不占额外空间）
 *       → 都没有才从 HuggingFace / HF-Mirror 下载（带 SHA-256 校验）。
 *
 * 用法：
 *   node scripts/fetch-models.mjs              # 智能选择：复用或下载
 *   node scripts/fetch-models.mjs --check      # 只检查（自带目录或 DSH 缓存任一可用即通过）
 *   node scripts/fetch-models.mjs --copy       # 把 DSH 缓存复制进自带目录（独立于 DSH）
 *   node scripts/fetch-models.mjs --download   # 强制下载
 *   node scripts/fetch-models.mjs --out /path  # 指定目录
 *   node scripts/fetch-models.mjs --fp32       # 用 fp32 权重（937MB，更准更慢）
 */
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

const REVISION = '2365baeacb507f821a0c8120fcee3d484dba7a07';
const HF = 'https://huggingface.co';
const HF_MIRROR = 'https://hf-mirror.com';
const SENSEVOICE_REPO = 'csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17';
const VAD_REVISION = 'fba88cd2e921609e7675c3aaf51e0b9b295da4bc';

/** 每个文件的固定哈希；换了模型必须同步这里。 */
const ASSETS = {
  model: {
    fp32: {
      url: `${HF}/${SENSEVOICE_REPO}/resolve/${REVISION}/model.onnx`,
      bytes: 937617178,
      sha256: '977016bd9c79f9eb343430b5cc305e07ab64d5212dff41b0dcfa1694bee9a8cb',
    },
    int8: {
      url: `${HF}/${SENSEVOICE_REPO}/resolve/${REVISION}/model.int8.onnx`,
      bytes: 239233841,
      sha256: 'c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51',
    },
  },
  tokens: {
    url: `${HF}/${SENSEVOICE_REPO}/resolve/${REVISION}/tokens.txt`,
    bytes: 315894,
    sha256: 'f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc',
  },
  vad: {
    url: `${HF}/csukuangfj/vad/resolve/${VAD_REVISION}/silero_vad.onnx`,
    bytes: 1807522,
    sha256: 'a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28',
  },
};

/** DSH（DeepSeek Harness）已经下载过的模型缓存位置。 */
const DSH_CACHE = path.join(homedir(), '.dsh', 'speech-to-text', 'sensevoice', 'models');

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const value = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : fallback;
};

const outRoot = value('--out', path.join(homedir(), '.voice-global', 'models'));
const precision = flag('--fp32') ? 'fp32' : 'int8';

/** 目标文件布局与 sidecar/server.mjs 的默认约定一致。 */
const TARGETS = [
  { key: 'model', label: `SenseVoice 权重（${precision}）`, dest: path.join(outRoot, 'sensevoice-onnx', precision === 'fp32' ? 'model.onnx' : 'model.int8.onnx') },
  { key: 'tokens', label: '词表 tokens.txt', dest: path.join(outRoot, 'sensevoice-onnx', 'tokens.txt') },
  { key: 'vad', label: 'Silero VAD', dest: path.join(outRoot, 'silero', 'silero_vad.onnx') },
];

/** 校验一个文件的大小与 SHA-256。 */
async function verify(file, spec) {
  const stat = fs.statSync(file);
  if (stat.size !== spec.bytes) return false;
  const hash = createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest('hex') === spec.sha256;
}

/** 带进度地把 URL 下载到临时文件，再原子重命名。 */
async function download(url, dest, expectedBytes) {
  const response = await fetch(url, { redirect: 'follow' });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const temp = `${dest}.part`;
  const out = fs.createWriteStream(temp);
  let received = 0;
  let lastReport = 0;

  for await (const chunk of response.body) {
    received += chunk.length;
    if (!out.write(chunk)) await new Promise((resolve) => out.once('drain', resolve));
    const now = Date.now();
    if (now - lastReport > 1000) {
      lastReport = now;
      const percent = ((received / expectedBytes) * 100).toFixed(1);
      process.stdout.write(`\r    ${percent}% (${(received / 1048576).toFixed(0)}MB / ${(expectedBytes / 1048576).toFixed(0)}MB)`);
    }
  }
  await new Promise((resolve, reject) => out.end((error) => (error ? reject(error) : resolve())));
  process.stdout.write('\r');
  fs.renameSync(temp, dest);
}

/**
 * 复用本机已有模型：先看自带目录，再看 DSH 缓存。
 * @returns {boolean} 是否已经齐备
 */
async function checkExisting(verbose = true) {
  let allPresent = true;
  for (const target of TARGETS) {
    const spec = target.key === 'model' ? ASSETS.model[precision] : ASSETS[target.key];
    if (fs.existsSync(target.dest) && (await verify(target.dest, spec))) {
      if (verbose) console.log(`  ✓ ${target.label}`);
    } else {
      allPresent = false;
      if (verbose) console.log(`  ✗ ${target.label}`);
    }
  }
  return allPresent;
}

/** DSH 缓存是否完整可用（原地复用，不复制）。 */
async function dshCacheReady() {
  const files = [
    path.join(DSH_CACHE, 'sensevoice-onnx/model.int8.onnx'),
    path.join(DSH_CACHE, 'sensevoice-onnx/tokens.txt'),
    path.join(DSH_CACHE, 'silero/silero_vad.onnx'),
  ];
  for (const file of files) {
    if (!fs.existsSync(file)) return false;
  }
  return (await verify(files[0], ASSETS.model.int8))
    && (await verify(files[1], ASSETS.tokens))
    && (await verify(files[2], ASSETS.vad));
}

/** 把 DSH 缓存里的三个文件复制到自带目录（DSH 缓存仍然保留原样）。 */
async function reuseFromDSH() {
  const mapping = [
    ['sensevoice-onnx/model.int8.onnx', TARGETS[0].dest],
    ['sensevoice-onnx/tokens.txt', TARGETS[1].dest],
    ['silero/silero_vad.onnx', TARGETS[2].dest],
  ];
  for (const [from, to] of mapping) {
    const source = path.join(DSH_CACHE, from);
    if (!fs.existsSync(source)) return false;
  }
  for (const [from, to] of mapping) {
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.copyFileSync(path.join(DSH_CACHE, from), to);
  }
  return true;
}

console.log('检查本地模型…');
const ownReady = await checkExisting(false) && !flag('--download');
if (ownReady) {
  console.log(`  ✓ 自带目录已有完整模型：${outRoot}`);
  console.log(`\n✅ 模型已就绪：${outRoot}`);
  process.exit(0);
}

// 自带目录没有，就看本机有没有现成语音包——DSH 下过一次就不该再下一次
if (!flag('--download') && precision === 'int8' && await dshCacheReady()) {
  if (flag('--check')) {
    console.log(`\n✅ 可复用本机已有的语音包：${DSH_CACHE}`);
    process.exit(0);
  }
  if (flag('--copy')) {
    console.log(`\n发现本机 DSH 语音包，复制到自带目录：`);
    console.log(`  ${DSH_CACHE}`);
    if (await reuseFromDSH() && await checkExisting()) {
      console.log(`\n✅ 模型已就绪：${outRoot}`);
      process.exit(0);
    }
    console.log('复制后校验不通过，改为自行下载。');
  } else {
    console.log(`\n✅ 复用本机已有的语音包，不复制、不下载（省 228MB）：`);
    console.log(`   ${DSH_CACHE}`);
    console.log('   想让它独立于 DSH：node scripts/fetch-models.mjs --copy');
    process.exit(0);
  }
}

if (flag('--check')) {
  console.log('\n✗ 没有找到可用模型。运行 node scripts/fetch-models.mjs 下载。');
  process.exit(1);
}

const sources = [HF, HF_MIRROR];
const totalBytes = ASSETS.model[precision].bytes + ASSETS.tokens.bytes + ASSETS.vad.bytes;
console.log(`\n开始下载（约 ${(totalBytes / 1048576).toFixed(0)}MB）`);

for (const target of TARGETS) {
  const spec = target.key === 'model' ? ASSETS.model[precision] : ASSETS[target.key];
  if (fs.existsSync(target.dest) && (await verify(target.dest, spec))) {
    console.log(`  ✓ ${target.label}（已有，跳过）`);
    continue;
  }
  let done = false;
  for (const base of sources) {
    const url = spec.url.replace(HF, base);
    try {
      console.log(`  ↓ ${target.label}  ← ${new URL(base).host}`);
      await download(url, target.dest, spec.bytes);
      if (!(await verify(target.dest, spec))) throw new Error('SHA-256 校验失败');
      console.log(`  ✓ ${target.label}`);
      done = true;
      break;
    } catch (error) {
      console.log(`    失败：${error.message}`);
      fs.rmSync(`${target.dest}.part`, { force: true });
    }
  }
  if (!done) {
    console.error(`\n❌ ${target.label} 下载失败。可手动下载后放到：${target.dest}`);
    console.error(`   URL: ${spec.url}`);
    process.exit(1);
  }
}

console.log(`\n✅ 模型已就绪：${outRoot}`);
if (dshAvailable) console.log('（也可以直接复用 DSH 缓存：node scripts/fetch-models.mjs --from-dsh）');
