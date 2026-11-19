# Cowork + Swarm Rules

1. **Fast-Plan, Zero-Relay & Ship-First (`交付优先，后置审查`)**
- Plan (`<=1`t): `<5` unread=`0` ext/swarm; `>=5`=max `1` sync (no `-OutFile`, `.response`, `-AutoRecordOk`, no `schedule`/`.events.jsonl`).
- Exec: Open `/swarm`+`/cowork` post-`exit_plan_mode`. Workers (`gemini-4-neon-high`/`gemini-4-hydrogen-xhigh`; monitor/scan `high`/`med`; no `Orchestrator`) run local slices. Host calls ONLY ready ext roles at `T=0` (0 Opus backend-only; Opus waits for UI shots/tokens; no `gatekeeper`).
- **Ship-First**: Deliver v1 post-`L0/L1` local Truth Gate; run lean reviews post-delivery (pre-block ONLY security/auth/payment/destructive or user ask).

2. **Host Routing (`-HostModel orchestrator|neon|carbon|hydrogen`)**
- `orchestrator`: ~80% Carbon->4H; Carbon keeps `architecture`/`paper/essay/copywriting`/`math/algorithm` rev.
- `neon`: default `high` (`xhigh` only `math/architecture`), `scan/bulk`->`4H`/`med`.
- `carbon`: Carbon; `scan`(med) & `bulk/boilerplate/test_gen`(high)->4H.
- `hydrogen`: 4H; `final_reviewer=gemini-4-carbon` on `paper/essay/copywriting/architecture` or `-AllowEscalation`.
- `claude-opus-5-5` (`primary_disabled=true`): Aesthetic/`<=800`w only.

3. **Single-File Repair & Office Gate**
- `.pptx`/`.docx`/`.xlsx`: `high`/`med` (no `xhigh` micro-turns); 1 `BypassSandbox` (`-NoProfile -ExecutionPolicy Bypass`) ref+open -> 1 Python diff/patch -> 1 COM verify (`<=2` approvals).
- No hand-rolled OOXML (`python-pptx` or `Astra` `office_plugins`); HTML/Playwright != real Office open.

4. **Lean Tests, Review & Model Eval (`Pre-Run ETA + Speed-Only Local`)**
- State **estimated runtime (`ETA`)** BEFORE running any test/review `>5s`.
- Tiers: `L0` AST+`sync-docs -Check` (~`2s`) -> `L1` affected suite `selftest.ps1 -Only <suite>` (~`16-90s`) -> `L2` full `selftest` (~`138s`, core/release only). Skip multi-round `>15KB` full-diff reviews (~`25-45s` compact summary only when needed).
- **Model Eval**: Local = **1 short speed ping ONLY** (`"Reply ONLY with: OK"`, ~`15-45s`, `timings_ms`). Capabilities = **`web_search` ONLY** (never run local `probe-model.ps1 -Grade` capability tests).

5. **KV Cache & Pools**
- 4H `-Tags scan`(med)->`context_pack.md`; `-ContextFiles` top KV, quiet stdout, fresh sessions (no `-Resume` share), logs `<=20`L.
- Pools: `agy_google<=7`, `codex_openai<=4` (AIMD `15s->1`), `agy_anthropic<=3`, `200ms` stagger.

