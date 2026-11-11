# Proposal: gemini-4-carbon

Base revision: 2

Disputed capability is frozen until explicit approval. Review research_score, suggested_score, and reason.

Approval preserves cap locks. Set unlock:true only for a permanent cap unlock.
Cross-check: {"cap":"office_docs","research_score":5,"suggested_score":null,"reason":"[所引API文档](https://ai.google.dev/gemini-api/docs/document-processing?authuser=1\u0026hl=en)说明PDF视觉理解及其他格式纯文本处理，未证明原生解析三类Office文件，且缺少agy通道实测，5分依据不足。"}

```json
[
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.office_docs.score",
        "old_value":  5,
        "value":  5,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.office_docs.source",
        "old_value":  "inherited",
        "value":  "public",
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.office_docs.confidence",
        "old_value":  0.4,
        "value":  0.6,
        "unlock":  false
    },
    {
        "op":  "set",
        "path":  "models[id=gemini-4-carbon].caps.office_docs.evidence",
        "old_value":  [

                      ],
        "value":  [
                      {
                          "claim":  "Gemini API 原生支持读取解析 .docx/.pptx/.xlsx 等 Office 文档（计 5 分），但 Antigravity 通道无 Codex 专属的本地 Office/PPT 原生生成与操控插件链。",
                          "date":  "2026-10-28",
                          "url":  "https://ai.google.dev/gemini-api/docs/document-processing"
                      }
                  ],
        "unlock":  false
    }
]
```
