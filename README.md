# cowork (Lite)

Lightweight, stateless cross-platform CLI bridge between **Antigravity (`agy`)** and **Codex CLI (`codex`)**, designed to pair cleanly with standalone **Gemini 4 Neon**, **Gemini 4 Carbon**, and **`/swarm`**.

## Highlights
- **Host-Only (Pairs with `/swarm`)**: Only the primary coordinator invokes Cowork; Swarm workers and subagents never call it.
- **No Same-Platform CLI Hop**: Inside Antigravity, never invoke Gemini via CLI. Use Cowork strictly for cross-platform strengths: **GPT-6.2 Astra** (Codex, official Fast mode `service_tier="fast"`, `high`/`xhigh` reasoning) and **Claude Opus 5.5** (forced read-only final UI aesthetic review).
- **Presets & Line Slicing**: Built-in `-Preset code|math|review|ui|office|image` plus `-ContextFiles "path:start-end"` for focused, low-noise prompts.
- **Bounded Parallel Batch (`<=3`)**: Optional `scripts/invoke-batch.ps1` hard-capped at 3 concurrent tasks for independent heavy jobs.
- **Zero Overhead**: No `state.json`, no file locks, no slot leases, no telemetry, direct `CODEX_CLI_PATH` lookup, `<3s` offline smoke check (`scripts/smoke.ps1`).

## Structure
- `SKILL.md` — static roster, presets, and CLI cheat sheet
- `registry/models.json` — static 5-model table + aliases
- `scripts/invoke-model.ps1` — stateless one-shot runner (`-Preset`, `-ServiceTier`/`-NoFast`, line slicing, read-only guard, proxy + passive Cockpit rotation)
- `scripts/invoke-batch.ps1` — parallel batch wrapper (strict `<=3` hard cap)
- `scripts/smoke.ps1` — `<3s` AST + config + preset + slice + batch cap check
- `scripts/lib/common.ps1` & `scripts/lib/ps1-shim-runner.ps1` — minimal shared helpers
- `scripts/sync-to-codex.ps1` — Codex skill junction helper
- `integrations/cowork-orchestrator-plugin/` — global Antigravity `AGENTS.md` rule bundle

## Quick Usage
```powershell
# Offline smoke check (<3s)
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\smoke.ps1"

# One-shot Astra Fast (high) with line-range context slice
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\invoke-model.ps1" -Preset code -ContextFiles "src\ctrl.py:120-260" -Prompt "Verify concurrency edge cases."

# Bounded parallel batch (<=3 tasks)
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\invoke-batch.ps1" -BatchFile tasks.json
```
