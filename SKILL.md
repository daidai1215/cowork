---
name: cowork
description: Lightweight cross-platform model bridge (GPT-6.2 Astra Fast high/xhigh on Codex, Claude Opus 5.5 read-only aesthetic review): host-only, T=0 async, <=3 bounded batch, pairs with plain Neon/Carbon & /swarm. Triggers: cowork, gpt-write, gpt-review, Astra, Opus.
---
# cowork (Lite)
Root: `~/.gemini/config/skills/cowork` | Config: `registry/models.json` | Policy: `AGENTS.md`

## Core Rules
- **主控与 `/swarm` 协同**：日常用普通 **Gemini 4 Neon (`High`)**，长文/论文/架构用普通 **Gemini 4 Carbon (`High`)**，多模块并行开 **`/swarm`**（Worker 用 `Neon`/`Hydrogen`）。仅主智能体可调用 Cowork；Worker 与子智能体禁止调用。
- **禁止同平台 CLI 套娃**：在 Antigravity 内禁止通过 CLI 调用 `agy` 通道的 Gemini 模型；仅跨平台借力 GPT-6.2 Astra（Codex）与 Claude Opus 5.5（终稿视觉只读审查）。
- **T=0 后台抢跑 & 低频重任务**：调用前告知 ETA（`~20-45s`），以 `WaitMsBeforeAsync=5000` 后台启动，等待期间主控继续推进无依赖本地活；禁止碎任务高频调用与多轮续聊。
- **默认 0 外部审核**：仅用户明确要求、安全/认证/支付/破坏性变更或重要前端终稿视觉把关时，触发最多 1 次单向审核；构建与单测由本地先跑通。

## Static Roster (`registry/models.json`)
| Model | ID / Alias | Channel | Defaults | Scope |
|---|---|---|---|---|
| **GPT-6.2 Astra** | `gpt-6.2-astra` (`best-rigor`, `best-math`, `best-image`) | `codex` | `high`/`xhigh`, `service_tier=fast` | 重后端/并发、数学算法、根因排查、原生生图、`office_plugins` |
| **Claude Opus 5.5** | `claude-opus-5-5` (`best-aesthetic`) | `agy` | `high`, **read-only** | 重要前端终稿截图视觉把关（`-Preset ui`，`<=500`w，单次） |
| **Gemini 4 Neon / Carbon / Hydrogen** | `gemini-4-neon`, `gemini-4-carbon`, `gemini-4-hydrogen` | `agy` | `high` | 仅 Codex 侧跨平台调用（1M 长上下文/长文/高速批处理） |

## CLI (`powershell -NoProfile -ExecutionPolicy Bypass -File "<root>\scripts\<s>.ps1"`)
- **Single Invoke**：`invoke-model.ps1 [-Preset code|math|review|ui|office|image] [-Model <id|alias>] -Prompt <text>|-PromptFile <path> [-Access read|write] [-WorkDir <dir>] [-Effort high|xhigh] [-NoFast|-ServiceTier default|fast] [-ContextFiles "a.py:10-80,b.py"] [-OutFile <path>] [-AllowCodexShell] [-FullCodexConfig] [-TimeoutSec 600] [-DryRun]`
- **Bounded Batch (`<=3` 硬上限)**：`invoke-batch.ps1 -BatchFile <tasks.json>|-TasksJson <json> [-MaxParallel 3] [-DryRun]`
- **Smoke Check (`<3s`)**：`smoke.ps1`
- **实现说明**：无状态/无锁/无统计；直读 `config.toml` 的 `CODEX_CLI_PATH`、默认 Codex `--ephemeral` + `service_tier="fast"` + 缓存 `models_cache.json` + Cockpit 被动避让（`account_rotation: true`），不含实验特性黑盒参数。
