# Cowork+Swarm全局规则(全对话生效)

1. **Orchestrator 极速立项与执行期双开铁律**
- **执行期双开**: `exit_plan_mode`后高速执行器开`/swarm`(编码/勘察`gemini-4-hydrogen-xhigh`,监控/扫描`gemini-4-hydrogen-high`/`medium`,禁继承`Orchestrator`)+`/cowork`(`$HOME\.gemini\config\skills\cowork\SKILL.md`)。
- **Plan Mode免空转(`<=1`轮)**: 上下文已备或新读`<5`文件**0外调**(禁`/swarm`与`Astra`,Carbon单轮出计划/`exit_plan_mode`); `>=5`未读文件限`1`轮同步外调:省`-OutFile`直读`.response`+`-AutoRecordOk`,禁`schedule 35s`/读`.events.jsonl`/再跑`record-outcome.ps1`。

2. **三档主控感知路由(`route.ps1 -HostModel`)**
- `Orchestrator`->`orchestrator`(`orchestrator_fast`):80%+ Carbon负载交`4H Extra`,Carbon留架构/`paper,essay,copywriting`/`math,algorithm`复核。
- `Gemini 4 Carbon`->`carbon`(`carbon_peak`):仅`bulk/boilerplate/scan/test_gen`转`4H`,余归Carbon。
- `Gemini 4 Hydrogen`->`hydrogen`(`hydrogen_max`):Gemini全走`4H`,仅`paper,essay,copywriting,architecture`或`-AllowEscalation`触发`final_reviewer=gemini-4-carbon`。
- `4H`三档: 纯`scan`->`medium`, `bulk/boilerplate/test_gen`->`high`, 其余->`xhigh`。全模式直通`gpt-6.2-astra`+`claude-opus-5-5`(截图Aesthetic Gate/`<=800`字终裁,禁主写)。

3. **上下文、KV缓存与冷启瘦身**
- 跨多文件先用`4H medium`(`scan`)建`<scratch>/context_pack.md`。
- `invoke-model.ps1`默认静默(勿`-StreamStdout`)+`-ContextFiles`锁静态包顶部吃KV缓存;冷启瘦身: Codex纯推理`--ignore-user-config --ignore-rules`(无`-Resume`配`-AutoRecordOk`自动`--ephemeral`), agy直连`agy.exe --disable-slash-commands`;长测试写日志摘`<=20`行。

4. **多池负载均衡与空分/时分切片铁律**
- 跨池+LPT+AIMD: 活跃`<2`跨三池(`agy_google<=7` 4H/Carbon+`codex_openai<=4` Astra[AIMD 429/切号15s收1槽]+`agy_anthropic<=3` Opus禁主写)并行:**LPT `T=0`先发Astra**+`4H`写互斥分片/`tests/`+`Opus`审图/`<=800`字终裁;200ms错峰;**并发禁共享`-Resume`,新会话+`-ContextFiles`**。
- 空分: `workspace:"share"`/`extract-files.ps1 -AllowedPrefixes`隔离;唤醒`waiting`热缓存小工Work-Stealing。
- 时分: 微切片`写->审->修`;`pack-context.ps1`打包`<scratch>/context_pack.md`,二审先本地语法/单测快筛再`-GitDiff`喂Diff。
