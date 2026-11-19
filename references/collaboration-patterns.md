# Collaboration Patterns & Templates

**Host** (recon, contracts, verification, replanning) | **Author** (disjoint prefix implementer) | **Active Verifier** (heterogeneous test/audit reviewer; never edits author files).

## 0. Core Invariants
1. **Fast-Plan Gate (`plan_external_min_unread_files=5`)**: `<5` unread/in-context = `0` external/swarm calls; `>=5` = max `1` sync round without `-OutFile` (inline `.response`, `>64KB`->`.response.md`) + `-AutoRecordOk` (no `schedule 35s`/`.events.jsonl`/`record-outcome.ps1`).
2. **Zero-Relay Execution & Ship-First (`交付优先，后置审查`)**: Post-`exit_plan_mode`, open `/swarm` + `/cowork`. Host calls ONLY selected external roles whose inputs are ready at `T=0` (0 Opus on backend-only; Opus Aesthetic Gate waits for UI screenshots/tokens; `slots` caps concurrency); workers (`gemini-4-neon-high` or `gemini-4-hydrogen-xhigh` code/recon/tests; `high`/`medium` monitor/scan; never `Orchestrator`) run local slices only (no `gatekeeper`). Once v1 passes the fast local Truth Gate (build/tests/real-app open), **deliver v1 immediately** and run slow external cross-model reviews (`Astra` `code_rigor`, `Opus` Aesthetic Gate, `Carbon` prose) post-delivery as an async polish pass (block pre-delivery ONLY for security/auth/payment/destructive actions or explicit user request).
3. **Host Modes (`-HostModel orchestrator|neon|carbon|hydrogen`)**: `orchestrator_fast` offloads ~80% Carbon->`4H` (Carbon keeps `architecture`, `paper/essay/copywriting`, `math/algorithm` review); `neon_peak` runs `gemini-4-neon` at `high` (`xhigh` only on `math`/`architecture`), offloading `scan` (`medium`) + `bulk/boilerplate/test_gen` (`high`) to `4H`; `carbon_peak` keeps Carbon with the same `4H` offload; `hydrogen_max` runs `4H` (`final_reviewer=gemini-4-carbon` on `paper/essay/copywriting/architecture` or `-AllowEscalation`).
4. **Pools & Efforts**: Gemini (`Neon`/`Carbon`/`4H`) shares Antigravity (`4H` = ~2.5x speed); Claude (`claude-opus-5-5`, `primary_disabled=true`) is scarce (Aesthetic Gate/`<=800`w); Codex (`gpt-6.2-astra`, supports `low|medium|high|xhigh|max|ultra`) uses external OpenAI + Cockpit `auth.json` rotation (`<=4`, `200ms` stagger, AIMD `15s->1`).
5. **Gates**: Recon (`context_pack.md` + `plan_contract.md`) -> Disjoint Shards (`extract-files.ps1` exit `2`) -> `Re-plan if` (`=====ORCHESTRA_REPLAN_REQUIRED=====` exit `3`) -> Zero Defensive Prose -> Truth Gate -> Outcome log (`-AutoRecordOk`/`record-outcome.ps1`).

## 1. Delegate-Execute
1. Recon (`4H`/`Carbon` `-Access read`) -> `<scratch>/plan_contract.md`.
2. Author: `gpt-6.2-astra` runs `-Access read -OutFile` (pure-brain `--disable shell_tool --disable unified_exec`), emits `=====FILE: <path>=====` -> `extract-files.ps1` atomic apply (on `resume_invalidated=true`, restart without `-Resume`); `agy` uses `-Access write`.
3. Active Verifier + host run Verification Gate (`-AllowEscalation` on failures).

## 2. Pipelined Review + Disjoint Sharding
1. Disjoint shards (`1..K`) + read-only contract pre-review -> `<scratch>/plan_contract.md`.
2. Parallel shards -> fresh heterogeneous Active Verifier per shard (no `-Resume`; never edits author files) -> `<scratch>/shard_<n>_review.md` with >=2 counterexamples & test runs.
3. Final cross-shard audit (`Blocker/Major/Minor`); bounce Blockers/Majors to original author.

## 3. Dual-Draft Synthesis (Best-of-2)
For `dual_draft_eligible=true` (`algorithm`, `concurrency`, `bugfix`, `math`): launch parallel `gpt-6.2-astra` + `gemini-4-carbon`/`4H Extra` from shared `plan_contract.md` -> run unit/stress benchmarks -> adopt winner + edge fixes (send `<=800`w summary to `claude-opus-5-5` if tied).

## 4. Aesthetic Gate (UI)
1. `Carbon`/`4H Extra` writes UI + tokens -> capture `1440/768/390` screenshots.
2. Send ONLY screenshots, tokens & key snippets to `claude-opus-5-5` (`high`, `-Access read`) for 6-axis score + tokens + `<=10` CSS edits (max 2 rounds; fallback: fresh Carbon session).
- **6-Item Checklist**: (1) single focal point/screen, heading/body >=1.25; (2) 4/8px spacing rhythm; (3) <=5 colors, >=WCAG AA; (4) line-height 1.4-1.6 EN / 1.6-1.8 ZH, 35-75 chars/line; (5) <=3 radii/shadow tiers + hover/focus/active; (6) distinctive non-template visual anchor.

## 5. Strength Delegation
| Subtask | Owner | Note |
|---|---|---|
| `image_gen` / mockups / alpha | `gpt-6.2-astra` (`high`) | Codex-only (`image_gen`); copy to repo |
| PPT / Word / Excel / LaTeX / desktop | `gpt-6.2-astra` (`high`) | Pair slides with Aesthetic Gate |
| Hard `math` / concurrency / deep bugs | `gpt-6.2-astra` (`xhigh`; `max`/`ultra` for extreme cases) | Dual-Draft eligible |
| General coding / architecture / long-context | `gemini-4-neon` (`high`; `xhigh` only `math`/`architecture`) | `neon_peak` flagship; offload `bulk`/`scan` to `4H` |
| High-bar `paper` / `essay` / `copywriting` | `gemini-4-carbon` (`high`) | Final prose polish & anti-AI-tone |
| `scan` / `bulk` / `boilerplate` / `test_gen` | `gemini-4-hydrogen` (`medium`/`high`/`xhigh`) | `scan`=`medium`, mechanical=`high`, code=`xhigh` |

## 6. Truth Gate, Lean Review, Pre-Run ETA & Office Fast-Path
- **Truth Gate**: Verify DOIs, stats, theorem preconditions, APIs, and benchmarks via host `search_web`/authority DB/execution check.
- **Pre-Run ETA & Tiered Verification**: State estimated runtime before running any `>5s` test/review. Use `L0` AST+`sync-docs -Check` (`~2s`) -> `L1` affected suite (`selftest.ps1 -Only <suite>`, `~16-90s`) -> `L2` full `selftest.ps1` (`~138s`, core/release only).
- **Ship-First, Lean Async Review (`交付优先，后置审查`)**: Ship usable v1 right after local `L0/L1` verification passes; if an external review is needed, send a `<15KB` focused summary (`~25-45s`) post-delivery rather than `800KB` full-diff multi-round loops (pre-delivery blocking applies only to security/auth/payment/destructive actions or explicit user request).
- **Model Evaluation Rule (Speed-Only Local + Web Capability)**: For new/updated models, run ONLY 1 short local speed ping (`"Reply ONLY with exact token: OK"`, `~15-45s`) for `timings_ms` + thinking ratio; obtain all capability/benchmark scores via **`web_search` ONLY** (never run local `probe-model.ps1 -Grade` capability suites).
- **Single-File Deterministic Repair Fast-Path**: For broken `.pptx`/`.docx`/`.xlsx` files, use `high`/`medium` (never `xhigh` micro-turns) and batch into `<=2` `BypassSandbox` (`-NoProfile -ExecutionPolicy Bypass`) COM approvals: (1) 1 COM script generating a 1-slide reference file + testing open on target -> (2) 1 Python structural diff & atomic patch (root tags, `[Content_Types].xml`, `.rels`, duplicate theme refs) -> (3) 1 final Office COM open + render verification.
- **Real-App Office Truth Gate**: Never hand-roll raw OOXML XML strings when generating Office files (install `python-pptx` or delegate to `gpt-6.2-astra` `office_plugins`); HTML/Playwright previews never replace real Office open verification.

## 7. Two-Tier Context Hygiene & Clean Handoff
1. **Tier 1**: Max `1` quick local tooling fix; on failure, isolate in `invoke_subagent(TypeName="self", Role="Tooling Debugger", ...)` (or non-resume Codex child), returning ONLY `Status | Modified Files | Verification Evidence | Residual Constraints`.
2. **Tier 2**: At stage gates or repeated drift, write `<scratch>/handoff.md` (Template E; no raw `stderr`; dead ends as `Method | Failed Precondition | Evidence | Retry Condition`) and start a fresh conversation.

## 8. Zero-Relay Swarm + Cowork
- Post-`exit_plan_mode`, host opens `/swarm` + `/cowork` and calls ONLY external roles selected for the task whose inputs are ready at `T=0` (`gpt-6.2-astra <=4` when ready; zero Opus on backend-only work; Opus Aesthetic Gate `<=3` waits until UI output/screenshots/tokens exist; `slots` enforces caps; no `gatekeeper`).
- Workers (`gemini-4-neon-high` or `gemini-4-hydrogen-xhigh` code/recon/tests; `high`/`medium` monitor/scan; never `Orchestrator`) run local `workspace:"share"` slices only, with unique `-StatusFile`, quiet stdout, `-ContextFiles`, fresh sessions (no shared `-Resume`), and `#seq` peer mentions.

## 9. KV Prefix Cache & CLI Cold-Boot Slimming
1. **Static Pack**: Build `<scratch>/context_pack.md` via `pack-context.ps1` or `4H` `-Tags scan` (`medium`).
2. **CLI Slimming Defaults**: Pure Codex (`-Access read`/`-OutFile`, no `-AllowCodexShell`) emits `--ignore-user-config --ignore-rules`, scalar `-c` (never `auth.json`), `--enable skip_host_skill_discovery`, `--enable omit_skill_descriptions`, & disables 34 desktop/plugin features (`-FullCodexConfig` overrides). `-Ephemeral`/`-AutoRecordOk` without `-Resume` sets `--ephemeral` (`-KeepSession` overrides); `-AutoRecordOk` logs `active` runs `<5ms` in-process (`record-outcome.ps1` for `candidate` only). Direct `agy.exe --disable-slash-commands` skips PS wrapper, inherits proxy + `NODE_USE_ENV_PROXY=1` (`-EnableAgySlashCommands`), & supports `-AgySettings <json|path>` (`--settings`).
3. **`-ContextFiles`, Quiet Stdout & Milestones**: Pins static packs (`=====CONTEXT_PACK: ...=====`) above `=====TASK_INSTRUCTIONS=====` (`--add-dir` on Codex) for KV hits (`cached_tokens`, `cache_hit_rate`). Quiet stdout writes `.events.jsonl` (`7d` prune; `-StreamStdout` for debug); `timings_ms` exposes `slot_wait_ms`, `spawn_to_first_event_ms`, `first_event_to_done_ms`, & `total_ms`.
4. **Cache Hygiene**: Never share `-Resume` across parallel workers (fresh + `-ContextFiles`). Use `fork` for shared exploration prefixes; park idle workers `waiting` (`0` tokens); cap test logs at `<=20` lines.

## 10. Multi-Pool 7/4/3 Balancing, LPT & SDM/TDM
1. **Semaphore, AIMD & 200ms Stagger**: `$HOME\.cowork\slots\*.json` caps `agy_google<=7`, `codex_openai<=4`, `agy_anthropic<=3` (reclaims dead PIDs/`>7200s`; `doctor.ps1 slot_hygiene`). AIMD `_codex_rotation_cooldown.meta` (`15s`) drops `codex_openai` to `1` on 429/rotation, rebounding to `4` on `thread.started`. `launch_stagger_ms=200` staggers active launches. `-SlotWaitSec 300` queues `queued_slot` before Codex handshake timer (`-NoSlotWait` exit `5`).
2. **`route.ps1 -BusyAgents -PreferIdle`**: Overlays live slots + `-BusyAgents` (`pool_load`, `scale_out_hint`, `parallel_lanes`); `-PreferIdle` shifts saturated pools while enforcing `min_cap`, `primary_disabled`, `hard_rules`.
3. **LPT + SDM/TDM**: When `<2` active, launch LPT (`Astra`) + `4H` `tests/`/`context_pack.md` at `T=0`, overlap `Opus` at `T=1`. Enforce SDM (`workspace:"share"`, `extract-files.ps1`, `waiting` stealing) & TDM (`Write->Review->Fix` slices: local tests first, then `pack-context.ps1 -GitDiff -TestLogFile <log>`, `<=20` lines).

## Templates A-E
### A. `<scratch>/plan_contract.md`
```markdown
# Plan Contract: <Task>
- AllowedPrefixes / ForbiddenPrefixes: <csv> | <csv>
- Invariants & Pitfalls: <signatures, constraints>
- Ordered Steps: <file/symbol edits>
- Verification Gate: `<cmd>` -> `<pass criteria>`
- Re-plan if: <invalidating conditions>
```
### B. Executor Contract
```text
Edit ONLY within AllowedPrefixes (<csv>); never touch ForbiddenPrefixes (<csv>). Contract: <inline>
If Re-plan if holds, STOP and emit only:
=====ORCHESTRA_REPLAN_REQUIRED=====
trigger: <clause> | evidence: <conflict> | impact: <slice>
=====END ORCHESTRA_REPLAN_REQUIRED=====
Else emit =====FILE: <relpath>===== ... =====END FILE===== + =====NOTES=====.
```
### C. Active Verifier (Read-Only)
```text
Read-only independent verifier. Never modify files. Contract & Diff: <inline>
Audit edge/null/concurrency/signatures, construct >=2 counterexamples & run read-only checks, flag Truth Gate items.
Format: Blocker/Major/Minor ("Issue -> Repro -> Fix"), <= <N>w. No defensive caveats.
```
### D. Opus Aesthetic Gate / Tie-Break (`<=600`w)
```text
Input: <3 screenshots + tokens + snippets> OR <Draft A vs B <=800w>.
Aesthetic: 6-axis scores (1-10) + tokens JSON + <=10 CSS edits. Tie-Break: winner/split, <=3 reasons, 1-2 risks.
```
### E. `<scratch>/handoff.md`
```markdown
# Clean Handoff: <Task>
- Goal & Gate: `<cmd>` -> `<expected>` | Hard Constraints: <list>
- Verified State: `<repo>@<branch>(<sha>)`, artifacts, git status, active env limits (no stderr)
- Dead Ends: `<Method> | <Failed Precondition> | <Evidence> | <Retry Condition>`
- Next Step: verify state, then `<action>`
```
