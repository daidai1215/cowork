# Proposal: gemini-4-carbon

Base revision: 2

Disputed capability is frozen until explicit approval. Review research_score, suggested_score, and reason.

Approval preserves cap locks. Set unlock:true only for a permanent cap unlock.
Cross-check: {"cap":"agentic_coding","research_score":9,"suggested_score":9,"reason":"59分、第二名可由[AA发布说明](https://artificialanalysis.ai/articles/gemini-4-carbon-new-number-1)核实，9分可暂留，但LMArena Agent第二名仅引用首页，缺少榜单快照。"}

```json
[
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.agentic_coding.score",
        "old_value":  7,
        "value":  9,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.agentic_coding.source",
        "old_value":  "inherited",
        "value":  "public",
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.agentic_coding.confidence",
        "old_value":  0.4,
        "value":  0.6,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.agentic_coding.evidence",
        "old_value":  [

                      ],
        "value":  [
                      {
                          "claim":  "Artificial Analysis Coding Agent Index（搭配 Antigravity CLI）得分 59，位居全球第 2（仅次于 Claude Opus 5.5 的 62 分）；LMArena Agent Arena 排名第 2。",
                          "date":  "2026-10-28",
                          "url":  "https://artificialanalysis.ai/models/gemini-4-carbon"
                      },
                      {
                          "claim":  "Terminal-Bench 4.0 得分 65.2%（成功作弊率降至 0.0%），SWE-sweep 得分 9.6%（为 Argon 4.3% 的两倍以上），SEC-bench Pro 达 88.2%。",
                          "date":  "2026-10-28",
                          "url":  "https://blog.google/technology/ai/gemini-4-carbon/"
                      }
                  ],
        "unlock":  false
    }
]
```
