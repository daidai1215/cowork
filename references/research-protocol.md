# 新模型调研协议（Research Protocol）

> 本文件兼作 `scripts/research-prompt.ps1` 的提示词模板，脚本会自动替换文中的 `{{…}}` 占位符。
> 调用命令：`invoke-model.ps1 -Model best-knowledge -Access read -PromptFile <生成的提示词> -JsonSchema registry/research.schema.json -OutFile <scratch>/research-<id>.json`

---

## 调研提示词（模板正文从这里开始）

你是 AI 模型评测分析师。今天是 {{TODAY}}。请**联网检索**以下模型的最新公开信息，并严格按给定的 JSON Schema 输出结构化评估报告。

- 待调研模型 slug：`{{MODEL_ID}}`
- 调研模式：`{{MODE}}`（`new` = 首次建档；`refresh` = 存量档案的 30 天例行刷新，仅需核查上次调研后的新增变化）
- 评估能力维度（每项均需打分）：{{CAP_DIMENSIONS}}
- 各维度当前最强模型（打分参照基准）：
{{INCUMBENTS}}

### 必查信息源（每类至少检索一项，未查获的需记入 `sources_checked` 并注明“未找到”）
1. **官方渠道**：发布公告、model card、system card、API 文档，以及定价、速率限制与订阅额度说明。
2. **综合评测榜**：Artificial Analysis（智能指数、吐字速度、API 定价）、LMArena（总榜与各分项榜）、BenchLM 等。
3. **专项基准测试**：
   - `code_rigor` / `backend` / `agentic_coding`：SWE-bench（Verified / Pro）、DeepSWE、Terminal-Bench、Aider Polyglot；
   - `math`：AIME、FrontierMath、HMMT；
   - `frontend_aesthetic`：WebDev Arena、Design Arena 等前端与 UI 审美榜单；
   - `prose`：Creative Writing / EQ-Bench、长文写作评测；
   - `world_knowledge`：SimpleQA、GPQA、HLE；
   - `long_context`：MRCR、RULER、官方上下文窗口规格；
   - `image_gen`：是否原生支持图像生成，以及 Image Arena 排名；
   - `office_docs`：是否具备原生 Office / PPT 文档处理工具链。
4. **开发者社区口碑**：Reddit（r/LocalLLaMA、r/ClaudeAI、r/OpenAI、r/Bard）、Hacker News、X 平台上的开发者实测反馈，重点提取“在哪些具体场景显著变强或变弱”。
5. **横向对比评测**：该模型与上述各维度现任最强模型的直接对比分析或实测报告。

### 打分规则
- 分值范围 0~10 分，**严格以当前档案分值为标尺**：各维度现任最强模型的基准分见上文。若待调研模型显著更强则给更高分，持平给同分，较弱则酌情扣减。`vs_incumbent` = 本模型得分 − 当前最强模型得分。
- 完全不支持某项能力（如不支持原生生图）记 0 分，`confidence` 记 0.8。
- `confidence` 取值标准：仅凭官方宣称记 0.5；有单一独立基准佐证记 0.6~0.7；有多个独立信源交叉印证记 0.8+；仅有零散传闻记 ≤ 0.4。
- 每个维度的 `evidence` 至少提供一条记录，必须包含 `url`、`claim`（一句话概括，须含具体评测数值）与 `date`。**严禁编造 URL 或数据**；确实查无实据时填空数组，并将 `confidence` 降至 ≤ 0.3。
- `speed_rank_hint` / `quota_rank_hint`：取值 1~3，与档案现有模型横向比较，3 代表速度最快或额度最充裕。
- `channel`：本机调用通道，填 `codex`（OpenAI 系）或 `agy`（Gemini、Claude 等 Antigravity 支持的模型）。
- `supersedes`：若该模型是档案中某现有模型的同系直接继任者（新版本），填被替代模型的 id；否则填 null。
- `suggested_hard_rules`：仅在该模型具备独一无二的原生能力（如“唯一原生支持某项功能”）时提出建议。

### 输出
仅输出符合 Schema 的合法 JSON，不要包含任何额外解释文字或代码围栏说明。

---

## 主控在调研之后的工作（不属于提示词）

1. **异构交叉核验**：将调研生成的 JSON 交由另一厂商模型（通常为 GPT，只读模式）审查。提示词：“逐条核查以下报告中证据和分数是否一致、URL 是否可疑、数字是否失真。只输出 `{"disputed":[{"cap","reason","suggested_score"}]}`。”将返回结果保存为 `cross-check-<id>.json`。
2. **主控重点抽查**：挑出影响最大的 3 条核心结论（通常是得分最高的维度，以及声称超越现任最强模型的维度），亲自调用 `search_web` 查证。凡核实不准确的，一并追加至 disputed 列表。
3. **按需执行基准小测**：若存在分值争议，或该模型声称在某维度超越现任最强模型，则运行 `probe-model.ps1 -ModelId <id>` 实测，并交由对应维度的强项模型交叉盲评（代码与数学由 GPT 评，文笔由 Gemini 评，审美由 Opus 评）。
4. **合并入档**：执行 `apply-research.ps1 -ResearchFile research-<id>.json -CrossCheckFile cross-check-<id>.json`。
5. **向用户汇报**：属自动生效范围的改动，在当前任务结束时用一句话告知用户；属待确认范围的改动，列出生成的提案文件路径，待用户确认后执行 `apply-research.ps1 -Approve <提案>.json` 生效。
