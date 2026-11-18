# 主力模型优缺点与口碑档案（Model Profiles）

<!-- AUTO:ROSTER:START -->
> 自动同步自 `registry/models.json` (`registry_rev: 9`, 活跃模型: 4)

| 模型 | ID / 通道 | 默认档位 | 顶级长板（>=9） | 额度 (`quota_rank`) | 速度 (`speed_rank`) | 运行特性 |
|---|---|---|---|---|---|---|
| **Claude Opus 5.5** | `claude-opus-5-5` (`agy`) | `high` | frontend_aesthetic (10), agentic_coding (9.5) | 1 (稀缺) | 2 (居中) | 仅审查/把关（禁主写）; tools: `web_search`, `browser` |
| **Gemini 4 Carbon** | `gemini-4-carbon` (`agy`) | `high` | long_context (10), prose (10), world_knowledge (10), agentic_coding (9) | 3 (充裕) | 2 (居中) | tools: `web_search`, `browser`, `long_context_1m` |
| **GPT-6.2 Astra** | `gpt-6.2-astra` (`codex`) | `high` (攻坚 `xhigh`) | backend (10), code_rigor (10), image_gen (10), math (10), agentic_coding (9.5), office_docs (9.5), long_context (9) | 2 (中等) | 1 (较慢) | Cockpit 自动切号自愈; tools: `image_gen`, `office_plugins`, `latex`, `browser`, `computer_use` |
| **Gemini 4 Hydrogen** | `gemini-4-hydrogen` (`agy`) | `xhigh` | long_context (9.5) | 3 (充裕) | 3 (最快) | tools: `web_search`, `browser`, `long_context_1m` |

- **可用额度排序（低 → 高）**: Claude Opus 5.5 (`claude-opus-5-5`) < GPT-6.2 Astra (`gpt-6.2-astra`) < Gemini 4 Carbon (`gemini-4-carbon`) < Gemini 4 Hydrogen (`gemini-4-hydrogen`)
- **响应速度排序（快 → 慢）**: Gemini 4 Hydrogen (`gemini-4-hydrogen`) > Claude Opus 5.5 (`claude-opus-5-5`) > Gemini 4 Carbon (`gemini-4-carbon`) > GPT-6.2 Astra (`gpt-6.2-astra`)
- **通道池并发上限 (`pool_concurrency_limits`)**: `codex_openai` <= 2, `agy_anthropic` <= 2, `agy_google` <= 6
<!-- AUTO:ROSTER:END -->

### 标准别名与典型路由速查

<!-- AUTO:ROUTING:START -->
- **标准能力别名**: `best-aesthetic` -> `claude-opus-5-5`, `best-image` -> `gpt-6.2-astra`, `best-knowledge` -> `gemini-4-carbon`, `best-math` -> `gpt-6.2-astra`, `best-prose` -> `gemini-4-carbon`, `best-rigor` -> `gpt-6.2-astra`
- **默认路由模式**: `peak` (零额度/速度扣分，纯能力上限优先)

| 典型场景 | 标签 (`-Tags`) | 主执行 (`primary`) | 审查 (`reviewer`) | 润色 (`polisher`) | 协作模式 (`pattern`) |
|---|---|---|---|---|---|
| 前端页面 / 落地页 | `frontend,landing_page` | `gemini-4-carbon` | `claude-opus-5-5` | - | `aesthetic_gate` |
| 后端 / API / 并发 | `backend,concurrency` | `gpt-6.2-astra` | `gemini-4-carbon` | - | `pipelined_review` |
| 数学推导 / 算法 | `math,algorithm` | `gpt-6.2-astra` (`xhigh`) | `gemini-4-carbon` | - | `pipelined_review` |
| 疑难 Bug / 根因定位 | `bugfix` | `gpt-6.2-astra` | `gemini-4-carbon` | - | `pipelined_review` |
| 论文 / 长文 / 文案 | `prose,paper` | `gemini-4-carbon` | `gpt-6.2-astra` | - | `pipelined_review` |
| 配图 / 插画 / Mockup | `image_gen` | `gpt-6.2-astra` | `claude-opus-5-5` | - | `strength_delegation` |
| PPT / Word / Excel | `office,ppt` | `gpt-6.2-astra` | `claude-opus-5-5` | - | `strength_delegation` |
| 检索 / 综述 / 大仓库理解 | `research,long_context` | `gemini-4-carbon` | `gpt-6.2-astra` | - | `pipelined_review` |

- **4H Extra 快速模式 (`-Mode fast_4h`)**: 将大部分 `gemini-4-carbon` 任务下放 `gemini-4-hydrogen` (`xhigh`)，仅高要求主写 (`paper`, `essay`, `copywriting`, `architecture`), 高要求审查 (`math`, `algorithm`, `architecture`) 及 `-AllowEscalation` 保留给 `gemini-4-carbon` (后端/数学/生图/Office 主攻仍由 GPT-6.2 Astra 承担):

| 快速场景 (`fast_4h`) | `-Tags` | 主执行 | 审查 | 升级兜底 |
|---|---|---|---|---|
| 前端 / UI / 落地页 | `frontend,landing_page` | `gemini-4-hydrogen` (`xhigh`) | `claude-opus-5-5` (`high`) | `gemini-4-carbon` |
| 检索 / 大仓库预读 | `research,long_context` | `gemini-4-hydrogen` (`xhigh`) | `gpt-6.2-astra` (`high`) | `gemini-4-carbon` |
| 日常文档 / 总结 | `prose` | `gemini-4-hydrogen` (`xhigh`) | `gpt-6.2-astra` (`high`) | `gemini-4-carbon` |
| 高要求论文 / 深度长文 | `prose,paper` | `gemini-4-carbon` (`high`) | `gpt-6.2-astra` (`high`) | - |
| 常规后端 / Bugfix | `bugfix` | `gpt-6.2-astra` (`high`) | `gemini-4-hydrogen` (`xhigh`) | - |
| 数学 / 算法验算 | `math,algorithm` | `gpt-6.2-astra` (`xhigh`) | `gemini-4-carbon` (`high`) | - |

- **主控感知三档自动分层 (`-HostModel orchestrator|carbon|hydrogen`)**: 依据主控环境自动切换 `orchestrator_fast` / `carbon_peak` / `hydrogen_max` (在 `bulk`/`boilerplate`/`scan`/`test_gen` 自动降为 `high` 提速，其余保持 `xhigh`):

| 主控模式 (`-HostModel`) | 典型场景 | `-Tags` | 主执行 (`primary`) | 审查 (`reviewer`) | 终审 (`final_reviewer`) |
|---|---|---|---|---|---|
| `orchestrator` -> `orchestrator_fast` | 前端 / 常规研发 | `frontend,landing_page` | `gemini-4-hydrogen` (`xhigh`) | `claude-opus-5-5` (`high`) | - |
| `orchestrator` -> `orchestrator_fast` | 架构设计 / 复杂后端 | `architecture` | `gpt-6.2-astra` (`high`) | `gemini-4-carbon` (`high`) | - |
| `carbon` -> `carbon_peak` | 常规旗舰主控 | `frontend,landing_page` | `gemini-4-carbon` (`high`) | `claude-opus-5-5` (`high`) | - |
| `carbon` -> `carbon_peak` | 批量机械分片 / 仓扫 | `bulk,scan` | `gemini-4-hydrogen` (`high`) | `gpt-6.2-astra` (`high`) | - |
| `hydrogen` -> `hydrogen_max` | 常规 Bugfix | `bugfix` | `gpt-6.2-astra` (`high`) | `gemini-4-hydrogen` (`xhigh`) | - |
| `hydrogen` -> `hydrogen_max` | 论文 / 长文终审门禁 | `prose,paper` | `gemini-4-hydrogen` (`xhigh`) | `gpt-6.2-astra` (`high`) | `gemini-4-carbon` |
<!-- AUTO:ROUTING:END -->

---

<!-- AUTO:PROFILES:START -->
## 1. Claude Opus 5.5 (`high`) -- `anthropic` / `agy` | 仅审查/把关（禁主写）

- **10 维能力分** (`*`=锁定): `code_rigor`: 8.5, `backend`: 8, `math`: 8, `image_gen`: 0, `frontend_aesthetic`: 10*, `prose`: 8.5, `world_knowledge`: 8, `long_context`: 8, `agentic_coding`: 9.5, `office_docs`: 5
- **额度 / 速度**: `quota_rank=1 (稀缺)`, `speed_rank=2 (居中)`

**核心长板**:
- 审美最好，尤其前端 UI / 落地页 / 视觉层级与细节质感
- AA Coding Agent Index 全球第 1（62 分），多文件自主重构与架构品味极佳
- 指令理解细腻

**短板与避坑**:
- 单池额度最稀缺，必须惜用（只做决策拍板、审美把关与精简终裁，不铺写大段初稿）
- 速度居中（慢于 Gemini 4 Carbon / Hydrogen，快于 GPT-6.2 Astra）
- 不能原生生图

---

## 2. Gemini 4 Carbon (`high`) -- `google` / `agy`

- **10 维能力分** (`*`=锁定): `code_rigor`: 8.5, `backend`: 8.5, `math`: 8.5, `image_gen`: 0, `frontend_aesthetic`: 8, `prose`: 10*, `world_knowledge`: 10*, `long_context`: 10, `agentic_coding`: 9, `office_docs`: 5
- **额度 / 速度**: `quota_rank=3 (充裕)`, `speed_rank=2 (居中)`

**核心长板**:
- 文笔最好、自然去 AI 腔，LMArena 文本总榜第 1
- 世界知识与联网检索综述最强（AA Intelligence Index v5 60 分、Omniscience 第 1、HLE 69.1%）
- 1M 超长上下文（整仓深读、长文档图推理极强）
- 快速模式下专守论文/长文/深度定稿与数学/算法复核等少数高要求关口，日常负载可无缝下放 4H Extra

**短板与避坑**:
- AA 实测幻觉率约 11%，涉及文献、具体数值与 API 事实时必须经过 Truth Gate 双查
- 极限形式数学与底层后端严谨性略逊于 GPT-6.2 Astra；响应慢于 4H Extra
- 前端视觉品味虽强（WebDev 第 4），仍次于 Opus 5.5
- 不支持原生图像生成，无 Codex 专属本地 Office 插件链

---

## 3. GPT-6.2 Astra (`high` / 攻坚 `xhigh`) -- `openai` / `codex`

- **10 维能力分** (`*`=锁定): `code_rigor`: 10*, `backend`: 10*, `math`: 10*, `image_gen`: 10*, `frontend_aesthetic`: 7.5, `prose`: 7, `world_knowledge`: 8.5, `long_context`: 9, `agentic_coding`: 9.5, `office_docs`: 9.5
- **额度 / 速度**: `quota_rank=2 (中等)`, `speed_rank=1 (较慢)`

**核心长板**:
- OpenAI 最新旗舰（2026-11-17）：AA Intelligence Index 62 分（全球第 2），GPQA 97%，科研与数学推导再创新高
- 扩展至 1M 上下文窗口且支持 $0.40/M 缓存定价，后端契约、极端边界与并发严谨性极强
- 生图最强（Codex 内置 image_gen）与 Office/PPT/LaTeX 生态完备

**短板与避坑**:
- AA Omniscience 事实幻觉率从 50% 升至 59%，涉及文献引用、API 签名与客观数值时绝不可跳过 Truth Gate
- AA Coding Agent Index 相比 6 Astra 未拉大代差；前端 UI 审美仍不如 Opus 5.5
- 单账号额度依赖 Cockpit 自动切号，四家中响应最慢，日常批量分片编码推荐配合 4H Extra

---

## 4. Gemini 4 Hydrogen (`xhigh`) -- `google` / `agy`

- **10 维能力分** (`*`=锁定): `code_rigor`: 8, `backend`: 8, `math`: 8, `image_gen`: 0, `frontend_aesthetic`: 7.5, `prose`: 8, `world_knowledge`: 8.5, `long_context`: 9.5, `agentic_coding`: 8.5, `office_docs`: 5
- **额度 / 速度**: `quota_rank=3 (充裕)`, `speed_rank=3 (最快)`

**核心长板**:
- 速度极快（约 2.5 倍于重型旗舰）且支持 Gemini 4 独有的 xhigh（4H Extra）深思档（AA 54 分，超越 Argon）
- 1M 超长上下文 + 高并发高吞吐，Agents Last Exam 71.6%、AutomationBench 76.1%，Swarm 分片首选底座
- 工具调用与虚构 API 幻觉较 3.8 Flash 大幅下降；日常替代 Carbon 承担前端起草、仓扫综述与常规审查，疑难时自动升级 Carbon

**短板与避坑**:
- 极高文笔要求（论文/深度长文）与极深跨跳知识（HLE）天花板不及 Carbon，且 xhigh 档延迟与 token 开销明显高于 high
- 不支持原生生图与 Codex Office 插件；极限底层后端与数学严谨性交 GPT-6.2 Astra
<!-- AUTO:PROFILES:END -->

---

## 附：模型阵容更换与未来新模型自评估

1. **安装或更换默认阵容（`scripts/setup.ps1`）**：随时可通过 `setup.ps1 -Models <模型1,模型2,...> [-ReviewOnlyModels <审查专用模型>] -Evaluate <auto|research|probe|full>` 自选本机任意可用模型组合，自动完成 10 维能力评测、异构核验/实测盲评、重绑 `best-*` 别名并同步渲染本页档案。
2. **后台自动发现新模型（`scripts/detect-models.ps1`）**：自动对比 `agy models` 与 Codex 目录中的基线（安装时未选中的存量模型已自动记入 `baseline_slugs` 不打扰）。一旦官方上线全新模型，后台按 `references/research-protocol.md` 联网调研 + 异构交叉核验，以 `candidate` 试运行或生成待批提案。
