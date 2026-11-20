# cowork (Lite)

Lightweight, stateless adaptive cross-platform CLI bridge between **Antigravity (`agy`)** and **Codex CLI (`codex`)**, designed to pair cleanly with standalone **Gemini 4 Neon**, **Gemini 4 Carbon**, and **`/swarm`**.

## Highlights
- **3-Layer Adaptive Dispatch**: Zero-overhead 4D semantic triage with transparent 1-line routing card, calibrated native `research` subagent recon (`flash` = `gemini-4-hydrogen-tiered-high`, `inherit` = flagship Neon/Carbon), automatic 2-round stuck escalation with line-range slices to Astra, and human-editable `registry/preferences.md`.
- **One-Time New-Model Calibration**: Zero daily probing; only when a new model ships, run 1 tiny empirical speed/identity check (subagent transcript `model` / CLI `"OK"` ping) + `web_search` public benchmarks and update `registry/models.json`.
- **Host-Only & No Same-Platform CLI Hop**: Only the primary coordinator invokes Cowork (workers/subagents never call it). Inside Antigravity, never invoke Gemini via CLI — reserve Cowork for **GPT-6.2 Astra** (Codex official Fast mode `service_tier="fast"`, `high`/`xhigh`) and **Claude Opus 5.5** (forced read-only final UI screenshot review).
- **Presets, Line Slicing & Bounded Batch (`<=3`)**: Built-in `-Preset code|math|review|ui|office|image`, `-ContextFiles "path:start-end"`, and `scripts/invoke-batch.ps1` (hard-capped at 3 concurrent tasks).
- **Zero Overhead**: No `state.json`, no file locks, no slot leases, no telemetry, direct `CODEX_CLI_PATH` lookup, `<5s` offline smoke check (`scripts/smoke.ps1`).

## Structure
- `SKILL.md` — adaptive dispatch guide, calibrated roster, presets, and CLI cheat sheet
- `registry/models.json` — static 5-model table, aliases, and calibrated `subagent_tiers`
- `registry/preferences.md` — human-editable routing preferences (`<=20` rules)
- `scripts/invoke-model.ps1` — stateless one-shot runner (`-Preset`, `-ServiceTier`/`-NoFast`, line slicing, read-only guard, proxy + passive Cockpit rotation)
- `scripts/invoke-batch.ps1` — parallel batch wrapper (strict `<=3` hard cap)
- `scripts/smoke.ps1` — `<5s` AST + config + tiers + preset + slice + batch cap check
- `scripts/lib/common.ps1` & `scripts/lib/ps1-shim-runner.ps1` — minimal shared helpers
- `scripts/sync-to-codex.ps1` — Codex skill junction helper
- `integrations/cowork-orchestrator-plugin/` — global Antigravity `AGENTS.md` rule bundle

## Quick Usage
```powershell
# Offline smoke check (<5s)
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\smoke.ps1"

# One-shot Astra Fast (high) with line-range context slice
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\invoke-model.ps1" -Preset code -ContextFiles "src\ctrl.py:120-260" -Prompt "Verify concurrency edge cases."

# Bounded parallel batch (<=3 tasks)
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\invoke-batch.ps1" -BatchFile tasks.json
```
