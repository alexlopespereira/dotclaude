---
description: Executa ciclo completo de PLANEJAMENTO — planeja como Agente Planejador, depois revisa como Adversário
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(find *), Bash(test *), Bash(ls *), Agent
argument-hint: [descrição do problema ou feature] [--grill]
---

Execute as fases em sequência para: $ARGUMENTS

## Fase 0 — Grilling opcional (`--grill`)

Se `$ARGUMENTS` contiver `--grill` ou se o usuário pediu "grill me" / "stress-test", **antes** de planejar invoque a skill `grill-me` (ou `grill-with-docs` se o repo tem `CONTEXT.md`/`docs/adr/`):

1. Faça uma pergunta de cada vez, esperando a resposta.
2. Caminhe pela árvore de decisão até resolver as dependências.
3. Para cada pergunta, dê sua recomendação de resposta.
4. Quando alcançar entendimento compartilhado, prossiga para a Fase 1 com base nas respostas.

Aplique o **modo inline** da biblioteca `domain-docs` durante o grilling — leia `~/.claude/skills/domain-docs/SKILL.md` e siga as regras lá (criação lazy + anúncio de 1 linha, escrita inline de termo no `CONTEXT.md`, oferta de ADR quando a decisão passa no gate triplo). **Não reproduza as regras de formato aqui.**

## Fase 1 — Planejamento

1. Leia `~/.claude/skills/react-feynman/SKILL.md`.
2. Assuma o papel de **Agente Planejador**.
3. Execute o ciclo ReAct completo.
4. Produza o plano usando o Template: Plano.
5. Salve o plano em `.claude/plans/[slug-do-titulo].md`.
6. **Docs de domínio (modo batch):** ao salvar, escreva os **termos OBSERVADOS** no `CONTEXT.md` (criação lazy + anúncio de 1 linha) e inclua a seção `## ADRs propostos` com o texto integral de cada ADR que passa no gate triplo. Regras na biblioteca `domain-docs` (`~/.claude/skills/domain-docs/SKILL.md`) — não duplique o formato. Os ADRs materializam na Fase 3 (após o veredito).

## Fase 2 — Revisão Adversária

1. Troque para o papel de **Agente Revisor Adversário**.
2. Releia o plano que acabou de produzir com olhos frescos.
3. Para cada decisão, tente refutar. Aplique Teste Feynman.
4. Produza o parecer usando o Template: Revisão Adversária.
5. Adicione o parecer ao final do mesmo arquivo do plano, sob `---` separador.

## Fase 3 — Síntese

Se o veredicto for APROVADO ou APROVADO COM RESSALVAS:
- **Reconcilie o CORPO do plano com o veredito (obrigatório antes de qualquer conversão).**
  O parecer da Fase 2 fica no rodapé (sob `---`) e o `prd-convert` lê **só o
  corpo** — logo, uma decisão condenada que continue no corpo vira user story
  executável. Para **cada finding de severidade Crítica/Alta**, edite o corpo
  (tabela de Decisões técnicas / fatias): **remova ou corrija a decisão
  condenada** de modo que o corpo passe a descrever a solução final, não a
  proposta rejeitada. Ressalvas residuais (validação a fazer) viram ACs, mas a
  decisão em si tem de sair do corpo. Depois de reconciliar, carimbe
  `<!-- plan-reconciled: <verdict-slug> -->` no topo do corpo. Esse marcador é o
  que o gate `plan-verdict-gate.sh` exige para liberar a conversão. Se APROVADO
  **limpo** (sem findings Crítica/Alta), não há o que reconciliar — pule este passo.
- **Materialize os ADRs propostos** (gate de materialização do `/full-planning-cycle` na biblioteca `domain-docs`): a seção `## ADRs propostos` do plano vira arquivo(s) em `docs/adr/` e os termos cunhados pela solução entram no `CONTEXT.md`, resolvendo a numeração na hora. Se **APROVADO COM RESSALVAS**, **incorpore as ressalvas no texto do ADR primeiro** — o ADR registra a decisão final, não a proposta. Emita o marcador `<!-- adr-materialized -->` na seção `## ADRs propostos` do plano. (Regras de formato na biblioteca — não duplique aqui.)
- Liste as ações imediatas para a Próxima Fatia.
- Sugira: "Plano aprovado. Para executar implementação completa (prd.json + Ralph), use `/full-cycle`. Para converter manualmente, use `/prd-convert`."

Se REPROVADO (nada toca `docs/adr/` — ADRs propostos ficam pendentes):
- Destaque os 3 pontos mais críticos que precisam de revisão humana.
- NÃO tente resolver automaticamente — escale para o humano.

**Este comando PARA aqui.** Não converte em prd.json nem executa Ralph — deixe o usuário revisar o plano primeiro. Para fluxo end-to-end automatizado, use `/full-cycle`.

**Princípio 11 (consistência):** as Fases 0→1→2→3 internas a este comando são transições internas e não pedem confirmação humana entre elas. Humano pode interromper a qualquer momento via Ctrl-C. O **gate humano de alto nível** é a escolha entre `/full-planning-cycle` (PARA após o veredicto) e `/full-cycle` (CONTINUA até PR).
