# 协作模式手册（Collaboration Patterns · 极致性能与快速分层版）

本文件整合原 `gpt-write`、`gpt-review` 的全部核心规则，并将 Antigravity **Orchestrator** 与 **Swarm** 的控制论骨架（**规划期硬只读门禁、自包含契约交接、`Re-plan if` 硬熔断、无冲突分片并行、独立实跑验证员**）反向嫁接至四大主力阵容：**GPT-6.2 Astra (`high` / 攻坚 `xhigh`)**、**Gemini 4 Carbon (`high`)**、**Gemini 4 Hydrogen (`4H Extra / xhigh`)**、**Claude Opus 5.5 (`high`，`primary_disabled=true` 严格保护)**。

术语定义：
- **主控**：当前对话模型（负责只读勘察立项、签发契约、实跑验收与熔断重排）；
- **执行者（Author）**：按契约在受管路径分片内落地的专长旗舰；
- **独立实跑验证员（Active Verifier）**：异构厂商模型，结合实跑测试/脚本/检索验真，**绝不直接修改作者文件**。

---

## 0. 通用铁律（所有模式都适用）

1. **规划期双开 + 三档主控感知路由 + Antigravity 多池隔离**
   - **Orchestrator 规划期默认双开（`/swarm` + `/cowork`）**：当主控处于 `Orchestrator (Carbon)` 或 `Orchestrator (Argon)` 时，**即便在只读规划 / 勘察 / 架构拆解阶段，也默认开启 `/swarm`（`native_swarm`）并行派出只读 `4H` 勘察员，并经 `/cowork` 异步咨询 `GPT-6.2 Astra`**，加速立项、彻底避免单线程 Carbon 慢速阻塞；创建 Worker 时必须显式指定模型：**编码/勘察/测试工指定 `model: "gemini-4-hydrogen-xhigh"`，监控与机械扫描工指定 `model: "gemini-4-hydrogen-high"`**，严禁直接继承 `Orchestrator` 双跳税。
   - **三档主控感知自动分层（`route.ps1 -HostModel orchestrator|carbon|hydrogen`）**：
     - `orchestrator_fast`（`-HostModel orchestrator`）：约 80%+ 原 Carbon 负载下放 `4H Extra`（`gemini-4-hydrogen`），Carbon 仅留守 `architecture`、`paper`/`essay`/`copywriting`、`math`/`algorithm` 复核与 `-AllowEscalation` 升级。
     - `carbon_peak`（`-HostModel carbon`）：Carbon 保留主力权限，仅将大量简单/机械任务（`bulk` / `boilerplate` / `scan` / `test_gen`，未传 `-AllowEscalation`）分流给 `4H` **`high`** 档提速，其余全归 Carbon。
     - `hydrogen_max`（`-HostModel hydrogen`）：Gemini 侧 100% 由 `4H` 执行（日常 `xhigh`、机械 `high`），仅当 `-AllowEscalation` 或命中 `paper`/`essay`/`copywriting`/`architecture` 时才设置 `orchestration.final_reviewer = "gemini-4-carbon"` 终审。
     - **4H 机械降档**：`4H` 在普通/推理任务运行 `xhigh`（4H Extra），命中 `mechanical_fast_tags`（`bulk` / `boilerplate` / `scan` / `test_gen`）且未升级时自动降为极速 **`high`** 档。
   - **平时默认 `peak` 与 Antigravity 共享池认知（Shared-Pool Insight）**：
     - **Gemini 共享池**：在 Antigravity 内 `Gemini 4 Carbon` 与 `Gemini 4 Hydrogen (4H/4H Extra)` **共享 Gemini 配额池**，但 `4H` 响应快约 2.5 倍且机械 `high` 档更省延迟，因此分流 `4H` 的核心收益在于**并发吞吐提速与避免长等待阻塞**，同时把 Carbon 精准留给高文笔/强世界知识/架构把关。
     - **Claude 独立稀缺池（`claude-opus-5-5` 锁定 `primary_disabled=true`）**：Opus 独占稀缺 Claude 池，严禁主写或开整池 Opus Worker；始终保持 `high` 档，专职前端/视觉 Aesthetic Gate、文案质感把关，以及双旗舰竞标难分高下时的精简方案终裁（输入 ≤ 800 字或截图 + tokens）。
     - **Codex 外部池（`gpt-6.2-astra`）**：完全不消耗 Antigravity 额度，由本机 Codex + **Cockpit 自动轮换 `auth.json`** 驱动，全部主控模式下均经 `cowork` 直通承担后端/并发/数学/疑难 Bug/生图/Office；并发控制在 **1~2 路**以防多路踩踏切号窗口。
2. **先只读勘察立项，后分片动笔（Read-Only Recon Gate）**
   - 复杂任务严禁边看边改。动笔前先用 `4H High`（`-Tags scan`）或只读通道（`-Access read`）汇总仓库骨架至 `<scratch>/context_pack.md`，必要时叠加 Carbon / Astra 复核，签发自包含 `<scratch>/plan_contract.md`：
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

在 Antigravity 开启 `/swarm`（`native_swarm`）后（Orchestrator 模式下即便在只读规划期也应默认双开 `/swarm` + `/cowork`）：
- **为什么必须通过 `cowork` 桥接**？
  1. 原生 `swarm{action:"add"}` 只能选择 Antigravity 通道模型（`Carbon / 4H Extra / Opus`），**无法直接拉起 Codex 通道的 `gpt-6.2-astra`**；
  2. `Opus 5.5` 独占稀缺 Claude 配额池，不应开一整池 `Opus 5.5` Worker 并行耗额度；而是仅在 UI Aesthetic Gate 或双方案难分高下时，通过 `cowork` 单次精简调用 `claude-opus-5-5`。
  3. 当主控处于 **`Orchestrator`** 或 **4H Extra (`hydrogen_max` / `fast_4h`)** 模式开启 `/swarm` 时，大量分片编码/测试由显式指定 `4H` 的 Worker 并行推进，需要高阶文笔、架构终审或复杂复核时经 `cowork` 调 `gemini-4-carbon`。

### 推荐架构（单点 Gatekeeper + 显式定型防双跳税）
1. **主力勘察、编码与测试池（显式指定 4H 模型）**：`2~5` 个原生 Swarm Worker，各自绑定互不重叠的 `workspace:"share"` 与文件前缀；**编码/勘察/测试工显式传 `model: "gemini-4-hydrogen-xhigh"`，监控（`monitor`）与机械扫描工显式传 `model: "gemini-4-hydrogen-high"`**，绝不让 Worker 继承 `Orchestrator` 导致双跳延迟与额外消耗。
2. **单点异构门禁工（`gatekeeper` / `rigor-gate`，推荐 1 名，留 `inherit` 或 `4H`）**：
   - **专门充当 Swarm 内的 `cowork` 统一单点网关**，集中打包 `<scratch>/context_pack.md` 并受控发起外部旗舰调用；
   - 需要 **GPT-6.2 Astra**（硬核算法/并发/疑难 Bug/生图/Office/核心 Diff 严审）时，在 `gatekeeper` 内通过 `run_command`（若工具声明有 `BypassSandbox` 参数则传 `true`）调 `invoke-model.ps1 -Model gpt-6.2-astra -ContextFiles ... -StatusFile "$HOME\.cowork\live\swarm-gatekeeper.json"`，并发控制在 **≤ 1~2 路**，彻底避免多个 Worker 同时踩踏 Cockpit 账号池或相互抢换 `auth.json`；
   - 需要 **Claude Opus 5.5**（多视口截图审美把关或 Best-of-2 ≤ 800 字终裁）时，调用 `invoke-model.ps1 -Model claude-opus-5-5 -StatusFile "$HOME\.cowork\live\swarm-opus.json"`，并将精简回执以 `#seq` 编号贴回看板或直接 `@` 下一步负责的作者（仅 `@` 下一位 peer，无阻塞不 `@coordinator` 或 `@all`）。
3. **Worker 直接按需调用时的硬约束**（若由普通分片 Worker 直接触发 `cowork`）：
   - Coordinator 必须在创建 Worker 的 `brief` 中内联以下**模板 F**（因为新 Swarm Worker 对主对话与技能上下文天然零记忆）；
   - 每次调用**必须传唯一 `-StatusFile`**（如 `swarm-<worker名>.json`；若工具声明有 `BypassSandbox` 则传 `true`），使用默认静默事件流并尽量配合 `-ContextFiles`。

---

## 9. Context & KV Prefix Cache Protocol（上下文与 KV 前缀缓存协议）

1. **多文件先做静态压缩包（`<scratch>/context_pack.md`）**：跨多文件工作先派 `4H High`（`-Tags scan`）只读提取目录骨架、关键符号签名、契约与不变量写入 `<scratch>/context_pack.md`，禁止反复把完整长文件原文硬塞进每轮 prompt。
2. **`-ContextFiles` 静态前缀置顶锁缓存**：调用 `invoke-model.ps1` 时将静态参考文件传给 `-ContextFiles "<scratch>/context_pack.md,..."`（支持数组或逗号分隔相对路径）。脚本会自动剥离 BOM、统一 `\n` 换行并按确定顺序固定拼接在提示词**最顶部**（`=====CONTEXT_PACK: <filename>===== ... =====END_CONTEXT_PACK=====`），其后才接 `=====TASK_INSTRUCTIONS=====` 与动态 `$Prompt`（Codex 通道自动通过 `--add-dir` 挂载父目录）。保证静态包只增不改即可持续命中底层 KV 前缀缓存（Astra `$0.40/M` 缓存定价 / agy 前缀复用）。
3. **默认静默 stdout 与 `.events.jsonl` 持久化**：`invoke-model.ps1` 默认静默吞掉中间流式 JSON 行（`stdout` 仅输出末行 1 条 `orchestra_result` 汇总 JSON），彻底杜绝海量流事件撑爆主控上下文；完整原始事件统一落盘至 `$HOME\.cowork\live\<invocation_id>.events.jsonl`（返回 `events_file`，超 7 天自动清理）。仅在现场排障时显式加 `-StreamStdout`。
4. **`cached_tokens` 缓存命中遥测**：`invoke-model.ps1` 在 `$finalResult.usage` 与 `usage.jsonl` 中统一回填 `input_tokens`、`output_tokens`、`thinking_tokens`、`cached_tokens`（映射 `agy` `cache_read_tokens` 与 `codex` `cached_input_tokens`）、`total_tokens` 与 `cache_hit_rate`。若连续调用 `cache_hit_rate` 异常偏低，优先核查 `-ContextFiles` 文件列表顺序或顶部是否混入动态时间戳。
5. **`-Resume` 与 `-ContextFiles` 选型边界**：
   - **用 `-Resume <sid>`**：同一模型/账号内的轻量连续追问（上下文增量极小，且未触发 Cockpit 切号 `resume_invalidated=true`）。
   - **用新会话 + `-ContextFiles`（不传 `-Resume`）**：独立 Active Verifier 严审、多路分片并行、发生 Cockpit 切号失效（`resume_invalidated=true`）或阶段变更之后——确定性静态前缀同样能吃满 KV 缓存，且彻底隔离旧会话推理锁与历史试错噪声。
6. **Swarm `fork` 热缓存、`waiting` 复用与 `#channel` 隔离**：
   - **`fork` 热缓存**：仅当新 Worker 需复用现有成员（或 `coordinator`）已读完的同一大型探索前缀以直吃 KV 热缓存时使用 `fork: "<member>"`；常规互斥分片优先冷启动配合 `<scratch>/context_pack.md`，避免把无关闲聊带入子上下文。
   - **`waiting` 保活复用**：可复用的作者/审查 Worker 任务告一段落后保持 `waiting`（等待状态 0 token 消耗并保留热上下文），待验收返修再 `@` 唤醒；仅在分片彻底合并收尾后才 `kill`（`kill` 会永久销毁其工作区）。
   - **`#channel` / 看板隔离**：看板正文保持极简，用 `#seq` 引用历史消息、仅 `@` 下一步负责的 peer；长分析报告与日志写入 `<scratch>/` 或各自文件，不刷屏共享看板。
7. **长测试与命令输出节流（Output Log Throttling）**：运行大批量单测、构建或扫描时，将完整日志重定向到 `<scratch>/*.log`（外部调用依赖 `.events.jsonl`），**仅摘取 `<= 20` 行**核心结论（退出码、通过/失败计数、首个错误断言）进入主对话或看板。

---

## 10. Multi-Pool Load Balancing, LPT Scheduling & SDM/TDM Slicing Protocol（多池负载均衡、LPT 调度与空分/时分切片协议）

为消除单池空跑与串行等待，在 `registry/models.json` (`policy.pool_concurrency_limits`)、`scripts/lib/common.ps1`、`scripts/route.ps1`、`scripts/invoke-model.ps1` 与 `scripts/pack-context.ps1` 中建立实时三池信号灯与空分/时分流水线：

1. **三池实时并发槽位与自适应自愈（`$HOME\.cowork\slots\*.json`）**：
   - 默认配额上限：`agy_google`（4H / Carbon）=`6` 槽、`codex_openai`（GPT-6.2 Astra）=`2` 槽（严防 Cockpit 切号踩踏）、`agy_anthropic`（Claude Opus 5.5）=`2` 槽。
   - 每次通过 `invoke-model.ps1` 发起调用时自动申请目标池槽位（死进程 PID 或超 `7200s` 陈旧租约自动回收；`doctor.ps1` 增加 `slot_hygiene` 检查，传 `-Repair` 主动清理陈旧租约）。
   - **排队与首包计时分离（`-SlotWaitSec` / `-NoSlotWait`）**：默认 `-SlotWaitSec 300`，若目标池满槽则在启动子进程前进入 `queued_slot` 阶段等待（实时写 `status_file` 并在输出与 `usage.jsonl` 上报 `pool` 与 `slot_wait_sec`）；若传 `-NoSlotWait` 或超时则立即以退出码 `5`（`ORCHESTRA_LOCK_TIMEOUT`）快速失败。**Codex 首包握手计时器（`-ConnectTimeoutSec`）在成功获得槽位之后才开始计时**，不会因排队而误杀。
2. **多池感知路由与负载均衡（`route.ps1 -BusyAgents -PreferIdle`）**：
   - `-BusyAgents <模型ID或池名,...>`：在实时 `Slots` 租约之上叠加当前 Swarm/在途占用的模型或池名（`codex_openai` / `agy_anthropic` / `agy_google`），返回 `orchestration.pool_load`（`total_active`、`underutilized = ($total_active -lt 2)` 及三池 `active / limit / available`）与 `orchestration.scale_out_hint`。
   - `-PreferIdle`：当首选模型所在池已饱和（`available <= 0`）时，在**严格守住 `min_cap`、`primary_disabled` 与 `hard_rules` 不破防**的前提下，自动从同能力达标池中切至拥有空闲槽位的候选模型；非强锁的 `reviewer` 与 `co_drafter` 也优先回避饱和池。
3. **LPT 慢关键路径优先 + 跨三池并发（`orchestration.parallel_lanes`）**：
   - 当活跃子智能体 `< 2`（`underutilized=true`）时，严禁单线程只跑一个池，应主动参考 `route.ps1` 返回的 `orchestration.parallel_lanes` 同步拉开无冲突旁路：
     - **`T=0` LPT 先发慢关键路径**：立即优先拉起耗时最长的 `GPT-6.2 Astra` 主攻（后端/数学/疑难 Bug/生图/核心契约），或前端场景并行启动 Astra 契约/资产验证；
     - **`T=0` 同步拉起 Google 池旁路**：同步派 `4H Extra`（`gemini-4-hydrogen-xhigh`）写互斥路径分片、生成 `tests/` 或由 `4H High` 打包 `<scratch>/context_pack.md`；
     - **`T=1` 重叠流水线把关**：首片/截图就绪立即并行派 `Claude Opus 5.5` 做多视口截图 Aesthetic Gate 或双方案 `<= 800` 字终裁。
4. **空分复用（SDM：Space-Division Multiplexing）**：
   - **物理写入隔离**：Swarm Worker 分配互斥 `workspace:"share"` 与路径前缀，外部写盘统一过 `extract-files.ps1 -AllowedPrefixes ... -ForbiddenPrefixes ...`。
   - **热缓存 Work-Stealing**：优先 `@` 唤醒处于 `waiting` 状态的 Swarm 空闲小工（0 token 待命且自带热 KV 上下文）认领闲置分片或补测，不重复 `kill` + `add`。
5. **时分切片与增量审稿流（TDM + `scripts/pack-context.ps1`）**：
   - 将长实现拆为微切片，按 `写（Slice N+1） -> 审（Slice N） -> 修` 三拍重叠推进。
   - **静态打包锁缓存**：`pack-context.ps1 -WorkDir <d> -Files <f1,f2> -OutFile <scratch>/context_pack.md [-MaxLinesPerFile 400]` 按确定顺序去 BOM、统一 `\n` 并截断超长文件，搭配 `invoke-model.ps1 -ContextFiles` 置顶锁死前缀 KV 缓存。
   - **增量 Diff 送审（先过本地快筛再送外部旗舰）**：修改后先在本地跑完语法/单测快筛（日志落盘 `<scratch>/test.log`），再用 `pack-context.ps1 -WorkDir <d> -GitDiff [-BaseRef <ref>] [-AllowedPrefixes <p>] -TestLogFile <scratch>/test.log -OutFile <scratch>/delta_review.md [-MaxLogTailLines 20]` 仅打包 `git status --short`、`git diff --unified=3` 与末尾 `<= 20` 行测试摘要送给 Astra/Opus 二审。

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
当你负责的分片遇到以下场景时，禁止在本地模型硬猜或越权开原生 Opus 池，请通过 cowork 脚本调用外部旗舰（仅当 run_command 声明含 BypassSandbox 时传 true；无此字段直接运行；默认静默输出仅返回 1 行汇总 JSON，勿传 -StreamStdout）：
1. 调用 GPT-6.2 Astra（硬核算法/后端/疑难Bug/严审，先读或通过 -ContextFiles 挂载 <scratch>/context_pack.md 与 plan_contract.md，纯文本交付避免内部 shell 卡死）：
   powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\invoke-model.ps1" -Model gpt-6.2-astra -Access read -Tags "<tags>" -ContextFiles "<scratch>/context_pack.md" -PromptFile "<prompt.md>" -OutFile "<astra_out.md>" -StatusFile "$HOME\.cowork\live\swarm-<worker>.json"
   若输出含 =====FILE: ...=====，用 extract-files.ps1 -AllowedPrefixes "<你的分片>" 落盘并实跑测试；长测试日志写入文件仅摘 <=20 行贴入看板。
2. 调用 Claude Opus 5.5（仅限 UI 截图/tokens 审美把关或 ≤800 字双方案架构终裁，严禁派长代码初稿）：
   powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\invoke-model.ps1" -Model claude-opus-5-5 -Access read -Tags "frontend,ui" -PromptFile "<aesthetic_prompt.md>" -OutFile "<opus_out.md>" -StatusFile "$HOME\.cowork\live\swarm-<worker>-opus.json"
3. 验收完毕后回填结果：record-outcome.ps1 -SessionId <sid> -Outcome ok|redo|fail；并在看板仅 @ 需衔接的下一位 peer（无阻塞不要 @coordinator 或 @all）。
```
