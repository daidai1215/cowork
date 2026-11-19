# Cowork changelog

## 2026-11-19T06:25:00.0000000Z - Onboard `gemini-4-neon` (`neon_peak`), `max`/`ultra` effort allowlists, and `ship_first_async_review` (`rev 15`)
- registry_rev: 14 -> 15
- onboarded `gemini-4-neon` (`Gemini 4 Neon`, `active`, `agy`, `default_effort="high"`, `peak_effort="xhigh"`, `quota_rank=3`, `speed_rank=2`) backed by 2026-11-19 empirical blind probes (`code_rigor=9.0`, `backend=9.0`, `math=9.0`, `agentic_coding=9.5`, `office_docs=6`, +36% decode throughput over Carbon); skipped `gemini-4-argon` and `gpt-6.2-sol`
- expanded `gpt-6.2-astra.invoke.efforts` to `["low","medium","high","xhigh","max","ultra"]` while keeping `default_effort="high"`, `peak_effort="xhigh"`, and `claude-opus-5-5.primary_disabled=true`
- added mode `neon_peak` (`lambda_q=0.0, lambda_s=0.0`), `policy.host_mode_map` entries (`neon: neon_peak`, `orchestrator_neon: orchestrator_fast`), and `policy.delivery_mode="ship_first_async_review"`
- updated `route.ps1` (`-HostModel neon` & `Orchestrator (Neon)` routing, `neon_peak` mechanical offload to 4H, generalized `xhigh` scan/mechanical downshift, `delivery_mode` + `review_timing="post_delivery_async"`, `Neon` scale-out label) and effort allowlists (`max`/`ultra`) across `setup.ps1`, `probe-model.ps1`, and `apply-research.ps1`
- backup: registry/history/models-20261119-142500-14-pre15.json

## 2026-11-18T18:51:18.0000000Z - Performance, locking & routing optimization (`rev 14`): lockless read/cache fast paths, pre-indexed telemetry, load-balance/lane guards, and 2-space LF registry
- registry_rev: 13 -> 14
- reformatted `registry/models.json` to compact 2-space LF indentation (`87,057` B -> `36,371` B) while keeping every model score, alias, policy, and `claude-opus-5-5.primary_disabled=true` identical
- updated `route.ps1` with lockless registry/state reads, `-RegistryObject`/`-SkipTelemetry` fast path, `New-OutcomeStatsIndex` single-pass telemetry, `$PreferIdle` guards on reviewer/co-drafter shifts, `HardPreferredIds` preservation over vendor diversity, `-BusyAgents` vs active-lease deduplication, and `parallel_lanes` pool/`hydrogen_max` filters
- updated `detect-models.ps1` (clear `$leaseToken` on commit + lockless skip pre-check), `calibrate-telemetry.ps1` (`-SinceDays $WindowDays` + indexed stats), `setup.ps1` (isolated `-ReportDir` on non-canonical registry), and `maintain.ps1` (reuse `$finalReg`)
- backup: registry/history/models-20261119-024500-13-pre14.json

## 2026-11-18T17:15:00.0000000Z - Concise English registry & ~80% doc/rule compression, zero-relay Swarm, Codex stealth-feature trim, and in-process `-AutoRecordOk`
- registry_rev: 12 -> 13
- compressed all `models.json` narrative strings (`hard_rules[].note`, `strengths`, `weaknesses`, `evidence[].claim`) into concise English (~80% overall doc/rule bloat reduction) while keeping every score, ID, alias, `primary_disabled`, and `policy` invariant identical
- enabled zero-relay Swarm (host calls `gpt-6.2-astra` / `claude-opus-5-5` directly, no `gatekeeper`), Codex stealth-feature trimming (`skip_host_skill_discovery`, `omit_skill_descriptions`, 22 disabled desktop/plugin features; `45.6K -> 14.2K` tokens & `42.4s -> 17.2s`), and in-process `-AutoRecordOk` fast path
- backup: registry/history/models-20261119-011200-12-pre13.json

## 2026-11-18T14:32:00.0000000Z - CLI cold-boot slimming (Codex pure-brain `--ignore-user-config --ignore-rules` & `--ephemeral`, direct `agy.exe --disable-slash-commands`) and `4H medium` ultra-fast tier
- registry_rev: 11 -> 12
- added `policy.ultra_fast_tags: ["scan"]` routing pure `scan` workhorse tasks to `medium` (`gemini-4-hydrogen-medium`), while `bulk`/`boilerplate`/`test_gen` stay `high` and general tasks stay `xhigh`
- updated `invoke-model.ps1` with Codex pure-brain slimming (`--ignore-user-config --ignore-rules` + essential scalar `-c`), `--ephemeral` auto-enabled on `-AutoRecordOk` without `-Resume`, direct `agy.exe --disable-slash-commands`, and `-InvocationId` auto-recording
- backup: registry/history/models-20261118-222500-11-pre12.json

## 2026-11-18T13:42:00.0000000Z - Fast-Plan Exemption Gate (`plan_external_min_unread_files = 5`), inline `response` without `-OutFile`, and `-AutoRecordOk`
- registry_rev: 10 -> 11
- added `policy.plan_external_min_unread_files = 5` (exempts in-context / `< 5` unread-file Plan Mode turns from external `/swarm` or `Astra` round-trips)
- updated `invoke-model.ps1` to return inline `response` (plus `response_truncated`, spilling `>64KB` to `.response.md`) when `-OutFile` is omitted, and added `-AutoRecordOk` single-step outcome logging
- backup: registry/history/models-20261118-214000-10-pre11.json

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

