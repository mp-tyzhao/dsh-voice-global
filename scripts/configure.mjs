#!/usr/bin/env node
/**
 * 写入/合并配置
 * =============
 *
 * 只改指定的字段，其余保持原样；密钥单独写进 .env（0600），不落进可分享的 config.json。
 *
 * 用法：
 *   node scripts/configure.mjs --cleanup llm --model deepseek-flash --api-key sk-xxx
 *   node scripts/configure.mjs --api-key "" --cleanup rules     # 退回纯离线
 *   node scripts/configure.mjs --print                          # 打印当前生效配置
 */
import fs from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';

const HOME = path.join(homedir(), '.voice-global');
const CONFIG = path.join(HOME, 'config.json');
const ENV_FILE = path.join(HOME, '.env');

const args = process.argv.slice(2);
const value = (name) => {
  const index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : undefined;
};
const has = (name) => args.includes(name);

/** 默认配置：与 Sources/Config.swift 的默认值保持一致。 */
const DEFAULTS = {
  language: 'auto',
  cleanup: 'rules',
  tapMaxSeconds: 0.45,
  nodePath: '',
  modelRoot: '',
  modelPath: '',
  tokensPath: '',
  vadPath: '',
  threads: 2,
  restoreClipboard: true,
  pasteDelayMs: 90,
  restoreDelayMs: 650,
  showHUD: true,
  playSounds: true,
  idleUnloadSeconds: 300,
  // 开发模式（特别版）：指向仓库根，改完 sidecar/*.mjs 不用重新打包
  devSidecarRoot: '',
  devAutoReload: true,
  // 录音留存（特别版）：音频只留本机
  keepRecordings: false,
  recordingsMaxCount: 500,
  recordingsMaxMB: 500,
  recordingsMaxDays: 30,
  llm: {
    enabled: false,
    baseURL: '',
    apiKey: '',
    apiKeyEnv: 'DEEPSEEK_API_KEY',
    apiKeyCommand: '',
    model: '',
    timeoutMs: 8000,
  },
};

fs.mkdirSync(HOME, { recursive: true });

let config = { ...DEFAULTS, llm: { ...DEFAULTS.llm } };
if (fs.existsSync(CONFIG)) {
  try {
    const existing = JSON.parse(fs.readFileSync(CONFIG, 'utf8'));
    config = { ...config, ...existing, llm: { ...config.llm, ...(existing.llm ?? {}) } };
  } catch {
    console.warn('现有 config.json 无法解析，将重写一份默认配置。');
  }
}

if (has('--print')) {
  const shown = { ...config, llm: { ...config.llm } };
  if (shown.llm.apiKey) shown.llm.apiKey = '***';
  console.log(JSON.stringify(shown, null, 2));
  console.log(`\n密钥文件：${fs.existsSync(ENV_FILE) ? ENV_FILE + '（存在）' : '不存在'}`);
  process.exit(0);
}

const setIf = (flag, apply) => {
  if (has(flag)) apply();
};

setIf('--cleanup', () => { config.cleanup = value('--cleanup'); });
setIf('--language', () => { config.language = value('--language'); });
setIf('--model-root', () => { config.modelRoot = value('--model-root'); });
setIf('--threads', () => { config.threads = Number(value('--threads')); });
setIf('--idle-unload', () => { config.idleUnloadSeconds = Number(value('--idle-unload')); });
setIf('--base-url', () => { config.llm.baseURL = value('--base-url'); });
setIf('--model', () => { config.llm.model = value('--model'); });
setIf('--api-key-env', () => { config.llm.apiKeyEnv = value('--api-key-env'); });
setIf('--api-key-command', () => { config.llm.apiKeyCommand = value('--api-key-command'); });

// 开发模式：把 sidecar 指向仓库，改完 .mjs 立刻生效
setIf('--dev-root', () => { config.devSidecarRoot = value('--dev-root') ?? ''; });
setIf('--dev-autoreload', () => { config.devAutoReload = value('--dev-autoreload') !== 'false'; });

// 录音留存：默认关；--keep-recordings false 也能关掉
if (has('--keep-recordings')) {
  config.keepRecordings = (value('--keep-recordings') ?? 'true') !== 'false';
}
setIf('--recordings-max-count', () => { config.recordingsMaxCount = Number(value('--recordings-max-count')); });
setIf('--recordings-max-mb', () => { config.recordingsMaxMB = Number(value('--recordings-max-mb')); });
setIf('--recordings-max-days', () => { config.recordingsMaxDays = Number(value('--recordings-max-days')); });

// 密钥走 .env，不进 config.json；传 --api-key "" 表示清掉
if (has('--api-key')) {
  const key = value('--api-key');
  const name = config.llm.apiKeyEnv || 'DEEPSEEK_API_KEY';
  let envText = fs.existsSync(ENV_FILE) ? fs.readFileSync(ENV_FILE, 'utf8') : '';
  envText = envText
    .split('\n')
    .filter((line) => line.trim() && !new RegExp(`^(export\\s+)?${name}=`).test(line.trim()))
    .join('\n');
  if (key) {
    envText = `${envText ? envText.trimEnd() + '\n' : ''}${name}=${key}\n`;
    fs.writeFileSync(ENV_FILE, envText, { mode: 0o600 });
    console.log(`✓ 密钥已写入 ${ENV_FILE}（权限 600，不进 git）`);
  } else {
    fs.writeFileSync(ENV_FILE, envText ? envText.trimEnd() + '\n' : '', { mode: 0o600 });
    console.log('✓ 已清除 .env 中的密钥');
  }
  try { fs.chmodSync(ENV_FILE, 0o600); } catch { /* 忽略 */ }
  config.llm.apiKey = '';
}

if (config.cleanup === 'llm') config.llm.enabled = true;
if (!config.llm.baseURL && config.llm.enabled) config.llm.baseURL = 'https://api.deepseek.com/v1';
if (!config.llm.model && config.llm.enabled) config.llm.model = 'deepseek-flash';

fs.writeFileSync(CONFIG, JSON.stringify(config, null, 2) + '\n', { mode: 0o600 });
console.log(`✓ 配置已写入 ${CONFIG}`);
console.log(`  清理模式 ${config.cleanup}｜润色模型 ${config.llm.enabled ? config.llm.model : '未启用'}`);
