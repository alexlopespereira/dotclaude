---
name: ralph-adversarial
description: Loop de implementação autônomo baseado no padrão Ralph com revisão adversária do Codex. Claude Code implementa uma user story por iteração com contexto fresco. Codex revisa o código usando a rubrica em skills/ralph-adversarial/CODE_REVIEW.md. Use após converter um plano aprovado em prd.json.
---

# Skill: Ralph Adversarial Loop

## Pré-requisitos
- prd.json na raiz do repositório (gerado pela skill prd)
- Rubrica de revisão em `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md`
- Claude Code CLI e Codex CLI instalados e autenticados
- jq instalado

## Arquitetura

Cada iteração do loop:
1. Script bash spawna Claude Code com contexto fresco
2. Claude lê prd.json, progress.txt, git log
3. Claude implementa 1 story + roda checks + preenche ac_trace no commit
4. Script spawna Codex para revisar o diff
5. Codex aplica rubrica de `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md`
6. Se MERGE: marca story passes:true, próxima iteração
7. Se BLOCK/REQUEST_CHANGES: feedback vai para progress.txt, Claude corrige na próxima iteração
8. Se 2 iterações consecutivas da mesma story falham: escalar ao humano

## Memória entre iterações (estado no disco, não no contexto)
- prd.json: quais stories faltam (passes: true/false)
- progress.txt: aprendizados, feedback do Codex, gotchas
- git history: código já produzido
- AGENTS.md: convenções descobertas durante implementação

## Integração com o sistema ReAct+Feynman
O plano aprovado no full-planning-cycle é a FONTE do prd.json.
O fluxo manual (3 passos) é:
  /full-planning-cycle → plano aprovado
  → /prd-convert → prd.json
  → /ralph-adversarial → implementação com revisão

Alternativa automática (1 passo): /full-cycle executa os três acima em sequência,
parando no gate de aprovação se o plano for REPROVADO.
