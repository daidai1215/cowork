# cowork

多模型协同总调度 Skill（面向 **Antigravity (`agy`)** 与 **OpenAI Codex CLI (`codex`)** 双端共享），结合各家旗舰模型的强弱项、额度稀缺度、响应速度与线上口碑进行任务路由、流水线互审、审美把关（Aesthetic Gate）、真伪双查（Truth Gate）以及新模型自动发现与分级入档。

## 当前主力阵容（默认全开 `high` 档）

| 模型 | 通道 | 核心强项 | 额度与速度特征 |
|---|---|---|---|
| **GPT-6 Astra (`high`)** | `codex` | 代码严谨性、后端并发、复杂数学推导、原生 `image_gen` 生图、Office 插件链 | 速度最慢；单号额度较少，支持 **Cockpit 自动切号中断自愈** |
| **Gemini 4 Carbon (`high`)** | `agy` | 文笔定稿、世界知识综述、1M 超长上下文通读、日常高速 Agentic 工程 | 三家最快、额度最充裕（事实类输出强制叠加 Truth Gate） |
| **Claude Opus 5.5 (`high`)** | `agy` | 前端 UI 视觉审美、排版品味与复杂架构把关（Aesthetic Gate） | 速度居中、额度最稀缺（仅审多视口截图与 design tokens） |

## 目录结构

```text
cowork/
├── SKILL.md                          # 主控执行协议（身份识别 → 新模型检测 → 路由 → 协作 → 90s 看门狗）
├── registry/
│   ├── models.json                   # 数据化模型档案（10 维能力分、锁定标记、别名、硬规则、轮换参数）
│   ├── research.schema.json          # 新模型联网调研 JSON Schema
│   ├── CHANGELOG.md                  # 档案修订日志
│   ├── history/                      # 历史版本快照（支持一键回滚）
│   └── proposals/                    # 待人工确认的调分/别名/下架提案
├── references/
│   ├── model-profiles.md             # 各主力模型优缺点与避坑指南
│   ├── collaboration-patterns.md     # 5 种协作模式（含原 gpt-write / gpt-review）与提示词模板
│   └── research-protocol.md          # 新模型自动调研与异构交叉核验协议
├── scripts/
│   ├── route.ps1                     # 按标签与模式（balanced/quality/economy/fast）自动派工
│   ├── invoke-model.ps1              # 统一跨通道调用入口（含 Cockpit 自动切号等待、指纹校验与重试）
│   ├── detect-models.ps1             # 自动扫描 agy 与 Codex 目录发现新模型 / 离线模型
│   ├── research-prompt.ps1           # 生成新模型联网调研提示词（带防并发租约）
│   ├── apply-research.ps1            # 分级应用调研结果、生成提案与回滚档案
│   ├── record-outcome.ps1            # 记录调用结果（ok/redo/fail），驱动候选模型自动转正或淘汰
│   ├── probe-model.ps1               # 5 道标准小测题快速摸底新模型
│   ├── extract-files.ps1             # 安全落盘文本交付代码块（路径白名单 + 防目录穿越/Junction）
│   ├── sync-to-codex.ps1             # 创建 ~/.codex/skills/cowork Junction 实现双端同源
│   ├── selftest.ps1                  # 全量静态检查 + 5 套离线回归测试套件
│   └── lib/                          # 公共底层库（文件锁、原子写入、SHA-256 凭证指纹、Cockpit 静默等待）
├── evals/                            # 新模型探测题库与测试夹具
└── tests/                            # 离线回归测试（apply / detect / invoke / probe / route）
```

## 安装与双端同步（Windows PowerShell）

1. 将本仓库克隆至 Antigravity 全局技能目录：
   ```powershell
   git clone https://github.com/daidai1215/cowork.git "$HOME\.gemini\config\skills\cowork"
   ```
2. 同步创建 Codex CLI 端的 Junction（使 Antigravity 与 Codex 共享同一份技能与档案）：
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\sync-to-codex.ps1"
   ```
3. 确保本机已配置：
   - OpenAI Codex CLI（`>= 0.153.0`）
   - Antigravity CLI 包装脚本 `$HOME\.gemini\bin\agy-exec.ps1`（或通过环境变量 `MODEL_ORCHESTRA_AGY_WRAPPER` 指定路径）
   - 运行时状态默认保存在 `$HOME\.cowork\`（含 `state.json` 与 `usage.jsonl`，与仓库代码隔离，不会污染 Git 工作区）

## 运行离线自测

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.gemini\config\skills\cowork\scripts\selftest.ps1"
```

## 隐私与安全边界

- 运行时状态（`$HOME\.cowork\`）与本机凭证完全在仓库目录之外。
- Cockpit 切号检测仅通过 `auth.json` 的修改时间与单向不透明 SHA-256 字节摘要判断账号切换，**绝不解析、输出或持久化任何明文凭证与 Token**。
