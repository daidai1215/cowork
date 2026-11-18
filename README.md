# cowork

多模型协同总调度 Skill（面向 **Antigravity (`agy`)**、**OpenAI Codex CLI (`codex`)** 与 **`/swarm` 多智能体编排**共享）。默认以**极致性能（`peak` 模式零额度扣分）**为第一目标，同时支持 **`-Mode fast_4h`（4H Extra `xhigh` 快速分级，将大部分原 Carbon 负载下放 4H Extra，仅少数高要求论文/深度长文与算法复核保留 Carbon）**，以及 **`/swarm` 下经 `cowork` 统一调用 `Claude Opus 5.5` 与 `GPT-6.2 Astra`**。

## 当前主力阵容（默认 `peak` 极致性能 / 按需 `fast_4h` 4H Extra 快速分级）

<!-- AUTO:ROSTER:START -->
> 自动同步自 `registry/models.json` (`registry_rev: 7`, 活跃模型: 4)

| 模型 | ID / 通道 | 默认档位 | 顶级长板（>=9） | 额度 (`quota_rank`) | 速度 (`speed_rank`) | 运行特性 |
|---|---|---|---|---|---|---|
| **Claude Opus 5.5** | `claude-opus-5-5` (`agy`) | `high` | frontend_aesthetic (10), agentic_coding (9.5) | 1 (稀缺) | 2 (居中) | 仅审查/把关（禁主写）; tools: `web_search`, `browser` |
| **Gemini 4 Carbon** | `gemini-4-carbon` (`agy`) | `high` | long_context (10), prose (10), world_knowledge (10), agentic_coding (9) | 3 (充裕) | 2 (居中) | tools: `web_search`, `browser`, `long_context_1m` |
| **GPT-6.2 Astra** | `gpt-6.2-astra` (`codex`) | `high` (攻坚 `xhigh`) | backend (10), code_rigor (10), image_gen (10), math (10), agentic_coding (9.5), office_docs (9.5), long_context (9) | 2 (中等) | 1 (较慢) | Cockpit 自动切号自愈; tools: `image_gen`, `office_plugins`, `latex`, `browser`, `computer_use` |
| **Gemini 4 Hydrogen** | `gemini-4-hydrogen` (`agy`) | `xhigh` | long_context (9.5) | 3 (充裕) | 3 (最快) | tools: `web_search`, `browser`, `long_context_1m` |

- **可用额度排序（低 → 高）**: Claude Opus 5.5 (`claude-opus-5-5`) < GPT-6.2 Astra (`gpt-6.2-astra`) < Gemini 4 Carbon (`gemini-4-carbon`) < Gemini 4 Hydrogen (`gemini-4-hydrogen`)
- **响应速度排序（快 → 慢）**: Gemini 4 Hydrogen (`gemini-4-hydrogen`) > Claude Opus 5.5 (`claude-opus-5-5`) > Gemini 4 Carbon (`gemini-4-carbon`) > GPT-6.2 Astra (`gpt-6.2-astra`)
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

- **4H Extra 快速模式 (`-Mode fast_4h`)**: 将大部分 `gemini-4-carbon` 任务下放 `gemini-4-hydrogen` (`xhigh`)，仅高要求主写 (`paper`, `essay`, `copywriting`), 高要求审查 (`math`, `algorithm`) 及 `-AllowEscalation` 保留给 `gemini-4-carbon` (后端/数学/生图/Office 主攻仍由 GPT-6.2 Astra 承担):

| 快速场景 (`fast_4h`) | `-Tags` | 主执行 | 审查 | 升级兜底 |
|---|---|---|---|---|
| 前端 / UI / 落地页 | `frontend,landing_page` | `gemini-4-hydrogen` (`xhigh`) | `claude-opus-5-5` (`high`) | `gemini-4-carbon` |
| 检索 / 大仓库预读 | `research,long_context` | `gemini-4-hydrogen` (`xhigh`) | `gpt-6.2-astra` (`high`) | `gemini-4-carbon` |
| 日常文档 / 总结 | `prose` | `gemini-4-hydrogen` (`xhigh`) | `gpt-6.2-astra` (`high`) | `gemini-4-carbon` |
| 高要求论文 / 深度长文 | `prose,paper` | `gemini-4-carbon` (`high`) | `gpt-6.2-astra` (`high`) | - |
| 常规后端 / Bugfix | `bugfix` | `gpt-6.2-astra` (`high`) | `gemini-4-hydrogen` (`xhigh`) | - |
| 数学 / 算法验算 | `math,algorithm` | `gpt-6.2-astra` (`xhigh`) | `gemini-4-carbon` (`high`) | - |
<!-- AUTO:ROUTING:END -->

## 目录结构

```text
cowork/
├── SKILL.md                          # 主控执行协议（身份识别 → 新模型检测 → 路由 → 协作 → 90s 看门狗 → 自维护）
├── registry/
│   ├── models.json                   # 数据化模型档案（10 维能力分、锁定标记、别名、硬规则、轮换与自维护策略）
│   ├── research.schema.json          # 新模型联网调研 JSON Schema
│   ├── probe-grade.schema.json       # 异构匿名盲评输出 JSON Schema
│   ├── CHANGELOG.md                  # 档案修订日志
│   ├── history/                      # 历史版本快照（定额保留 + 自动保护回滚快照）
│   └── proposals/                    # 待人工确认的调分/别名/下架提案（跨源按字段路径去重）
├── references/
│   ├── model-profiles.md             # 各主力模型优缺点与避坑指南
│   ├── collaboration-patterns.md     # 6 种协作模式（含只读契约、Re-plan if 熔断、分片并行、双旗舰竞标）与模板
│   └── research-protocol.md          # 新模型自动调研与异构交叉核验协议
├── scripts/
│   ├── setup.ps1                     # 安装引导与阵容切换器（扫描本机模型 → 自选默认主力/仅审查模型 → 自动评估 10 维性能并同步文档）
│   ├── route.ps1                     # 按标签与模式（默认 peak 零税冲上限，支持自动升 xhigh 与双旗舰竞标）自动派工
│   ├── invoke-model.ps1              # 统一跨通道调用入口（含自动升档、Re-plan 熔断检测、Cockpit 自动切号等待与重试）
│   ├── detect-models.ps1             # 自动扫描 agy 与 Codex 目录发现新模型 / 离线模型
│   ├── research-prompt.ps1           # 生成新模型联网调研提示词（带防并发租约）
│   ├── apply-research.ps1            # 分级应用调研结果、生成提案与回滚档案
│   ├── record-outcome.ps1            # 记录调用结果（ok/redo/fail），驱动候选模型自动转正或淘汰
│   ├── probe-model.ps1               # 5 道去剧透标准小测题 + 可选手动异构匿名盲评（-Grade）
│   ├── calibrate-telemetry.ps1       # 30 天真实返工率与实测耗时自校准提案器
│   ├── sync-docs.ps1                 # 从 models.json 自动渲染受管文档区块与防漂移校验（-Check）
│   ├── doctor.ps1                    # 环境自检、Junction 自愈与新版 Codex shell 能力探测
│   ├── maintain.ps1                  # 一键自我维护与自我升级编排器（含 selftest 门禁回滚与安全 Git 提交）
│   ├── extract-files.ps1             # 双遍原子落盘（Re-plan 硬熔断拦截 + Allowed/Forbidden 分片白黑名单 + 防穿越/Junction）
│   ├── sync-to-codex.ps1             # 创建 ~/.codex/skills/cowork Junction 实现双端同源
│   ├── selftest.ps1                  # 全量静态检查 + 文档防漂移门禁 + 6 套离线回归测试套件
│   └── lib/                          # 公共底层库（文件锁、原子写入、账本幂等归档、SHA-256 凭证指纹、Cockpit 等待）
├── evals/                            # 新模型探测题库与测试夹具
└── tests/                            # 离线回归测试（apply / detect / invoke / maintain / probe / route）
```

## 安装、自选默认模型与性能评估（Windows PowerShell）

1. 将本仓库克隆至 Antigravity 全局技能目录：
   ```powershell
   git clone https://github.com/daidai1215/cowork.git "$HOME\.gemini\config\skills\cowork"
   ```
2. 运行安装引导器 `setup.ps1`（自动创建 `~/.codex/skills/cowork` Junction、扫描本机 `agy` + `Codex` 全部可用模型、让你自选默认主力阵容，并在选定后自动评估各模型性能、重绑 `best-*` 别名与同步文档）：
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
