# Cowork Lite Rules

1. **角色分工与调用权限（支持 `/swarm` 协同，不含 Orchestrator）**
- **主控分工**：日常编码/精密重构/前端主力用普通 **Gemini 4 Neon (`High`)**；论文/长文/深度架构用普通 **Gemini 4 Carbon (`High`)**；可横向拆分的独立多模块大工程开 **`/swarm`**（写代码 Worker 用 `Neon`，扫描/单测 Worker 用 `Hydrogen`）。
- **仅主智能体调用**：无论常规对话还是 `/swarm`，**只有主智能体（Coordinator）**可调用 `invoke-model.ps1` / `invoke-batch.ps1`；Swarm Worker 与子智能体一律禁止调用 Cowork。

2. **跨平台异步提速（禁止同平台套娃，严控低频）**
- **禁止 AGY 套娃**：在 Antigravity 内禁止通过 CLI 调用 `agy` 通道的 Gemini 模型（Neon / Carbon / 4H），同平台直接主模型或原生 Subagent / Swarm。
- **T=0 后台抢跑**：确定边界后立刻以 `WaitMsBeforeAsync=5000` 后台启动 Cowork，等待期间主控/Swarm 推进无依赖本地工作，绝不干等。
- **精准瘦身与硬核档位**：
  - `gpt-6.2-astra`（Codex，默认官方 Fast 加速 `service_tier="fast"`，思考锁定 `high` / `xhigh`，配合 Cockpit `account_rotation: true`）：优先用 `-Preset code|math|review|office|image` + `-ContextFiles path:start-end` 行号切片；仅做大块独立重任务（复杂后端/并发、数学算法推导、根因排查、原生生图、`office_plugins`），绝不做碎任务高频调用。
  - `claude-opus-5-5`（AGY，强制只读 `-Access read`，`high`）：仅用于重要前端终稿截图视觉把关（`-Preset ui`，`<=500` 字，单次），绝不做后端或写代码。
- **受控并发上限**：多路独立重任务可使用 `invoke-batch.ps1`，严格硬上限 **`<=3` 并发**且仅限低频场景。

3. **本地真值前置、极简审核与冒烟**
- **本地真值前置**：构建、单测、语法报错由本地 Neon / Hydrogen 解决，绝不把编译/粗加工丢给外部 CLI。
- **默认 0 外部审核**：日常任务主控本地自检直接交付（无 Polisher / Final Reviewer / Dual Draft）；仅用户明确要求、安全/认证/支付/破坏性变更或重要前端终稿视觉把关时，触发最多 1 次单向审核。
- **极简验证**：日常 0 体检；仅改 Cowork 脚本后跑 `scripts\smoke.ps1`（`<3s`），排查故障时才手动 1-shot ping（调用前告知 ETA `~20-45s`）。
