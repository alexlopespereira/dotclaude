---
name: grill-me
description: Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree. Use when user wants to stress-test a plan, get grilled on their design, or mentions "grill me".
---

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time.

If a question can be answered by exploring the codebase, explore the codebase instead.

## Docs de domínio (modo inline)

Quando a entrevista cristalizar um **termo de domínio** ou uma **decisão hard-to-reverse**, aplique o **modo inline** da biblioteca `domain-docs` — escreva o `CONTEXT.md` na hora e ofereça o ADR quando a decisão passar no gate triplo. Não reproduza as regras aqui: leia `~/.claude/skills/domain-docs/SKILL.md` (criação lazy + anúncio de 1 linha, gate triplo de ADR, formatos) e siga o modo inline descrito lá. Sessão sem termo/decisão de domínio não cria nada.

## Ao produzir o plano (telemetria de DoD)

Se durante a entrevista **emergir um artefato concreto** (ex.: "isso vira um hook", "vamos criar uma skill"), ao encerrar persista um plano em `.claude/plans/<ISO-timestamp>-<slug>.md` (formato ReAct+Feynman) com seção `## Artefatos a produzir`: mapeie cada artefato a uma Categoria/Tarefa do `DOD.md`, copie o DoD **verbatim** em checklist, e emita o marcador `<!-- dod-use: <id> -->` após cada bloco. Siga [DOD-MAPPING.md](../auto-grill-me/references/DOD-MAPPING.md). **Não chame `log_event`** — o Stop hook conta a partir do marcador. Entrevista exploratória sem artefato mapeável continua efêmera (sem arquivo).
