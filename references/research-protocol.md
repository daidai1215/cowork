# Research Protocol (Web Capability + Local Speed Only)

> Prompt template for `scripts/research-prompt.ps1` (auto-replaces `{{...}}` placeholders).
> **Policy**: Score capabilities from **online sources ONLY** (`web_search`, official model cards, Artificial Analysis, LMArena, Terminal-Bench). Locally, run at most **1 short speed/connectivity ping** (`"Reply ONLY with exact token: OK"`, ETA `~15-45s`) to check `timings_ms` and thinking ratio — **do NOT run local multi-question capability probes** (`probe-model.ps1 -Grade`).

---

## Research Prompt (Template Starts Here)

You are an AI model benchmark analyst. Today is {{TODAY}}. Perform **web research ONLY** on the model below and output valid JSON matching the given schema only.

- Target model slug: `{{MODEL_ID}}`
- Mode: `{{MODE}}` (`new` = initial profile; `refresh` = 30-day delta refresh since last review)
- Capability dimensions (score all): {{CAP_DIMENSIONS}}
- Current incumbents per dimension (calibration baseline):
{{INCUMBENTS}}

### Required Web Sources (check >=1 per category; record misses as "not found" in `sources_checked`)
1. **Official**: release blog, model/system card, API docs, pricing, rate limits, quotas.
2. **Leaderboards**: Artificial Analysis (Intelligence Index, tok/s, pricing), LMArena, BenchLM.
3. **Domain Benchmarks**:
   - `code_rigor`/`backend`/`agentic_coding`: SWE-bench (Verified/Pro), DeepSWE, Terminal-Bench, Aider Polyglot
   - `math`: AIME, FrontierMath, HMMT
   - `frontend_aesthetic`: WebDev Arena, Design Arena
   - `prose`: Creative Writing / EQ-Bench, long-form evals
   - `world_knowledge`: SimpleQA, GPQA, HLE
   - `long_context`: MRCR, RULER, context window spec
   - `image_gen`: native image generation & Image Arena
   - `office_docs`: native Office / PPT tooling
4. **Community**: Reddit (r/LocalLLaMA, r/ClaudeAI, r/OpenAI, r/Bard), Hacker News, X -- note concrete wins/regressions.
5. **Head-to-Head**: direct comparisons against the incumbents listed above.

### Scoring Rules
- Scale `0..10`, anchored to incumbent scores above (`vs_incumbent = score - incumbent_score`).
- Unsupported capabilities (e.g., no native image gen): `score = 0`, `confidence = 0.8`.
- `confidence`: official claims only `0.5`; single independent benchmark `0.6-0.7`; multiple independent sources `0.8+`; rumors `<=0.4`.
- Each dimension needs `evidence` (`url`, concise `claim` with metrics, `date`). **Never fabricate URLs or numbers**; if missing, emit `[]` and `confidence <= 0.3`.
- `speed_rank_hint` / `quota_rank_hint`: `1..3` (`3` = fastest / most abundant).
- `channel`: `codex` (OpenAI) or `agy` (Antigravity Gemini/Claude/etc.).
- `supersedes`: direct predecessor model ID if replacing one, else `null`.
- `suggested_hard_rules`: only for unique native capabilities.

### Output
Valid JSON matching the schema ONLY (no markdown fences or commentary).

---

## Host Post-Research Steps (Lean)

1. **Pre-Run ETA**: Tell the user before any `>5s` check (`web_search` ~5-15s; optional 1-shot speed ping ~15-45s).
2. **Optional 1-Shot Speed Ping (Local, NO Capability Probing)**: Run ONE short `invoke-model.ps1 -Model <id>` (or `-AdHocChannel <agy|codex> -AdHocModelFlag <slug>`) `-Access read -Prompt "Reply ONLY with exact token: OK"` with a temp `-StateDir` to record `timings_ms` and confirm availability. Never run `probe-model.ps1 -Grade` locally for routine scoring.
3. **Spot Check**: Verify high-impact claims with `search_web` if any web metric looks inconsistent; skip multi-round full-file cross-checks unless sources directly conflict.
4. **Apply**: `apply-research.ps1 -ResearchFile research-<id>.json` (or direct `models.json` registry update + `sync-docs.ps1`), then report pending `registry/proposals/*.json` if any.
