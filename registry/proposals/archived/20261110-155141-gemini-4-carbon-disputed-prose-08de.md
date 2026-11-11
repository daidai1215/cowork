# Proposal: gemini-4-carbon

Base revision: 2

Disputed capability is frozen until explicit approval. Review research_score, suggested_score, and reason.

Approval preserves cap locks. Set unlock:true only for a permanent cap unlock.
Cross-check: {"cap":"prose","research_score":10,"suggested_score":9,"reason":"Text Arena总榜衡量综合偏好，不能直接证明写作维度与Argon同为10分，且首页引用缺少写作分榜、置信区间和样本信息。"}

```json
[
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.prose.score",
        "old_value":  10,
        "value":  9,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.prose.source",
        "old_value":  "inherited",
        "value":  "public",
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.prose.confidence",
        "old_value":  0.4,
        "value":  0.6,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.prose.evidence",
        "old_value":  [

                      ],
        "value":  [
                      {
                          "claim":  "LMArena Text Arena 盲测总榜中 Gemini 4 Carbon (High) 以约 1528 Elo 排名第 1，略超 Claude Opus 5.5 与 GPT-6 Astra；EQ-Bench Creative Writing 尚未收录独立成绩。",
                          "date":  "2026-10-30",
                          "url":  "https://lmarena.ai/"
                      }
                  ],
        "unlock":  false
    }
]
```
