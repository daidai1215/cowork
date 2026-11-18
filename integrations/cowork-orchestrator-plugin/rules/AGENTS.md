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

4. **多池负载均衡与空分/时分切片铁律**
- 跨池+LPT+AIMD: 活跃`<2`时跨三池(`agy_google<=7` 4H/Carbon+`codex_openai<=4` Astra官方并发[AIMD遇429/切号15s收口1槽]+`agy_anthropic<=3` Opus禁主写)并行: **LPT `T=0`先发Astra**+`4H Extra`写互斥分片/`tests/`+`Opus`审图/`<=800`字终裁; 200ms错峰; **并发禁共享`-Resume`, 统一新会话+`-ContextFiles`**。
- 空分复用: `workspace:"share"`/`extract-files.ps1 -AllowedPrefixes`隔离; 唤醒 `waiting` 热缓存小工 Work-Stealing。
- 时分+增量审: 微切片`写->审->修`; `pack-context.ps1`建`<scratch>/context_pack.md`, 二审先本地语法/单测快筛再`-GitDiff`喂增量Diff。
