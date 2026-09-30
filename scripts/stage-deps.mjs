#!/usr/bin/env node
/**
 * 物化 DSH 内置的语音依赖
 * ========================
 *
 * DSH 桌面版把 sherpa-onnx 的 JS 包放在 app.asar 里、原生库放在 app.asar.unpacked 里。
 * 普通 Node 进程读不了 asar，所以这里把两半都取出来，放进 sidecar/node_modules，
 * 让 sidecar 可以脱离 Electron 独立运行。
 *
 * 用法：
 *   node scripts/stage-deps.mjs [--app "/Applications/DeepSeek Harness.app"] [--target sidecar/node_modules]
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, '..');

const args = process.argv.slice(2);
const argValue = (name, fallback) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : fallback;
};

const appPath = argValue('--app', '/Applications/DeepSeek Harness.app');
const targetDir = path.resolve(projectRoot, argValue('--target', 'sidecar/node_modules'));
const asarPath = path.join(appPath, 'Contents/Resources/app.asar');
const unpackedDir = path.join(appPath, 'Contents/Resources/app.asar.unpacked');

for (const required of [asarPath, unpackedDir]) {
  if (!fs.existsSync(required)) {
    console.error(`找不到 ${required}`);
    console.error('请用 --app 指定 DSH.app 的位置。');
    process.exit(1);
  }
}

/** 解析 asar 头部，返回 { entries, dataOffset }。 */
function readAsarIndex(archive) {
  const fd = fs.openSync(archive, 'r');
  try {
    const head = Buffer.alloc(16);
    fs.readSync(fd, head, 0, 16, 0);
    const headerPickleSize = head.readUInt32LE(4);
    const header = Buffer.alloc(headerPickleSize);
    fs.readSync(fd, header, 0, headerPickleSize, 8);
    const jsonSize = header.readUInt32LE(4);
    const json = JSON.parse(header.subarray(8, 8 + jsonSize).toString('utf8'));
    return { fd, tree: json, dataOffset: 8 + headerPickleSize };
  } catch (error) {
    fs.closeSync(fd);
    throw error;
  }
}

/** 递归收集匹配前缀的文件条目。 */
function collect(node, prefix, matcher, out) {
  for (const [name, value] of Object.entries(node.files ?? {})) {
    const entryPath = prefix ? `${prefix}/${name}` : name;
    if (value.files) {
      collect(value, entryPath, matcher, out);
      continue;
    }
    if (value.link || value.offset === undefined) continue;
    if (matcher.test(entryPath)) out.push({ path: entryPath, size: Number(value.size), offset: Number(value.offset) });
  }
  return out;
}

const packages = ['sherpa-onnx-node'];
let extracted = 0;

const { fd, tree, dataOffset } = readAsarIndex(asarPath);
try {
  for (const pkg of packages) {
    const matcher = new RegExp(`^dsh/node_modules/${pkg}/`);
    const entries = collect(tree, '', matcher, []);
    if (entries.length === 0) {
      console.error(`${asarPath} 里找不到 dsh/node_modules/${pkg}`);
      process.exitCode = 1;
      continue;
    }
    for (const entry of entries) {
      const relative = entry.path.replace(/^dsh\/node_modules\//u, '');
      const destination = path.join(targetDir, relative);
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      const buffer = Buffer.alloc(entry.size);
      if (entry.size > 0) fs.readSync(fd, buffer, 0, entry.size, dataOffset + entry.offset);
      fs.writeFileSync(destination, buffer);
      extracted++;
    }
    console.log(`✓ ${pkg}: ${entries.length} 个文件`);
  }
} finally {
  fs.closeSync(fd);
}

// 原生库：直接从 unpacked 目录拷贝（里面是 .node / .dylib，asar 无法直接加载）
const nativeSource = path.join(unpackedDir, 'dsh/node_modules');
for (const entry of fs.readdirSync(nativeSource)) {
  if (!entry.startsWith('sherpa-onnx-')) continue;
  const from = path.join(nativeSource, entry);
  const to = path.join(targetDir, entry);
  fs.rmSync(to, { recursive: true, force: true });
  fs.cpSync(from, to, { recursive: true });
  console.log(`✓ ${entry}: 原生库已拷贝`);
}

console.log(`\n完成：${extracted} 个文件 → ${path.relative(projectRoot, targetDir)}`);
