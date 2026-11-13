---
name: cowork
description: 【多模型协同总调度·极致性能版】在 GPT-6 Astra（high / 攻坚 xhigh，Codex + Cockpit 自动切号）、Gemini 4 Carbon（high）与 Claude Opus 5.5（high，严格保护仅做审美把关与精简终裁）之间，按纯能力天花板自动派工；融合 Orchestrator 只读勘察契约（plan_contract.md）、Re-plan if 硬熔断、无冲突分片并行、独立实跑验证员（Active Verifier）与异构双旗舰竞标合成（Best-of-2），内置自动发现新模型与自维护——提及 cowork、多模型配合、多模型协作、派工、gpt-write、gpt-review、GPT 执笔、GPT 审稿、Opus 把关审美、Gemini 润色时触发。
---

# cowork：多模型协同总调度

**唯一源**：`$HOME\.gemini\config\skills\cowork`（下称 `ROOT`）。Codex 端的 `~\.codex\skills\cowork` 是指向此处的 Junction。
**运行时状态**：`$HOME\.cowork\`。其中 `state.json` 记录额度状态、基线与扫描时间，`usage.jsonl` 记录调用账本。
**当前主力阵容与资源排序（由 `scripts/sync-docs.ps1` 自动同步）**：
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

| 想做什么 | 看哪里 |
|---|---|
| 三大主力模型强弱项与避坑档案 | `references/model-profiles.md` |
| 6 种协作模式（含只读契约、`Re-plan if` 熔断、分片并行、双旗舰竞标）与模板 | `references/collaboration-patterns.md` |
| 新模型调研协议 | `references/research-protocol.md` |
| 机器可读档案（分数、别名、硬规则、策略参数） | `registry/models.json` |

---

## 第 0 步：确认自己是谁（主控身份与极致性能准则）

**当前对话所用模型即主控**，负责只读勘察立项、契约签发、实跑验收与熔断重排。默认路由模式为 **`peak`（零额度/速度扣分，纯冲能力上限）**：常规代码/排错/并发一律开极速高质量 **`high` 档**（约 40~90 秒）；仅命中硬核数学证明（`math`）或初稿实跑未过带 `-AllowEscalation` 二次攻坚时，`gpt-6-astra` 才升至 **`xhigh` 档**。**`claude-opus-5-5` 严格不解禁主写（`primary_disabled=true`）**，仅用于审美把关与精简方案终裁。

| 你在哪 | 你是谁 | 怎么调用 GPT-6 Astra (`high` / 攻坚 `xhigh`) | 怎么调用 Carbon / Opus (`high`) |
|---|---|---|---|
| Antigravity，主控为 Gemini 4 Carbon | 1M 全局勘察、长文主创兼总控 | `invoke-model.ps1 -Model gpt-6-astra -Tags <tags>`（**`run_command` 首次必传 `BypassSandbox: true`**，切勿先跑默认断网沙箱） | 审美/终裁调 Opus：`invoke-model.ps1 -Model claude-opus-5-5`（**同样首次必传 `BypassSandbox: true`**） |
| Antigravity，主控为 Claude Opus 5.5 | **惜用模式的总控（禁铺写长代码/长文）** | 同上（**首次必传 `BypassSandbox: true`**） | 勘察/起草一律派 Carbon：`invoke-model.ps1 -Model gemini-4-carbon`（**首次必传 `BypassSandbox: true`**） |
| Codex，主控为 GPT-6 Astra | 硬核实现与严谨性总控 | （自身即 Astra） | `invoke-model.ps1 -Model gemini-4-carbon` / `claude-opus-5-5`，**必须申请 `sandbox_permissions="require_escalated"`**，否则会误报 “not logged into Antigravity”；不要给 agy 加 `--sandbox` |

- **Antigravity 越沙箱直连铁律**：在 Antigravity 内调用 `invoke-model.ps1`、`detect-models.ps1`、`maintain.ps1`、`doctor.ps1 -ProbeCodexShell` 时，因必须访问本机代理端口（`127.0.0.1`）及 `~/.codex` / `~/.cowork` 目录，**第一次调用 `run_command` 就必须显式传 `BypassSandbox: true`**，严禁先跑必败的 `BypassSandbox: false` 白耗回合！
- **Opus 5.5 严格保护铁律**：Opus 绝不进入 `primary` / `fallback` 主写池。Opus 任主控时仅做立项拍板与审美/架构终裁，全仓检索与大段实现一律派给 Carbon 或 Astra。
- **GPT-6 Astra 任主控时**：全库 1M 通读、联网检索与文字定稿派给 Gemini 4 Carbon，审美把关派给 Opus 5.5，主控专注核心实现与形式化/严谨性把关。

### 已知环境限制、极速直连与 Cockpit 自动切号防护（必读）

1. **Codex 实时系统代理注入、端口快检与防死连熔断（`invoke-model.ps1` 已内置）**：
   - **动态代理同步 + 1.2s 端口快检**：每次拉起 `codex.exe` 前自动读取注册表 `HKCU\...\Internet Settings` 注入最新 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`，并对本地代理端口做 1.2 秒 TCP 预检——若代理未开或端口变更不通，**1 秒内立即报错退出**，绝不盲等。
   - **彻底关闭无限重连 + 25s 首包握手熔断**：强制向 `codex exec` 传入 `--disable unbounded_connection_retries`，并设 **25 秒首包握手超时**（`connect_timeout_sec=25`）与**重连风暴快断**（连续 2 次 `Reconnecting...` / `stream disconnected` 立即杀进程树），杜绝 1800 秒黑盒死等。
2. **Cockpit 自动切换 Codex 账号（核心运行机制）**：
   - `gpt-6-astra` 单个账号额度较少，本机 **Cockpit** 会在后台自动切换 `~\.codex\auth.json`（期间在 `~\.codex\.cockpit-profile-mutation-locks` / `.cockpit-token-locks` 产生短暂锁，并对历史会话执行加密推理清洗）。
   - **严禁触碰明文凭证**：任何检查只允许看 `auth.json` 的 `LastWriteTime` 或由脚本计算不透明 SHA-256 指纹，**绝不读取或打印 `auth.json` 内容**。
   - **`invoke-model.ps1` 已内置切号自愈**：
     - 单账号触发 429/额度限制，或执行途中因切号发生 401/流中断（`auth.json` 指纹变化）时，脚本自动等待 Cockpit 完成切号与锁释放（默认等 10 秒，最多自动重试 2 次 = 共 3 次尝试）。
     - 仅当连续 3 次尝试均报额度耗尽时，才将 `gpt-6-astra` 短暂标记 `exhausted` **30 分钟**并返回退出码 4，再由主控切换 `fallback`。
   - **跨账号 `-Resume <sid>` 失效处理（`resume_invalidated=true`）**：
     - 一旦返回 JSON 中 `resume_invalidated=true`，**严禁继续对旧 `<sid>` 重试**！必须立即**去掉 `-Resume` 开启新会话**，将 `<scratch>/plan_contract.md` 等阶段上下文内联续接。
3. **PATH 上的 `codex.exe` 为 0.145 旧版**：必须使用桌面版自带的新版 `%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe`（`invoke-model.ps1` 自动解析）。
4. **GPT 默认“纯推理大脑快道”（硬件级禁内部 Shell 防沙箱假死）**：
   - 本地工具极快的 Gemini 4 Carbon 负责读文件、将上下文与契约打包进 `<scratch>/plan_contract.md`；
   - `invoke-model.ps1` 在默认 `-Access read`（含 `-OutFile` 纯文本代码块交付）下自动追加 `--disable shell_tool --disable unified_exec`，并自动通过 `--add-dir` 挂载 `-PromptFile` / `-OutFile` 所在的 `<scratch>` 目录——从命令行层面拔掉易卡死的 Windows 内部沙箱 shell，让 GPT 直奔推理与代码生成（仅 `image_gen` / `office` / `ppt` 标签、直接 `-Access write` 无 `-OutFile`，或显式传 `-AllowCodexShell` 时才启用 Codex 内部工具）。
   - agy（Gemini 4 Carbon / Opus 5.5）的文件与终端工具正常，可直接使用 `-Access write`。
5. **PowerShell 5.1 编码陷阱**：含中文的 `.ps1` 必须保存为 UTF-8 with BOM（`extract-files.ps1` 已自动处理），命令行不要直接传中文字面量，统一走 `-PromptFile`。

所有脚本统一按以下方式调用：
`powershell -NoProfile -ExecutionPolicy Bypass -File "ROOT\scripts\<脚本>.ps1" ...`
（下文省略调用前缀）。

---

## 第 1 步：新模型检测（每次触发时执行，耗时几秒）

```powershell
detect-models.ps1          # 24 小时内已扫描过会直接返回 {"skipped":true}
```

- `new` 非空，或 `stale` 非空（档案超过 30 天未更新）：在**后台**按 `references/research-protocol.md` 启动调研（Gemini 4 Carbon 调研 → GPT-6 Astra 交叉核验 → 主控抽查 → `apply-research.ps1`）。**不要阻塞当前任务**。
- `gpt-6.1-sol`、`gemini-4-argon` 等停用模型已记入 `state.json` 的 `baseline_slugs`，不会被误报为新模型。
- **首次运行（`baseline_initialized=true`）后，必须把被记入基线的 slug 列表报告给用户**确认。
- **agy 模型列表可能“闪烁”**：新模型出现一次即算检测到；判定下线需连续 2 次成功扫描缺席（脚本已内置）。
- **分级生效**：`candidate` 入档、小幅非锁定调分（相对 `approved_score` 累计偏离 ≤ 2）、未锁定排名调整、`unavailable` 恢复、满 3 次 `ok` 转正均自动生效；修改锁定分数、修改 `best-*` 别名或硬规则、下架 active 模型、累计偏离 > 2、交叉核验存疑维度均生成提案至 `registry/proposals/` 待用户裁决（`apply-research.ps1 -Approve` / `-ApproveAll` / `-Rollback`）。

---

## 第 2 步：派工（默认 `peak` 极致性能路由）

1. 为任务打标签（见 `models.json` 的 `tags`，如 `frontend, landing_page, backend, concurrency, bugfix, math, algorithm, prose, paper, research, image_gen, ppt, refactor`）。
2. 执行 `route.ps1 -Tags <标签…> [-Mode peak|balanced|quality|economy|fast] [-AllowEscalation]`，获取 `primary / primary_effort / reviewer / polisher / fallback / pattern / orchestration`。
3. 主控可否决 route 的建议，但必须在最终汇报中说明理由。

**硬规则**（`route.ps1` 与 `models.json` 已双锁死，主控必须遵守）：
- **零额度税冲上限 + 档位提速**：默认 `peak` 模式（$\lambda_q=0,\ \lambda_s=0$）下，Astra 与 Carbon 纯按能力分竞争主写；常规 `bugfix / concurrency / algorithm / backend` 默认跑极速高质量 **`high` 档**，仅硬核 `math` 或带 `-AllowEscalation` 返工升级时才拉满至 **`xhigh` 档**。
- **Opus 5.5 不解禁主写**：`claude-opus-5-5` 已锁定 `primary_disabled=true`，永不承担大段初稿或主写兜底；前端、UI、落地页走 Aesthetic Gate（Carbon `high` 主写，Opus 5.5 `high` 仅审多视口截图、design tokens 与关键组件片段；Opus 不可用时由 Carbon 另开独立会话对照清单自审）。
- **生图独占**：生图仅走 Codex（`gpt-6-astra` `image_gen`）。
- **异构复核与去防御性定稿**：数学、后端、疑难 Bug 由 `gpt-6-astra` 主攻、异构厂商 `gemini-4-carbon` 任独立实跑验证员（Active Verifier）；最终文字润色统一交 `best-prose`（`gemini-4-carbon` `high`），剔除一切防御性套话。

**标准别名与常见任务速查**（由 `scripts/sync-docs.ps1` 自动从 `models.json` 与 `route.ps1` 渲染）：
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

## 第 3 步：按模式协作（借鉴 Orchestrator 闭环控制）

详细步骤与模板见 `references/collaboration-patterns.md`：

| pattern / 机制 | 一句话 |
|---|---|
| **Read-Only Recon Gate**（前置门禁） | 动笔前先 `-Access read` 全局勘察，签发自包含 `<scratch>/plan_contract.md`（含白名单、禁区、验收命令、`Re-plan if`） |
| **`Re-plan if` 熔断回交**（全模式硬约束） | 执行中一旦触发计划假设失效条件，禁止临场硬凑脏补丁，必须输出 `=====ORCHESTRA_REPLAN_REQUIRED=====` 停手回交（`extract-files.ps1` 硬阻断落盘） |
| `solo` | 单模型按契约直接执行，主控实跑验收 |
| `delegate_execute`（契约化委派） | 双旗舰只读立项（落盘 `plan_contract.md`） → 专长旗舰按分片落地 → 主控/异构验证员实跑验收 |
| `pipelined_review`（流水线并审） | 方案预审（落盘共识） → 分片并行/边写边由异构 Active Verifier 实跑核验 → 完稿汇总终审 → 主控裁决 |
| `dual_draft_synthesis`（异构双旗舰竞标） | 核心算法/并发/疑难 Bug（`dual_draft_eligible=true`）并行派 `Astra (xhigh)` + `Carbon (high)` 独立出解，实跑基准择优融合（分歧时可交 Opus 精简终裁） |
| `aesthetic_gate` | Carbon 写前端，Opus 5.5 (`high`) 仅审截图与 tokens，最多 2 轮 |
| `strength_delegation` | 生图、Office、LaTeX、重度形式推导外包给 GPT-6 Astra，后台并行 |
| Truth Gate（真伪双查） | 涉及文献、数据、API、公式真伪时：异构模型交叉查证，主控最后亲自复核 |

**性能、隔离与并发铁律**：
- **无冲突分片并行（Disjoint Sharding）**：多模块任务拆为互不重叠的路径分片，每个后台会话绑定独立的 `-AllowedPrefixes` 与 `-ForbiddenPrefixes`；`extract-files.ps1` 执行全或无原子校验（任一文件越界则整批零写入退出 `2`）。
- **读写职责隔离（Active Verifier）**：审查者绝不直接修改作者文件，但必须通过实跑测试、脚本验算或权威检索给出可证伪结论。
- **阶段契约必落盘**：`plan_contract.md`、预审结论、分片审稿意见一律写入 `<scratch>/*.md`，确保 Cockpit 随时切换 Astra 账号导致旧会话失效时，新会话读取契约即可零损续接。
- 后台外部调用一律异步并行推进，主控在同一回合内继续执行无冲突任务。

---

## 第 4 步：调用外部模型与原子落盘（统一入口）

```powershell
# Antigravity 内调用 run_command 时，首次必须直接传 BypassSandbox: true！
invoke-model.ps1 -Model <id|别名> -Access read|write -PromptFile <f> -WorkDir <d> [-Tags <tags>] [-Effort <e>] [-ConnectTimeoutSec <n>] [-AllowCodexShell] [-StatusFile <f>] [-Resume <sid>] [-OutFile <f>] [-JsonSchema <f>] [-DryRun]
extract-files.ps1 -InputFile <f> -Root <d> -AllowedPrefixes <p1,p2> [-ForbiddenPrefixes <f1,f2>] [-DryRun]
```

- 别名与自动升档：支持全部模型 ID 与 `best-*` 能力别名；未显式传 `-Effort` 且 `-Tags` 命中 `peak_effort_tags`（当前仅 `math`）时自动升至 `xhigh`，其余日常场景保持快速的 `high` 档。
- 输出末行为汇总 JSON，包含 `effort`、`session_id`、`proxy`、`codex_shell_enabled`、`startup_timeout`、`reconnect_aborted`、`status_file`、`attempts`、`account_switched`、`resume_invalidated`、`quota_error`、`replan_required`、`replan_detail`。
- **熔断拦截**：若 `replan_required=true`（或 `extract-files.ps1` 返回退出码 `3`），严禁强行落盘，主控必须回到只读勘察更新 `plan_contract.md` 后重派。
- **验收后必做**：执行 `record-outcome.ps1 -SessionId <sid> -Outcome ok|redo|fail`。

---

## 第 5 步：35 秒阶段感知看门狗与 Cockpit 切号重连（告别黑盒盲等）

每次通过 `run_command`（**`BypassSandbox=true`**, `WaitMsBeforeAsync=5000`）在后台启动 `invoke-model.ps1` 后：

1. **实时状态面板**：`invoke-model.ps1` 会实时刷新 `$HOME\.cowork\live\latest-codex.json`（或返回字段中的 `status_file`），包含当前阶段 `phase`（`connecting | connected | reasoning | tool_exec | responding | reconnecting | completed | failed`）、`proxy`、`elapsed_sec`、`reconnect_count`、`last_event_type`。
2. **立即挂载 35 秒首检看门狗**（脚本本身已内置 25s 首包握手超时与 2 次重连风暴快断）：
   `schedule(DurationSeconds=35, TimerCondition="<TaskId>", Prompt="Inspect GPT background task (<TaskId>) and read ~/.cowork/live/latest-codex.json phase; re-arm 60s timer if phase is reasoning/responding, or handle failure/reconnect immediately.")`
3. **被唤醒后**：先读 `$HOME\.cowork\live\latest-codex.json` 与 `manage_task(status)`：
   - **若任务已结束**：
     - `exit=0`：正常读取产出；若 `account_switched=true`，在《协同摘要》简注“期间 Cockpit 自动切换账号并自愈成功”。
     - `startup_timeout=true` 或 `reconnect_aborted=true`：说明 25 秒握手未通或流重连风暴已被脚本主动快断——先核对 `proxy` 端口是否通畅，若代理正常则重发 1 次或直接切 `fallback`，**绝不原地傻等**。
     - `resume_invalidated=true`：**立即去掉 `-Resume`**，将 `<scratch>/plan_contract.md` 内联重新发起新会话！
     - `exit=4`（`quota_error=true`）：按 route 的 `fallback` 降级并告知用户。
   - **若任务仍在运行，按 `latest-codex.json` 的 `phase` 精准处置**：
     1. **`phase == "reasoning"` 或 `"responding"`**：说明握手已完成、正在深度推理或生成文本！检查 `(Get-Item "$HOME\.codex\auth.json").LastWriteTime`（**严禁读取内容**）——若 `auth.json` 未在启动后发生变更，属于**正常思考**，续挂 **60 秒**看门狗安心等待；若 `auth.json` 已变更且 `updated_utc` 停滞超过 60 秒，说明切号断流，立即终止并重连。
     2. **`phase == "tool_exec"` 且停滞 > 45 秒**：说明误入内部工具沙箱卡死——立即 `manage_task(kill)`，不带 `-AllowCodexShell` 重发（强制纯推理大脑模式）。
4. **判定需人工终止并重连时**：
   1. 执行 `manage_task(kill)` 并仅按 PID 清理进程树（切勿通杀 `codex.exe`）。
   2. 自动重连（最多 2 次）：未切号用 `-Resume <sid>`；已切号直接去掉 `-Resume` 内联 `<scratch>/plan_contract.md` 新开会话。
   3. 连续失败时立即切换 `fallback`（如 `gemini-4-carbon`）并告知用户。

---

## 第 6 步：交付汇报

在回复末尾附上简短的**《协同摘要》**，包含：
- 派工方案（起草、审查、润色各由哪个模型承担，均标明 `high`）；
- 采纳与驳回的审查意见及理由；
- 真伪复查结论；
- 额度与账号池概况（各模型调用次数；如期间触发 Cockpit 自动切号重试，简要说明）；
- 新模型检测结果或档案变更（如有待确认提案，列出提案文件路径）。

---

## 第 7 步：自我维护与自我升级（doctor / calibrate / maintain）

- **一键自检与修复**：`doctor.ps1 [-Repair] [-ProbeCodexShell] [-NoNetwork]`（检查双端 Junction、文档漂移、过期租约、调用 `outcome` 回填率及新版 Codex 非交互 shell 自愈探测）。
- **遥测自校准提案**：`calibrate-telemetry.ps1 [-WindowDays 30] [-DryRun]`（聚合近 30 天真实返工率、实测耗时反转与切号健康度，生成待批提案至 `registry/proposals/`，绝不直接改线上分数）。
- **去剧透实测与手动盲评**：`probe-model.ps1 -ModelId <id> [-Grade] [-EmitProposals]`（仅在手动指定时运行；发给被测模型前自动剥离 `Scoring by ...` 评分细则防剧透，`-Grade` 时强制选异构厂商评委匿名盲评并本地核算封顶）。
- **受管文档防漂移同步**：`sync-docs.ps1 [-Check]`（将 `models.json` 与 `route.ps1` 自动同步至 `SKILL.md`、`references/model-profiles.md`、`README.md`）。
- **全链路编排门禁**：`maintain.ps1 [-SkipResearch] [-ForceDetect] [-RunProbe] [-CompactUsage] [-NoGitCommit] [-Push] [-DryRun]`（默认仅联网调研与异构核验，不自动跑耗额度的实测题；任何受管变更必过 `selftest.ps1` 门禁，失败自动原子回滚；门禁全绿后归档冷账本并在本地安全 `git commit`，仅显式传 `-Push` 才推送远端）。
