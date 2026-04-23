---
name: ralph-adversarial
description: Loop de implementação autônomo baseado no padrão Ralph com revisão adversária do Codex. Claude Code implementa uma user story por iteração com contexto fresco. Codex revisa o código usando a rubrica em skills/ralph-adversarial/CODE_REVIEW.md. Use após converter um plano aprovado em prd.json.
---

# Skill: Ralph Adversarial Loop

## Pré-requisitos
- prd.json na raiz do repositório (gerado pela skill prd)
- Rubrica de revisão em `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md`
- Claude Code CLI e jq instalados
- Codex CLI (opcional, recomendado). Se ausente ou se a OpenAI retornar
  quota/rate-limit, o loop cai automaticamente para uma instância
  `claude --model sonnet` aplicando a mesma rubrica — a troca fica
  registrada em `progress.txt` como `CODEX_QUOTA`.

## Arquitetura

Cada iteração do loop:
1. Script bash spawna Claude Code com contexto fresco
2. Claude lê prd.json, progress.txt, git log
3. Claude implementa 1 story + roda checks + preenche ac_trace no commit
4. Script spawna o reviewer (Codex por padrão; Claude Sonnet em fallback)
5. Reviewer aplica rubrica de `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md`
6. Se MERGE: marca story passes:true, próxima iteração
7. Se BLOCK/REQUEST_CHANGES: feedback vai para progress.txt, Claude corrige na próxima iteração
8. Se 2 iterações consecutivas da mesma story falham: escalar ao humano

## Fallback de reviewer
- Detector: `detect-quota.sh::is_codex_quota_error` identifica padrões
  de quota/rate-limit (HTTP 429, `insufficient_quota`, "exceeded your
  current quota", etc.).
- Gatilhos: Codex ausente no PATH no início do loop, ou output de uma
  execução contém sinal de quota.
- Estado: uma vez ativado, `CODEX_UNAVAILABLE=true` persiste pelo resto
  da execução para não desperdiçar iterações chamando um provedor que
  acabou de falhar.
- Saída do reviewer: o Claude Sonnet fallback termina com `## Verdict:
  MERGE|BLOCK|REQUEST_CHANGES`, já reconhecido pelo `parse-verdict.sh`.
- Arquivo de review: salvo em `.claude/research/review-<STORY>-iter<N>-<reviewer>.txt`.

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
