---
description: Sintetiza relatório final de pesquisa adversarial já executada
allowed-tools: Read, Write, Bash(find *), Bash(cat *), Bash(ls *)
argument-hint: [caminho ou "última"]
---

1. Se "última"/"last": diretório mais recente em .claude/research/
2. Leia meta.json + todos report-v*.md + factcheck-*.md + logic-review-*.md
3. Síntese Final conforme template do /project:adversarial-research
4. Salve como synthesis.md
