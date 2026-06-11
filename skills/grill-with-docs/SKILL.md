---
name: grill-with-docs
description: Grilling session that challenges your plan against the existing domain model, sharpens terminology, and updates documentation (CONTEXT.md, ADRs) inline as decisions crystallise. Use when user wants to stress-test a plan against their project's language and documented decisions.
disable-model-invocation: true
---

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time, waiting for feedback on each question before continuing.

If a question can be answered by exploring the codebase, explore the codebase instead.

## Domain awareness

Esta é a skill de grilling especialista em **modelagem de domínio**: além de pressionar o plano, ela mantém o glossário (`CONTEXT.md`) e as decisões hard-to-reverse (`docs/adr/`) afiados. Seu default é o **modo inline** da biblioteca `domain-docs` — captura cada decisão no momento em que cristaliza, sem acumular em batch.

Durante a exploração do código, localize a documentação existente (`CONTEXT.md` / `CONTEXT-MAP.md` no root, `docs/adr/`) para saber contra o que pressionar.

**Não reproduza aqui as regras nem os exemplos do comportamento de docs — delegue-os à biblioteca.** Leia `~/.claude/skills/domain-docs/SKILL.md` e siga o **modo inline** descrito lá (criação lazy + anúncio de 1 linha, desafiar contra o glossário, sharpen de termos vagos, cross-reference com o código, escrita inline de termo no `CONTEXT.md` e oferta de ADR no gate triplo). As regras e os exemplos vivem na biblioteca; se ela mudar o modo inline, esta skill acompanha sem edição.

Contribuição própria do grilling de domínio (não está na biblioteca): **cenários concretos** — stress-teste as relações de domínio com casos de borda que forcem precisão.

Os formatos canônicos vivem em [CONTEXT-FORMAT.md](../domain-docs/CONTEXT-FORMAT.md) e [ADR-FORMAT.md](../domain-docs/ADR-FORMAT.md).

## Ao produzir o plano (telemetria de DoD)

Ortogonal ao fluxo CONTEXT.md/ADR acima: se durante a sessão **emergir um artefato concreto** (hook, skill, comando, página…), ao encerrar persista um plano em `.claude/plans/<ISO-timestamp>-<slug>.md` com seção `## Artefatos a produzir` — mapeie cada artefato a uma Categoria/Tarefa do `DOD.md`, copie o DoD **verbatim** em checklist, e emita o marcador `<!-- dod-use: <id> -->` após cada bloco. Siga [DOD-MAPPING.md](../auto-grill-me/references/DOD-MAPPING.md). **Não chame `log_event`** — o Stop hook conta a partir do marcador. Isso é separado de `CONTEXT.md`/`docs/adr/` (que continuam como descrito). Sessão exploratória sem artefato mapeável não gera plano.
