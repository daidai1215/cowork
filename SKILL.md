---
name: cowork
description: Lightweight adaptive cross-platform model bridge (GPT-6.2 Astra Fast high/xhigh on Codex, Claude Opus 5.5 read-only aesthetic review): 4D triage, calibrated subagent tiers, stuck-escalation, preferences.md, <=3 bounded batch. Triggers: cowork, gpt-write, gpt-review, Astra, Opus.
---
# cowork (Lite)
Root: `~/.gemini/config/skills/cowork` | Config: `registry/models.json`, `registry/preferences.md` | Policy: `AGENTS.md`

## Adaptive Dispatch Rules
- **4 维语义分诊 + 透明调度卡**：复杂任务开工前即时评估「能力短板 × 35s 异步重叠 ROI × 一次通过置信度 × 多模块可拆度」，输出 1 行 `[调度] ...`；优先遵循 `registry/preferences.md`（<=20 条）。
- **大仓探路（已标定 `subagent_tiers`，`2026-11-20`）**：陌生大仓先派只读 `research` 子智能体——默认 **`flash`**（`= gemini-4-hydrogen-tiered-high`, ~8s, AA 51 / TB 57%）；深度调研用 **`inherit`**（Neon/Carbon）；禁用 `flash_lite`，常规不用 `pro`（`= gemini-4-hydrogen-tiered-xhigh`, 思考重）。
- **主控与 `/swarm` 协同**：精密编码/前端用普通 `Neon (High)`；长文/论文用普通 `Carbon (High)`；多模块并行开 `/swarm`（写代码 `Neon`、扫描/单测 `Hydrogen`、长文档 `Carbon`）。**仅主智能体可调用 Cowork**，Worker/子智能体禁止调用。
- **T=0 抢跑 & 卡壳 2 轮升级**：确定边界后以 `WaitMsBeforeAsync=5000` 后台启动，等待期间推进本地活；本地同 Bug/数值问题连续 2 轮未收敛时，自动切片（`path:start-end` + `<=20` 行报错）唤 Astra 破局。禁止 AGY 内 CLI 套娃调 Gemini；默认 0 外部审核。
- **新模型发布一次性标定（日常 0 测速）**：仅发新模型时跑 1 次极短实测看底层模型与耗时（子智能体读 transcript `model`，外部 CLI 跑 1 次 `"OK"` ping）+ `web_search` 查公开榜单，更新 `registry/models.json`。

## Static Roster (`registry/models.json`)
| Model | ID / Alias | Channel | Defaults | Scope |
|---|---|---|---|---|
| **GPT-6.2 Astra** | `gpt-6.2-astra` (`best-rigor`, `best-math`, `best-image`) | `codex` | `high`/`xhigh`, `service_tier=fast` | 重后端/并发、数学算法、根因排查、原生生图、`office_plugins` |
| **Claude Opus 5.5** | `claude-opus-5-5` (`best-aesthetic`) | `agy` | `high`, **read-only** | 重要前端终稿截图视觉把关（`-Preset ui`，`<=500`w，单次） |
| **Gemini 4 Neon / Carbon / Hydrogen** | `gemini-4-neon`, `gemini-4-carbon`, `gemini-4-hydrogen` | `agy` | `high` | 仅 Codex 侧跨平台调用（1M 长上下文/长文/高速批处理） |

## CLI (`powershell -NoProfile -ExecutionPolicy Bypass -File "<root>\scripts\<s>.ps1"`)
- **Single Invoke**：`invoke-model.ps1 [-Preset code|math|review|ui|office|image] [-Model <id|alias>] -Prompt <text>|-PromptFile <path> [-Access read|write] [-WorkDir <dir>] [-Effort high|xhigh] [-NoFast|-ServiceTier default|fast] [-ContextFiles "a.py:10-80,b.py"] [-OutFile <path>] [-AllowCodexShell] [-FullCodexConfig] [-TimeoutSec 600] [-DryRun]`
- **Bounded Batch (`<=3` 硬上限)**：`invoke-batch.ps1 -BatchFile <tasks.json>|-TasksJson <json> [-MaxParallel 3] [-DryRun]`
- **Smoke Check (`<5s`)**：`smoke.ps1`
