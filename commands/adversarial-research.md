---
description: Deep research adversarial com 3 provedores — Gemini elabora, Perplexity fact-checks, OpenAI revisa logica
allowed-tools: Read, Write, Bash(python3 *), Bash(pip *), Bash(find *), Bash(cat *), Bash(ls *), Bash(head *)
argument-hint: [tema da pesquisa em linguagem natural]
---

Pesquisa adversarial sobre: **$ARGUMENTS**

1. Leia `~/.claude/skills/adversarial-research/SKILL.md`.

2. Verifique deps:
   ```bash
   python3 -c "import requests, openai; print('OK')" 2>/dev/null || pip install google-genai openai requests --break-system-packages
   ```

3. Verifique keys:
   ```bash
   python3 -c "
   import os
   for k in ['GEMINI_API_KEY','PERPLEXITY_API_KEY','OPENAI_API_KEY']:
       assert os.environ.get(k), f'{k} missing'
   print('3 API keys OK')
   "
   ```

4. Execute:
   ```bash
   python3 ~/.claude/skills/adversarial-research/runner.py "$ARGUMENTS"
   ```

5. Leia artefatos do diretório mais recente em `.claude/research/`.
   Leia: último `report-v*.md`, último `factcheck-*.md`, último `logic-review-*.md`.

6. Produza Síntese Final:

   # Síntese: [Tema]
   **Data / Ciclos / Veredicto Final**
   **Provedores:** Gemini (elaborador) | Perplexity (fact-check) | OpenAI (lógica)

   ## Resumo Executivo
   ## Mapa de Confiança
   | Seção | Fatos (Perplexity) | Lógica (OpenAI) | Confiança Geral |
   |-------|--------------------|-----------------|-----------------|
   ## Claims Não Verificados
   ## Contra-Evidências Relevantes
   ## Correções V1→Vfinal
   ## Recomendações para Investigação Manual

7. Salve em `.claude/research/[dir]/synthesis.md`

NÃO edite relatórios originais. Para modelo OpenAI diferente: --openai-model gpt-4.1
