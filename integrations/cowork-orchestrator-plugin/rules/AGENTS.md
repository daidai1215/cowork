# Cowork + Swarm 全局自动加速规则(全对话生效)

1. **Orchestrator 规划期双开铁律**
- `Orchestrator (Carbon/Argon)` 默认开 `/swarm`(`native_swarm`)+`/cowork`(`$HOME\.gemini\config\skills\cowork\SKILL.md`)；只读规划/勘察/拆解亦开 `/swarm` 派只读 `4H` 勘察+`/cowork` 异步咨询 `GPT-6.2 Astra`，避单线程 Carbon 阻塞。
- Worker 显式定型防双跳税：编码/勘察 `model: "gemini-4-hydrogen-xhigh"`，监控/扫描 `model: "gemini-4-hydrogen-high"`，禁继承 `Orchestrator`。

2. **三档主控感知路由(`route.ps1 -HostModel`)**
- `Orchestrator`->`orchestrator`(`orchestrator_fast`)：80%+ Carbon 负载交 `4H Extra`，Carbon 留架构/`paper,essay,copywriting`/`math,algorithm` 复核。
- `Gemini 4 Carbon`->`carbon`(`carbon_peak`)：仅 `bulk/boilerplate/scan/test_gen` 转 `4H` `high`，余归 Carbon。
- `Gemini 4 Hydrogen(4H/4H Extra)`->`hydrogen`(`hydrogen_max`)：Gemini 全走 `4H`，仅 `paper,essay,copywriting,architecture` 或 `-AllowEscalation` 触发 `final_reviewer=gemini-4-carbon`。
- 全模式直通 `gpt-6.2-astra`(后端/并发/数学/Bug/生图/Office)+`claude-opus-5-5`(只审截图 Aesthetic Gate 或 `<=800` 字终裁，禁主写)。

3. **上下文与 KV 缓存铁律**
- 跨多文件先用 `4H High` 生成 `<scratch>/context_pack.md`。
- `invoke-model.ps1` 用默认静默流(勿传 `-StreamStdout`)+`-ContextFiles` 锁静态包顶部吃 KV 缓存；长测试写日志摘 `<=20` 行入主对话。
