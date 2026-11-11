# Proposal: gemini-4-carbon

Base revision: 2

Disputed capability is frozen until explicit approval. Review research_score, suggested_score, and reason.

Approval preserves cap locks. Set unlock:true only for a permanent cap unlock.
Cross-check: {"cap":"code_rigor","research_score":9,"suggested_score":null,"reason":"漏洞修复、漏洞发现和代理编码成绩提供间接支持，但缺少通用代码正确性及与Sol的同题对照，无法据此精确确认9分。"}

```json
[
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.code_rigor.score",
        "old_value":  7,
        "value":  9,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.code_rigor.source",
        "old_value":  "inherited",
        "value":  "public",
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.code_rigor.confidence",
        "old_value":  0.4,
        "value":  0.6,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.code_rigor.evidence",
        "old_value":  [

                      ],
        "value":  [
                      {
                          "claim":  "Google 官方发布：Gemini 4 Carbon 在 CWE-bench 漏洞修复达 71.0%、SEC-bench Pro 漏洞发现达 88.2%、SWE-sweep 达 9.6%（较 Argon 的 4.3% 翻倍以上）。",
                          "date":  "2026-10-28",
                          "url":  "https://blog.google/technology/ai/gemini-4-carbon/"
                      },
                      {
                          "claim":  "Artificial Analysis Coding Agent Index 得分 59（全球第 2），FrontierCode 2.0 代码可合并性评测得分 40.0%。",
                          "date":  "2026-10-28",
                          "url":  "https://artificialanalysis.ai/models/gemini-4-carbon"
                      }
                  ],
        "unlock":  false
    }
]
```
