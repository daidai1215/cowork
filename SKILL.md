---
name: cowork
description: Multi-model orchestration (Astra, Neon, Carbon, 4H Extra, Opus 5.5): host routing, ship-first review, Swarm, KV cache. Triggers: cowork, multi-model, swarm, gpt-write, gpt-review, Neon, Gemini 4 Neon, 4H Extra, Astra, Opus.
---
# cowork
Root: `~/.gemini/config/skills/cowork` | State: `~/.cowork` | Policy: `AGENTS.md`, `references/`
<!-- AUTO:ROSTER:START -->
> Auto-synced from `registry/models.json` (`registry_rev: 15`, active: 5)

|Model|ID (Ch)|Effort|Strengths (>=9)|Q|S|Traits|
|---|---|---|---|---|---|---|
|**Claude Opus 5.5**|`claude-opus-5-5` (`agy`)|`high`|frontend_aesthetic(10), agentic_coding(9.5)|1|2|Review only; `web_search`, `browser`|
|**Gemini 4 Carbon**|`gemini-4-carbon` (`agy`)|`high`|long_context(10), prose(10), world_knowledge(10), agentic_coding(9)|3|2|`web_search`, `browser`, `long_context_1m`|
|**GPT-6.2 Astra**|`gpt-6.2-astra` (`codex`)|`high`/`xhigh`|backend(10), code_rigor(10), image_gen(10), math(10), agentic_coding(9.5), office_docs(9.5), long_context(9)|2|1|Cockpit; `image_gen`, `office_plugins`, `latex`, `browser`, `computer_use`|
|**Gemini 4 Hydrogen**|`gemini-4-hydrogen` (`agy`)|`xhigh`|long_context(9.5)|3|3|`web_search`, `browser`, `long_context_1m`|
|**Gemini 4 Neon**|`gemini-4-neon` (`agy`)|`high`/`xhigh`|long_context(10), agentic_coding(9.5), prose(9.5), world_knowledge(9.5), backend(9), code_rigor(9), math(9)|3|2|`web_search`, `browser`, `long_context_1m`|

- **Pools**: `codex_openai`<=4, `agy_anthropic`<=3, `agy_google`<=7
<!-- AUTO:ROSTER:END -->

## Dispatch (`AGENTS.md`: Fast-Plan, Ship-First, Pools, KV)
Skip `detect-models`/`route` on table hits. Launch ready ext roles at `T=0` (0 Opus backend-only; Opus waits for UI shots/tokens); workers run local slices. **Ship-First**: deliver v1 post-local Truth Gate; run slow reviews async after (pre-block only security/auth/payment/destructive or user ask).

<!-- AUTO:ROUTING:START -->
- **Mode**: `peak` | **Aliases**: `best-aesthetic`->`claude-opus-5-5`, `best-image`->`gpt-6.2-astra`, `best-knowledge`->`gemini-4-carbon`, `best-math`->`gpt-6.2-astra`, `best-prose`->`gemini-4-carbon`, `best-rigor`->`gpt-6.2-astra`

|`-Tags`|Primary|Reviewer|Polisher|Pattern|
|---|---|---|---|---|
|`frontend,landing_page`|`gemini-4-neon`|`claude-opus-5-5`|`gemini-4-carbon`|`aesthetic_gate`|
|`backend,concurrency`|`gpt-6.2-astra`|`gemini-4-neon`|-|`pipelined_review`|
|`math,algorithm`|`gpt-6.2-astra` (`xhigh`)|`gemini-4-neon`|-|`pipelined_review`|
|`bugfix`|`gpt-6.2-astra`|`gemini-4-neon`|-|`pipelined_review`|
|`prose,paper`|`gemini-4-carbon`|`gpt-6.2-astra`|-|`pipelined_review`|
|`image_gen`|`gpt-6.2-astra`|`claude-opus-5-5`|-|`strength_delegation`|
|`office,ppt`|`gpt-6.2-astra`|`claude-opus-5-5`|-|`strength_delegation`|
|`research,long_context`|`gemini-4-carbon`|`gpt-6.2-astra`|-|`pipelined_review`|

- **`-Mode fast_4h`**: `gemini-4-carbon`->`gemini-4-hydrogen` (`xhigh`), except `paper/essay/copywriting/architecture` (`math/algorithm/architecture` rev) & `-AllowEscalation`.

- **Host Tiers (`-HostModel`)**: `orchestrator_fast`/`neon_peak`/`carbon_peak`/`hydrogen_max` (`Neon`: `high` (`math`/`arch` `xhigh`, `bulk`/`scan`->`4H`); `4H`: `scan`->`med`, `bulk`/`boilerplate`/`test_gen`->`high`, else `xhigh`):

|Host|`-Tags`|Primary|Reviewer|Gate|
|---|---|---|---|---|
|`orchestrator`|`frontend,landing_page`|`gemini-4-hydrogen` (`xhigh`)|`claude-opus-5-5` (`high`)|-|
|`orchestrator`|`architecture`|`gpt-6.2-astra` (`high`)|`gemini-4-neon` (`high`)|-|
|`neon`|`frontend,landing_page`|`gemini-4-neon` (`high`)|`claude-opus-5-5` (`high`)|-|
|`neon`|`bulk,scan`|`gemini-4-hydrogen` (`high`)|`gpt-6.2-astra` (`high`)|-|
|`carbon`|`frontend,landing_page`|`gemini-4-neon` (`high`)|`claude-opus-5-5` (`high`)|-|
|`carbon`|`bulk,scan`|`gemini-4-hydrogen` (`high`)|`gpt-6.2-astra` (`high`)|-|
|`hydrogen`|`bugfix`|`gpt-6.2-astra` (`high`)|`gemini-4-hydrogen` (`xhigh`)|-|
|`hydrogen`|`prose,paper`|`gemini-4-hydrogen` (`xhigh`)|`gpt-6.2-astra` (`high`)|`gemini-4-carbon`|
<!-- AUTO:ROUTING:END -->

## CLI (`powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\<s>.ps1"`)
- `invoke-model.ps1 -Model -Access read|write -PromptFile -WorkDir [-ContextFiles -Tags -Effort low|med|high|xhigh|max|ultra -AgySettings -OutFile -AutoRecordOk -Resume -DryRun]` (`.response`, `timings_ms`; `max`/`ultra` Astra)
- `pack-context.ps1` | `route.ps1 -Tags [-HostModel orchestrator|neon|carbon|hydrogen -BusyAgents -PreferIdle -AllowEscalation]` | `extract-files.ps1` | `selftest.ps1 [-Only <csv>] [-EstimateOnly] [-SkipTests]` | `setup|doctor|sync-docs [-Check]`

## Slim, Lean Eval & Gates
- **ETA + Tiered Tests/Review**: State **estimated runtime** before any `>5s` run. Default `L0` AST+`sync-docs -Check` (`~2s`) -> `L1` `selftest.ps1 -Only <suite>` (`~16-90s`) -> `L2` full `selftest.ps1` (`~138s`, core/release only). Reviews stay `<15KB` (`~25-45s`) post-delivery (`Ship-First`).
- **Model Eval Rule**: Local = **1 short speed ping ONLY** (`"OK"`, `timings_ms`, `~15-45s`); capability/performance scores = **online `web_search` ONLY** (never run local `probe-model.ps1 -Grade` capability tests; `references/research-protocol.md`).
- Codex skips config/34 features + injects fresh `models_cache.json` (`-FullCodexConfig`), `--ephemeral` on `-AutoRecordOk`; `agy.exe --disable-slash-commands`; `BypassSandbox` schema-only (`require_escalated`).
- Astra (`WaitMsBeforeAsync=5000`): `schedule(35s)` (`resume_invalidated`->fresh; >45s `tool_exec`->no shell). Opus (`primary_disabled`): Aesthetic/`<=800`w. Recon -> `Re-plan if` (`=====ORCHESTRA_REPLAN_REQUIRED=====`) -> Truth Gate.
- **Repair & Office Gate**: `.pptx`/`.docx`/`.xlsx` repairs use `high`/`med`, `<=2` `BypassSandbox` COM runs (ref+open -> Python diff/patch -> COM verify). No hand-rolled OOXML (`python-pptx`/`Astra` `office_plugins`); HTML/Playwright != Office open.

