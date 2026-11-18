# Cowork changelog

## 2026-11-18T12:55:00.0000000Z - Pool concurrency upgrade (`7 / 4 / 3`), AIMD Codex rotation cooldown, and 200ms launch stagger
- registry_rev: 9 -> 10
- updated `policy.pool_concurrency_limits` to `{ "agy_google": 7, "codex_openai": 4, "agy_anthropic": 3 }`
- added `policy.launch_stagger_ms=200` and `policy.codex_rotation_cooldown_sec=15`
- updated `route.ps1` fallback limits (`7/4/3`), AIMD `rotation_cooldown` / `configured_limit` propagation, and `codex_pool_saturated` hint (`<=4 slots`, AIMD `1` during rotation)
- backup: registry/history/models-20261118-205200-9-pre10.json

## 2026-11-18T11:25:00.0000000Z - Multi-pool concurrency limits, load-aware routing (`-BusyAgents`, `-PreferIdle`, `parallel_lanes`), and SDM/TDM slot leasing
- registry_rev: 8 -> 9
- added `policy.pool_concurrency_limits` (`codex_openai=2`, `agy_anthropic=2`, `agy_google=6`)
- updated `route.ps1` with live slot load tracking, `-BusyAgents` / `-PreferIdle` safe load balancing (honoring `min_cap`, `primary_disabled`, `hard_rules`), `orchestration.pool_load`, `orchestration.scale_out_hint`, and `orchestration.parallel_lanes`
- backup: registry/history/models-20261118-192000-8-pre9.json

## 2026-11-18T10:30:00.0000000Z - Host-aware three-tier routing (`orchestrator_fast`, `carbon_peak`, `hydrogen_max`), mechanical `high` tier, and `final_reviewer` gate
- registry_rev: 7 -> 8
- added tags: `bulk`, `boilerplate`, `scan`, `test_gen`, and `architecture` (`min_cap=8.5`)
- added host-aware modes `orchestrator_fast` (`lambda_q=0.0, lambda_s=0.2`), `carbon_peak` (`lambda_q=0.0, lambda_s=0.0`), and `hydrogen_max` (`lambda_q=0.0, lambda_s=0.25`)
- added `policy.host_mode_map`, `policy.mechanical_fast_tags`, `policy.carbon_peak_offload_tags`, `policy.hydrogen_max_policy` (`final_review_triggers=["paper","essay","copywriting","architecture"]`), and added `architecture` to `fast_workhorse_map` retention tags
- backup: registry/history/models-20261118-183000-7-pre8.json

## 2026-11-18T08:40:00.0000000Z - Upgrade gpt-6-astra -> gpt-6.2-astra, add gemini-4-hydrogen (4H Extra / fast_4h tier), and Swarm cowork bridge
- registry_rev: 6 -> 7
- replaced `gpt-6-astra` (`retired`) with evaluated `gpt-6.2-astra` (`active`, `high` / peak `xhigh`, `aliases` rebound: `best-rigor`, `best-math`, `best-image`)
- added `gemini-4-hydrogen` (`4H Extra`, default `xhigh`, `speed_rank=3`, `quota_rank=3`, `escalate_to=gemini-4-carbon`) and calibrated `gemini-4-carbon` (`speed_rank=2`)
- added mode `fast_4h` (`lambda_q=0.0, lambda_s=0.2`) and `policy.fast_workhorse_map` offloading routine Carbon tasks to 4H Extra while reserving Carbon for high-bar `paper`/`essay`/`copywriting`, `math`/`algorithm` verification, and `-AllowEscalation`
- backup: registry/history/models-20261118-164000-6-pre62h.json

## 2026-11-18T07:55:57.2789440Z - Roster setup: gemini-4-carbon, gpt-6.2-astra, claude-opus-5-5
- registry_rev: 5 -> 6
- active models: gemini-4-carbon, gpt-6.2-astra, claude-opus-5-5
- review-only models: claude-opus-5-5
- backup: registry/history/models-20261118-075557-5-setup.json

## 2026-11-13T03:12:00.0000000Z - Codex fast-connect, proxy auto-injection, pure-brain mode, and phase heartbeat
- registry_rev: 4 -> 5
- narrowed `policy.peak_effort_tags` to `["math"]` so routine `bugfix`/`concurrency`/`algorithm` run at fast `high` effort (with `-AllowEscalation` boosting to `xhigh`)
- added `connect_timeout_sec=25` and `reconnect_abort_count=2` to `gpt-6-astra.invoke`
- disabled `unbounded_connection_retries` and default `shell_tool`/`unified_exec` on read-only/pure-brain Codex runs, with dynamic Windows `HKCU` proxy injection, 1.2s local proxy TCP fast pre-check, and `~/.cowork/live/` status heartbeat
- backup: registry/history/models-20261113-111200-4-fast-codex.json

## 2026-11-13T01:05:00.0000000Z - Performance-first orchestration upgrade (Orchestrator principles)
- registry_rev: 3 -> 4
- added mode `peak` (`lambda_q=0.0, lambda_s=0.0`) as `policy.default_mode`
- configured `gpt-6-astra` `invoke.peak_effort="xhigh"` for `math`, `concurrency`, `algorithm`, `bugfix`, and escalation
- locked `claude-opus-5-5` `primary_disabled=true` (strictly reserved for Aesthetic Gate, review, and compact arbitration)
- configured `policy.dual_draft_tags` for heterogeneous Best-of-2 competitive synthesis
- backup: registry/history/models-20261113-090500-3-perf.json

## 2026-11-10T19:47:00.0000000Z - Roster update: 3-flagship high lineup & Cockpit rotation
- registry_rev: 2 -> 3
- active models: gpt-6-astra (high, account_rotation=true), claude-opus-5-5 (high), gemini-4-carbon (high, promoted to active)
- retired to baseline_slugs: gpt-6.1-sol, gemini-4-argon
- backup: registry/history/models-20261110-194600-2-roster.json

## 2026-11-10T15:51:41.4698315Z - Research: gemini-4-carbon
- registry_rev: 1 -> 2
- backup: registry/history/models-20261110-155141-1-78fd.json

## 2026-11-10T15:51:41.5474493Z - Applied research: gemini-4-carbon
- Registry revision: 2
- Automatic changes: 1
- Proposals: 8
- Backup: registry/history/models-20261110-155141-1-78fd.json

