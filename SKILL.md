---
name: cowork
description: Multi-model orchestration (GPT-6.2 Astra, Gemini 4 Carbon, 4H Extra, Claude Opus 5.5): host-aware routing, zero-relay Swarm, CLI slimming, KV caching. Triggers: cowork, multi-model, swarm, gpt-write, gpt-review, 4H Extra, Astra, Opus.
---
# cowork
Root: `$HOME\.gemini\config\skills\cowork` (`~/.codex/skills/cowork`) | State: `$HOME\.cowork` | Docs: `references/{collaboration-patterns,model-profiles,research-protocol}.md`, `registry/models.json`
<!-- AUTO:ROSTER:START -->
> Auto-synced from `registry/models.json` (`registry_rev: 13`, active: 4)

| Model | ID / Channel | Effort | Top Strengths (>=9) | Quota | Speed | Traits |
|---|---|---|---|---|---|---|
| **Claude Opus 5.5** | `claude-opus-5-5` (`agy`) | `high` | frontend_aesthetic (10), agentic_coding (9.5) | 1 (scarce) | 2 (medium) | Review only; tools: `web_search`, `browser` |
| **Gemini 4 Carbon** | `gemini-4-carbon` (`agy`) | `high` | long_context (10), prose (10), world_knowledge (10), agentic_coding (9) | 3 (abundant) | 2 (medium) | tools: `web_search`, `browser`, `long_context_1m` |
| **GPT-6.2 Astra** | `gpt-6.2-astra` (`codex`) | `high` (peak `xhigh`) | backend (10), code_rigor (10), image_gen (10), math (10), agentic_coding (9.5), office_docs (9.5), long_context (9) | 2 (medium) | 1 (slower) | Cockpit rotation; tools: `image_gen`, `office_plugins`, `latex`, `browser`, `computer_use` |
| **Gemini 4 Hydrogen** | `gemini-4-hydrogen` (`agy`) | `xhigh` | long_context (9.5) | 3 (abundant) | 3 (fastest) | tools: `web_search`, `browser`, `long_context_1m` |

- **Quota (Low->High)**: `claude-opus-5-5` < `gpt-6.2-astra` < `gemini-4-carbon` < `gemini-4-hydrogen`
- **Speed (Fast->Slow)**: `gemini-4-hydrogen` > `claude-opus-5-5` > `gemini-4-carbon` > `gpt-6.2-astra`
- **Pool Limits**: `codex_openai` <= 4, `agy_anthropic` <= 3, `agy_google` <= 7
<!-- AUTO:ROSTER:END -->

## Speed-First Rules
- **Skip `detect-models.ps1`** on normal tasks (`setup`/`maintain` only); **skip `route.ps1`** on table hits (call for mixed tags, `-BusyAgents`/`-PreferIdle`, `parallel_lanes`).
- **Zero-Relay `/swarm`**: Host calls `gpt-6.2-astra` & `claude-opus-5-5` directly at `T=0`; workers run local slices only (`gemini-4-hydrogen-xhigh` code/recon; `high`/`medium` monitor/scan; never `Orchestrator`; no `gatekeeper`).
- **Fast-Plan Gate**: `<5` unread/in-context = `0` external/swarm calls (`exit_plan_mode`/plan); `>=5` = max `1` sync round (no `-OutFile`, add `-AutoRecordOk`, no `schedule 35s`/`.events.jsonl`/`record-outcome.ps1`).

<!-- AUTO:ROUTING:START -->
- **Aliases**: `best-aesthetic` -> `claude-opus-5-5`, `best-image` -> `gpt-6.2-astra`, `best-knowledge` -> `gemini-4-carbon`, `best-math` -> `gpt-6.2-astra`, `best-prose` -> `gemini-4-carbon`, `best-rigor` -> `gpt-6.2-astra`
- **Default Mode**: `peak` (peak capability, zero penalty)

| Scenario | `-Tags` | Primary | Reviewer | Polisher | Pattern |
|---|---|---|---|---|---|
| Frontend/UI | `frontend,landing_page` | `gemini-4-carbon` | `claude-opus-5-5` | - | `aesthetic_gate` |
| Backend/API | `backend,concurrency` | `gpt-6.2-astra` | `gemini-4-carbon` | - | `pipelined_review` |
| Math/Algo | `math,algorithm` | `gpt-6.2-astra` (`xhigh`) | `gemini-4-carbon` | - | `pipelined_review` |
| Bugfix | `bugfix` | `gpt-6.2-astra` | `gemini-4-carbon` | - | `pipelined_review` |
| Paper/Prose | `prose,paper` | `gemini-4-carbon` | `gpt-6.2-astra` | - | `pipelined_review` |
| Image Gen | `image_gen` | `gpt-6.2-astra` | `claude-opus-5-5` | - | `strength_delegation` |
| Office/PPT | `office,ppt` | `gpt-6.2-astra` | `claude-opus-5-5` | - | `strength_delegation` |
| Repo Research | `research,long_context` | `gemini-4-carbon` | `gpt-6.2-astra` | - | `pipelined_review` |

- **`-Mode fast_4h`**: `gemini-4-carbon`->`gemini-4-hydrogen` (`xhigh`), keeping `gemini-4-carbon` for `paper`, `essay`, `copywriting`, `architecture`/`math`, `algorithm`, `architecture` & `-AllowEscalation`:

| Fast | `-Tags` | Primary | Reviewer | Escalate |
|---|---|---|---|---|
| Frontend/UI | `frontend,landing_page` | `gemini-4-hydrogen` (`xhigh`) | `claude-opus-5-5` (`high`) | `gemini-4-carbon` |
| Repo Pre-Read | `research,long_context` | `gemini-4-hydrogen` (`xhigh`) | `gpt-6.2-astra` (`high`) | `gemini-4-carbon` |
| Routine Docs | `prose` | `gemini-4-hydrogen` (`xhigh`) | `gpt-6.2-astra` (`high`) | `gemini-4-carbon` |
| Paper/Long Prose | `prose,paper` | `gemini-4-carbon` (`high`) | `gpt-6.2-astra` (`high`) | - |
| Backend/Bugfix | `bugfix` | `gpt-6.2-astra` (`high`) | `gemini-4-hydrogen` (`xhigh`) | - |
| Math/Algo | `math,algorithm` | `gpt-6.2-astra` (`xhigh`) | `gemini-4-carbon` (`high`) | - |

- **Host Tiers (`-HostModel orchestrator|carbon|hydrogen`)**: `orchestrator_fast` / `carbon_peak` / `hydrogen_max` (4H: `scan`->`medium`, `bulk/boilerplate/test_gen`->`high`, else `xhigh`):

| Host | Scenario | `-Tags` | Primary | Reviewer | Final Gate |
|---|---|---|---|---|---|
| `orchestrator` -> `orchestrator_fast` | Frontend/Dev | `frontend,landing_page` | `gemini-4-hydrogen` (`xhigh`) | `claude-opus-5-5` (`high`) | - |
| `orchestrator` -> `orchestrator_fast` | Architecture | `architecture` | `gpt-6.2-astra` (`high`) | `gemini-4-carbon` (`high`) | - |
| `carbon` -> `carbon_peak` | Flagship | `frontend,landing_page` | `gemini-4-carbon` (`high`) | `claude-opus-5-5` (`high`) | - |
| `carbon` -> `carbon_peak` | Bulk/Scan | `bulk,scan` | `gemini-4-hydrogen` (`high`) | `gpt-6.2-astra` (`high`) | - |
| `hydrogen` -> `hydrogen_max` | Bugfix | `bugfix` | `gpt-6.2-astra` (`high`) | `gemini-4-hydrogen` (`xhigh`) | - |
| `hydrogen` -> `hydrogen_max` | Paper Gate | `prose,paper` | `gemini-4-hydrogen` (`xhigh`) | `gpt-6.2-astra` (`high`) | `gemini-4-carbon` |
<!-- AUTO:ROUTING:END -->

## CLI (`powershell -NoProfile -ExecutionPolicy Bypass -File "ROOT\scripts\<s>.ps1"`)
- `invoke-model.ps1 -Model <m> -Access read|write -PromptFile <f> -WorkDir <d> [-ContextFiles -Tags -Effort -OutFile -AutoRecordOk -Resume -DryRun]` | `pack-context.ps1 -WorkDir <d> [-Files|-GitDiff [-TestLogFile]] -OutFile <f>`
- `route.ps1 -Tags <t> [-HostModel <h>] [-BusyAgents] [-PreferIdle] [-AllowEscalation]` | `extract-files.ps1 -InputFile <f> -Root <d> -AllowedPrefixes <csv>` | `setup.ps1` | `doctor.ps1 [-Repair] [-NoNetwork]` | `sync-docs.ps1 [-Check]`

## Rev 13 Defaults & Invariants
- **Slimming**: Pure Codex (`-Access read`/`-OutFile`) skips user config/rules/22 desktop features; `-AutoRecordOk` (no `-Resume`) sets `--ephemeral` + `<5ms` logging (`record-outcome.ps1` for `candidate`); `agy.exe --disable-slash-commands` skips PS wrapper + inherits proxy. Overrides: `-FullCodexConfig`, `-KeepSession`, `-EnableAgySlashCommands`, `-AllowCodexShell`, `-Ephemeral`. Omit `-OutFile` -> `.response` (`>64KB`->`.response.md`).
- **Pools & KV**: `BypassSandbox` only if in schema (`require_escalated`). Pools: `agy_google<=7`, `codex_openai<=4` (AIMD `15s->1`, `200ms` stagger, `-NoSlotWait`), `agy_anthropic<=3`. Pin `-ContextFiles <scratch>/context_pack.md`, quiet stdout, never share `-Resume`, logs `<=20`L.
- **Watchdog & Gates**: Exec Astra (`WaitMsBeforeAsync=5000`): `schedule(35s)` on `status_file.phase` (`resume_invalidated`->fresh; >45s `tool_exec`->no shell). `claude-opus-5-5` (`primary_disabled`): Aesthetic Gate/`<=800`w only. Enforce Recon, `Re-plan if` (`=====ORCHESTRA_REPLAN_REQUIRED=====`), & Truth Gate.

