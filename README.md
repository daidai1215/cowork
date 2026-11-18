# cowork

多模型协同总调度 Skill（面向 **Antigravity (`agy`)**、**OpenAI Codex CLI (`codex`)** 与 **`/swarm` 多智能体编排**共享）。默认以**极致性能（`peak` 模式零额度扣分）**为第一目标，内置 **Orchestrator 规划期双开 `/swarm` + `/cowork` 全局插件（`cowork-orchestrator`）**、**三档主控感知自动分层（`-HostModel orchestrator|carbon|hydrogen` → `orchestrator_fast` / `carbon_peak` / `hydrogen_max`）**、**单点 Swarm `gatekeeper`** 以及 **Context & KV Prefix Cache 静态前缀锁定与静默事件流协议**。

## 当前主力阵容（默认 `peak` 极致性能 / 三档主控感知分层）

<!-- AUTO:ROSTER:START -->
> 自动同步自 `registry/models.json` (`registry_rev: 10`, 活跃模型: 4)

| 模型 | ID / 通道 | 默认档位 | 顶级长板（>=9） | 额度 (`quota_rank`) | 速度 (`speed_rank`) | 运行特性 |
|---|---|---|---|---|---|---|
| **Claude Opus 5.5** | `claude-opus-5-5` (`agy`) | `high` | frontend_aesthetic (10), agentic_coding (9.5) | 1 (稀缺) | 2 (居中) | 仅审查/把关（禁主写）; tools: `web_search`, `browser` |
| **Gemini 4 Carbon** | `gemini-4-carbon` (`agy`) | `high` | long_context (10), prose (10), world_knowledge (10), agentic_coding (9) | 3 (充裕) | 2 (居中) | tools: `web_search`, `browser`, `long_context_1m` |
| **GPT-6.2 Astra** | `gpt-6.2-astra` (`codex`) | `high` (攻坚 `xhigh`) | backend (10), code_rigor (10), image_gen (10), math (10), agentic_coding (9.5), office_docs (9.5), long_context (9) | 2 (中等) | 1 (较慢) | Cockpit 自动切号自愈; tools: `image_gen`, `office_plugins`, `latex`, `browser`, `computer_use` |
| **Gemini 4 Hydrogen** | `gemini-4-hydrogen` (`agy`) | `xhigh` | long_context (9.5) | 3 (充裕) | 3 (最快) | tools: `web_search`, `browser`, `long_context_1m` |

- **可用额度排序（低 → 高）**: Claude Opus 5.5 (`claude-opus-5-5`) < GPT-6.2 Astra (`gpt-6.2-astra`) < Gemini 4 Carbon (`gemini-4-carbon`) < Gemini 4 Hydrogen (`gemini-4-hydrogen`)
- **响应速度排序（快 → 慢）**: Gemini 4 Hydrogen (`gemini-4-hydrogen`) > Claude Opus 5.5 (`claude-opus-5-5`) > Gemini 4 Carbon (`gemini-4-carbon`) > GPT-6.2 Astra (`gpt-6.2-astra`)
- **通道池并发上限 (`pool_concurrency_limits`)**: `codex_openai` <= 4, `agy_anthropic` <= 3, `agy_google` <= 7
<!-- AUTO:ROSTER:END -->

### 标准能力别名与自动路由速查

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

## 目录结构

```text
cowork/
├── SKILL.md                          # 主控执行协议（主控感知路由 → 新模型检测 → 协作/KV缓存 → 看门狗 → 自维护）
├── integrations/
│   └── cowork-orchestrator-plugin/   # 全局常驻 Antigravity 插件（setup.ps1 自动部署至 ~/.gemini/config/plugins/cowork-orchestrator/）
│       ├── plugin.json
│       └── rules/AGENTS.md           # 全对话生效：Orchestrator 规划期双开、三档 -HostModel、KV 缓存与多池 LPT/SDM/TDM 铁律（<=2.2 KB）
├── registry/
│   ├── models.json                   # 数据化模型档案（10 维能力分、锁定标记、别名、硬规则、三档主控与池并发配额）
│   ├── research.schema.json          # 新模型联网调研 JSON Schema
│   ├── probe-grade.schema.json       # 异构匿名盲评输出 JSON Schema
│   ├── CHANGELOG.md                  # 档案修订日志
│   ├── history/                      # 历史版本快照（定额保留 + 自动保护回滚快照）
│   └── proposals/                    # 待人工确认的调分/别名/下架提案（跨源按字段路径去重）
├── references/
│   ├── model-profiles.md             # 各主力模型优缺点与避坑指南
│   ├── collaboration-patterns.md     # 协作模式（含三档主控感知、/swarm 单点 gatekeeper、KV 缓存与多池 LPT/SDM/TDM 协议）与模板
│   └── research-protocol.md          # 新模型自动调研与异构交叉核验协议
├── scripts/
│   ├── setup.ps1                     # 安装引导、阵容切换与 cowork-orchestrator 全局插件同步（支持 -SkipGlobalPlugin）
│   ├── route.ps1                     # 按标签、-HostModel（三档主控感知）、-BusyAgents/-PreferIdle 与 parallel_lanes 自动派工
│   ├── invoke-model.ps1              # 统一跨通道调用入口（三池并发槽位排队、-ContextFiles 置顶缓存、静默 .events.jsonl、cached_tokens 遥测、Cockpit 切号自愈）
│   ├── pack-context.ps1              # 静态上下文打包与 -GitDiff + -TestLogFile (<=20行) 增量审稿打包器
│   ├── detect-models.ps1             # 自动扫描 agy 与 Codex 目录发现新模型 / 离线模型
│   ├── research-prompt.ps1           # 生成新模型联网调研提示词（带防并发租约）
│   ├── apply-research.ps1            # 分级应用调研结果、生成提案与回滚档案
│   ├── record-outcome.ps1            # 记录调用结果（ok/redo/fail），驱动候选模型自动转正或淘汰
│   ├── probe-model.ps1               # 5 道去剧透标准小测题 + 可选手动异构匿名盲评（-Grade）
│   ├── calibrate-telemetry.ps1       # 30 天真实返工率与实测耗时自校准提案器
│   ├── sync-docs.ps1                 # 从 models.json 自动渲染受管文档区块与防漂移校验（-Check）
│   ├── doctor.ps1                    # 环境自检、Junction 自愈、slot_hygiene 池租约清理与新版 Codex shell 能力探测
│   ├── maintain.ps1                  # 一键自我维护与自我升级编排器（含 selftest 门禁回滚与安全 Git 提交）
│   ├── extract-files.ps1             # 双遍原子落盘（Re-plan 硬熔断拦截 + Allowed/Forbidden 分片白黑名单 + 防穿越/Junction）
│   ├── sync-to-codex.ps1             # 创建 ~/.codex/skills/cowork Junction 实现双端同源
│   ├── selftest.ps1                  # 全量静态检查 + 文档防漂移门禁 + 7 套离线回归测试套件
│   └── lib/                          # 公共底层库（分层锁与池槽位信号灯、原子写入、账本幂等归档、SHA-256 凭证指纹、Cockpit 等待）
├── evals/                            # 新模型探测题库与测试夹具
└── tests/                            # 离线回归测试（apply / detect / invoke / maintain / probe / route / setup）
```

## 主控感知加速、多池隔离与 KV 前缀缓存协议

1. **Orchestrator 规划期默认双开（`cowork-orchestrator` 全局常驻规则）**：
   - 主控为 `Orchestrator (Carbon/Argon)` 时，**即便在只读规划 / 勘察 / 架构拆解阶段，也默认开启 `/swarm` + `/cowork`**，并行派出只读 `4H` 勘察员并经 `/cowork` 异步咨询 `GPT-6.2 Astra`，加速立项并避免单线程 Carbon 阻塞；
   - Swarm Worker 显式定型防双跳税：编码/勘察用 `model: "gemini-4-hydrogen-xhigh"`，监控与机械扫描用 `model: "gemini-4-hydrogen-high"`，绝不无脑继承 `Orchestrator`。
2. **三档主控感知自动分层（`route.ps1 -HostModel orchestrator|carbon|hydrogen`）**：
   - `orchestrator_fast` (`-HostModel orchestrator`)：约 80%+ 原 Carbon 负载下放 `4H Extra`，Carbon 留守架构、`paper/essay/copywriting`、`math/algorithm` 复核；
   - `carbon_peak` (`-HostModel carbon`)：Carbon 保持主力，仅大量机械/扫描/样板任务（`bulk/boilerplate/scan/test_gen`）自动分流至 `4H` **`high`** 档提速；
   - `hydrogen_max` (`-HostModel hydrogen`)：Gemini 侧 100% 由 `4H` 执行（推理/编码 `xhigh`、机械 `high`），仅 `paper/essay/copywriting/architecture` 或 `-AllowEscalation` 触发 `final_reviewer = gemini-4-carbon` 终审。
3. **Antigravity 共享池认知 & 单点 Swarm `gatekeeper`**：
   - **Gemini 共享池**：`Carbon` 与 `4H` 同属 Antigravity Gemini 池，分流 `4H` 主要换取 **2.5 倍吞吐速度与低延迟**；**Claude 独立稀缺池**：`Opus 5.5` 只审截图 Aesthetic Gate 或 ≤ 800 字终裁，严禁主写或整池开 Worker；**Codex 外部池**：`GPT-6.2 Astra` 走独立 Codex + Cockpit 自动切号，不耗 Antigravity 配额；
   - `/swarm` 中通过 **1 名单点 `gatekeeper`（`rigor-gate`）** 集中调 `gpt-6.2-astra`（官方直连平时可并发 `<= 4` 路，AIMD 遇 429/切号锁自动 `15s` 收口 1 槽保护、接通即弹回 `4` 槽）与 `claude-opus-5-5`（`<= 3` 路并行审图/终裁）。
4. **Context & KV Prefix Cache Protocol**：
   - **静态包前置**：多文件任务先用 `4H High` 生成 `<scratch>/context_pack.md`，调用 `invoke-model.ps1` 时传 `-ContextFiles` 将其固定置顶于 `=====TASK_INSTRUCTIONS=====` 之前，吃满前缀 KV 缓存；
   - **默认静默 stdout 与遥测**：`invoke-model.ps1` 默认静默不打印中间流 JSON（完整事件写 `$HOME\.cowork\live\<id>.events.jsonl`，7 天清理；仅排障加 `-StreamStdout`），并在 `usage` / `usage.jsonl` 采集 `cached_tokens` 与 `cache_hit_rate`；
   - **`-Resume` 边界、Swarm 复用与日志节流**：仅单路串行窄域续问用 `-Resume`，**并发 Worker/子会话严禁共享同一 `-Resume`**（独立 Verifier / 并行分片 / 切号后统一开新会话 + 共享 `-ContextFiles`）；Swarm 同探索前缀用 `fork` 吃热缓存，可复用 Worker 留 `waiting`（0 耗），按 `#seq` 与单向 `@peer` 隔离看板；长测试输出写日志只摘 `<= 20` 行入主对话。
5. **多池负载均衡、LPT 调度与 SDM/TDM 切片**：
   - **三池槽位限流、AIMD 切号门控与 200ms 错峰（`invoke-model.ps1 -SlotWaitSec -NoSlotWait`）**：基于 `$HOME\.cowork\slots` 实施三池并发配额（`agy_google <=7`、`codex_openai <=4`、`agy_anthropic <=3`），支持死 PID / 陈旧租约自动回收；池内已有活跃进程时自动错峰 `~200ms`（`policy.launch_stagger_ms`）发车，避免 TLS 握手尖峰与 `.codex/*.sqlite` WAL 争抢；遇 `429`/Cockpit 切号瞬时收口 `codex_openai` 至 `1` 槽冷却 `15s`（`codex_rotation_cooldown_sec`），`thread.started` 接通即弹回 `4` 槽；满槽默认在启动前进入 `queued_slot` 排队并上报 `pool` 与 `slot_wait_sec`（Codex 首包握手计时在获槽后开始），传 `-NoSlotWait` 立即返回退出码 `5`；
   - **多池感知与 LPT 泳道（`route.ps1 -BusyAgents -PreferIdle`）**：叠加实时槽位与 `-BusyAgents` 输出 `orchestration.{pool_load, scale_out_hint, parallel_lanes}`；`-PreferIdle` 在严守 `min_cap` 与 `hard_rules` 前提下将任务切往空闲池，活跃 `< 2` 时按 LPT `T=0` 先发 Astra 并同步拉开 `4H` 互斥分片/`tests/` 与 `Opus` 重叠终裁；
   - **增量审稿打包器（`scripts/pack-context.ps1`）**：支持确定性静态打包（`static_pack`）与 `-GitDiff [-AllowedPrefixes] -TestLogFile <log>`（末尾 `<= 20` 行）增量 Diff 打包，配合本地语法/单测快筛实现三拍重叠微切片流水线。

## 安装、自选默认模型与性能评估（Windows PowerShell）

1. 将本仓库克隆至 Antigravity 全局技能目录：
   ```powershell
   git clone https://github.com/daidai1215/cowork.git "$HOME\.gemini\config\skills\cowork"
   ```
2. 运行安装引导器 `setup.ps1`（自动创建 `~/.codex/skills/cowork` Junction、部署 `~/.gemini/config/plugins/cowork-orchestrator/` 全局规则插件、扫描本机 `agy` + `Codex` 全部可用模型、让你自选默认主力阵容，并在选定后自动评估各模型性能、重绑 `best-*` 别名与同步文档；若暂不安装全局插件可加 `-SkipGlobalPlugin`）：
   - **交互式菜单自选**：
     ```powershell
     powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\setup.ps1" -Interactive
     ```
   - **命令行简写直选（例如选 `carbon, 6.2astra, 4h, opus5.5`，并将 `opus5.5` 设为仅把关禁主写）**：
     ```powershell
     powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\setup.ps1" -Models carbon,6.2astra,4h,opus5.5 -ReviewOnlyModels opus5.5 -Evaluate auto
     ```
   - **切换为其他任意本机模型并在选定后全面评估性能**（支持 `-Evaluate auto|research|probe|full|none` 与 `-ForceEvaluate`）：
     ```powershell
     # 先查看本机检测到的全部可选模型列表：
     powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\setup.ps1" -ListAvailable

     # 选定新组合（如 hydrogen + sonnet5.5 + 6.2astra）并立即执行 10 维联网调研 + 5 题异构盲评实测：
     powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\setup.ps1" -Models hydrogen,sonnet5.5,6.2astra -Evaluate full
     ```
3. 前置环境要求：
   - OpenAI Codex CLI（`>= 0.153.0`）与/或 Antigravity CLI 包装脚本 `$HOME\.gemini\bin\agy-exec.ps1`（或环境变量 `MODEL_ORCHESTRA_AGY_WRAPPER`）
   - 运行时状态默认保存在 `$HOME\.cowork\`（含 `state.json`、`live/` 与 `usage.jsonl`，与仓库代码隔离，不会污染 Git 工作区）

## 运行离线自测

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\selftest.ps1"
```

## 隐私与安全边界

- 运行时状态（`$HOME\.cowork\`）与本机凭证完全在仓库目录之外。
- Cockpit 切号检测仅通过 `auth.json` 的修改时间与单向不透明 SHA-256 字节摘要判断账号切换，**绝不解析、输出或持久化任何明文凭证与 Token**。
