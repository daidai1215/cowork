# Model Profiles (Strengths & Pitfalls)

<!-- AUTO:PROFILES:START -->
> Auto-synced from `registry/models.json` (`registry_rev: 14`, active: 4)

## 1. Claude Opus 5.5 (`high`) -- `anthropic` / `agy` | Review/gate only (primary disabled)

- **10-Dim Scores** (`*`=locked): `code_rigor`: 8.5, `backend`: 8, `math`: 8, `image_gen`: 0, `frontend_aesthetic`: 10*, `prose`: 8.5, `world_knowledge`: 8, `long_context`: 8, `agentic_coding`: 9.5, `office_docs`: 5
- **Quota / Speed**: `quota_rank=1`, `speed_rank=2`

**Core Strengths**:
- Top aesthetic judgment for frontend UI, landing pages, visual hierarchy, and finish
- AA Coding Agent Index #1 (62) with strong multi-file refactoring and architectural taste
- Nuanced instruction comprehension

**Weaknesses & Pitfalls**:
- Scarcest shared quota pool; conserve strictly for aesthetic gates, key decisions, and <=800w arbitration (never long primary drafts)
- Medium latency (slower than Gemini 4 Carbon/Hydrogen, faster than GPT-6.2 Astra)
- No native image generation

---

## 2. Gemini 4 Carbon (`high`) -- `google` / `agy`

- **10-Dim Scores** (`*`=locked): `code_rigor`: 8.5, `backend`: 8.5, `math`: 8.5, `image_gen`: 0, `frontend_aesthetic`: 8, `prose`: 10*, `world_knowledge`: 10*, `long_context`: 10, `agentic_coding`: 9, `office_docs`: 5
- **Quota / Speed**: `quota_rank=3`, `speed_rank=2`

**Core Strengths**:
- Best natural prose without AI filler; LMArena Text Arena #1
- Top world knowledge and synthesis (AA Intelligence Index v5 60, Omniscience #1, HLE 69.1%)
- 1M context window for deep whole-repo reading and long-document graph reasoning
- In fast modes, focuses on high-bar papers/prose/architecture and math/algorithm verification while offloading routine loads to 4H Extra

**Weaknesses & Pitfalls**:
- ~11% AA hallucination rate; verify citations, exact numbers, and API signatures via Truth Gate
- Formal math and backend edge-case rigor trail GPT-6.2 Astra; slower than 4H Extra
- Strong frontend taste (WebDev #4) but trails Opus 5.5
- No native image_gen or Codex local Office plugin chain

---

## 3. GPT-6.2 Astra (`high` / peak `xhigh`) -- `openai` / `codex`

- **10-Dim Scores** (`*`=locked): `code_rigor`: 10*, `backend`: 10*, `math`: 10*, `image_gen`: 10*, `frontend_aesthetic`: 7.5, `prose`: 7, `world_knowledge`: 8.5, `long_context`: 9, `agentic_coding`: 9.5, `office_docs`: 9.5
- **Quota / Speed**: `quota_rank=2`, `speed_rank=1`

**Core Strengths**:
- OpenAI latest flagship (2026-11-17): AA Intelligence Index 62 (#2), GPQA 97%, top scientific and mathematical reasoning
- 1M context window with $0.40/M cached input pricing; top rigor on backend contracts, edge cases, and concurrency
- Best image_gen (Codex built-in) and full Office/PPT/LaTeX ecosystem

**Weaknesses & Pitfalls**:
- AA Omniscience hallucination rate rose from 50% to 59%; never skip Truth Gate on citations, API signatures, or numeric facts
- No large Coding Agent jump over 6 Astra; frontend UI taste trails Opus 5.5
- Per-account quota relies on Cockpit auto-rotation and is slowest of all 4 models; pair with 4H Extra for parallel bulk shards

---

## 4. Gemini 4 Hydrogen (`xhigh`) -- `google` / `agy`

- **10-Dim Scores** (`*`=locked): `code_rigor`: 8, `backend`: 8, `math`: 8, `image_gen`: 0, `frontend_aesthetic`: 7.5, `prose`: 8, `world_knowledge`: 8.5, `long_context`: 9.5, `agentic_coding`: 8.5, `office_docs`: 5
- **Quota / Speed**: `quota_rank=3`, `speed_rank=3`

**Core Strengths**:
- ~2.5x faster than heavy flagships with exclusive xhigh (4H Extra) tier (AA 54, surpassing Argon)
- 1M context + high concurrency (Agents Last Exam 71.6%, AutomationBench 76.1%); default Swarm shard workhorse
- Much lower API/tool hallucination than Flash 3.8; handles routine UI drafts, repo scans, and checks with seamless Carbon escalation

**Weaknesses & Pitfalls**:
- High-bar prose (papers/essays) and deep multi-hop knowledge (HLE) trail Carbon; xhigh has higher latency/tokens than high/medium
- No native image_gen or Codex Office plugins; route extreme backend/math rigor to GPT-6.2 Astra
<!-- AUTO:PROFILES:END -->

---

## Roster Customization & Auto-Discovery

1. **Customize / Switch Roster (`scripts/setup.ps1`)**: Run `setup.ps1 -Models <m1,m2,...> [-ReviewOnlyModels <r1,...>] -Evaluate <auto|research|probe|full>` to select any local `agy`/`Codex` models, run 10-dim research + heterogeneous blind probes, rebind `best-*` aliases, and sync docs.
2. **Background Model Discovery (`scripts/detect-models.ps1`)**: Compares live `agy` and Codex catalogs against `baseline_slugs`; newly released models trigger background research per `references/research-protocol.md` (trial as `candidate` or emit proposals).
