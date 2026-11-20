# Routing Preferences (Max 20 Rules, Human-Editable)

> Append 1 concise line whenever you correct a model-routing decision. Keep `<=20` active rules.

- 涉及复杂数学推导、控制律/优化求解或稳定性证明时，优先 T=0 后台异步调用 Astra (`-Preset math`, `xhigh`, Fast)。
- 涉及 `.pptx`/`.docx`/`.xlsx` 制作修复或原生生图时，直接走 Astra (`-Preset office` / `-Preset image`)，不手写原始 OOXML。
- 内部调试工具/简单管理页面免调 Opus 审 UI；对外展示/汇报/高颜值页面在本地出终稿截图后单次异步调用 Opus (`-Preset ui`，强制只读)。
- 当前主控为 `Neon` 但接到长篇论文/学术润色/深度综述任务时，先用 1 句提醒建议切普通 `Gemini 4 Carbon (High)`。
- 同一 Bug、单测或数值发散问题本地连续修 2 轮仍未收敛时，自动用行号切片 (`path:start-end`) + `<=20` 行报错日志唤 Astra 定位根因。
- 日常小改动（`<100` 行常规代码/简单问答/编译报错）全部本地秒解，不触发外部 CLI。
