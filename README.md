# Voice Global

[中文](README.md) | [English](README.en.md)

**在 macOS 上按一下 Fn 说话，文字自动落到任意应用的光标处。** 本地识别 + 云端润色，说人话、出书面语。

```
单击 Fn ──▶ 录音 ──▶ 本机转写（SenseVoice）──▶ 清理/润色 ──▶ 自动粘贴到当前应用
```

- **本地识别**：SenseVoice 多语言模型跑在你的 CPU 上，音频永远不出机器
- **说人话出书面语**：删语气词、处理"不对我是说"这类口头修正、补标点、修同音字
- **任意应用可用**：微信、飞书、浏览器、IDE、终端，不挑输入框
- **成本≈0**：本机识别免费；云端润色实测约 **¥0.0006 / 次**

---

## 🚀 最省事的安装方式：让你的 Agent 帮你装

把下面这段话**整段复制**，发给你自己的编码 Agent（Codex / Claude Code / Cursor / 任何能执行命令的助手）：

```text
请帮我在这台 macOS 上安装并配置好 Voice Global（一个按 Fn 说话、自动转写并粘贴到当前应用的全局听写工具）。

仓库地址：https://github.com/mp-tyzhao/dsh-voice-global
请先 clone 这个仓库，然后**完整阅读仓库里的 docs/agent-setup.md**，严格按那份文档一步一步执行：
环境检查 → 一键安装（./scripts/setup.sh）→ 带我完成系统授权 → 逐项验证 → 告诉我怎么用。

几个你必须遵守的点：
1. 系统授权（麦克风 / 辅助功能 / 输入监控）必须由我本人去「系统设置」里勾选，你不能代我点，
   请把确切路径告诉我，并在授权后用 "$APP" --check 和 "$APP" --listen 15 验证。
2. 我会自己提供 DeepSeek API Key（如果需要）。在我给你之前不要猜、不要编、不要写进任何文件；
   拿到后只写进 ~/.voice-global/.env，不要在终端回显、不要提交到 git。
3. 云端润色是可选项：如果我不想让文字出本机，就用 ./scripts/setup.sh --no-llm 走纯离线模式。
4. 每一步都要先验证再继续，失败时先读 ~/.voice-global/log.txt，不要盲目重试。
```

---

## 手动安装

```bash
git clone https://github.com/mp-tyzhao/dsh-voice-global.git
cd dsh-voice-global
./scripts/setup.sh --api-key sk-xxxxxxxx     # 有 DeepSeek 密钥：开启云端润色
# 或者
./scripts/setup.sh --no-llm                   # 纯离线，不联网
```

安装脚本的策略是**先找现成的，再决定要不要从头搭**：

| 步骤 | 逻辑 |
| --- | --- |
| 识别运行库 | 项目里已有 → `npm install`（官方源不通自动回退 npmmirror）→ 从本机已装的 DeepSeek Harness 里提取原生库 |
| 识别模型 | 自带目录已有 → **原地复用本机 DSH 已下载的语音包（省 228MB 下载）** → 都没有才下载；下载前**并发探测 HuggingFace 与 HF-Mirror，谁先响应用谁**，全程 SHA-256 校验 |
| 润色模型 | 用 `--api-key` 或 `DEEPSEEK_API_KEY` 环境变量；没有就退回纯离线并告诉你怎么申请 |

装完启动：

```bash
open "build/DSH Voice.app"
```

首次要过三关（App 会自己弹窗引导）：

1. **麦克风**：系统设置 → 隐私与安全性 → 麦克风 → 勾选 `DSH Voice`
2. **辅助功能**：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 `DSH Voice`（没有它无法自动粘贴）
3. **输入监控**：系统设置 → 隐私与安全性 → 输入监控 → 勾选 `DSH Voice`（按 Fn 没反应时再来开）

**关键一步**：系统设置 → 键盘 → 「按下 🌐 键时」→ **不执行任何操作**（否则每次按 Fn 还会弹表情面板）。

授权后**不用重启 App**：它每 2 秒检测一次，检测到就自动生效。

## 怎么用

| 操作 | 效果 |
| --- | --- |
| 单击 `Fn` | 开始聆听（屏幕底部出现电平条） |
| 再单击 `Fn` | 结束、转写、清理，然后自动粘贴 |
| `Esc` | 放弃这次录音 |
| 按住 `Fn` + 其他键 | 仍是系统功能（Fn+←=Home 等），不会被误判为单击 |

菜单栏麦克风图标里可以：切换清理模式、打开配置、看日志、权限自检、退出。

## 效果

清理层做的事（左原始、右结果）：

```
呃那个我们下周三下午三点开个评审会你记得把上回那个原型图带上另外就是如果时间来得及我们顺便把预算过一下
  ↓
我们下周三下午3点开个评审会，你记得把上回那个圆形图带上。另外，如果时间来得及，我们顺便把预算过一下。
```

```
我觉得这个方案可以不对，我是说这个方案可行。呃，那个我们下周再讨论细节。
  ↓
这个方案可行。我们下周再讨论细节。
```

| 能力 | 说明 |
| --- | --- |
| 删语气词/口头禅 | 嗯、呃、那个、就是说、uh、um……"这个项目"里的"这个"不会被误伤 |
| 口头自我修正 | "……不对，我是说……" 只保留修正后的内容 |
| 结巴重复 | "我我我" → "我"、"就是就是" → "就是"（保护汉语的"看看/想想"） |
| 标点与断句 | 补逗号句号、规范标点、中文数字格式化（"三点" → "3点"） |
| 同音字纠错 | 需要云端润色；模型只能改"明显不合理"的词，缺少上下文时（如 原型图/圆形图）也会出错 |
| 空输入保护 | 静音或噪声导致的空转写直接丢弃，绝不粘出奇怪内容 |

## 架构

```
Voice Global.app                  Swift 菜单栏常驻，无 Dock 图标（LSUIElement）
├── HotkeyTap    CGEventTap 监听 Fn（listen-only，不吞事件，不破坏 Fn 组合键）
├── Recorder     AVAudioEngine → 16kHz 单声道 PCM16 WAV
├── HUD          不抢焦点的悬浮状态条（抢焦点会把 ⌘V 粘到自己身上）
├── Injector     剪贴板 + 合成 ⌘V，粘贴后恢复原剪贴板
└── Sidecar      spawn 一个 Node 常驻进程
    └── server.mjs  SenseVoice-small ONNX + Silero VAD（本地 CPU 推理）
        ├── cleanup.mjs  规则清理（22 项单测，可独立运行）
        └── llm.mjs      可选云端润色（OpenAI 兼容端点）
```

几个刻意的设计：

- **常驻 sidecar**：模型只在启动时加载一次（0.4 秒），之后每句话只花推理时间——实测 11 秒语音 190ms。
- **空闲卸载**：5 分钟没动静就释放识别进程（常驻约 900MB），下次录音时先预热，你说话的时间够它加载完。
- **本地签名证书**：`scripts/setup-signing.sh` 生成固定证书，重新构建不会掉系统授权（ad-hoc 签名每次都掉）。
- **不抢焦点**：HUD 用 nonactivating 面板，否则粘贴会粘到自己身上。

## 模型与成本

| 环节 | 模型 | 位置 |
| --- | --- | --- |
| 语音识别 | SenseVoice-Small int8（228MB）+ Silero VAD，经 sherpa-onnx | 本机 CPU，零成本 |
| 规则清理 | 自研规则引擎 | 本机，零延迟 |
| 润色 | `deepseek-flash`（DeepSeek-V4.1-Flash），已关闭思考模式 | DeepSeek API |

实测（打包后的真实流水线）：

```
本地识别 190ms  +  云端润色 559ms   ≈  说完后 0.75 秒出字
输入 251–297 tokens（含固定系统提示 ~230，可命中缓存）  输出 8–35 tokens
```

按官方定价（USD / 1M tokens，`deepseek-flash`）：

| | 非高峰 | 高峰 |
| --- | --- | --- |
| 输入·缓存命中 | $0.003 | $0.006 |
| 输入·未命中 | $0.15 | $0.30 |
| 输出 | $0.60 | $1.20 |

→ **单次约 ¥0.0006，每千次约 ¥0.6**；每天 100 次 ≈ ¥1.8/月。

> 高峰时段是 UTC 01:00–04:00 与 06:00–10:00 的工作日（北京时间 09:00–12:00、14:00–18:00），
> 正好覆盖国内工作时段，所以上表按高峰价算更实在。
> 复现脚本见 [`bench/cost.mjs`](bench/cost.mjs)。

**隐私边界**：音频永远只在本机；只有 `cleanup=llm` 时，**转写出的文字**才会发到你配置的端点。
想完全离线就把 `cleanup` 设成 `rules`，成本归零。

## 配置

配置文件 `~/.voice-global/config.json`（数据目录首次运行自动创建），密钥单独放 `~/.voice-global/.env`（600 权限）。

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `cleanup` | `rules` | `off` 只转写 / `rules` 规则清理 / `llm` 规则+云端润色 |
| `language` | `auto` | `auto` / `zh` / `en` / `yue` / `ja` / `ko` |
| `tapMaxSeconds` | `0.45` | 单击 Fn 的判定阈值，超过算长按（不触发） |
| `modelRoot` / `modelPath` / `tokensPath` / `vadPath` | 空 | 自定义识别模型位置 |
| `threads` | `2` | 推理线程数 |
| `idleUnloadSeconds` | `300` | 空闲多久卸载模型；0 = 常驻 |
| `restoreClipboard` | `true` | 粘贴后恢复原剪贴板 |
| `showHUD` / `playSounds` | `true` | 悬浮条 / 提示音 |
| `llm.*` | 关闭 | `baseURL` / `model` / `apiKeyEnv` / `apiKeyCommand` / `timeoutMs` |

改完点菜单里的**重新加载配置**即可生效（不用重启）：它会停掉识别进程，下次按 Fn 时按新配置重新拉起。

换润色模型（任何 OpenAI 兼容端点都行，包括本地 Ollama）：

```json
"llm": {
  "enabled": true,
  "baseURL": "https://api.deepseek.com/v1",
  "model": "deepseek-flash",
  "apiKeyEnv": "DEEPSEEK_API_KEY"
}
```

更详细的配置说明见 [docs/agent-setup.md](docs/agent-setup.md#可选换模型)。

## 自检与排障

```bash
APP="build/DSH Voice.app/Contents/MacOS/DSHVoice"
"$APP" --check              # 权限、模型来源、识别服务状态
"$APP" --listen 15          # 探测 Fn 事件是否真的收得到
"$APP" --selftest 5         # 录 5 秒并输出转写 JSON
"$APP" --cycle-test a.wav 3 # 启动→转写→卸载→重启 压测
node sidecar/cleanup.test.mjs   # 规则清理单测
swiftc -O -o /tmp/single-instance-test Sources/SingleInstance.swift tests/single-instance.test.swift \
  && /tmp/single-instance-test  # 单实例保护单测
```

| 症状 | 处理 |
| --- | --- |
| 说一句话却被录入两遍 | 有两份 App 同时在跑。新版本会自己拦住并弹窗告诉你另一份在哪；旧版本请手动 `ps aux \| grep DSHVoice` 找出多余那份并退出 |
| 按 Fn 没反应 | 开「输入监控」；确认「按下 🌐 键时」= 不执行任何操作；用 `--listen` 确认 |
| 能转写但不粘贴 | 辅助功能权限没给；文字此时会留在剪贴板，手动 ⌘V 可用 |
| 提示"没听清" | 正常行为：没有有效语音就不粘贴任何东西 |
| 没有标点 | 当前是 `rules` 模式；确认 `.env` 有密钥且 `cleanup=llm` |
| 润色超时 | 自动退回规则层结果，不影响使用；可调 `llm.timeoutMs` |
| 与 Typeless 等工具冲突 | 它们默认也抢 Fn，建议只留一个 |

日志：`~/.voice-global/log.txt`（每次听写会记录耗时与 token 用量）。

## 发给别人用

如果你的朋友不想自己编译，可以直接给他们一个压缩包：**包内已自带 Node 运行时和识别模型**
（官方 Node 二进制只依赖系统库，可以整个搬进 bundle）。对方不需要装 Xcode、不需要装 Node、
也不需要下载模型。

```bash
./scripts/package.sh              # → dist/DSH Voice.zip（约 197MB）
./scripts/package.sh --no-model   # 不内置模型，包小很多，但对方首次要自己下 231MB
```

压缩包里带一份《安装说明.md》，对方照做即可，也可以直接把说明丢给他的 Agent。

**有一个坑必须提醒对方**：压缩包如果是从微信 / 飞书 / AirDrop / 浏览器收到的，macOS 会给它
打上隔离标记，直接打开只会弹「Apple 无法验证…是否包含恶意软件」，而且**没有「仍要打开」按钮**。
所以装完 App 后要先跑一次：

```bash
xattr -dr com.apple.quarantine "/Applications/DSH Voice.app"
```

这条命令要在**第一次启动之前**执行 —— App 已经在运行时，它所在的 bundle 会被系统锁住，
命令会报 `Operation not permitted`（这是实测行为，不是权限没给够）。

> 分发包没有做 Apple 公证（那需要 $99/年的开发者账号），所以这步 `xattr` 省不掉。
> 好在对方本来就要去「系统设置」里勾三项权限，多一条命令不算额外负担。
>
> 签名用的是本机证书，**换证书会让老用户的系统授权失效**，所以请沿用
> `scripts/setup-signing.sh` 生成的那一张，不要随手重建。

## 目录结构

```
Sources/                   Swift 宿主（热键 / 录音 / HUD / 注入 / 配置）
  SingleInstance.swift     单实例保护（文件锁，防止两份 App 同时监听 Fn）
sidecar/                   Node 转写服务
  server.mjs               SenseVoice 推理 + 协议
  cleanup.mjs              规则清理（可独立单测）
  llm.mjs                  云端润色
scripts/
  setup.sh                 一键安装
  fetch-models.mjs         模型获取：先复用，再下载（带 SHA-256 校验）
  configure.mjs            配置读写（密钥与配置分离）
  stage-deps.mjs           从本机 DSH 提取 sherpa-onnx 原生库
  setup-signing.sh         生成本地签名证书（避免反复授权）
  package.sh               打「发出去就能用」的分发包（内置 Node 与模型）
  dist-readme.md           随分发包一起发出的《安装说明》
tests/
  single-instance.test.swift  单实例保护单测
docs/agent-setup.md        给 AI Agent 的安装引导
bench/cost.mjs             成本复现脚本
```

## 环境要求

- macOS 13+，Apple Silicon（arm64）
- Xcode Command Line Tools（提供 `swiftc`）
- Node.js 20+

Windows / Intel / 流式字幕 / 唤醒词暂不支持。

## 致谢与来源

识别栈（SenseVoice + Silero VAD via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)）与模型清单源自
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的语音输入子系统；
本项目把它从"只能在应用内用"扩展成"系统级可用"，并补上了清理与润色层。

## License

MIT — 见 [LICENSE](LICENSE)。
