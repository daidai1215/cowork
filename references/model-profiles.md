# 主力模型优缺点与口碑档案（Model Profiles）

<!-- AUTO:ROSTER:START -->
> 自动同步自 `registry/models.json` (`registry_rev: 5`, 活跃模型: 3)

| 模型 | ID / 通道 | 默认档位 | 顶级长板（>=9） | 额度 (`quota_rank`) | 速度 (`speed_rank`) | 运行特性 |
|---|---|---|---|---|---|---|
| **GPT-6 Astra** | `gpt-6-astra` (`codex`) | `high` (攻坚 `xhigh`) | backend (10), code_rigor (10), image_gen (10), math (10), agentic_coding (9.5), office_docs (9), world_knowledge (9) | 2 (中等) | 1 (较慢) | Cockpit 自动切号自愈; tools: `image_gen`, `office_plugins`, `latex`, `browser`, `computer_use` |
| **Claude Opus 5.5** | `claude-opus-5-5` (`agy`) | `high` | frontend_aesthetic (10), agentic_coding (9.5) | 1 (稀缺) | 2 (居中) | 仅审查/把关（禁主写）; tools: `web_search`, `browser` |
| **Gemini 4 Carbon** | `gemini-4-carbon` (`agy`) | `high` | long_context (10), prose (10), world_knowledge (10), agentic_coding (9) | 3 (充裕) | 3 (最快) | tools: `web_search`, `browser`, `long_context_1m` |

- **可用额度排序（低 → 高）**: Claude Opus 5.5 (`claude-opus-5-5`) < GPT-6 Astra (`gpt-6-astra`) < Gemini 4 Carbon (`gemini-4-carbon`)
- **响应速度排序（快 → 慢）**: Gemini 4 Carbon (`gemini-4-carbon`) > Claude Opus 5.5 (`claude-opus-5-5`) > GPT-6 Astra (`gpt-6-astra`)
<!-- AUTO:ROSTER:END -->

### 标准别名与典型路由速查

<!-- AUTO:ROUTING:START -->
- **标准能力别名**: `best-aesthetic` -> `claude-opus-5-5`, `best-image` -> `gpt-6-astra`, `best-knowledge` -> `gemini-4-carbon`, `best-math` -> `gpt-6-astra`, `best-prose` -> `gemini-4-carbon`, `best-rigor` -> `gpt-6-astra`
- **默认路由模式**: `peak` (零额度/速度扣分，纯能力上限优先)

| 典型场景 | 标签 (`-Tags`) | 主执行 (`primary`) | 审查 (`reviewer`) | 润色 (`polisher`) | 协作模式 (`pattern`) |
|---|---|---|---|---|---|
| 前端页面 / 落地页 | `frontend,landing_page` | `gemini-4-carbon` | `claude-opus-5-5` | - | `aesthetic_gate` |
| 后端 / API / 并发 | `backend,concurrency` | `gpt-6-astra` | `gemini-4-carbon` | - | `pipelined_review` |
| 数学推导 / 算法 | `math,algorithm` | `gpt-6-astra` (`xhigh`) | `gemini-4-carbon` | - | `pipelined_review` |
| 疑难 Bug / 根因定位 | `bugfix` | `gpt-6-astra` | `gemini-4-carbon` | - | `pipelined_review` |
| 论文 / 长文 / 文案 | `prose,paper` | `gemini-4-carbon` | `gpt-6-astra` | - | `pipelined_review` |
| 配图 / 插画 / Mockup | `image_gen` | `gpt-6-astra` | `claude-opus-5-5` | - | `strength_delegation` |
| PPT / Word / Excel | `office,ppt` | `gpt-6-astra` | `claude-opus-5-5` | - | `strength_delegation` |
| 检索 / 综述 / 大仓库理解 | `research,long_context` | `gemini-4-carbon` | `gpt-6-astra` | - | `pipelined_review` |
<!-- AUTO:ROUTING:END -->

---

<!-- AUTO:PROFILES:START -->
## 1. GPT-6 Astra (`high` / 攻坚 `xhigh`) -- `openai` / `codex`

- **10 维能力分** (`*`=锁定): `code_rigor`: 10*, `backend`: 10*, `math`: 10*, `image_gen`: 10*, `frontend_aesthetic`: 7, `prose`: 6, `world_knowledge`: 9, `long_context`: 8, `agentic_coding`: 9.5, `office_docs`: 9
- **额度 / 速度**: `quota_rank=2 (中等)`, `speed_rank=1 (较慢)`

**核心长板**:
- OpenAI 能力天花板：代码严谨性、后端工程、极难多步数学与形式推导
- 生图最强（Codex 内置 image_gen，三家中唯一）
- Codex 专属生态：Office 原生文档 / PPT / LaTeX / 浏览器与桌面操作
- 结构化输出与契约遵循极稳

**短板与避坑**:
- 单账号额度较少，依赖 Cockpit 自动切换账号，切换瞬间可能打断在途流或使旧会话加密推理状态失效
- 三家中最慢
- 防御性写作倾向（叠甲、免责前提、‘并非 X 而是 Y’套话），不宜直接定稿长文
- 前端视觉品味不如 Opus 5.5

---

## 2. Claude Opus 5.5 (`high`) -- `anthropic` / `agy` | 仅审查/把关（禁主写）

- **10 维能力分** (`*`=锁定): `code_rigor`: 8.5, `backend`: 8, `math`: 8, `image_gen`: 0, `frontend_aesthetic`: 10*, `prose`: 8.5, `world_knowledge`: 8, `long_context`: 8, `agentic_coding`: 9.5, `office_docs`: 5
- **额度 / 速度**: `quota_rank=1 (稀缺)`, `speed_rank=2 (居中)`

**核心长板**:
- 审美最好，尤其前端 UI / 落地页 / 视觉层级与细节质感
- AA Coding Agent Index 全球第 1（62 分），多文件自主重构与架构品味极佳
- 指令理解细腻

**短板与避坑**:
- 单池额度最稀缺，必须惜用（只做决策拍板、审美把关与关键重构，不铺写大段初稿）
- 速度居中（慢于 Gemini 4 Carbon，快于 GPT-6 Astra）
- 不能原生生图

---

## 3. Gemini 4 Carbon (`high`) -- `google` / `agy`

- **10 维能力分** (`*`=锁定): `code_rigor`: 8.5, `backend`: 8.5, `math`: 8.5, `image_gen`: 0, `frontend_aesthetic`: 8, `prose`: 10*, `world_knowledge`: 10*, `long_context`: 10, `agentic_coding`: 9, `office_docs`: 5
- **额度 / 速度**: `quota_rank=3 (充裕)`, `speed_rank=3 (最快)`

**核心长板**:
- 文笔最好、自然去 AI 腔，LMArena 文本总榜第 1
- 世界知识与联网检索综述最强（AA Intelligence Index v5 第 1、Omniscience 第 1）
- 1M 超长上下文（整仓通读、长文档图推理极强）
- 长程 Agentic 与安全工程较上一代大幅跃升（Coding Agent Index 全球第 2）
- 三家中额度最充裕、综合响应最快

**短板与避坑**:
- AA 实测幻觉率约 11%，涉及文献、具体数值与 API 事实时必须经过 Truth Gate 双查
- 极限形式数学与底层后端严谨性略逊于 GPT-6 Astra
- 前端视觉品味虽大幅进步（WebDev 第 4），仍次于 Opus 5.5
- 不支持原生图像生成，无 Codex 专属本地 Office 插件链
<!-- AUTO:PROFILES:END -->

---

## 附：模型阵容更换与未来新模型自评估

1. **安装或更换默认阵容（`scripts/setup.ps1`）**：随时可通过 `setup.ps1 -Models <模型1,模型2,...> [-ReviewOnlyModels <审查专用模型>] -Evaluate <auto|research|probe|full>` 自选本机任意可用模型组合，自动完成 10 维能力评测、异构核验/实测盲评、重绑 `best-*` 别名并同步渲染本页档案。
2. **后台自动发现新模型（`scripts/detect-models.ps1`）**：自动对比 `agy models` 与 Codex 目录中的基线（安装时未选中的存量模型已自动记入 `baseline_slugs` 不打扰）。一旦官方上线全新模型，后台按 `references/research-protocol.md` 联网调研 + 异构交叉核验，以 `candidate` 试运行或生成待批提案。
