# Cowork Lite Rules

1. **动态智能调度（4 维分诊 + 原生探路 + `/swarm` 协同）**
- **开工 4 维分诊（0 延迟）**：对非琐碎任务即时评估「能力短板 × 35s 异步重叠 ROI × 一次通过置信度 × 多模块可拆度」，复杂任务首行输出透明调度卡 `[调度] ...`。
- **大仓原生探路**：遇陌生大仓/模糊大需求先派 1 个只读 `research` 子智能体摸底，按 `registry/models.json` 的 `subagent_tiers` 标定选档——默认 **`flash`**（实测 = `gemini-4-hydrogen-tiered-high`，~8s），深度分析用 **`inherit`**（继承 Neon/Carbon），避开 `flash_lite`（3.5 Lite）与 `pro`（4H xhigh）。
- **主控与 `/swarm` 分工**：精密编码/前端主力用普通 **Gemini 4 Neon (`High`)**；长文/论文/深度架构用普通 **Gemini 4 Carbon (`High`)**（在 Neon 接到典型长文/论文任务先 1 句提醒切 Carbon）；多模块并行开 **`/swarm`**（写代码 Worker 用 `Neon`，扫描/单测 Worker 用 `Hydrogen`，长文档用 `Carbon`）。
- **仅主智能体调用**：无论常规对话还是 `/swarm`，只有主智能体（Coordinator）可调用 `invoke-model.ps1` / `invoke-batch.ps1`；Worker 与子智能体禁止调用 Cowork。

2. **事中自适应升级 & 跨平台异步提速（禁套娃，严控低频）**
- **禁止 AGY 套娃**：Antigravity 内禁止通过 CLI 调用 `agy` 通道的 Gemini 模型（Neon / Carbon / 4H），同平台直接主模型或原生 Subagent / Swarm。
- **T=0 后台抢跑**：确定边界后立刻以 `WaitMsBeforeAsync=5000` 后台启动 Cowork，等待期间主控/Swarm 推进无依赖本地工作，绝不干等。
- **卡壳自适应升级**：中等任务先本地快跑；若同 Bug/单测/数值发散**连续修 2 轮未收敛**或遇隐蔽数学/并发陷阱，自动截取 `-ContextFiles path:start-end` + `<=20` 行报错日志唤 `gpt-6.2-astra` 破局。
- **精准档位与受控并发**：
  - `gpt-6.2-astra`（Codex，默认官方 Fast `service_tier="fast"`，思考锁定 `high`/`xhigh`，Cockpit `account_rotation: true`）：优先 `-Preset code|math|review|office|image` + 行号切片；仅做大块独立重任务，禁碎任务高频调用。
  - `claude-opus-5-5`（AGY，强制只读 `-Access read`，`high`）：仅重要前端终稿截图视觉把关（`-Preset ui`，`<=500` 字，单次）。
  - `invoke-batch.ps1` 硬上限 **`<=3` 并发**且仅限低频独立重任务。

3. **个人偏好、新模型标定与极简验证**
- **个人偏好自进化**：优先遵循 `~/.gemini/config/skills/cowork/registry/preferences.md`（用户纠正路由时追加 1 条，上限 20 条）。
- **新模型发布一次性标定（日常 0 测速）**：仅在新模型发布或平台升级时手动标定 1 次——本地 1 次极短实测确认底层真实模型名与耗时（子智能体查 transcript `model` 字段；外部 CLI 跑 1 次 `"OK"` ping），能力评分全靠 `web_search` 查公开榜单（禁跑本地能力题），结论回写 `registry/models.json`。
- **本地真值前置 & 极简审核/冒烟**：构建、单测、语法报错由本地解决；默认 0 外部审核（仅用户要求、安全/认证/支付/破坏性变更或重要前端终稿视觉把关时最多 1 次单向审核）；日常 0 体检，仅改脚本跑 `scripts\smoke.ps1`（`<5s`）。
