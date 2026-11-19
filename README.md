# cowork

Multi-model orchestration for **Antigravity (`agy`)**, **Codex CLI**, and **`/swarm`**: Fast-Plan Gate (`<5` unread = 0 external/swarm calls), **Ship-First Async Review**, Zero-Relay `/swarm`, `-HostModel orchestrator|neon|carbon|hydrogen` routing, Single-File Office Repair Fast-Path, CLI slimming, 7/4/3 AIMD pools, and KV caching.

## Active Roster

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

### Capability Aliases & Auto-Routing

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

## Highlights (Rev 15)

- **Gemini 4 Neon (`neon_peak`) & `max`/`ultra` Efforts**: Onboards `gemini-4-neon` (`high` default, `xhigh` only on `math`/`architecture`, mechanical `bulk`/`scan` -> `4H`) alongside `orchestrator_fast`/`carbon_peak`/`hydrogen_max`, and enables Codex/Astra `max`/`ultra` effort tiers (`low|medium|high|xhigh|max|ultra`).
- **Ship-First, Async-Review-After (`交付优先，后置审查`)**: Deliver usable v1 immediately once the fast local Truth Gate (build/tests/real-app open) passes; run slow external cross-model reviews (`Astra` `code_rigor`, `Opus` Aesthetic Gate, `Carbon` prose) post-delivery as an async polish pass (pre-block only for security/auth/payment/destructive actions or explicit user request).
- **Single-File Repair Fast-Path & Real-App Office Truth Gate**: Deterministic `.pptx`/`.docx`/`.xlsx` repairs stay on `high`/`medium` (no `xhigh` micro-turns) with `<=2` `BypassSandbox` PowerPoint/Office COM approvals (ref+open -> 1 Python structural diff/patch -> final COM verify). Never hand-roll raw OOXML XML (install `python-pptx` or delegate `Astra` `office_plugins`); HTML/Playwright previews never replace real Office open verification.
- **Speed-First, Zero-Relay `/swarm` & 7/4/3 Pools**: Skip `detect-models.ps1` and `route.ps1` on table hits. Plan Mode `<5` unread = `0` external/swarm calls; `>=5` = max `1` sync round. Host calls ONLY ready selected external roles at `T=0`; `$HOME\.cowork\slots` enforces `agy_google<=7`, `codex_openai<=4`, `agy_anthropic<=3` (`200ms` stagger, `15s` Codex AIMD cooldown).
- **CLI Slimming, KV Cache & Telemetry**: Pure Codex skips user config/rules/host skills (`-FullCodexConfig` overrides) + auto `--ephemeral` on `-AutoRecordOk` without `-Resume` (`-KeepSession` overrides); `agy.exe --disable-slash-commands` (supports `-AgySettings`). Silent `.events.jsonl`, `timings_ms` milestones, & pinned `-ContextFiles` maximize `cached_tokens`.

## Structure

`SKILL.md` | `integrations/cowork-orchestrator-plugin/` | `registry/` | `references/` (`collaboration-patterns.md`, `model-profiles.md`, `research-protocol.md`) | `scripts/` (`setup.ps1`, `route.ps1`, `invoke-model.ps1`, `pack-context.ps1`, `sync-docs.ps1`, `doctor.ps1`, `maintain.ps1`, `selftest.ps1`) | `tests/`

## Setup & Test

```powershell
git clone https://github.com/daidai1215/cowork.git "$HOME\.gemini\config\skills\cowork"
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\setup.ps1" -Models neon,carbon,6.2astra,4h,opus5.5 -ReviewOnlyModels opus5.5 -Evaluate auto
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\selftest.ps1"
```

- **Prereqs & Privacy**: Codex CLI (`>= 0.153.0`) and/or `agy.exe` (`MODEL_ORCHESTRA_AGY_WRAPPER`); `setup.ps1` supports `-Interactive`, `-ListAvailable`, `-SkipGlobalPlugin`, `-Evaluate`. Runtime state stays in `$HOME\.cowork\`; Cockpit rotation checks `auth.json` mtime + SHA-256 only (never parses/logs tokens).
