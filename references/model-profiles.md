# 主力模型优缺点与口碑档案（Model Profiles）

<!-- AUTO:ROSTER:START -->
> 自动同步自 `registry/models.json` (`registry_rev: 3`, 活跃模型: 3)

| 模型 | ID / 通道 | 默认档位 | 顶级长板（>=9） | 额度 (`quota_rank`) | 速度 (`speed_rank`) | 运行特性 |
|---|---|---|---|---|---|---|
| **GPT-6 Astra** | `gpt-6-astra` (`codex`) | `high` | backend (10), code_rigor (10), image_gen (10), math (10), agentic_coding (9.5), office_docs (9), world_knowledge (9) | 2 (中等) | 1 (较慢) | Cockpit 自动切号自愈; tools: `image_gen`, `office_plugins`, `latex`, `browser`, `computer_use` |
| **Claude Opus 5.5** | `claude-opus-5-5` (`agy`) | `high` | frontend_aesthetic (10), agentic_coding (9.5) | 1 (稀缺) | 2 (居中) | tools: `web_search`, `browser` |
| **Gemini 4 Carbon** | `gemini-4-carbon` (`agy`) | `high` | long_context (10), prose (10), world_knowledge (10), agentic_coding (9) | 3 (充裕) | 3 (最快) | tools: `web_search`, `browser`, `long_context_1m` |

- **可用额度排序（低 → 高）**: Claude Opus 5.5 (`claude-opus-5-5`) < GPT-6 Astra (`gpt-6-astra`) < Gemini 4 Carbon (`gemini-4-carbon`)
- **响应速度排序（快 → 慢）**: Gemini 4 Carbon (`gemini-4-carbon`) > Claude Opus 5.5 (`claude-opus-5-5`) > GPT-6 Astra (`gpt-6-astra`)
<!-- AUTO:ROSTER:END -->

### 标准别名与典型路由速查

<!-- AUTO:ROUTING:START -->
- **标准能力别名**: `best-aesthetic` -> `claude-opus-5-5`, `best-image` -> `gpt-6-astra`, `best-knowledge` -> `gemini-4-carbon`, `best-math` -> `gpt-6-astra`, `best-prose` -> `gemini-4-carbon`, `best-rigor` -> `gpt-6-astra`

| 典型场景 | 标签 (`-Tags`) | 主执行 (`primary`) | 审查 (`reviewer`) | 润色 (`polisher`) | 协作模式 (`pattern`) |
|---|---|---|---|---|---|
| 前端页面 / 落地页 | `frontend,landing_page` | `gemini-4-carbon` | `claude-opus-5-5` | - | `aesthetic_gate` |
| 后端 / API / 并发 | `backend,concurrency` | `gpt-6-astra` | `gemini-4-carbon` | - | `pipelined_review` |
| 数学推导 / 算法 | `math,algorithm` | `gpt-6-astra` | `gemini-4-carbon` | - | `pipelined_review` |
| 论文 / 长文 / 文案 | `prose,paper` | `gemini-4-carbon` | `gpt-6-astra` | - | `pipelined_review` |
| 配图 / 插画 / Mockup | `image_gen` | `gpt-6-astra` | `claude-opus-5-5` | - | `strength_delegation` |
| PPT / Word / Excel | `office,ppt` | `gpt-6-astra` | `claude-opus-5-5` | - | `strength_delegation` |
| 检索 / 综述 / 大仓库理解 | `research,long_context` | `gemini-4-carbon` | `gpt-6-astra` | - | `pipelined_review` |
<!-- AUTO:ROUTING:END -->

---

## 1. GPT-6 Astra (`high`) —— OpenAI · Codex 通道

**核心定位**：代码严谨性、后端工程、高难数学推导与多模态工具链的绝对底座。

**核心长板**：
- **代码严谨性与后端天花板（10/10，锁定）**：边界条件、并发安全、类型与协议契约、数值稳定性与隐蔽 bug 排查最稳。
- **数学与形式推理最强（10/10，锁定）**：长链条证明、复杂算法复杂度与不变量分析最可靠。
- **唯一原生生图（10/10，锁定）**：三家中唯一自带 Codex `image_gen` 工具链，科研配图、UI Mockup、透明背景素材与局部重绘必走此路。
- **Codex 专属文档与桌面工具链（9/10）**：原生 PPT、Word 修订与 Office Math、Excel 跨表公式、LaTeX 编译排错与本机环境联动。

**短板与避坑**：
- **单账号额度较少，依赖 Cockpit 自动切号**：单个账号跑 `gpt-6-astra` 很快会触及限额，Cockpit 会自动轮换 `~\.codex\auth.json`。切号瞬间可能引起：(a) 单次 429 报错；(b) 在途流被 401/断流打断；(c) 旧会话 `<sid>` 的加密推理状态在新账号下无法 `-Resume`（返回 `resume_invalidated=true`）。`invoke-model.ps1` 已内置等待锁释放与自动重试，多轮协作时也必须把中间结论落盘到 `<scratch>` 以便随时开新会话续接。
- **速度最慢（`speed_rank=1`）**：委派后一律放后台异步执行并挂 90 秒看门狗，主控并行干活，切勿前台空等。
- **防御性写作重灾区（prose 6/10）**：爱叠甲、加免责前提与“并非 X 而是 Y”句式，**严禁由其直接定稿面向读者的文章**，成文须交 Gemini 4 Carbon 润色。
- **非交互 `codex exec` 的 shell 工具限制**：当前版本非交互模式下 shell 工具易挂起，向其派工时应内联材料或让其输出 `=====FILE: …=====` 文本块由主控落盘。

---

## 2. Gemini 4 Carbon (`high`) —— Google · Antigravity (`agy`) 通道

**核心定位**：文笔定稿、世界知识综述、1M 超长上下文通读与高速日常主力（2026-10-28 正式发布并接替 Argon）。

**核心长板**：
- **文笔与语言自然度最佳（10/10，锁定）**：LMArena 文本盲测总榜第 1（约 1528 Elo），行文流畅、去 AI 腔能力最强，承担所有长文起草与终稿润色（`best-prose`）。
- **世界知识与综合智能榜首（10/10，锁定）**：Artificial Analysis Intelligence Index v5 第 1（59 分）、AA-Omniscience 知识榜第 1（54 分）、HLE-Diamond 第 1（69.1%）。
- **1M 超长上下文统治力（10/10）**：100 万 token 窗口，GraphWalks BFS（256K–1M 图推理）达 96.2% F1，适合整仓代码通读、跨文件重构与大批量文献综述。
- **长程 Agentic 与安全工程跃升（9/10）**：AA Coding Agent Index 59 分（全球第 2，仅次于 Opus 5.5 的 62 分），Terminal-Bench 4.0 达 65.2%（作弊率 0.0%），CWE-bench 漏洞修复 71.0%，前端 WebDev Arena 提升至 1768 Elo（第 4）。
- **额度最充裕、速度最快（`quota_rank=3, speed_rank=3`）**：日常起草、大仓库预读、联网调研的首选主力。

**短板与避坑**：
- **事实幻觉率需警惕（AA 实测约 11%）**：虽然推理与知识广度登顶，但幻觉率高于上一代 Argon（4%→11%）。凡涉及具体文献元数据、统计数字、API 签名与客观事实，**绝对不能跳过 Truth Gate**，必须由 GPT-6 Astra 交叉核查并由主控实查验证。
- **极限数学与底层严谨性略逊 Astra**：硬核后端并发与形式数学证明仍以 GPT-6 Astra 为主写或终审。
- **前端最终视觉品味次于 Opus 5.5**：适合快速写出结构完整的前端页面，再交 Opus 5.5 做 Aesthetic Gate 点睛。
- **无原生生图与 Codex 本地 Office 插件链**。

---

## 3. Claude Opus 5.5 (`high`) —— Anthropic · Antigravity (`agy`) 通道

**核心定位**：视觉审美总把关、前端 UI 品味定调与高复杂度架构裁决。

**核心长板**：
- **前端与视觉审美独一档（10/10，锁定）**：层级节奏、留白呼吸感、色彩克制感、排版细节与去模板化能力三家最强（`best-aesthetic`）。
- **顶级 Agentic 编码与架构品味（9.5/10）**：AA Coding Agent Index 全球第 1（62 分），代码组织干净、抽象克制。

**短板与避坑**：
- **额度最稀缺（`quota_rank=1`）**：绝不让 Opus 铺写几千行样板代码或大段综述初稿。始终保持 `high` 档质量，通过**精简输入体积**（只喂三视口截图 + design tokens + 核心组件片段）和**限制轮次**（Aesthetic Gate 最多 2 轮）来节约额度。
- **速度居中（`speed_rank=2`）**：快于 GPT-6 Astra，慢于 Gemini 4 Carbon。
- **不支持原生生图**。
- **降级预案**：当 Opus 额度耗尽进入 `exhausted` 时，前端审美把关自动降级由 Gemini 4 Carbon 另开独立会话，严格对照《设计检查清单》完成自审。

---

## 4. 面向未来新模型的准备

当官方后续推出新模型（如 GPT-6.2、Gemini 4.5、Claude 6 等）时：
1. `detect-models.ps1` 自动对比 `agy models` 与 `cockpit-model-catalog.json` 中的基线（已停用的 `gpt-6.1-sol`、`gemini-4-argon` 等固定在基线中不打扰）。
2. 一旦发现新模型，后台按 `references/research-protocol.md` 执行联网调研 + 异构模型交叉核验 + 主控抽查。
3. 新模型先以 `candidate`（带 −1 分安全惩罚，且不担任审查者/润色者）试运行，积累真实调用反馈与用户批准提案后平滑晋升或替换现有席位。
