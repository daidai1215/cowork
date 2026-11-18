# Cowork + Swarm Rules

1. **Fast-Plan & Zero-Relay Execution**
- Plan Mode (`<=1` turn): `<5` unread files/in-context = `0` external/swarm calls (plan/`exit_plan_mode`). `>=5` unread = max `1` sync call: omit `-OutFile`, read `.response`, `-AutoRecordOk` (no `schedule 35s`/`.events.jsonl`/`record-outcome.ps1`).
- Execution: Open `/swarm`+`/cowork` post-`exit_plan_mode`. Workers run local slices (`gemini-4-hydrogen-xhigh`; monitor/scan `high`/`medium`; never `Orchestrator`). Host calls ONLY selected external roles whose inputs are ready at `T=0` (0 Opus on backend-only; Opus Aesthetic Gate waits for UI screenshots/tokens; no `gatekeeper`).

2. **Host Routing (`-HostModel orchestrator|carbon|hydrogen`)**
- `orchestrator`: ~80% Carbon->4H Extra; Carbon keeps `architecture`, `paper/essay/copywriting`, `math/algorithm` review.
- `carbon`: Carbon primary; `scan`(medium) & `bulk/boilerplate/test_gen`(high)->4H.
- `hydrogen`: Gemini on 4H; `final_reviewer=gemini-4-carbon` only on `paper/essay/copywriting/architecture` or `-AllowEscalation`.
- `claude-opus-5-5` (`primary_disabled=true`): Aesthetic Gate/`<=800`w only.

3. **KV Cache & Pools**
- 4H `-Tags scan`(medium)->`<scratch>/context_pack.md`; `-ContextFiles` top KV, quiet stdout, fresh sessions (never share `-Resume`), logs `<=20` lines.
- Pools: `agy_google<=7`, `codex_openai<=4` (AIMD `15s->1`), `agy_anthropic<=3`, `200ms` stagger.
