# Proposal: gemini-4-carbon

Base revision: 2

Disputed capability is frozen until explicit approval. Review research_score, suggested_score, and reason.

Approval preserves cap locks. Set unlock:true only for a permanent cap unlock.
Cross-check: {"cap":"math","research_score":9,"suggested_score":null,"reason":"综合智能指数、跨学科HLE及科学代理任务不能直接替代数学单项成绩，报告缺少数学分项及与Sol的可比证据，无法确认并列9分。"}

```json
[
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.math.score",
        "old_value":  7,
        "value":  9,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.math.source",
        "old_value":  "inherited",
        "value":  "public",
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.math.confidence",
        "old_value":  0.4,
        "value":  0.6,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.math.evidence",
        "old_value":  [

                      ],
        "value":  [
                      {
                          "claim":  "Artificial Analysis Intelligence Index v5.0 综合得分 59（排名第 1），在涵盖高难度数学与科学推理的 HLE-Diamond（69.1%）与 Terminal-Bench-Science 子项位列第 1；AIME 与 FrontierMath 单项分值未单独公开。",
                          "date":  "2026-10-28",
                          "url":  "https://artificialanalysis.ai/models/gemini-4-carbon"
                      }
                  ],
        "unlock":  false
    }
]
```
