# Proposal: gemini-4-carbon

Base revision: 2

Disputed capability is frozen until explicit approval. Review research_score, suggested_score, and reason.

Approval preserves cap locks. Set unlock:true only for a permanent cap unlock.
Cross-check: {"cap":"world_knowledge","research_score":10,"suggested_score":10,"reason":"[AA发布说明](https://artificialanalysis.ai/articles/gemini-4-carbon-new-number-1)支持Omniscience领先，但其幻觉率由Argon的4%升至11%，报告把内部无依据断言减少约50%混作知识幻觉改善；10分可暂留。"}

```json
[
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.world_knowledge.score",
        "old_value":  10,
        "value":  10,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.world_knowledge.source",
        "old_value":  "inherited",
        "value":  "public",
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.world_knowledge.confidence",
        "old_value":  0.4,
        "value":  0.6,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.world_knowledge.evidence",
        "old_value":  [

                      ],
        "value":  [
                      {
                          "claim":  "Artificial Analysis Intelligence Index v5.0 得分 59（第 1 名），HLE-Diamond 专家知识与推理评测得分 69.1%（第 1 名），AA-Omniscience 得分 54（第 1 名），且幻觉与无依据断言率较 Argon 降低约 50%。",
                          "date":  "2026-10-28",
                          "url":  "https://artificialanalysis.ai/models/gemini-4-carbon"
                      }
                  ],
        "unlock":  false
    }
]
```
