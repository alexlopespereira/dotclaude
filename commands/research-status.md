---
description: Lista pesquisas adversariais realizadas
allowed-tools: Read, Bash(find *), Bash(cat *), Bash(ls *)
---

1. `ls -lt .claude/research/ 2>/dev/null || echo "Nenhuma pesquisa"`
2. Para cada: leia meta.json (tema, data, ciclos, provedores)
3. Verifique se synthesis.md existe (concluída vs pendente)
4. Tabela: # | Data | Tema | Ciclos | Status
5. Ofereça sintetizar pendentes.
