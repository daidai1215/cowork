---
name: cowork
description: Multi-model orchestration (Astra, Carbon, 4H Extra, Opus 5.5): host routing, zero-relay Swarm, CLI slimming, KV cache. Triggers: cowork, multi-model, swarm, gpt-write, gpt-review, 4H Extra, Astra, Opus.
---
# cowork
Root: `~/.gemini/config/skills/cowork` | State: `~/.cowork` | Policy: `AGENTS.md`, `references/`
<!-- AUTO:ROSTER:START -->
> Auto-synced from `registry/models.json` (`registry_rev: 14`, active: 4)

|Model|ID (Ch)|Effort|Strengths (>=9)|Q|S|Traits|
|---|---|---|---|---|---|---|
|**Claude Opus 5.5**|`claude-opus-5-5` (`agy`)|`high`|frontend_aesthetic(10), agentic_coding(9.5)|1|2|Review only; `web_search`, `browser`|
|**Gemini 4 Carbon**|`gemini-4-carbon` (`agy`)|`high`|long_context(10), prose(10), world_knowledge(10), agentic_coding(9)|3|2|`web_search`, `browser`, `long_context_1m`|
|**GPT-6.2 Astra**|`gpt-6.2-astra` (`codex`)|`high`/`xhigh`|backend(10), code_rigor(10), image_gen(10), math(10), agentic_coding(9.5), office_docs(9.5), long_context(9)|2|1|Cockpit; `image_gen`, `office_plugins`, `latex`, `browser`, `computer_use`|
|**Gemini 4 Hydrogen**|`gemini-4-hydrogen` (`agy`)|`xhigh`|long_context(9.5)|3|3|`web_search`, `browser`, `long_context_1m`|

- **Pools**: `codex_openai`<=4, `agy_anthropic`<=3, `agy_google`<=7
<!-- AUTO:ROSTER:END -->

## Dispatch (`AGENTS.md`: Fast-Plan, Pools, KV)
Skip `detect-models.ps1` & table-hit `route.ps1`. Direct `T=0` calls launch ONLY selected external roles with ready inputs (0 Opus backend-only; Opus waits for UI screenshots/tokens). Workers run local slices.

<!-- AUTO:ROUTING:START -->
- **Mode**: `peak` | **Aliases**: `best-aesthetic`->`claude-opus-5-5`, `best-image`->`gpt-6.2-astra`, `best-knowledge`->`gemini-4-carbon`, `best-math`->`gpt-6.2-astra`, `best-prose`->`gemini-4-carbon`, `best-rigor`->`gpt-6.2-astra`

|`-Tags`|Primary|Reviewer|Pattern|
|---|---|---|---|
|`frontend,landing_page`|`gemini-4-carbon`|`claude-opus-5-5`|`aesthetic_gate`|
|`backend,concurrency`|`gpt-6.2-astra`|`gemini-4-carbon`|`pipelined_review`|
|`math,algorithm`|`gpt-6.2-astra` (`xhigh`)|`gemini-4-carbon`|`pipelined_review`|
|`bugfix`|`gpt-6.2-astra`|`gemini-4-carbon`|`pipelined_review`|
|`prose,paper`|`gemini-4-carbon`|`gpt-6.2-astra`|`pipelined_review`|
|`image_gen`|`gpt-6.2-astra`|`claude-opus-5-5`|`strength_delegation`|
|`office,ppt`|`gpt-6.2-astra`|`claude-opus-5-5`|`strength_delegation`|
|`research,long_context`|`gemini-4-carbon`|`gpt-6.2-astra`|`pipelined_review`|

- **`-Mode fast_4h`**: `gemini-4-carbon`->`gemini-4-hydrogen` (`xhigh`), except `paper/essay/copywriting/architecture` (`math/algorithm/architecture` rev) & `-AllowEscalation`.

- **Host Tiers (`-HostModel`)**: `orchestrator_fast`/`carbon_peak`/`hydrogen_max` (`4H`: `scan`->`med`, `bulk`/`boilerplate`/`test_gen`->`high`, else `xhigh`):

|Host|`-Tags`|Primary|Reviewer|Gate|
|---|---|---|---|---|
|`orchestrator`|`frontend,landing_page`|`gemini-4-hydrogen` (`xhigh`)|`claude-opus-5-5` (`high`)|-|
|`orchestrator`|`architecture`|`gpt-6.2-astra` (`high`)|`gemini-4-carbon` (`high`)|-|
|`carbon`|`frontend,landing_page`|`gemini-4-carbon` (`high`)|`claude-opus-5-5` (`high`)|-|
|`carbon`|`bulk,scan`|`gemini-4-hydrogen` (`high`)|`gpt-6.2-astra` (`high`)|-|
|`hydrogen`|`bugfix`|`gpt-6.2-astra` (`high`)|`gemini-4-hydrogen` (`xhigh`)|-|
|`hydrogen`|`prose,paper`|`gemini-4-hydrogen` (`xhigh`)|`gpt-6.2-astra` (`high`)|`gemini-4-carbon`|
<!-- AUTO:ROUTING:END -->

## CLI (`powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\<s>.ps1"`)
- `invoke-model.ps1 -Model -Access read|write -PromptFile -WorkDir [-ContextFiles -Tags -Effort -AgySettings <json|path> -OutFile -AutoRecordOk -Resume -DryRun]` (`.response`/`>64KB`->`.response.md`, `timings_ms`)
- `pack-context.ps1 -WorkDir [-Files|-GitDiff [-TestLogFile]] -OutFile` | `route.ps1 -Tags [-HostModel -BusyAgents -PreferIdle -AllowEscalation]` | `extract-files.ps1 -InputFile -Root -AllowedPrefixes` | `setup|doctor|sync-docs [-Check]`

## Slim, Watchdog & Gates
- Pure Codex skips config/34 features (`-FullCodexConfig`); `-AutoRecordOk` sets `--ephemeral` (`-KeepSession`); `agy.exe --disable-slash-commands` (`-EnableAgySlashCommands`); `BypassSandbox` schema-only (`require_escalated`).
- Astra (`WaitMsBeforeAsync=5000`): `schedule(35s)` on `status_file.phase` (`resume_invalidated`->fresh; >45s `tool_exec`->no shell). `claude-opus-5-5` (`primary_disabled`): Aesthetic/`<=800`w only. Recon -> `Re-plan if` (`=====ORCHESTRA_REPLAN_REQUIRED=====`) -> Truth Gate.

