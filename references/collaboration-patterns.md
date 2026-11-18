# 协作模式手册（Collaboration Patterns · 极致性能与快速分层版）

本文件整合原 `gpt-write`、`gpt-review` 的全部核心规则，并将 Antigravity **Orchestrator** 与 **Swarm** 的控制论骨架（**规划期硬只读门禁、自包含契约交接、`Re-plan if` 硬熔断、无冲突分片并行、独立实跑验证员**）反向嫁接至四大主力阵容：**GPT-6.2 Astra (`high` / 攻坚 `xhigh`)**、**Gemini 4 Carbon (`high`)**、**Gemini 4 Hydrogen (`4H Extra / xhigh`)**、**Claude Opus 5.5 (`high`，`primary_disabled=true` 严格保护)**。

术语定义：
- **主控**：当前对话模型（负责只读勘察立项、签发契约、实跑验收与熔断重排）；
- **执行者（Author）**：按契约在受管路径分片内落地的专长旗舰；
- **独立实跑验证员（Active Verifier）**：异构厂商模型，结合实跑测试/脚本/检索验真，**绝不直接修改作者文件**。

---

## 0. 通用铁律（所有模式都适用）

1. **极致性能优先 + 4H Extra 快速分级 + Opus 5.5 严格不解禁主写**
   - 默认启用 `peak` 模式（$\lambda_q=0,\ \lambda_s=0$），`GPT-6.2 Astra` 与 `Gemini 4 Carbon` 纯按能力上限竞争主写；常规工程与排错跑极速高质量 `high` 档，命中硬核数学（`math`）或带 `-AllowEscalation` 升级重试时，Astra 自动拉满至 **`xhigh` 档**。
   - **4H Extra 快速分级（`-Mode fast_4h` / `-Fast4H`）**：当用户要求用 **Gemini 4H Extra (`gemini-4-hydrogen-xhigh`)** 快速使用时，将原属 `Carbon` 的前端起草、大仓库预读/检索/重构、日常文档以及常规后端/Bug 审查与竞标副笔下放至 `4H Extra`（速度约 2.5 倍且工具调用幻觉率低）；仅少数高要求关卡保留 `Carbon`（`paper` / `essay` / `copywriting`、高难 `math` / `algorithm` 复核、以及 `-AllowEscalation` 升级任务），`GPT-6.2 Astra` 继续稳守后端/数学/疑难 Bug/生图/Office 主攻。
   - **`claude-opus-5-5` 锁定 `primary_disabled=true`**：严禁让 Opus 承担大段代码/长文初稿或主写 fallback（无论普通模式还是 `/swarm` 模式）；Opus 始终保持 `high` 档，专职前端/视觉 Aesthetic Gate、文案质感把关，以及双旗舰竞标难分高下时的精简方案终裁（输入 ≤ 800 字或截图 + tokens）。
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

适用场景：将主体实现交由该领域能力天花板模型完成（后端/并发/数学/疑难 Bug/Office 交 GPT-6.2 Astra `high`/`xhigh`；1M 全仓重构/长文起草在 `peak` 下交 Gemini 4 Carbon `high`，在 `fast_4h` 下大部分交 4H Extra `xhigh`）。

1. **只读勘察与方案起草（`-Access read`）**：由 Carbon / 4H Extra（均 1M 上下文）或执行者只读诊断现状，产出候选方案至 `<scratch>/plan_proposal.md`。
2. **签发自包含契约（落盘 `<scratch>/plan_contract.md`）**：主控核定具体改动步骤、`AllowedPrefixes`、`ForbiddenPrefixes`、可执行验收命令及 `Re-plan if:` 清单。
3. **专长执行者落地**：
   - **GPT-6.2 Astra（codex 通道）**：默认以 `-Access read -Tags <tags> -OutFile <f>`（纯推理大脑快道，自动 `--disable shell_tool --disable unified_exec`）调用，要求按 `=====FILE: …=====` 交付完整文件（或触发熔断时输出 `=====ORCHESTRA_REPLAN_REQUIRED=====`），由主控执行 `extract-files.ps1 -AllowedPrefixes <白名单> -ForbiddenPrefixes <禁区>` 原子落盘。若因 Cockpit 切号报 `resume_invalidated=true`，直接去掉 `-Resume` 内联 `plan_contract.md` 与源码开新会话零损续接。
   - **Gemini 4 Carbon / Gemini 4 Hydrogen（agy 通道）**：可直接 `-Access write` 按契约落地。
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
   - **Draft A**：`gpt-6.2-astra`（`high` / 攻坚 `xhigh`，强于形式化不变量、极端边界与科研严密性）→ 输出至 `<scratch>/draft_astra.md`；
   - **Draft B**：`gemini-4-carbon`（`peak` 下 `high` 档）或 `gemini-4-hydrogen`（`fast_4h` 下 `xhigh` 档）→ 输出至 `<scratch>/draft_gemini.md`。
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
| 高精度生图、科研示意图、信息图、UI Mockup、透明通道、局部重绘 | GPT-6.2 Astra (`high`，Codex `image_gen`) | 硬规则：生图仅走 Codex，生成后拷入项目目录 |
| PPT（`ppt-master` / `nature-paper2ppt`）、Word 修订与公式、Excel 跨表公式、可填写 PDF | GPT-6.2 Astra (`high`，Codex 插件) | 版式可叠加 Aesthetic Gate 把关 |
| 专利交底书、基金证据表的严谨逻辑骨架 | GPT-6.2 Astra (`high`) 起草结构 | **最终成文与去 AI 腔润色必须交由 Gemini 4 Carbon 完成，严禁由 GPT 定稿** |
| LaTeX 模板编译排错、桌面/浏览器联动 | GPT-6.2 Astra (`high`) | |
| 形式数学推导、极隐蔽并发/数值稳定性 bug、科研与极限篇幅压缩 | GPT-6.2 Astra (`xhigh`) | `math` 与 `-AllowEscalation` 自动升 `xhigh`；关键难题可开启 `Dual-Draft Synthesis` |
| 极高要求学术论文/深度长文终稿、HLE 级深度综合分析 | Gemini 4 Carbon (`high`) | `fast_4h` 模式下依然保留给 Carbon |
| 整仓高速预读、常规检索与重构、高速前端草稿、Swarm 并发编码 | Gemini 4 Hydrogen (`xhigh` / 4H Extra) | 速度 2.5x、工具幻觉率更低；疑难通过 `escalate_to` 升 Carbon |

---

## 6. Truth Gate（真伪双查）

凡涉及参考文献（DOI、标题、作者、年份、卷期、页码、核心观点）、客观统计数据、数学定理适用条件、API 签名及行为、标准编号、基准测试数值的内容，必须执行：

1. **异构模型交叉核查**：一个模型产出初稿后，交由另一厂商模型只读核查（如 Carbon 写稿 → Astra 查证引用与数据；Astra 写算法 → Carbon 独立验算），列出全部疑点。
2. **主控亲自终审**：主控必须针对每条疑点，亲自通过 `search_web`、权威学术数据库（OpenAlex / Crossref / PubMed / arXiv）或实跑脚本**逐一复核**，确保最终交付 100% 可溯源、零幻觉。
3. **严禁将真伪核验完全甩给单一模型后放弃复核。**

---

## 7. Context Hygiene & Clean Handoff（两级主控防污染与纯状态交接协议）

主控（Orchestrator）一旦在主对话中连续执行与业务主线无关的工具抢修、环境排错或支线杂活，大量 `stderr`、重试轨迹与临时绕行假设会长期挤占注意力窗口；而通用上下文压缩（`/compact`）属于**轨迹摘要**而非**纯状态投影**，仍会将 `Errors & Fixes` 浓缩保留在摘要头部。必须执行两级隔离：

### 第一级：盘中排障 1 次熔断 → 用完即毁子会话隔离（免换窗）
1. **触发阈值**：主控在执行业务任务时撞上工具报错、脚本异常、代理/权限阻塞或测试基础设施故障，**本地顺手修复最多尝试 1 次**。一旦失败，或需要第二轮诊断、跨文件排障、修改工具脚本、变更环境依赖，立即触发隔离。
2. **隔离执行**：
   - **Antigravity 主控**：调用 `invoke_subagent(TypeName="self", Role="Tooling Debugger", Prompt=...)`，在独立子上下文中完成诊断、修复与自测；
   - **Codex 主控**：通过不带 `-Resume` 的独立子会话完成排障与验证。
3. **四项干净回执（严禁回传排障流水账）**：子会话结束时仅向主控返回 **`状态 | 变更文件 | 验证证据 | 残留环境约束`** 四项结构化结果，所有中间 `stderr` 与失败试探随子会话销毁。

### 第二级：阶段边界纯状态交接（`<scratch>/handoff.md`）+ 换新对话
1. **触发时机**（不按报错次数机械换窗）：
   - **阶段检查点切割**：已完成“工具链改造 / 架构探路 / 环境排障”等前置阶段、拥有可验证检查点，准备切入正式业务主线时；
   - **上下文漂移熔断**：经一次显式状态重述后，主控仍再次遗漏用户硬约束或重复已被证伪的路线时。
2. **严防“二次带毒”与“过度失忆”**：
   - **必须保留**：目标与验收条件、用户硬约束与授权边界、已落地产物路径与版本/Commit、已验证事实及证据位置、未提交修改与运行中任务登记、未验证假设与阻塞项、下一步动作；
   - **失败路线按四元组保留**：`方法 — 失败前提条件 — 实测证据 — 何时可重试`（既防止新会话重踩死胡同，也防止把“当时代理未开”等局部前提故障误写成永久禁令）；
   - **彻底剥离**：逐轮对话、完整 `stderr`、重复重试日志、已失效猜测；工具问题仅保留仍生效的环境硬限制、已固化修复与复现命令（详细日志外置存盘，不入交接正文）。
3. **交接前后核验闭环**：换对话前确认所有共享文件修改与后台任务状态已登记落盘；新对话启动后，首轮先核验交接单中的工作区状态与版本指纹，确认一致后再继续推进。

## 8. Swarm + Cowork 联合协同协议（`/swarm` 下调用 Opus 5.5 与 GPT-6.2 Astra）

在 Antigravity 开启 `/swarm`（`native_swarm`）后：
- **为什么必须通过 `cowork` 桥接**？
  1. 原生 `swarm{action:"add"}` 只能选择 Antigravity 通道模型（`Carbon / 4H Extra / Opus`），**无法直接拉起 Codex 通道的 `gpt-6.2-astra`**；
  2. 为保护稀缺额度，不应开一整池 `Opus 5.5` Worker 并行耗额度；而是仅在 UI Aesthetic Gate 或双方案难分高下时，通过 `cowork` 单次精简调用 `claude-opus-5-5`。
  3. 当用户处于 **4H Extra 快速模式** 开启 `/swarm` 时，大量分片编码/测试由 4H Extra Worker 并行推进，需要极高文笔或复杂复核时同样经 `cowork` 调 `gemini-4-carbon`。

### 推荐架构（避免多 Worker 并发撞 Cockpit 切号）
1. **主力编码与测试池**：`2~5` 个 **4H Extra (`gemini-4-hydrogen-xhigh`)** 或 **Carbon** 原生 Swarm Worker，各自绑定互不重叠的 `workspace:"share"` 与文件前缀，负责快速分片开发与实跑测试。
2. **专职异构门禁工（`rigor-gate` / `cowork-bridge`，推荐 1 名，留 `inherit`）**：
   - 运行在 4H/Carbon 上，**专门充当 Swarm 内的 `cowork` 统一网关**；
   - 需要 **GPT-6.2 Astra**（硬核算法/并发/疑难 Bug/生图/Office/核心 Diff 严审）时，在 Worker 内通过 `run_command`（若工具声明有 `BypassSandbox` 参数则传 `true`）调 `invoke-model.ps1 -Model gpt-6.2-astra -StatusFile "$HOME\.cowork\live\swarm-rigor.json"`，并发控制在 **≤ 1~2 路**，彻底避免多个 Worker 同时把 Cockpit 账号池打穿或相互抢换 `auth.json`；
   - 需要 **Claude Opus 5.5**（多视口截图审美把关或 Best-of-2 ≤ 800 字终裁）时，调用 `invoke-model.ps1 -Model claude-opus-5-5 -StatusFile "$HOME\.cowork\live\swarm-opus.json"`，并将回执结论以 `#seq` 编号贴回看板或直接 `@` 下一步负责的作者（遵循 `native_swarm` 的按需 `@mention` 规则，不无故 `@all`）。
3. **Worker 直接按需调用时的硬约束**（若由普通分片 Worker 直接触发 `cowork`）：
   - Coordinator 必须在创建 Worker 的 `brief` 中内联以下**模板 F**（因为新 Swarm Worker 对主对话与技能上下文天然零记忆）；
   - 每次调用**必须传唯一 `-StatusFile`**（如 `swarm-<worker名>.json`；若工具声明有 `BypassSandbox` 则传 `true`），不得多个 Worker 共读默认 `latest-codex.json`。

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

### E. `<scratch>/handoff.md` 纯状态交接单标准模板（跨对话去污重建）
```markdown
# Clean Handoff: <任务名称>

## 1. 目标与验收门禁（Goal & Verification Gate）
- 最终目标：<一句话目标与范围边界>
- 验收命令与通过标准：`<命令>` → `<预期指标>`

## 2. 用户硬约束与授权边界（Hard Constraints）
- <如：claude-opus-5-5 严禁主写；禁止未授权远端操作等>

## 3. 已验证状态与产物快照（Verified State）
- 仓库 / 分支 / Commit：`<路径>` @ `<branch>` (`<sha>`)
- 已完成产物：`<文件路径列表与职责>`
- 未提交修改与在途任务：`<git status / 后台任务状态，无则写“工作区干净，无在途任务”>`
- 仍生效的环境约束：`<仅写结论与复现命令，严禁粘贴排障过程与原始 stderr>`

## 4. 已证伪死胡同（Dead Ends · 四元组防重踩）
- 方法 `<A>` | 失败前提：`<条件>` | 证据：`<简述或日志路径>` | 何时可重试：`<前提改变条件 / 永不重试>`

## 5. 待验证假设与下一步（Open Assumptions & Next Step）
- 待核实假设：`<若有>`
- 新对话首步动作：**先核验第 3 节仓库/文件状态一致**，随后执行 `<下一步具体动作>`
```

### F. `/swarm` Worker 调用 `cowork` 桥接内联指令（写入 `swarm{action:"add", brief:...}`）
```text
【Swarm + Cowork 异构桥接授权】
当你负责的分片遇到以下场景时，禁止在本地模型硬猜或越权开原生 Opus 池，请通过 cowork 脚本调用外部旗舰（仅当 run_command 声明含 BypassSandbox 时传 true；无此字段直接运行）：
1. 调用 GPT-6.2 Astra（硬核算法/后端/疑难Bug/严审，先读或打包契约再执行，请使用纯文本交付避免内部 shell 卡死）：
   powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\invoke-model.ps1" -Model gpt-6.2-astra -Access read -Tags "<tags>" -PromptFile "<prompt.md>" -OutFile "<astra_out.md>" -StatusFile "$HOME\.cowork\live\swarm-<worker>.json"
   若输出含 =====FILE: ...=====，用 extract-files.ps1 -AllowedPrefixes "<你的分片>" 落盘并实跑测试。
2. 调用 Claude Opus 5.5（仅限 UI 截图/tokens 审美把关或 ≤800 字双方案架构终裁，严禁派长代码初稿）：
   powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\invoke-model.ps1" -Model claude-opus-5-5 -Access read -Tags "frontend,ui" -PromptFile "<aesthetic_prompt.md>" -OutFile "<opus_out.md>" -StatusFile "$HOME\.cowork\live\swarm-<worker>-opus.json"
3. 验收完毕后回填结果：record-outcome.ps1 -SessionId <sid> -Outcome ok|redo|fail；并在看板仅 @ 需衔接的下一位 peer（无阻塞不要 @coordinator 或 @all）。
```
