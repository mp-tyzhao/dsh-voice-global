# DSH Voice 安装说明

按一下 `Fn` 说话，文字自动落到任意应用的光标处。**音频只在本机处理。**

需要：**macOS 13+ 的 Apple 芯片 Mac（M 系列）**。包内已自带 Node 运行时会与识别模型，
**不需要装 Xcode、不需要装 Node、不需要联网下载模型**。

---

## 如果你是人类，把下面这段整个发给你的编码 Agent

```text
请帮我在这台 macOS 上装好 DSH Voice（一个按 Fn 说话、自动转写并粘贴到当前应用的工具）。
压缩包已经在我手上解压好了（或请我告诉你路径）。请：

1. 把「DSH Voice.app」放进 /Applications；
2. 执行 xattr -dr com.apple.quarantine "/Applications/DSH Voice.app"
   —— 这一步不能省，否则 macOS 会说"无法验证开发者"；
3. 启动它，然后用 "/Applications/DSH Voice.app/Contents/MacOS/DSHVoice" --check 验证；
4. 把需要在「系统设置」里手动勾选的权限项一条条告诉我（我自己去点，你不要代点）；
5. 三项都授权后再跑一次 --check，确认"识别服务：就绪"。

注意：系统授权（麦克风/辅助功能/输入监控）必须我本人操作，你只要把确切路径告诉我。
云端润色是可选功能，先不配置也能用（只是没有标点）。
```

---

## 如果你是 Agent，照下面做

### 1. 放进「应用程序」

```bash
cp -R "DSH Voice.app" /Applications/
```

### 2. 去掉 quarantine（**必须做，最容易漏**）

压缩包如果是从微信 / 飞书 / AirDrop / 浏览器下载的，macOS 会给它打上隔离标记，
直接打开会弹「Apple 无法验证…是否包含恶意软件」，而且只有「完成」和「移到废纸篓」两个选项。

```bash
xattr -dr com.apple.quarantine "/Applications/DSH Voice.app"
```

做一次就够。**注意要在第一次启动之前执行** —— App 已经在运行时，这个命令会报
`Operation not permitted`，那时先退出它再执行。

### 3. 启动并自检

```bash
open "/Applications/DSH Voice.app"
APP="/Applications/DSH Voice.app/Contents/MacOS/DSHVoice"
"$APP" --check
```

期望看到麦克风 / 辅助功能 / 识别模型 / 词表 / VAD 全是 ✅，最后一行 `✅ 识别服务：就绪`。

### 4. 带用户过权限（**必须由人操作，不要代点**）

| 权限 | 路径 | 没给会怎样 |
| --- | --- | --- |
| 麦克风 | 系统设置 → 隐私与安全性 → 麦克风 → 勾选 `DSH Voice` | 录不到声音 |
| 辅助功能 | 系统设置 → 隐私与安全性 → 辅助功能 → 勾选 `DSH Voice` | 能转写但粘不出去 |
| 输入监控 | 系统设置 → 隐私与安全性 → 输入监控 → 勾选 `DSH Voice` | 按 Fn 没反应 |

**再强调一步**：系统设置 → 键盘 → 「按下 🌐 键时」→ **不执行任何操作**。
不改的话，每次单击 Fn 都会弹出表情面板。

授权后**不用重启 App**，它每 2 秒检测一次，会自动生效。

### 5. 验证

```bash
"$APP" --listen 15     # 需要用户配合按一下 Fn；期望"收到 1 次 Fn 按下"
"$APP" --selftest 5    # 录 5 秒并输出转写结果
```

---

## 怎么用

| 操作 | 效果 |
| --- | --- |
| 单击 `Fn` | 开始聆听（屏幕底部出现电平条） |
| 再单击 `Fn` | 结束、转写，然后自动粘贴到光标处 |
| `Esc` | 放弃这次录音 |
| 按住 `Fn` + 其他键 | 仍是系统功能（Fn+←=Home 等），不会被误判 |

菜单栏的麦克风图标里可以切换清理模式、打开配置、看日志、退出。

---

## 可选：开启云端润色

不开也能用（规则清理会删语气词、结巴、补基本标点），开了之后会额外补标点、修同音字。
开启后**只有转写出的文字**会发到你配置的端点，音频始终不出本机。

拿到密钥后，一条命令搞定（包内自带了配置脚本，比手改 JSON 可靠）：

```bash
NODE="/Applications/DSH Voice.app/Contents/Resources/node/bin/node"
"$NODE" "/Applications/DSH Voice.app/Contents/Resources/setup/configure.mjs" \
  --cleanup llm \
  --base-url https://api.deepseek.com/v1 \
  --model deepseek-flash \
  --api-key sk-你的密钥
```

它会把密钥写进 `~/.voice-global/.env`（权限 600，不进任何可分享的文件），
并把 `~/.voice-global/config.json` 里的 `cleanup` 设为 `llm`、`llm.enabled` 设为 `true`。
**执行时不要回显密钥，也不要把它写进会被提交的文件。**

改完在菜单栏图标里点「重新加载配置」即可生效。

<details>
<summary>不想用脚本、要手写配置的话（点开）</summary>

`~/.voice-global/.env` 里写**一行**（不带 `export`、不带引号）：

```
DEEPSEEK_API_KEY=sk-你的密钥
```

`~/.voice-global/config.json` 里需要这几项同时到位 —— 只把 `cleanup` 改成 `llm`
而 `llm.enabled` 还是 `false` 是**不生效**的：

```json
{
  "cleanup": "llm",
  "llm": {
    "enabled": true,
    "baseURL": "https://api.deepseek.com/v1",
    "model": "deepseek-flash",
    "apiKeyEnv": "DEEPSEEK_API_KEY"
  }
}
```
</details>

密钥申请：https://platform.deepseek.com/api_keys

---

## 排障

| 症状 | 处理 |
| --- | --- |
| 提示"无法验证开发者" | 第 2 步的 `xattr` 没做，或做的时候 App 正在运行 |
| 放进 /Applications 报 Permission denied | 当前账号不是管理员，命令前加 `sudo` |
| 按 Fn 没反应 | 开「输入监控」；确认「按下 🌐 键时」= 不执行任何操作；用 `--listen 15` 确认 |
| 能转写但不粘贴 | 辅助功能权限没给；文字此时在剪贴板里，手动 ⌘V 可用 |
| 提示"没听清" | 正常行为：没有有效语音就不粘贴任何东西 |
| 没有标点 | 当前是纯离线模式，见上面「可选：开启云端润色」 |
| 模型/VAD 显示 ❌ | 说明包不完整；用包内脚本重下：`"/Applications/DSH Voice.app/Contents/Resources/node/bin/node" "/Applications/DSH Voice.app/Contents/Resources/setup/fetch-models.mjs"`（需联网约 231MB） |

日志：`~/.voice-global/log.txt`

---

## 卸载

```bash
rm -rf "/Applications/DSH Voice.app" ~/.voice-global
```

> `~/.voice-global/signing/` 里存的是本机签名证书的私钥，`rm -rf` 会一并删掉。
> 只是卸载的话这样没问题；如果你以后还要用它签新的构建，先备份那个目录。

再在「系统设置 → 隐私与安全性」里把 `DSH Voice` 从三项列表中去掉。
