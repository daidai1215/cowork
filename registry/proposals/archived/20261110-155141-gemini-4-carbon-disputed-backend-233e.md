# Proposal: gemini-4-carbon

Base revision: 2

Disputed capability is frozen until explicit approval. Review research_score, suggested_score, and reason.

Approval preserves cap locks. Set unlock:true only for a permanent cap unlock.
Cross-check: {"cap":"backend","research_score":9,"suggested_score":null,"reason":"65.2%与[Vals的63.13%](https://www.vals.ai/models/google_gemini-4-carbon)来自不同评测口径并非自相矛盾，但漏洞修复与终端任务不足以精确确定距Sol后端10分仅差1分。"}

```json
[
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.backend.score",
        "old_value":  7,
        "value":  9,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.backend.source",
        "old_value":  "inherited",
        "value":  "public",
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.backend.confidence",
        "old_value":  0.4,
        "value":  0.6,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.backend.evidence",
        "old_value":  [

                      ],
        "value":  [
                      {
                          "claim":  "Google DeepMind 报告：Gemini 4 Carbon 专为长周期后端与安全工程设计，在 CWE-bench 后端漏洞补丁修复得 71.0%、ExploitGym 得 54.8%，Terminal-Bench 4.0 达 65.2%。",
                          "date":  "2026-10-28",
                          "url":  "https://blog.google/technology/ai/gemini-4-carbon/"
                      },
                      {
                          "claim":  "Vals AI 独立评测：Gemini 4 Carbon 在 Terminal-Bench 真实命令行与后端系统工程任务中取得 63.13% 准确率。",
                          "date":  "2026-10-29",
                          "url":  "https://www.vals.ai/models/gemini-4-carbon"
                      }
                  ],
        "unlock":  false
    }
]
```
