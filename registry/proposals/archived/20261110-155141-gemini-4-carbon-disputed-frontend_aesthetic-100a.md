# Proposal: gemini-4-carbon

Base revision: 2

Disputed capability is frozen until explicit approval. Review research_score, suggested_score, and reason.

Approval preserves cap locks. Set unlock:true only for a permanent cap unlock.
Cross-check: {"cap":"frontend_aesthetic","research_score":8,"suggested_score":8,"reason":"1768 Elo、第四名及提升89分可由[正确Google公告](https://blog.google/innovation-and-ai/models-and-research/gemini-models/introducing-gemini-4-carbon/)核实，8分可暂留，但报告所引Arena首页不能追溯该日期与前三名配置。"}

```json
[
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.frontend_aesthetic.score",
        "old_value":  6,
        "value":  8,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.frontend_aesthetic.source",
        "old_value":  "inherited",
        "value":  "public",
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.frontend_aesthetic.confidence",
        "old_value":  0.4,
        "value":  0.6,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.frontend_aesthetic.evidence",
        "old_value":  [

                      ],
        "value":  [
                      {
                          "claim":  "LMArena WebDev Arena 榜单中 Gemini 4 Carbon 取得 1768 Elo（较 Argon 提升 +89 Elo），位列全球第 4，次于 Claude Opus 5.5 Max、GPT-6 Astra 与 Claude Sonnet 5.5。",
                          "date":  "2026-10-30",
                          "url":  "https://lmarena.ai/"
                      }
                  ],
        "unlock":  false
    }
]
```
