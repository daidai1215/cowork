# 协作模式手册（Collaboration Patterns · 极致性能版）

本文件整合原 `gpt-write`、`gpt-review` 的全部核心规则，并将 Antigravity **Orchestrator** 与 **Swarm** 的控制论骨架（**规划期硬只读门禁、自包含契约交接、`Re-plan if` 硬熔断、无冲突分片并行、独立实跑验证员**）反向嫁接至三大异构旗舰阵容：**GPT-6 Astra (`high` / 攻坚 `xhigh`)**、**Gemini 4 Carbon (`high`)**、**Claude Opus 5.5 (`high`，`primary_disabled=true` 严格保护)**。

术语定义：
- **主控**：当前对话模型（负责只读勘察立项、签发契约、实跑验收与熔断重排）；
- **执行者（Author）**：按契约在受管路径分片内落地的专长旗舰；
- **独立实跑验证员（Active Verifier）**：异构厂商模型，结合实跑测试/脚本/检索验真，**绝不直接修改作者文件**。

---

## 0. 通用铁律（所有模式都适用）

1. **极致性能优先 + Opus 5.5 严格不解禁主写**
   - 默认启用 `peak` 模式（$\lambda_q=0,\ \lambda_s=0$），Astra 与 Carbon 纯按能力上限竞争主写；命中 `math / concurrency / algorithm / bugfix` 或升级重试时，Astra 自动拉满至 **`xhigh` 档**。
   - **`claude-opus-5-5` 锁定 `primary_disabled=true`**：严禁让 Opus 承担大段代码/长文初稿或主写 fallback；Opus 始终保持 `high` 档，专职前端/视觉 Aesthetic Gate、文案质感把关，以及双旗舰竞标难分高下时的精简方案终裁（输入 ≤ 800 字或截图 + tokens）。
2. **先只读勘察立项，后分片动笔（Read-Only Recon Gate）**
   - 复杂任务严禁边看边改。动笔前必须通过只读通道（`-Access read`，优先用 Carbon 1M 上下文扫全局，硬核接口叠 Astra 复核）生成自包含的 `<scratch>/plan_contract.md`：
     - **目标与非目标**；
     - **文件所有权边界**：`AllowedPrefixes`（允许写入）与 `ForbiddenPrefixes`（禁止触碰）；
     - **不变量、接口签名与已知陷阱（Invariants & Pitfalls）**；
     - **可执行验收门禁（Verification Gate）**：明确命令、断言与通过判据；
     - **`Re-plan if:` 熔断条件清单**（一旦观测到哪些迹象说明原计划假设不成立）。
3. **`Re-plan if` 硬熔断回交（严禁临场凑脏补丁）**
   - 执行者遇到任何 `Re-plan if` 触发条件（如源码真实签名与契约冲突、单测因非预期前置缺陷失败、约束互斥）时，**严禁自行扩权改禁区文件或硬塞 workaround**，必须立刻停手并在输出中写入标准熔断块：
     ```text
     =====ORCHESTRA_REPLAN_REQUIRED=====
     trigger: <命中的 Re-plan if 条款>
     evidence: <实际观测到的源码签名/报错/冲突证据>
     impact: <受影响的分片或步骤>
     =====END ORCHESTRA_REPLAN_REQUIRED=====
     ```
   - `invoke-model.ps1` 自动标记 `replan_required=true`；`extract-files.ps1` 遇到该块会**硬阻断落盘（退出码 `3`，零文件写入）**，由主控修订 `plan_contract.md` 后重新派发。
4. **无冲突分片并行（Disjoint Sharding）与原子落盘**
   - 多模块/多章节任务拆分为**文件集合严格互斥**的若干分片，后台并行启动多个执行会话；
   - `extract-files.ps1 -AllowedPrefixes ... -ForbiddenPrefixes ...` 执行**双遍全或无原子校验**：只要任一文件块越界或触碰禁区，整批零写入并返回退出码 `2`。
5. **拒绝防御性写作**：凡添加免责叠甲、冗余限定词、“并非 X 而是 Y”套话的修改一律驳回；最终面向读者的文字统一交 `best-prose`（Gemini 4 Carbon `high`）定稿。
6. **真伪内容必过 Truth Gate**（见第 6 节），严禁采信单一模型（尤其 Carbon 幻觉率约 11%，事实与文献必经异构核查 + 主控实查）。
7. **阶段状态全落盘 + 验收记账**：契约、预审共识、分片审稿一律写入 `<scratch>/*.md`（天然免疫 Cockpit 切号导致的旧 `<sid>` 失效）；每次外部调用验收后必跑 `scripts/record-outcome.ps1 -SessionId <sid> -Outcome ok|redo|fail`。

---

## 1. Delegate-Execute（双旗舰只读立项 → 专长旗舰契约落地）—— 原 `gpt-write` 升级

适用场景：将主体实现交由该领域能力天花板模型完成（后端/并发/数学/疑难 Bug/Office 交 GPT-6 Astra `high`/`xhigh`；1M 全仓重构/长文起草交 Gemini 4 Carbon `high`）。

1. **只读勘察与方案起草（`-Access read`）**：由 Carbon（1M 上下文）或执行者只读诊断现状，产出候选方案至 `<scratch>/plan_proposal.md`。
2. **签发自包含契约（落盘 `<scratch>/plan_contract.md`）**：主控核定具体改动步骤、`AllowedPrefixes`、`ForbiddenPrefixes`、可执行验收命令及 `Re-plan if:` 清单。
3. **专长执行者落地**：
   - **GPT-6 Astra（codex 通道）**：若 `codex_shell_probe.shell_works != true`，以 `-Access read -Tags <tags>` 调用，要求按 `=====FILE: …=====` 交付完整文件（或触发熔断时输出 `=====ORCHESTRA_REPLAN_REQUIRED=====`），由主控执行 `extract-files.ps1 -AllowedPrefixes <白名单> -ForbiddenPrefixes <禁区>` 原子落盘。若因 Cockpit 切号报 `resume_invalidated=true`，直接去掉 `-Resume` 内联 `plan_contract.md` 与源码开新会话零损续接。
   - **Gemini 4 Carbon（agy 通道）**：可直接 `-Access write` 按契约落地。
4. **Active Verifier + 主控实跑验收**：核查 diff、实跑 `Verification Gate` 全部测试与指标；未达标处附实跑报错打回（必要时带 `-AllowEscalation`），严禁主控越界直接手改覆盖执行者代码。

---

## 2. Pipelined Review + Disjoint Sharding（分片并行实现 + 异构实跑并审）—— 原 `gpt-review` 升级

适用场景：大型多模块开发或长篇论文撰写，兼顾高吞吐并行与异构严审。

1. **只读拆解与【必经】方案预审**：主控拆解出互不重叠的分片（Shard 1..K）与接口契约，发给异构审查者（`-Access read`）挑错，共识写入 `<scratch>/plan_contract.md`。
2. **分片并行 / 边写边审**：
   - 各分片拥有互斥的 `AllowedPrefixes`，可后台并行派发或流水线推进；
   - 每完成一个分片，立即在后台启动**独立的异构 Active Verifier 会话**（不带 `-Resume`，避免会话锁与切号失效），输出至 `<scratch>/shard_<n>_review.md`。
   - **Active Verifier 职责**：不仅静态读代码/文本，还须针对该分片设计边界反例、核对跨分片类型签名或运行只读验证脚本；**严禁直接修改分片文件**。
3. **【必经】完稿汇总终审**：全部分片合入并通过分片验证后，交审查者核查全局一致性与硬指标，按 `Blocker / Major / Minor` 去重分级并列出待查真伪线索。
4. **裁决与闭环**：`Blocker / Major` 退回原分片作者返工并重跑验证；误判凭据驳回。

---

## 3. Dual-Draft Synthesis（异构双旗舰竞标合成 · Best-of-2）—— 极致性能专属

适用场景：核心算法设计、高并发死锁/竞态、疑难根因 `bugfix`、关键系统架构（`route.ps1` 在 `peak` 模式下返回 `orchestration.dual_draft_eligible = true` 及 `co_drafter`）。

1. **同一契约，双强盲写**：基于同一份 `<scratch>/plan_contract.md`，主控在后台**同时并行启动**：
   - **Draft A**：`gpt-6-astra`（`xhigh` 档，强于形式化不变量、极端边界与数学严密性）→ 输出至 `<scratch>/draft_astra.md`；
   - **Draft B**：`gemini-4-carbon`（`high` 档，强于 1M 全局关联、系统工程视角与简洁实现）→ 输出至 `<scratch>/draft_carbon.md`。
2. **实跑基准对决（Benchmark Gate）**：在隔离目录/沙盒分别落盘两套方案，用同一套单元测试、压力/边界用例与复杂度指标实测对比。
3. **择优融合（必要时请 Opus 精简终裁）**：
   - 若一方实测全绿且结构明显占优，直接采纳并吸收另一方发现的边界防御点；
   - 若两套方案均通过测试但架构取舍各有利弊，将**精简对比摘要（≤ 800 字，含核心 diff 与实测数据）**发给 `claude-opus-5-5`（`high`，`-Access read`）做一轮轻量架构品味终裁，绝不让 Opus 重写全量代码。

---

## 4. Aesthetic Gate（Carbon 写前端，Opus 严格只把关审美）

适用场景：前端页面、UI 组件、落地页、海报版式等视觉产出（**Opus 5.5 不解禁主写**，以精简输入换取最高视觉上限）。

1. **起草实现**：由 `gemini-4-carbon` (`high`) 完成页面编写，抽离清晰的 design tokens（颜色、字号阶梯、间距、圆角、阴影）。
2. **多视口截图**：主控截取三个关键视口（1440 / 768 / 390）渲染画面。
3. **审美把关**：仅将截图、tokens 与关键组件片段发给 `best-aesthetic`（Claude Opus 5.5 `high`，`-Access read`），切勿发送整个代码仓。要求 Opus 输出：
   - 按“视觉层级 / 排版节奏 / 配色 / 留白 / 一致性 / 细节质感”六维逐项打分并指出具体问题；
   - 直接给出修改后的 tokens 与 ≤ 10 条具体 CSS 修改指令。
4. **落地与复看**：由 Carbon 应用修改并重新截图，交 Opus 复看一次（最多 2 轮）。
5. **Opus 不可用时的降级**：切换为 Gemini 4 Carbon 另开独立会话对照下方清单严审，不得在同一会话内自评。

**设计检查清单**：
- 层级：每屏仅保留一个视觉焦点；标题、正文、辅助文字字号比例 ≥ 1.25；
- 节奏：间距严格采用 4/8 倍数，同类元素间距一致；
- 配色：主色、强调色、中性色合计 ≤ 5 种；文字对比度 ≥ WCAG AA；
- 排版：中文行高 1.6~1.8，英文 1.4~1.6；正文每行 35~75 字符；
- 质感：圆角与阴影克制且成体系（≤ 3 档）；完整覆盖 hover / focus / active 状态；
- 去模板感：摒弃廉价紫青渐变与千篇一律的居中卡片堆砌，至少保留一处鲜明视觉记忆点。

---

## 5. Strength Delegation（强项子任务外包）

| 子任务 | 交给 | 说明 |
|---|---|---|
| 高精度生图、科研示意图、信息图、UI Mockup、透明通道、局部重绘 | GPT-6 Astra (`high`，Codex `image_gen`) | 硬规则：生图仅走 Codex，生成后拷入项目目录 |
| PPT（`ppt-master` / `nature-paper2ppt`）、Word 修订与公式、Excel 跨表公式、可填写 PDF | GPT-6 Astra (`high`，Codex 插件) | 版式可叠加 Aesthetic Gate 把关 |
| 专利交底书、基金证据表的严谨逻辑骨架 | GPT-6 Astra (`high`) 起草结构 | **最终成文与去 AI 腔润色必须交由 Gemini 4 Carbon 完成，严禁由 GPT 定稿** |
| LaTeX 模板编译排错、桌面/浏览器联动 | GPT-6 Astra (`high`) | |
| 形式数学推导、极隐蔽并发/数值稳定性 bug、极限篇幅压缩 | GPT-6 Astra (`xhigh`) | 攻坚自动升 `xhigh`；关键难题可开启第 3 节 `Dual-Draft Synthesis` |
| 整仓或超长文档（1M 上下文）通读、联网检索、世界知识综述 | Gemini 4 Carbon (`high`) | 事实与文献数据须经 Astra 抽查（Truth Gate） |

---

## 6. Truth Gate（真伪双查）

凡涉及参考文献（DOI、标题、作者、年份、卷期、页码、核心观点）、客观统计数据、数学定理适用条件、API 签名及行为、标准编号、基准测试数值的内容，必须执行：

1. **异构模型交叉核查**：一个模型产出初稿后，交由另一厂商模型只读核查（如 Carbon 写稿 → Astra 查证引用与数据；Astra 写算法 → Carbon 独立验算），列出全部疑点。
2. **主控亲自终审**：主控必须针对每条疑点，亲自通过 `search_web`、权威学术数据库（OpenAlex / Crossref / PubMed / arXiv）或实跑脚本**逐一复核**，确保最终交付 100% 可溯源、零幻觉。
3. **严禁将真伪核验完全甩给单一模型后放弃复核。**

---

## 提示词与契约模板

### A. `<scratch>/plan_contract.md` 标准契约模板（只读立项产出）
```markdown
# Plan Contract: <任务简述>
- AllowedPrefixes: <允许写入的目录/文件前缀，逗号分隔>
- ForbiddenPrefixes: <严禁触碰的目录/文件前缀>
- Invariants & Pitfalls:
  1. <必须保持的接口签名 / 行为不变量 / 编码约束>
  2. <只读勘察发现的隐藏陷阱>
- Ordered Steps:
  1. <精确到文件与函数/符号的改动说明>
- Verification Gate:
  - Command: `<实跑验收命令>`
  - Must Show: `<预期通过指标>`
- Re-plan if:
  - <条件 1：如目标函数实际签名/入参与本契约不一致>
  - <条件 2：如在不修改 ForbiddenPrefixes 的前提下无法满足类型或测试约束>
```

### B. 执行者契约落地模板（含 `Re-plan if` 硬熔断）
```
严格按以下已签发的契约执行，严禁自行扩大范围或猜测未声明的接口。
允许写入（AllowedPrefixes）：<路径清单>
严禁触碰（ForbiddenPrefixes）：<路径清单>
执行契约：<内联 plan_contract.md>

【硬性熔断规则（Re-plan if）】
若你在实现过程中发现契约中的任一 Re-plan if 条件成立，或契约假设与实际代码冲突：
严禁临场硬凑 workaround 或越界修改禁区文件！请立即停止编写代码，仅输出以下熔断块：
=====ORCHESTRA_REPLAN_REQUIRED=====
trigger: <命中的具体条款>
evidence: <实际看到的签名/报错/冲突证据>
impact: <受影响的步骤>
=====END ORCHESTRA_REPLAN_REQUIRED=====

正常完成时，按 =====FILE: <相对路径>===== ... =====END FILE===== 输出完整文件，并在 =====NOTES===== 后附验收依据与存疑点。
```

### C. Active Verifier（异构独立实跑验证员）模板（只读）
```
你是异构独立验证员（只读，严禁修改任何项目文件）。
契约基准：<内联 plan_contract.md>
待验产出：<内联 diff / 文件内容 / 测试输出>
请重点执行：
1. 对照契约逐项核查边界条件、并发/空值/异常路径及跨模块签名一致性；
2. 构造至少 2 个针对性反例或边界输入推演其行为，核查是否存在“表面过测试的脏补丁”；
3. 核查真伪线索（API、公式、文献、数据）。
输出：中文，按 Blocker / Major / Minor 分级，每条写成“问题 → 复现/反例证据 → 修复方向”，总长度 ≤ <N> 字。
禁止：建议增加免责声明、冗余限定词或“并非 X 而是 Y”式防御性表述。
```

### D. Opus 5.5 审美把关 / 精简架构终裁模板（严格控体积）
```
你是资深视觉与架构评审人，只做高信息密度裁决，不铺写全量业务代码。
材料：<截图路径 ×3 + design tokens + 关键片段>（或：<Draft A vs Draft B 精简对比摘要 ≤ 800 字>）。
若为审美把关：按“层级 / 节奏 / 配色 / 留白 / 一致性 / 质感”逐项打 1~10 分并给出修改后的 tokens（JSON）和 ≤ 10 条具体 CSS 改动。
若为双方案终裁：指出胜出方案（或融合切分边界）、核心理由（≤ 3 条）及必防的 1~2 个架构隐患。总长度 ≤ 600 字。
```
