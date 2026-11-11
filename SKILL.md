---
name: cowork
description: 【多模型协同总调度】在 GPT-6 Astra high（Codex + Cockpit 自动切号）、Gemini 4 Carbon high、Claude Opus 5.5 high（Antigravity/agy）之间，按任务类型、模型强项、额度与速度自动派工、互审与真伪双查；内置 Cockpit 切号中断自愈，自动发现新模型、联网调研并自适应调整策略。已并入原 gpt-write（GPT 执笔）与 gpt-review（GPT 审稿）——提及 cowork、多模型配合、多模型协作、派工、gpt-write、gpt-review、GPT 执笔、GPT 审稿、Opus 把关审美、Gemini 润色时触发。
---

# cowork：多模型协同总调度

**唯一源**：`$HOME\.gemini\config\skills\cowork`（下称 `ROOT`）。Codex 端的 `~\.codex\skills\cowork` 是指向此处的 Junction。
**运行时状态**：`$HOME\.cowork\`。其中 `state.json` 记录额度状态、基线与扫描时间，`usage.jsonl` 记录调用账本。
**当前主力阵容与资源排序（由 `scripts/sync-docs.ps1` 自动同步）**：
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

| 想做什么 | 看哪里 |
|---|---|
| 三大主力模型强弱项与口碑档案 | `references/model-profiles.md` |
| 5 种协作模式与提示词模板（含原 gpt-write / gpt-review 全部规则） | `references/collaboration-patterns.md` |
| 新模型调研协议 | `references/research-protocol.md` |
| 机器可读档案（分数、别名、硬规则、策略参数） | `registry/models.json` |

---

## 第 0 步：确认自己是谁（主控身份）

**当前对话所用模型即主控**，负责决策拍板、结果整合与最终验收。所有模型调用默认统一使用 `high` 档，除非用户显式要求其他档位。

| 你在哪 | 你是谁 | 怎么调用 GPT-6 Astra (`high`) | 怎么调用 Carbon / Opus (`high`) |
|---|---|---|---|
| Antigravity，主控为 Gemini 4 Carbon | 起草与长文/检索主力兼主控 | `invoke-model.ps1 -Model gpt-6-astra` | 调用 Opus：`invoke-model.ps1 -Model claude-opus-5-5` |
| Antigravity，主控为 Claude Opus 5.5 | **惜用模式的主控** | 同上 | 调用 Carbon：`invoke-model.ps1 -Model gemini-4-carbon` |
| Codex，主控为 GPT-6 Astra | 严谨执行兼主控 | （自身即 Astra） | `invoke-model.ps1 -Model gemini-4-carbon` / `claude-opus-5-5`，**必须申请 `sandbox_permissions="require_escalated"`**，否则会误报 “not logged into Antigravity”；不要给 agy 加 `--sandbox` |

- **Opus 任主控时**：整段对话都在消耗最稀缺额度。主控仅做决策拍板与审美把关，大段起草与检索一律派给 Gemini 4 Carbon 或 GPT-6 Astra。
- **GPT-6 Astra 任主控时**：响应最慢且单账号额度较少，文字定稿、全库通读与检索派给 Gemini 4 Carbon，审美把关派给 Opus 5.5，主控专注核心实现与数学/严谨性把关。

### 已知环境限制与 Cockpit 自动切号防护（必读）

1. **Cockpit 自动切换 Codex 账号（核心运行机制）**：
   - `gpt-6-astra` 单个账号额度较少，本机 **Cockpit** 会在后台自动切换 `~\.codex\auth.json`（期间在 `~\.codex\.cockpit-profile-mutation-locks` / `.cockpit-token-locks` 产生短暂锁，并对历史会话执行加密推理清洗）。
   - **严禁触碰明文凭证**：任何检查只允许看 `auth.json` 的 `LastWriteTime` 或由脚本计算不透明 SHA-256 指纹，**绝不读取或打印 `auth.json` 内容**。
   - **`invoke-model.ps1` 已内置切号自愈**：
     - 单账号触发 429/额度限制，或执行途中因切号发生 401/流中断（`auth.json` 指纹变化）时，脚本**不会立即封禁模型**，而是自动等待 Cockpit 完成切号与锁释放（默认等 10 秒，最多自动重试 2 次 = 共 3 次尝试）。
     - 仅当连续 3 次尝试均报额度耗尽（说明 Cockpit 账号池全部耗尽）时，才将 `gpt-6-astra` 短暂标记 `exhausted` **30 分钟**并返回退出码 4，再由主控切换 `fallback`。
   - **跨账号 `-Resume <sid>` 失效处理（`resume_invalidated=true`）**：
     - 旧账号会话中的加密推理状态（`encrypted_content`）在切到新账号后可能无法续跑。一旦返回 JSON 中 `resume_invalidated=true`（或切号后 `-Resume` 报错），**严禁继续对旧 `<sid>` 重试**！必须立即**去掉 `-Resume` 开启新会话**，将 `<scratch>` 目录中已保存的共识方案、分块上下文或增量材料内联进提示词续接。
2. **PATH 上的 `codex.exe` 为 0.145 旧版**：必须使用桌面版自带的新版 `%LOCALAPPDATA%\OpenAI\Codex\bin\<hash>\codex.exe`（`invoke-model.ps1` 自动解析）。
3. **非交互 `codex exec` 中 GPT 的 shell 工具（code-mode host）限制与自进化探测**：
   - 若 `$HOME\.cowork\state.json` 中 `codex_shell_probe.shell_works == true` 且版本匹配当前 `codex.exe`，说明新版 Codex CLI 已修复非交互 shell 卡死问题，可直接按需放行；否则向 GPT-6 Astra 派工时必须绕开 shell 工具调用：
   - 审查类任务：将待审材料直接内联进提示词，明确声明“不要调用任何工具”；
   - 实现类任务：要求按 `=====FILE: <相对路径>=====` … `=====END FILE=====` 纯文本输出完整文件，由主控执行 `scripts/extract-files.ps1 -InputFile <回答> -Root <项目> -AllowedPrefixes <允许写的前缀>` 落盘并实跑测试；
   - agy（Gemini 4 Carbon / Opus 5.5）的文件与终端工具正常，可直接使用 `-Access write`。
4. **PowerShell 5.1 编码陷阱**：含中文的 `.ps1` 必须保存为 UTF-8 with BOM（`extract-files.ps1` 已自动处理），命令行不要直接传中文字面量，统一走 `-PromptFile`。

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

## 第 2 步：派工

1. 为任务打标签（见 `models.json` 的 `tags`，如 `frontend, landing_page, backend, math, prose, paper, research, image_gen, ppt, refactor`）。
2. 执行 `route.ps1 -Tags <标签…> [-Mode balanced|quality|economy|fast]`，获取 `primary / reviewer / polisher / fallback / pattern / reasons`。
3. 主控可否决 route 的建议，但必须在最终汇报中说明理由。

**硬规则**（route 已内置，主控必须遵守）：
- 生图仅走 Codex（`gpt-6-astra` `image_gen`）。
- 前端、UI、落地页走 Aesthetic Gate：Gemini 4 Carbon (`high`) 起草，Opus 5.5 (`high`) 仅审阅多视口截图、design tokens 与关键组件片段（靠精简输入省额度，不降推理档位）；Opus 不可用时由 Carbon 按设计检查清单独立自审。
- 数学与后端的正确性主写与把关优先走 `best-rigor`（`gpt-6-astra` `high`），由异构厂商模型（`gemini-4-carbon` `high`）复核接口、上下文一致性与实跑验证。
- 最终文字润色交给 `best-prose`（`gemini-4-carbon` `high`），剔除一切防御性写作表述。

**标准别名与常见任务速查**（由 `scripts/sync-docs.ps1` 自动从 `models.json` 与 `route.ps1` 渲染）：
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

## 第 3 步：按模式协作

详细步骤见 `references/collaboration-patterns.md`：

| pattern | 一句话 |
|---|---|
| `solo` | 单模型直接执行，主控验收 |
| `delegate_execute`（原 gpt-write） | 主控与执行者协商（落盘方案） → 主控拍板 → 执行者交付 → 主控独立验收 |
| `pipelined_review`（原 gpt-review） | 方案预审（落盘共识） → 主控写一块、审查者审上一块 → 完稿汇总终审 → 主控裁决 |
| `aesthetic_gate` | Carbon 写前端，Opus 5.5 (`high`) 仅审截图与 tokens，最多 2 轮 |
| `strength_delegation` | 生图、Office、LaTeX、重度形式推导外包给 GPT-6 Astra，后台并行 |
| Truth Gate（叠加在任何模式上） | 涉及文献、数据、API、公式真伪时：异构模型交叉查证，主控最后亲自复核 |

**额度与并发铁律**：
- 三个模型统一保持 `high` 档；Opus 靠“只传截图 + tokens + 关键片段、只审不铺写长文”省额度；Astra 靠“精准派发硬核子任务、不让它写普通长文”减少切号频率。
- **阶段状态必落盘**：协商方案、预审结论、分块审稿意见一律写入 `<scratch>/*.md`，确保 Cockpit 随时切换 Astra 账号导致旧会话失效时，新会话能直接读取磁盘状态零损续接。
- GPT-6 Astra 任务委派后一律放入后台运行，主控在同一回合内并行推进其他工作。

---

## 第 4 步：调用外部模型（统一入口）

```powershell
invoke-model.ps1 -Model <id|别名> -Access read|write -PromptFile <f> -WorkDir <d> [-Resume <sid>] [-OutFile <f>] [-Tags …] [-Effort …] [-JsonSchema <f>] [-DryRun]
```

- 别名：支持 `models.json` 中的全部模型 ID 与 `best-*` 能力别名（见第 2 步自动同步表）。
- 输出末行为汇总 JSON，包含 `session_id`、`attempts`、`account_switched`、`resume_invalidated`、`quota_error`。
- **验收后必做**：执行 `record-outcome.ps1 -SessionId <sid> -Outcome ok|redo|fail`。

---

## 第 5 步：90 秒看门狗与 Cockpit 切号重连（必须遵守）

每次通过 `run_command`（`WaitMsBeforeAsync=500`）在后台启动 `invoke-model.ps1`（或 `codex.exe`）后：

1. **立即挂载看门狗**：`schedule(DurationSeconds=90, TimerCondition="<TaskId>", Prompt="Inspect GPT background task (<TaskId>) status and log heartbeat; re-arm 90s timer if progressing, or kill and auto-reconnect if hung/failed.")`
2. **被唤醒后**：执行 `manage_task(status)` 查看近期日志。
   - 若任务已结束：
     - `exit=0`：正常读取产出；若 `account_switched=true`，在《协同摘要》中简注“期间 Cockpit 自动切换账号并自愈成功”。
     - `resume_invalidated=true`：说明 Cockpit 切号导致旧 `<sid>` 无法跨账号续跑，**立即去掉 `-Resume`**，将 `<scratch>` 中的阶段上下文内联进提示词重新发起新会话！
     - `exit=4`（`quota_error=true`）：说明重试后账号池仍无可用额度，按 route 的 `fallback` 降级并告知用户。
   - 若任务仍在运行但 90 秒无新输出：
     1. 检查会话日志 `~\.codex\sessions\YYYY\MM\DD\rollout-*-<sid>.jsonl` 的 `LastWriteTime` 与子进程存活状态；
     2. **【Cockpit 切号静默卡死特判】** 检查 `(Get-Item "$HOME\.codex\auth.json").LastWriteTime`（**严禁读取文件内容**）：若 `auth.json` 的修改时间**晚于**本后台任务的启动时间，且 `rollout` 已超过 60 秒无新写入，说明 Cockpit 切号导致旧连接静默断流卡死——**不要再等第二个 90 秒，立即判定中断并重连！**
     3. 若 `auth.json` 未变且进程仍在正常推理，续挂 90 秒；连续两次检查（≥ 180 秒）均无任何进展，或卡在 `Reading additional input from stdin...`，判定为卡死。
3. **判定卡死或切号静默中断后**：
   1. 执行 `manage_task(kill)`，并**仅按 PID 清理本任务的进程树**（切勿按进程名通杀 `codex.exe`，以免误伤桌面端或其他会话）。
   2. 若刚发生 Cockpit 切号，先确认 `~\.codex\.cockpit-profile-mutation-locks` 无最近几秒的活动锁（或稍等 5~10 秒）。
   3. 自动重连（最多 3 次）：
      - **未切号时**：优先用确切 `<sid>` 执行 `invoke-model.ps1 -Model gpt-6-astra -Resume <sid> ...`（拿不到 `<sid>` 且核对最新 rollout 的 cwd/时间匹配本任务时才用 `resume --last`）；
      - **已发生 Cockpit 切号时**：对于只读审查或文本块交付任务，**直接不带 `-Resume` 在新账号重跑**（最稳，彻底避开旧账号加密推理块冲突）；对于必须续接的多轮任务，若带 `-Resume <sid>` 报 `resume_invalidated` 或立即失败，立刻切换为不带 `-Resume` 的新会话并内联 `<scratch>` 已存状态；
      - 若发现 rollout 末条为工具调用卡死，重连提示词追加“不要调用任何工具，直接基于已有信息作答”；
      - agy 通道：附带 `--conversation <id>` 续跑。
   4. 为重连后的新任务重新挂载 90 秒看门狗。
4. 连续 3 次重连均失败时：按 route 的 `fallback` 切换备用模型，并告知用户。

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
