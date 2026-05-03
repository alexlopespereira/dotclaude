---
description: Executa ciclo completo de PLANEJAMENTO — planeja como Agente Planejador, depois revisa como Adversário
allowed-tools: Read, Write, Glob, Grep, Bash(find *), Bash(test *), Bash(ls *), Agent
argument-hint: [descrição do problema ou feature] [--grill]
---

Execute as fases em sequência para: $ARGUMENTS

## Fase 0 — Grilling opcional (`--grill`)

Se `$ARGUMENTS` contiver `--grill` ou se o usuário pediu "grill me" / "stress-test", **antes** de planejar invoque a skill `grill-me` (ou `grill-with-docs` se o repo tem `CONTEXT.md`/`docs/adr/`):

1. Faça uma pergunta de cada vez, esperando a resposta.
2. Caminhe pela árvore de decisão até resolver as dependências.
3. Para cada pergunta, dê sua recomendação de resposta.
4. Quando alcançar entendimento compartilhado, prossiga para a Fase 1 com base nas respostas.

Se o repo tem `CONTEXT.md`, atualize-o inline conforme termos forem resolvidos. Se uma decisão é hard-to-reverse + surprising + result of trade-off, ofereça criar um ADR em `docs/adr/`.

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
- Sugira: "Plano aprovado. Para executar implementação completa (prd.json + Ralph), use `/full-cycle`. Para converter manualmente, use `/prd-convert`."

Se REPROVADO:
- Destaque os 3 pontos mais críticos que precisam de revisão humana.
- NÃO tente resolver automaticamente — escale para o humano.

**Este comando PARA aqui.** Não converte em prd.json nem executa Ralph — deixe o usuário revisar o plano primeiro. Para fluxo end-to-end automatizado, use `/full-cycle`.

**Princípio 11 (consistência):** as Fases 0→1→2→3 internas a este comando são transições internas e não pedem confirmação humana entre elas. Humano pode interromper a qualquer momento via Ctrl-C. O **gate humano de alto nível** é a escolha entre `/full-planning-cycle` (PARA após o veredicto) e `/full-cycle` (CONTINUA até PR).
