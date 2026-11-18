---
name: cowork
description: 【多模型协同总调度·极致性能与三档主控感知版】在 GPT-6.2 Astra（high / 攻坚 xhigh，Codex + Cockpit 自动切号）、Gemini 4 Carbon（high，极高上限）、Gemini 4 Hydrogen（4H Extra xhigh / 机械 high 快速主力）与 Claude Opus 5.5（high，严格保护仅做审美把关与精简终裁）之间智能派工；支持 Orchestrator 规划期默认双开 /swarm + /cowork、三档主控感知路由（-HostModel orchestrator|carbon|hydrogen）、KV 前缀缓存置顶与静默事件流。提及 cowork、多模型配合、多模型协作、派工、gpt-write、gpt-review、4H 快速模式、swarm 调 GPT/Opus 时触发。
---

# cowork：多模型协同总调度

**唯一源**：`$HOME\.gemini\config\skills\cowork`（下称 `ROOT`）。Codex 端的 `~\.codex\skills\cowork` 是指向此处的 Junction。
**运行时状态**：`$HOME\.cowork\`。其中 `state.json` 记录额度状态、基线与扫描时间，`usage.jsonl` 记录调用账本。
**当前主力阵容与资源排序（由 `scripts/sync-docs.ps1` 自动同步）**：
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

| 想做什么 | 看哪里 |
|---|---|
| 主力阵容强弱项与避坑档案 | `references/model-profiles.md` |
| 协作模式（含三档主控感知、`/swarm` 单点 `gatekeeper`、多池 LPT 与 SDM/TDM 切片、KV 缓存协议）与模板 | `references/collaboration-patterns.md` |
| 新模型调研协议 | `references/research-protocol.md` |
| 机器可读档案（分数、别名、硬规则、策略参数） | `registry/models.json` |

---

## 第 0 步：确认自己是谁（主控感知三档分层、规划期双开与共享池准则）

**当前对话所用模型即主控**，负责只读勘察立项、契约签发、实跑验收与熔断重排。
- **Orchestrator 规划期默认双开铁律（全局插件 `cowork-orchestrator` 常驻生效）**：当主控处于 `Orchestrator (Carbon)` 或 `Orchestrator (Argon)` 时，**即便在只读规划 / 勘察 / 架构拆解阶段，也默认开启 `/swarm`（`native_swarm`）与 `/cowork`**——并行派出只读 `4H` 勘察员并经 `/cowork` 异步咨询 `GPT-6.2 Astra`，加速立项、避免单线程 Carbon 慢速阻塞。Orchestrator 创建 Swarm Worker 时必须显式降级防双跳税：**编码/勘察/测试工指定 `model: "gemini-4-hydrogen-xhigh"`，监控（`monitor`）与机械扫描工指定 `model: "gemini-4-hydrogen-high"`**，绝不无脑继承 `Orchestrator`。
- **三档主控感知自动分层（`route.ps1 -HostModel orchestrator|carbon|hydrogen`）**：
  - `Orchestrator` → `-HostModel orchestrator`（`orchestrator_fast`）：约 80%+ 原 Carbon 负载下放 `4H Extra`，Carbon 仅留守架构、`paper/essay/copywriting`、`math/algorithm` 复核及 `-AllowEscalation`。
  - `Gemini 4 Carbon` → `-HostModel carbon`（`carbon_peak`）：Carbon 保留绝对主力，仅大量机械/扫描/样板任务（`bulk/boilerplate/scan/test_gen`）自动分流至 `4H` **`high`** 档提速，其余全归 Carbon。
  - `Gemini 4 Hydrogen (4H/4H Extra)` → `-HostModel hydrogen`（`hydrogen_max`）：Gemini 侧 100% 由 `4H` 执行（推理/编码 `xhigh`、机械 `high`），仅 `paper/essay/copywriting/architecture` 或 `-AllowEscalation` 触发 `final_reviewer = gemini-4-carbon` 终审。
  - 平时显式直跑仍用 `peak`（零额度/速度扣分冲极值）或 `-Mode fast_4h`；全部模式下均经 `cowork` 直通 `gpt-6.2-astra`（后端/并发/数学/Bug/生图/Office）与 `claude-opus-5-5`（`primary_disabled=true` 严格禁主写）。
- **Antigravity 共享池与外部通道认知**：
  - **Gemini 共享池**：`Carbon` 与 `4H (Hydrogen)` 在 Antigravity 内共享 Gemini 配额池，分流 `4H` 核心换取 **2.5 倍吞吐速度、低延迟与机械 `high` 降耗**，同时将 Carbon 精准保留给高文笔/深知识/架构关口；
  - **Claude 独立稀缺池**：`Claude Opus 5.5` 独占稀缺 Claude 额度池，只审截图 Aesthetic Gate 或 ≤ 800 字终裁，严禁铺写或整池开 Swarm Worker；
  - **Codex 外部池**：`GPT-6.2 Astra` 走外部 OpenAI Codex + Cockpit 自动切号，不耗 Antigravity 配额。
- **`/swarm` + `cowork` 单点 `gatekeeper` 桥接铁律**：原生 `swarm{action:"add"}` 无法拉起 Codex 通道的 `gpt-6.2-astra`，且整池开 Opus 会迅速透支 Claude 额度。`/swarm` 中统一设 1 名单点 `gatekeeper`（`rigor-gate`）经 `scripts/invoke-model.ps1` 集中调用 `gpt-6.2-astra`（并发 ≤ 1~2 路防 Cockpit 抢锁）与 `claude-opus-5-5`（详见第 3 步与 `collaboration-patterns.md` 第 8 节）。

| 你在哪 | 你是谁 | 怎么调用 GPT-6.2 Astra (`high` / 攻坚 `xhigh`) | 怎么调用 Carbon / 4H Extra / Opus |
|---|---|---|---|
| Antigravity，主控为 Orchestrator (`Carbon/Argon`) | 规划期即默认双开 `/swarm` + `/cowork` | 经单点 `gatekeeper` 或 `invoke-model.ps1 -Model gpt-6.2-astra -ContextFiles ...`（若 `run_command` 含 `BypassSandbox` 则首次传 `true`） | Swarm Worker 显式传 `gemini-4-hydrogen-xhigh`/`high`；审美终裁调 Opus；高要求文档/复核调 Carbon |
| Antigravity，主控为 Gemini 4 Carbon / 4H | 1M 深度勘察/长文定稿（Carbon）或高速分片（4H） | 同上 | 审美/终裁调 `claude-opus-5-5`；`hydrogen_max` 命中 `final_reviewer` 升级 `gemini-4-carbon` |
| Antigravity，主控为 Claude Opus 5.5 | **惜用模式的总控（禁铺写长代码/长文）** | 同上 | 勘察/常规代码派 4H Extra（`gemini-4-hydrogen`）或 Carbon（`gemini-4-carbon`） |
| Codex，主控为 GPT-6.2 Astra | 硬核实现与严谨性总控 | （自身即 6.2 Astra） | `invoke-model.ps1 -Model gemini-4-carbon` / `gemini-4-hydrogen` / `claude-opus-5-5`，**必须申请 `sandbox_permissions="require_escalated"`**，否则会误报 “not logged into Antigravity”；不要给 agy 加 `--sandbox` |

- **Antigravity 越沙箱直连铁律**：调用 `invoke-model.ps1`、`detect-models.ps1`、`maintain.ps1`、`setup.ps1`、`doctor.ps1 -ProbeCodexShell` 必须能访问本机代理端口（`127.0.0.1`）及 `~/.codex` / `~/.cowork` 目录：**若当前 `run_command` 工具声明中存在 `BypassSandbox` 字段，第一次调用就必须显式传 `BypassSandbox: true`**（严禁先跑 `false` 白耗回合）；若当前新版 Antigravity 的 `run_command` 已不提供该字段，切勿强传未知参数，直接执行命令即可。
- **Opus 5.5 严格保护铁律**：Opus 绝不进入 `primary` / `fallback` 主写池。Opus 任主控或在 `/swarm` 中被调用时仅做立项拍板、视觉 Aesthetic Gate 与精简架构终裁，全仓检索与大段实现一律派给 Carbon / 4H Extra 或 GPT-6.2 Astra。
- **GPT-6.2 Astra 任主控时**：全库 1M 通读、联网检索与文字定稿派给 Carbon（快速批量任务可选 4H Extra），审美把关派给 Opus 5.5，主控专注核心实现、科研推理与严谨性把关；**注意 6.2 Astra 实测 Omniscience 无依据猜测率达 59%，涉及具体引用、API 与事实务必严过 Truth Gate**。

### 已知环境限制、极速直连与 Cockpit 自动切号防护（必读）

1. **Codex 实时系统代理注入、端口快检与防死连熔断（`invoke-model.ps1` 已内置）**：
   - **动态代理同步 + 1.2s 端口快检**：每次拉起 `codex.exe` 前自动读取注册表 `HKCU\...\Internet Settings` 注入最新 `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`，并对本地代理端口做 1.2 秒 TCP 预检——若代理未开或端口变更不通，**1 秒内立即报错退出**，绝不盲等。
   - **彻底关闭无限重连 + 25s 首包握手熔断**：强制向 `codex exec` 传入 `--disable unbounded_connection_retries`，并设 **25 秒首包握手超时**（`connect_timeout_sec=25`）与**重连风暴快断**（连续 2 次 `Reconnecting...` / `stream disconnected` 立即杀进程树），杜绝 1800 秒黑盒死等。
2. **Cockpit 自动切换 Codex 账号（核心运行机制）**：
   - `gpt-6.2-astra` 单个账号额度较少，本机 **Cockpit** 会在后台自动切换 `~\.codex\auth.json`（期间在 `~\.codex\.cockpit-profile-mutation-locks` / `.cockpit-token-locks` 产生短暂锁，并对历史会话执行加密推理清洗）。
   - **严禁触碰明文凭证**：任何检查只允许看 `auth.json` 的 `LastWriteTime` 或由脚本计算不透明 SHA-256 指纹，**绝不读取或打印 `auth.json` 内容**。
   - **`invoke-model.ps1` 已内置切号自愈**：
     - 单账号触发 429/额度限制，或执行途中因切号发生 401/流中断（`auth.json` 指纹变化）时，脚本自动等待 Cockpit 完成切号与锁释放（默认等 10 秒，最多自动重试 2 次 = 共 3 次尝试）。
     - 仅当连续 3 次尝试均报额度耗尽时，才将 `gpt-6.2-astra` 短暂标记 `exhausted` **30 分钟**并返回退出码 4，再由主控切换 `fallback`。
   - **跨账号 `-Resume <sid>` 失效处理（`resume_invalidated=true`）**：
     - 一旦返回 JSON 中 `resume_invalidated=true`，**严禁继续对旧 `<sid>` 重试**！必须立即**去掉 `-Resume` 开启新会话**，将 `<scratch>/plan_contract.md` 等阶段上下文内联续接。
3. **PATH 上的 `codex.exe` 为 0.145 旧版**：必须使用桌面版自带的新版 `%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe`（`invoke-model.ps1` 自动解析）。
4. **GPT 默认“纯推理大脑快道”（硬件级禁内部 Shell 防沙箱假死）**：
   - 本地工具极快的 Gemini 4 Carbon / 4H Extra 负责读文件、将上下文与契约打包进 `<scratch>/plan_contract.md`；
   - `invoke-model.ps1` 在默认 `-Access read`（含 `-OutFile` 纯文本代码块交付）下自动追加 `--disable shell_tool --disable unified_exec`，并自动通过 `--add-dir` 挂载 `-PromptFile` / `-OutFile` 所在的 `<scratch>` 目录——从命令行层面拔掉易卡死的 Windows 内部沙箱 shell，让 GPT 直奔推理与代码生成（仅 `image_gen` / `office` / `ppt` 标签、直接 `-Access write` 无 `-OutFile`，或显式传 `-AllowCodexShell` 时才启用 Codex 内部工具）。
   - agy（Gemini 4 Carbon / Gemini 4 Hydrogen / Opus 5.5）的文件与终端工具正常，可直接使用 `-Access write`。
5. **PowerShell 5.1 编码陷阱**：含中文的 `.ps1` 必须保存为 UTF-8 with BOM（`extract-files.ps1` 已自动处理），命令行不要直接传中文字面量，统一走 `-PromptFile`。

所有脚本统一按以下方式调用：
`powershell -NoProfile -ExecutionPolicy Bypass -File "ROOT\scripts\<脚本>.ps1" ...`
（下文省略调用前缀）。

---

## 第 1 步：新模型检测（每次触发时执行，耗时几秒）

```powershell
detect-models.ps1          # 24 小时内已扫描过会直接返回 {"skipped":true}
```

- `new` 非空，或 `stale` 非空（档案超过 30 天未更新）：在**后台**按 `references/research-protocol.md` 启动调研（Gemini 4 Carbon 调研 → GPT-6.2 Astra 交叉核验 → 主控抽查 → `apply-research.ps1`）。**不要阻塞当前任务**。
- `gpt-6-astra`、`gpt-6.1-sol`、`gemini-4-argon` 等停用模型已记入 `models.json` (`retired`) 或 `state.json` 的 `baseline_slugs`，不会被误报为新模型。
- **首次运行（`baseline_initialized=true`）后，必须把被记入基线的 slug 列表报告给用户**确认。
- **agy 模型列表可能“闪烁”**：新模型出现一次即算检测到；判定下线需连续 2 次成功扫描缺席（脚本已内置）。
- **分级生效**：`candidate` 入档、小幅非锁定调分（相对 `approved_score` 累计偏离 ≤ 2）、未锁定排名调整、`unavailable` 恢复、满 3 次 `ok` 转正均自动生效；修改锁定分数、修改 `best-*` 别名或硬规则、下架 active 模型、累计偏离 > 2、交叉核验存疑维度均生成提案至 `registry/proposals/` 待用户裁决（`apply-research.ps1 -Approve` / `-ApproveAll` / `-Rollback`）。

---

## 第 2 步：派工（主控感知 `-HostModel` 三档分层 / 默认 `peak` 极致性能）

1. 为任务打标签（见 `models.json` 的 `tags`，如 `frontend, landing_page, backend, concurrency, bugfix, math, algorithm, architecture, prose, paper, research, bulk, boilerplate, scan, test_gen, image_gen, ppt, refactor`）。
2. 执行 `route.ps1 -Tags <标签…> [-HostModel orchestrator|carbon|hydrogen] [-Mode peak|orchestrator_fast|carbon_peak|hydrogen_max|fast_4h|balanced|quality|economy|fast] [-Fast4H] [-BusyAgents <id|pool,...>] [-PreferIdle] [-AllowEscalation]`，获取 `primary / primary_effort / reviewer / polisher / fallback / pattern / orchestration`（含 `orchestration.host_mode`、`orchestration.final_reviewer`、`orchestration.final_review_triggers`、`orchestration.pool_load`、`orchestration.scale_out_hint`、`orchestration.parallel_lanes`）。
   - **三档主控感知路由（未显式指定 `-Mode` / `-Fast4H` 时由 `-HostModel` 自动映射）**：
     - `-HostModel orchestrator` → `orchestrator_fast`：按 `fast_workhorse_map` 将约 80%+ Carbon 常规负载下放 `gemini-4-hydrogen`，保留 Carbon 于 `paper/essay/copywriting`、`math/algorithm` 复核及 `-AllowEscalation`；
     - `-HostModel carbon` → `carbon_peak`：Carbon 维持主力，仅命中 `bulk/boilerplate/scan/test_gen`（且无 `-AllowEscalation`）时将 Gemini 分流给 `4H` **`high`** 档提速；
     - `-HostModel hydrogen` → `hydrogen_max`：Gemini 侧 100% 由 `4H` 执行，仅命中 `paper/essay/copywriting/architecture` 或 `-AllowEscalation` 时将 `orchestration.final_reviewer` 设为 `gemini-4-carbon` 终审。
   - **多池负载均衡与 LPT 并行编排（`-BusyAgents` / `-PreferIdle`）**：自动读取 `$HOME\.cowork\slots` 并叠加 `-BusyAgents`（模型 ID 或池名 `codex_openai`/`agy_anthropic`/`agy_google`）；当 `-PreferIdle` 开启且首选池满槽（`available <= 0`）时，在**严守 `min_cap` 与 `hard_rules`**前提下切至空闲池候选模型；同时通过 `parallel_lanes` 给出 LPT `T=0` 跨池并发建议（详见 `collaboration-patterns.md` 第 10 节）。
   - **4H 机械 `high` vs 推理 `xhigh`**：`4H` 在推理/开发/审查场景跑 `xhigh`（4H Extra），命中 `mechanical_fast_tags`（`bulk/boilerplate/scan/test_gen`）且未升级时自动降为极速 **`high`** 档。
3. 主控可否决 route 的建议，但必须在最终汇报中说明理由。

**硬规则**（`route.ps1` 与 `models.json` 已双锁死，主控必须遵守）：
- **零额度税冲上限 + 档位提速**：默认 `peak` 模式（$\lambda_q=0,\ \lambda_s=0$）下，Astra 与 Carbon 纯按能力分竞争主写；常规 `bugfix / concurrency / algorithm / backend` 默认跑极速高质量 **`high` 档**，仅硬核 `math` 或带 `-AllowEscalation` 返工升级时才拉满至 **`xhigh` 档**。
- **Opus 5.5 不解禁主写**：`claude-opus-5-5` 已锁定 `primary_disabled=true`，永不承担大段初稿或主写兜底；前端、UI、落地页走 Aesthetic Gate（`peak` 用 Carbon `high` 主写、`fast_4h` 用 `4H Extra` 主写，Opus 5.5 `high` 均仅审多视口截图、design tokens 与关键组件片段；Opus 不可用时由 Carbon/4H 另开独立会话对照清单自审）。
- **生图独占**：生图仅走 Codex（`gpt-6.2-astra` `image_gen`）。
- **异构复核与去防御性定稿**：数学、后端、疑难 Bug 由 `gpt-6.2-astra` 主攻、异构厂商 `gemini-4-carbon`（或 `fast_4h` 下日常审查用 `gemini-4-hydrogen` `xhigh`）任独立实跑验证员（Active Verifier）；高要求论文/文稿最终文字润色统一交 `best-prose`（`gemini-4-carbon` `high`），剔除一切防御性套话。

**标准别名与常见任务速查**（由 `scripts/sync-docs.ps1` 自动从 `models.json` 与 `route.ps1` 渲染）：
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
| `aesthetic_gate` | Carbon（或 `fast_4h` 下 4H Extra）写前端，Opus 5.5 (`high`) 仅审截图与 tokens，最多 2 轮 |
| `strength_delegation` | 生图、Office、LaTeX、重度形式推导外包给 GPT-6.2 Astra，后台并行 |
| **Swarm + Cowork 单点门禁**（`/swarm` 专属） | `/swarm` 原生 `add` 仅能调 `agy` 模型且编码/勘察 Worker 须显式指定 `gemini-4-hydrogen-xhigh`（监控/扫描用 `high`）；由 1 名单点 `gatekeeper`（`rigor-gate`）经 `invoke-model.ps1` 集中调用 **GPT-6.2 Astra**（≤1~2 并发防 Cockpit 抢锁）与 **Opus 5.5**（必传唯一 `-StatusFile` 与默认静默流） |
| Truth Gate（真伪双查） | 涉及文献、数据、API、公式真伪时：异构模型交叉查证，主控最后亲自复核（**6.2 Astra 幻觉率 59%，必过双查**） |

**性能、隔离与并发铁律**：
- **无冲突分片并行（Disjoint Sharding）**：多模块任务拆为互不重叠的路径分片，每个后台会话绑定独立的 `-AllowedPrefixes` 与 `-ForbiddenPrefixes`；`extract-files.ps1` 执行全或无原子校验（任一文件越界则整批零写入退出 `2`）。
- **读写职责隔离（Active Verifier）**：审查者绝不直接修改作者文件，但必须通过实跑测试、脚本验算或权威检索给出可证伪结论。
- **主控两级防污染铁律（Context Hygiene & Clean Handoff，详见 `references/collaboration-patterns.md` 第 7 节）**：
  1. **盘中排障 1 次上限 → 子智能体隔离**：主控遇到非业务主线的工具/环境/脚本错误，本地顺手修复**最多 1 次**；若失败或需多步诊断、修改工具/依赖，**严禁在主对话继续试错**（`/compact` 仍会残留 `Errors & Fixes` 排障摘要）！Antigravity 主控立即调 `invoke_subagent(TypeName="self", Role="Tooling Debugger", ...)`（Codex 主控拉起不带 `-Resume` 的独立子会话）隔离排障，仅向主上下文回传四项干净回执：**`状态 | 变更文件 | 验证证据 | 残留环境约束`**。
  2. **阶段边界纯状态交接 + 换新对话**：在大阶段切换点（如“工具改造/探路结束 → 进入正式业务实现”且有可验证检查点），或一次状态重述后仍再次遗漏硬约束、重复已否定路线时，登记完工作区修改与在途任务后生成 `<scratch>/handoff.md`（按模板 E 做纯状态投影：严禁抄入 `stderr` 与排障流水账；业务死胡同按 `方法—失败前提—证据—何时可重试` 四元组保留），提示用户开新对话并在新会话首轮先核验交接状态。
- **阶段契约必落盘**：`context_pack.md`、`plan_contract.md`、`handoff.md`、预审结论、分片审稿意见一律写入 `<scratch>/*.md`，确保切换新对话或 Cockpit 切号后均可零损续接。
- 后台外部调用一律异步并行推进，主控在同一回合内继续执行无冲突任务。

### Context & KV Prefix Cache Protocol + 多池 LPT 与空分/时分切片（详见 `collaboration-patterns.md` 第 9–10 节）

1. **静态打包 + 增量 Diff（`scripts/pack-context.ps1`）**：
   - 跨多文件先用 `pack-context.ps1 -WorkDir <d> -Files <f1,f2> -OutFile <scratch>/context_pack.md`（或派 `4H High -Tags scan`）生成静态包（去 BOM、统一 `\n`、单文件默认截断 400 行）；
   - 返修二审先跑本地语法/单测快筛（日志写 `<scratch>/test.log`），再用 `pack-context.ps1 -WorkDir <d> -GitDiff [-BaseRef <ref>] [-AllowedPrefixes <p>] -TestLogFile <scratch>/test.log -OutFile <scratch>/delta_review.md` 仅喂增量 Diff 与末尾 `<= 20` 行测试摘要送 Astra/Opus。
2. **`-ContextFiles` 静态前缀置顶**：调用 `invoke-model.ps1` 时传 `-ContextFiles "<scratch>/context_pack.md,..."`，脚本将其去 BOM、统一 `\n` 后固定拼接在提示词**最顶部**（`=====CONTEXT_PACK: ...=====`），其后接 `=====TASK_INSTRUCTIONS=====` 与动态 `$Prompt`（Codex 自动加 `--add-dir`），吃满模型 KV 前缀缓存。
3. **默认静默 stdout 与 `.events.jsonl` 持久化**：`invoke-model.ps1` 默认不向 `stdout` 输出中间流事件（仅末行输出 1 行 `orchestra_result` JSON），完整事件流实时写入 `$HOME\.cowork\live\<invocation_id>.events.jsonl`（返回 `events_file`，超 7 天自动清理）；仅排障时传 `-StreamStdout`。
4. **`cached_tokens` 缓存遥测**：`$finalResult.usage` 与 `usage.jsonl` 统一记录 `input_tokens`、`output_tokens`、`thinking_tokens`、`cached_tokens`（映射 `agy` `cache_read_tokens` 与 `codex` `cached_input_tokens`）、`total_tokens` 与 `cache_hit_rate`。
5. **`-Resume` vs `-ContextFiles` 选型**：窄域同会话轻量追问且未切号时用 `-Resume <sid>`；独立 Active Verifier、分片并行、Cockpit 切号失效（`resume_invalidated=true`）或阶段切换后一律开新会话 + `-ContextFiles`。
6. **跨池 LPT 并行与 SDM/TDM 切片**：活跃子智能体 `< 2` 时主动跨三池（`agy_google <=6` + `codex_openai <=2` + `agy_anthropic <=2`）同步并发——**LPT 慢关键路径 `T=0` 先发 Astra** + `4H Extra` 并行写互斥 `workspace:"share"` / `tests/`（空分 SDM）+ `Opus 5.5` 重叠做截图 Aesthetic Gate / `<= 800` 字终裁；按微切片推进 `写 -> 审 -> 修` 三拍重叠流水（时分 TDM），优先唤醒 `waiting` 热缓存空闲小工（0 token 待命）执行 Work-Stealing，长日志写文件仅摘 `<= 20` 行入主对话/看板。

---

## 第 4 步：调用外部模型与原子落盘（统一入口）

```powershell
# 若当前 run_command 声明含 BypassSandbox 参数则传 true；无该参数的新版环境直接调用
pack-context.ps1 -WorkDir <d> [-Files <f1,f2> | -GitDiff [-BaseRef <ref>] [-AllowedPrefixes <p>] [-TestLogFile <log>]] -OutFile <out.md>
invoke-model.ps1 -Model <id|别名> -Access read|write -PromptFile <f> -WorkDir <d> [-ContextFiles <f1,f2>] [-Tags <tags>] [-Effort <e>] [-SlotWaitSec <n>] [-NoSlotWait] [-StreamStdout] [-ConnectTimeoutSec <n>] [-AllowCodexShell] [-StatusFile <f>] [-Resume <sid>] [-OutFile <f>] [-JsonSchema <f>] [-DryRun]
extract-files.ps1 -InputFile <f> -Root <d> -AllowedPrefixes <p1,p2> [-ForbiddenPrefixes <f1,f2>] [-DryRun]
```

- 别名与自动升/降档：支持全部模型 ID 与 `best-*` 能力别名；未显式传 `-Effort` 时，`-Tags` 命中 `peak_effort_tags`（`math`）自动升至 `xhigh`，而 `4H`（`tier=fast`）命中 `mechanical_fast_tags`（`bulk/boilerplate/scan/test_gen`）自动降至极速 `high`。
- **三池并发槽位保护（`-SlotWaitSec` / `-NoSlotWait`）**：默认 `-SlotWaitSec 300`，启动前自动在 `$HOME\.cowork\slots` 申请池槽位（`agy_google <=6` / `codex_openai <=2` / `agy_anthropic <=2`），满槽时进入 `queued_slot` 等待，且 **Codex 首包握手计时器（`-ConnectTimeoutSec`）在获槽之后才开始计时**；传 `-NoSlotWait` 或等待超时立刻以退出码 `5`（`ORCHESTRA_LOCK_TIMEOUT`）快速失败。
- 输出末行为汇总 JSON（默认仅此 1 行到 `stdout`），包含 `effort`、`session_id`、`pool`、`slot_wait_sec`、`events_file`、`context_files_count`、`usage`（含 `cached_tokens`、`cache_hit_rate`）、`proxy`、`codex_shell_enabled`、`startup_timeout`、`reconnect_aborted`、`status_file`、`attempts`、`account_switched`、`resume_invalidated`、`quota_error`、`replan_required`、`replan_detail`。
- **熔断拦截**：若 `replan_required=true`（或 `extract-files.ps1` 返回退出码 `3`），严禁强行落盘，主控必须回到只读勘察更新 `plan_contract.md` 后重派。
- **验收后必做**：执行 `record-outcome.ps1 -SessionId <sid> -Outcome ok|redo|fail`。

---

## 第 5 步：35 秒阶段感知看门狗与 Cockpit 切号重连（告别黑盒盲等）

每次通过 `run_command`（`WaitMsBeforeAsync=5000`，仅在工具声明存在 `BypassSandbox` 时传 `true`）在后台启动 `invoke-model.ps1` 后：

1. **实时状态面板**：`invoke-model.ps1` 会实时刷新 `$HOME\.cowork\live\latest-codex.json`（或返回字段中的 `status_file`），包含当前阶段 `phase`（`queued_slot | connecting | connected | reasoning | tool_exec | responding | reconnecting | completed | failed`）、`proxy`、`elapsed_sec`、`reconnect_count`、`last_event_type`。
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

## 第 7 步：初始安装选型、自我维护与自我升级（setup / doctor / calibrate / maintain）

- **安装选型、全局规则同步与更换默认主力阵容**：`setup.ps1 [-ListAvailable] [-Interactive] [-Models <m1,m2,...>] [-ReviewOnlyModels <r1,...>] [-Evaluate auto|research|probe|full|none] [-ForceEvaluate] [-SkipGlobalPlugin]`
  - 当用户首次部署 `cowork` 或要求更换默认参与调度的模型组合时：先跑 `setup.ps1 -ListAvailable` 列出本机 `agy` 与 `Codex` 实测可用的全部模型，请用户选择默认激活的主力模型（支持简写如 `carbon,6.2astra,4h,opus5.5` 或其他任意模型）及是否设仅审查保护模型；选定后执行 `setup.ps1 -Models ... -Evaluate <auto|research|probe|full>` 自动建档、把未选存量模型记入 `baseline_slugs`、对新选模型执行 10 维联网基准调研 + 异构审查（及可选 5 题实测盲评）、重绑 `best-*` 能力别名、同步全套文档，并将 `integrations/cowork-orchestrator-plugin/` 安装到 `~/.gemini/config/plugins/cowork-orchestrator/`（除非传 `-SkipGlobalPlugin`）。
- **一键自检与修复**：`doctor.ps1 [-Repair] [-ProbeCodexShell] [-NoNetwork]`（检查双端 Junction、文档漂移、过期租约、`slot_hygiene` 池槽位健康、调用 `outcome` 回填率及新版 Codex 非交互 shell 自愈探测）。
- **遥测自校准提案**：`calibrate-telemetry.ps1 [-WindowDays 30] [-DryRun]`（聚合近 30 天真实返工率、实测耗时反转与切号健康度，生成待批提案至 `registry/proposals/`，绝不直接改线上分数）。
- **去剧透实测与手动盲评**：`probe-model.ps1 -ModelId <id> [-Grade] [-EmitProposals]`（仅在手动指定时运行；发给被测模型前自动剥离 `Scoring by ...` 评分细则防剧透，`-Grade` 时强制选异构厂商评委匿名盲评并本地核算封顶）。
- **受管文档防漂移同步**：`sync-docs.ps1 [-Check]`（将 `models.json` 与 `route.ps1` 自动同步至 `SKILL.md`、`references/model-profiles.md`、`README.md`）。
- **全链路编排门禁**：`maintain.ps1 [-SkipResearch] [-ForceDetect] [-RunProbe] [-CompactUsage] [-NoGitCommit] [-Push] [-DryRun]`（默认仅联网调研与异构核验，不自动跑耗额度的实测题；任何受管变更必过 `selftest.ps1` 门禁，失败自动原子回滚；门禁全绿后归档冷账本并在本地安全 `git commit`，仅显式传 `-Push` 才推送远端）。
