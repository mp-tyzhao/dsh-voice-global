# Voice Global

[中文](README.md) | [English](README.en.md)

**Tap Fn on macOS, speak, and the text lands at the cursor in whatever app you're in.** On-device recognition plus cloud polish: talk like a human, get written prose.

```
Tap Fn ──▶ Record ──▶ Transcribe on-device (SenseVoice) ──▶ Clean up / polish ──▶ Paste into the focused app
```

- **On-device recognition**: a multilingual SenseVoice model runs on your CPU — audio never leaves the machine
- **Talk like a human, get written prose**: strips filler words, handles spoken self-corrections like "no wait, I mean…", adds punctuation, fixes homophones
- **Works in any app**: WeChat, Feishu, browsers, IDEs, terminals — no special text field required
- **Cost ≈ 0**: on-device recognition is free; cloud polish measures about **¥0.0006 per dictation**

---

## 🚀 Easiest install: let your agent do it

Copy the block below **in one piece** and send it to your own coding agent (Codex / Claude Code / Cursor / anything that can run commands):

```text
Please install and configure Voice Global on this macOS machine — a global dictation tool that listens when I tap Fn, transcribes on-device, cleans the text up, and pastes it into the focused app.

Repository: https://github.com/mp-tyzhao/dsh-voice-global
Clone the repo, then read docs/agent-setup.md in full and follow it step by step:
environment checks → one-command install (./scripts/setup.sh) → walk me through the system permissions → verify each item → tell me how to use it.

Rules you must follow:
1. The system permissions (Microphone / Accessibility / Input Monitoring) can only be granted by me, in System Settings. Do not click them for me. Give me the exact paths, and after I grant them verify with "$APP" --check and "$APP" --listen 15.
2. I will supply the DeepSeek API key myself if one is needed. Until I do, don't guess one, don't invent one, and don't write it into any file. Once you have it, write it only to ~/.voice-global/.env — never echo it in the terminal, never commit it to git.
3. Cloud polish is optional. If I don't want my text leaving this machine, use ./scripts/setup.sh --no-llm for a fully offline setup.
4. Verify every step before moving on. If something fails, read ~/.voice-global/log.txt first instead of retrying blindly.
```

> `docs/agent-setup.md` is currently written in Chinese; its commands and paths are language-neutral, and any coding agent can follow it.

---

## Manual install

```bash
git clone https://github.com/mp-tyzhao/dsh-voice-global.git
cd dsh-voice-global
./scripts/setup.sh --api-key sk-xxxxxxxx     # with a DeepSeek key: enables cloud polish
# or
./scripts/setup.sh --no-llm                   # fully offline, no network calls
```

The installer's strategy is **reuse what's already on this machine before building anything from scratch**:

| Step | Logic |
| --- | --- |
| Recognition runtime | already vendored in the repo → `npm install` → extract the native library from a local DeepSeek Harness install |
| Recognition model | already in the project's own directory → **reuse the voice pack your local DSH already downloaded, in place (saves a 228MB download)** → only download from HuggingFace if neither exists |
| Polish model | use `--api-key` or the `DEEPSEEK_API_KEY` environment variable; without one it falls back to fully offline and explains how to get a key |

Then launch it:

```bash
open "build/DSH Voice.app"
```

First run has three gates to pass (the app prompts you through them):

1. **Microphone**: System Settings → Privacy & Security → Microphone → enable `DSH Voice`
2. **Accessibility**: System Settings → Privacy & Security → Accessibility → enable `DSH Voice` (without it the app can't paste for you)
3. **Input Monitoring**: System Settings → Privacy & Security → Input Monitoring → enable `DSH Voice` (only needed if Fn does nothing)

**One critical step**: System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing** (otherwise every Fn tap also pops the emoji picker).

You don't have to restart the app after granting: it polls every 2 seconds and takes effect on its own.

## Usage

| Action | What happens |
| --- | --- |
| Tap `Fn` | Starts listening (a level meter appears at the bottom of the screen) |
| Tap `Fn` again | Stops, transcribes, cleans up, then pastes automatically |
| `Esc` | Discards the current recording |
| Hold `Fn` + another key | Still a system shortcut (Fn+← = Home, etc.) — never mistaken for a tap |

The microphone icon in the menu bar lets you: switch cleanup mode, open the config, open the log, run a permission self-check, and quit.

## Results

What the cleanup layer does (raw input on top, result below). Both samples are Chinese — the primary target language for now — with the meaning explained underneath.

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

| Capability | Notes |
| --- | --- |
| Filler / verbal-tics removal | 嗯, 呃, 那个, 就是说, uh, um … while "这个" inside "这个项目" is left alone |
| Spoken self-correction | "…no, I mean…" keeps only the corrected half of the sentence |
| Stutter repetition | "我我我" → "我", "就是就是" → "就是" (Chinese verb reduplication like 看看/想想 is protected) |
| Punctuation and sentence breaks | Adds commas and periods, normalizes punctuation, formats Chinese numerals ("三点" → "3点") |
| Homophone correction | Needs cloud polish; the model only fixes clearly implausible words and still slips without context (e.g. 原型图 vs 圆形图) |
| Empty-input guard | Empty transcripts caused by silence or noise are dropped — nothing strange is ever pasted |

## Architecture

```
Voice Global.app                  Swift menu-bar app, no Dock icon (LSUIElement)
├── HotkeyTap    CGEventTap watching Fn (listen-only: never swallows events or breaks Fn combos)
├── Recorder     AVAudioEngine → 16kHz mono PCM16 WAV
├── HUD          Non-activating floating status bar (activating it would paste into itself)
├── Injector     Clipboard + synthesized ⌘V, restores the previous clipboard afterwards
└── Sidecar      Spawns a long-lived Node process
    └── server.mjs  SenseVoice-small ONNX + Silero VAD (local CPU inference)
        ├── cleanup.mjs  Rule-based cleanup (22 unit tests, runnable standalone)
        └── llm.mjs      Optional cloud polish (any OpenAI-compatible endpoint)
```

A few deliberate choices:

- **Long-lived sidecar**: the model loads once at startup (0.4s); after that each utterance only costs inference time — measured at 190ms for 11 seconds of speech.
- **Idle unload**: after 5 minutes of silence the recognizer process is released (about 900MB resident); the next recording pre-warms it, and the time you spend talking is enough for it to load.
- **Local signing certificate**: `scripts/setup-signing.sh` creates a fixed certificate so rebuilding doesn't drop your system permissions (ad-hoc signatures lose them every time).
- **Never steals focus**: the HUD is a non-activating panel — otherwise the paste would land on itself.

## Model and cost

| Stage | Model | Where it runs |
| --- | --- | --- |
| Speech recognition | SenseVoice-Small int8 (228MB) + Silero VAD, via sherpa-onnx | Your CPU, zero cost |
| Rule cleanup | Purpose-built rule engine | Local, zero latency |
| Polish | `deepseek-flash` (DeepSeek-V4.1-Flash), thinking mode disabled | DeepSeek API |

Measured on the packaged pipeline:

```
190ms on-device recognition  +  559ms cloud polish   ≈  0.75s from "stop talking" to text
251–297 input tokens (including a fixed ~230-token system prompt, which is cacheable)  8–35 output tokens
```

Official pricing (USD per 1M tokens, `deepseek-flash`):

| | Off-peak | Peak |
| --- | --- | --- |
| Input · cache hit | $0.003 | $0.006 |
| Input · cache miss | $0.15 | $0.30 |
| Output | $0.60 | $1.20 |

→ **about ¥0.0006 per dictation, ¥0.6 per thousand**; 100 dictations a day ≈ ¥1.8/month.

> Peak hours are 01:00–04:00 and 06:00–10:00 UTC on weekdays (09:00–12:00 and 14:00–18:00 Beijing time),
> which covers most of the Chinese working day — so the peak column above is the realistic one.
> Reproduce the numbers with [`bench/cost.mjs`](bench/cost.mjs).

**Privacy boundary**: audio always stays on this machine. Only when `cleanup=llm` does the **transcribed text** go to the endpoint you configured. Set `cleanup` to `rules` for a fully offline, zero-cost setup.

## Configuration

Config lives in `~/.voice-global/config.json` (the data directory is created on first run); the API key lives separately in `~/.voice-global/.env` (mode 600).

| Field | Default | Meaning |
| --- | --- | --- |
| `cleanup` | `rules` | `off` transcribe only / `rules` rule cleanup / `llm` rules + cloud polish |
| `language` | `auto` | `auto` / `zh` / `en` / `yue` / `ja` / `ko` |
| `tapMaxSeconds` | `0.45` | Tap threshold for Fn; a longer press counts as a hold and does nothing |
| `modelRoot` / `modelPath` / `tokensPath` / `vadPath` | empty | Point at custom recognition models |
| `threads` | `2` | Inference threads |
| `idleUnloadSeconds` | `300` | Release the model after this much idle time; 0 keeps it resident |
| `restoreClipboard` | `true` | Restore the previous clipboard after pasting |
| `showHUD` / `playSounds` | `true` | Floating status bar / audio cues |
| `llm.*` | off | `baseURL` / `model` / `apiKeyEnv` / `apiKeyCommand` / `timeoutMs` |

After editing, pick **Reload configuration** in the menu — no restart needed: it stops the recognizer process, which comes back with the new config on the next Fn tap.

Switching the polish model (any OpenAI-compatible endpoint works, including a local Ollama):

```json
"llm": {
  "enabled": true,
  "baseURL": "https://api.deepseek.com/v1",
  "model": "deepseek-flash",
  "apiKeyEnv": "DEEPSEEK_API_KEY"
}
```

For the full configuration reference, see [docs/agent-setup.md](docs/agent-setup.md#可选换模型) (Chinese).

## Self-check and troubleshooting

```bash
APP="build/DSH Voice.app/Contents/MacOS/DSHVoice"
"$APP" --check              # permissions, model source, recognizer status
"$APP" --listen 15          # check whether Fn events actually arrive
"$APP" --selftest 5         # record 5 seconds and print the transcript as JSON
"$APP" --cycle-test a.wav 3 # start → transcribe → unload → restart stress test
node sidecar/cleanup.test.mjs   # cleanup rule unit tests
```

| Symptom | Fix |
| --- | --- |
| Fn does nothing | Enable Input Monitoring; make sure "Press 🌐 key to" = Do Nothing; confirm with `--listen` |
| Transcribes but doesn't paste | Accessibility permission is missing; the text stays on the clipboard in the meantime, so manual ⌘V works |
| "Didn't catch that" | Working as designed: with no usable speech, nothing gets pasted |
| No punctuation | You're in `rules` mode; make sure `.env` has a key and `cleanup=llm` |
| Polish errors out or times out | It falls back to the rule-layer result automatically, so nothing breaks; you can raise `llm.timeoutMs` |
| Conflicts with tools like Typeless | They grab Fn by default too — keep only one of them |

Log: `~/.voice-global/log.txt` (every dictation records timing and token usage).

## Repository layout

```
Sources/                   Swift host (hotkey / recording / HUD / injection / config)
sidecar/                   Node transcription service
  server.mjs               SenseVoice inference + protocol
  cleanup.mjs              Rule cleanup (unit-testable standalone)
  llm.mjs                  Cloud polish
scripts/
  setup.sh                 One-command installer
  fetch-models.mjs         Model acquisition: reuse first, download second (SHA-256 verified)
  configure.mjs            Config read/write (key and config kept separate)
  stage-deps.mjs           Extract the sherpa-onnx native library from a local DSH install
  setup-signing.sh         Create the local signing certificate (avoids repeated re-authorization)
docs/agent-setup.md        Installation guide written for AI agents
bench/cost.mjs             Cost reproduction script
```

## Requirements

- macOS 13+, Apple Silicon (arm64)
- Xcode Command Line Tools (provides `swiftc`)
- Node.js 20+

Windows, Intel Macs, streaming captions and wake words are not supported yet.

## Credits and provenance

The recognition stack (SenseVoice + Silero VAD via [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)) and the model manifest come from the voice-input subsystem of
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).
This project extends it from "usable only inside that app" to "usable system-wide", and adds the cleanup and polish layers.

## License

MIT — see [LICENSE](LICENSE).
