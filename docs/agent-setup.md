# 交给 Agent 的安装指南

这份文档是写给 **AI Agent**（Codex / Claude Code / Cursor / 其它能执行命令的编码助手）看的。
人类用户只需要把项目介绍里的那段话发给你，你就照着下面一步一步做。

> 人类用户请直接看 [README.md](../README.md)，不用读这份。

## 你的目标

在一台 macOS 机器上装好 `Voice Global`：全局按 Fn 说话，本机转写 + 云端润色，文字自动落到当前光标处。
装完要能通过 `--check` 自检，并让用户亲自按一次 Fn 验证。

## 铁律

1. **不要替用户点系统授权弹窗。** 麦克风 / 辅助功能 / 输入监控 这三项只能由人在「系统设置」里勾选，
   你能做的是把用户领到确切位置、并给出验证命令。
2. **不要打印、不要提交任何 API 密钥。** 密钥只写入 `~/.voice-global/.env`（权限 600）。
   如果用户把密钥贴给了你，用完不要回显、不要写进任何会被提交的文件。
3. **每一步都要验证再往下走。** 命令失败时先读输出和 `~/.voice-global/log.txt`，不要盲目重试。
4. **不确定就问用户**，尤其是密钥、权限、以及"要不要启用云端润色"这类涉及隐私的选择。

## 第 0 步：先问用户两件事

| 问题 | 为什么要问 |
| --- | --- |
| 要不要启用**云端润色**？ | 音频永远在本机；但开启后**转写出的文字**会发到 DeepSeek。不开也能用，只是没有标点和同音字纠错。 |
| 有没有 DeepSeek API Key？ | 有就直接配；没有就给降级方案（纯离线），并告诉用户去哪申请。 |

如果用户要云端润色，让他去 https://platform.deepseek.com/api_keys 申请，模型用 `deepseek-flash`（即 DeepSeek-V4.1-Flash，快且便宜）。

## 第 1 步：环境检查

```bash
uname -s && uname -m          # 需要 Darwin + arm64
sw_vers -productVersion       # 需要 13.0+
xcode-select -p || xcode-select --install   # 需要 Command Line Tools（提供 swiftc）
node -v                       # 需要 v20+，没有就 brew install node
```

任何一项不满足，先帮用户解决，不要跳过。

## 第 2 步：一键安装

```bash
git clone <仓库地址> voice-global
cd voice-global

# 有密钥（推荐）：顺便启用云端润色
./scripts/setup.sh --api-key sk-xxxxxxxxxxxxxxxx

# 没有密钥 / 用户要纯离线
./scripts/setup.sh --no-llm
```

脚本自己会做这几件事，你只需要确认每一步都打了 ✓：

| 步骤 | 它会做什么 | 关键点 |
| --- | --- | --- |
| 1 环境检查 | macOS / swiftc / node 版本 | 缺什么就装什么 |
| 2 识别运行库 | 项目里已有就跳过；否则 npm 安装；再不行就从本机 DSH 提取 | 都不行会明确报错 |
| 3 识别模型 | **先找现成的**：自带目录 → 本机 DSH 已下载的语音包（原地复用，不复制不下载）→ 都没有才下载 231MB | 有 DSH 的机器不会重复下载 |
| 4 润色模型 | 验证密钥 → 写入 `~/.voice-global/.env` → 开启 `cleanup=llm` | `--no-llm` 时跳过，纯离线 |
| 5 构建 | 生成 `build/DSH Voice.app`，并生成本地签名证书 | 有固定证书就不必反复授权 |
| 6 提示 | 打印授权步骤与自检命令 | 把这部分转达给用户 |

如果第 3 步提示"没有找到可用模型"且下载失败（网络受限），告诉用户可以用 `HF-Mirror`：

```bash
HF_ENDPOINT=https://hf-mirror.com node scripts/fetch-models.mjs
```

## 第 3 步：带着用户过权限（必须由人操作）

先启动 App，它会自己弹一次授权引导：

```bash
open "build/DSH Voice.app"
```

然后请用户依次确认这三个开关（把路径原样念给用户）：

| 权限 | 路径 | 没给会怎样 |
| --- | --- | --- |
| 麦克风 | 系统设置 → 隐私与安全性 → 麦克风 → 勾选 `DSH Voice` | 录不到声音 |
| 辅助功能 | 系统设置 → 隐私与安全性 → 辅助功能 → 勾选 `DSH Voice` | 能转写但粘不出去（文字留在剪贴板） |
| 输入监控 | 系统设置 → 隐私与安全性 → 输入监控 → 勾选 `DSH Voice` | 按 Fn 没反应 |

**再强调一次 Fn 键设置**：系统设置 → 键盘 → 「按下 🌐 键时」→ **不执行任何操作**。
不设的话，每次单击 Fn 还会弹出表情面板。

授权后**不需要重启 App**：它每 2 秒检测一次，检测到会自己生效（用户会看到屏幕底部提示"就绪"）。

## 第 4 步：验证

按顺序跑，任何一步不符合预期就别往下走：

```bash
APP="build/DSH Voice.app/Contents/MacOS/DSHVoice"

# 1) 权限、模型来源、识别服务
"$APP" --check
#    期望：麦克风 ✅ / 辅助功能 ✅ / 识别模型 ✅（会注明是"复用 DSH 缓存"还是"自带目录"）
#         / 最后一行 "✅ 识别服务：就绪"

# 2) Fn 事件能不能收到（需要用户配合按一下 Fn）
"$APP" --listen 15
#    期望：✅ 收到 1 次 Fn 按下，识别为单击 1 次
#    如果 0 次 → 让用户去开「输入监控」，或检查「按下 🌐 键时」的设置

# 3) 转写链路（录 5 秒，让用户对着麦克风说一句话）
"$APP" --selftest 5
#    期望：输出 JSON，text 字段是识别+清理后的文字
```

第 3 步用户说话时，如果输出里 `"hits"` 含 `llm`，说明云端润色也通了；只看得到 `punctuation` 之类则是规则层结果。

## 第 5 步：交给用户

告诉用户最终用法，一句话就够：

> 在任何输入框里**单击 Fn** 开始说话，**再单击 Fn** 结束，文字会自己粘进光标处；Esc 可以取消这次录音。

再交代三件事：

- 菜单栏麦克风图标：切换清理模式（只转写 / 规则清理 / 规则+润色）、打开配置、看日志、退出。
- 配置文件 `~/.voice-global/config.json`；改完点菜单里的"重新加载配置"即可生效，不用重启。
- 开销：本机识别零成本；云端润色实测约 ¥0.0006/次（详见 README 的成本核算）。

## 故障排查

| 症状 | 先查什么 | 处理 |
| --- | --- | --- |
| 按 Fn 毫无反应 | `"$APP" --listen 15` | 收不到事件 → 开「输入监控」+ 检查 🌐 键设置 |
| 有反应但不粘贴 | `"$APP" --check` 里的辅助功能那行 | 没授权 → 去勾选；已授权仍不行 → 看目标应用是否禁止合成按键 |
| 提示"没听清" | `~/.voice-global/log.txt` | 这是设计行为：没有有效语音时不粘贴任何东西 |
| 转写正常但没有标点 | 菜单里的清理模式 | 说明在 `rules` 模式；确认 `.env` 里有密钥且 `cleanup=llm` |
| 润色报错或超时 | 日志里的 `tokens` 行 | 密钥/网络问题；超时会自动退回规则层结果，不影响使用 |
| 重新构建后要重新授权 | `codesign -d -r- "build/DSH Voice.app"` | 应显示 `certificate leaf = H"…"`；如果是 `cdhash`，说明签名证书没生成，跑 `bash scripts/setup-signing.sh` |
| 内存占用高 | `ps -o rss= -p $(pgrep -f server.mjs)` | 识别进程常驻约 900MB；`idleUnloadSeconds` 默认 300 秒空闲即释放 |

## 可选：换模型

- **换润色模型**：改 `~/.voice-global/config.json` 的 `llm.model` / `llm.baseURL`
  （`deepseek-v4-pro` 更准但贵 5 倍；任何 OpenAI 兼容端点都能用，包括本地 Ollama）。
- **换识别模型**：`modelPath` / `tokensPath` / `vadPath` 指向自己的 ONNX 文件；或 `modelRoot` 指到别的目录。
- **换语言**：`language` 填 `auto` / `zh` / `en` / `yue` / `ja` / `ko`。

改完点菜单里的"重新加载配置"，或让 App 重启：它会停掉识别进程，下次按 Fn 时按新配置重新拉起。
