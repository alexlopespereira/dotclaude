---
description: Executa ciclo completo — planeja como Agente Planejador, depois revisa como Adversário
allowed-tools: Read, Write, Glob, Grep, Bash(find *)
argument-hint: [descrição do problema ou feature]
---

Execute as duas fases em sequência para: $ARGUMENTS

## Fase 1 — Planejamento

1. Leia `~/.claude/skills/react-feynman/SKILL.md`.
2. Assuma o papel de **Agente Planejador**.
3. Execute o ciclo ReAct completo.
4. Produza o plano usando o Template: Plano.
5. Salve o plano em `.claude/plans/[slug-do-titulo].md`.

## Fase 2 — Revisão Adversária

1. Troque para o papel de **Agente Revisor Adversário**.
2. Releia o plano que acabou de produzir com olhos frescos.
3. Para cada decisão, tente refutar. Aplique Teste Feynman.
4. Produza o parecer usando o Template: Revisão Adversária.
5. Adicione o parecer ao final do mesmo arquivo do plano, sob `---` separador.

## Fase 3 — Síntese

Se o veredicto for APROVADO ou APROVADO COM RESSALVAS:
- Liste as ações imediatas para a Próxima Fatia.

Se REPROVADO:
- Destaque os 3 pontos mais críticos que precisam de revisão humana.
- NÃO tente resolver automaticamente — escale para o humano.

## Fase 4 — Conversão para Implementação (opcional)

Se o veredicto for APROVADO:
1. Pergunte ao usuário: "Plano aprovado. Deseja converter em prd.json e iniciar implementação Ralph?"
2. Se sim: use a skill `prd` para converter o plano em prd.json.
3. Após conversão, informe: "prd.json criado. Execute /ralph-adversarial para iniciar."
4. NÃO inicie o Ralph automaticamente — deixe o usuário revisar o prd.json primeiro.
