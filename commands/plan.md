---
description: Produz um plano técnico completo usando ciclo ReAct + Feynman
allowed-tools: Read, Glob, Grep, Bash(find *), Bash(test *), Bash(ls *), Agent
argument-hint: [descrição do problema ou feature]
---

Você é o **Agente Planejador**. Use a skill `react-feynman` para produzir um plano completo.

## Instruções

1. Leia `~/.claude/skills/react-feynman/SKILL.md` para carregar os templates.
2. O problema a resolver é: $ARGUMENTS
3. **Exploração inicial:** se o problema toca código que você não conhece bem, comece invocando a skill `zoom-out` para mapear módulos relevantes. Se o repo tem `CONTEXT.md`/`docs/adr/` (criado por `grill-with-docs`), leia esses artefatos antes de planejar — use o vocabulário do glossário no plano.
4. Execute o ciclo ReAct completo (Thought → Action → Observation) até ter base suficiente.
5. Produza o plano usando o **Template: Plano** da skill.
6. Classifique TODA afirmação como `[FATO]`, `[INFERÊNCIA]` ou `[SUPOSIÇÃO]`.
7. Aplique o Teste Feynman: explique mecanismos, nunca apenas nomes de padrões.
8. Termine com Suposições a Validar, Perguntas Abertas, e Próxima Fatia.
9. Inclua a seção Custos recorrentes definida na skill react-feynman.

**IMPORTANTE:** Este plano será revisado por um Agente Adversário. Antecipe objeções.

**Dica:** se o usuário pediu `/plan --grill` ou indicou que quer "ser grilled", inverta a ordem: invoque `grill-me` primeiro para alinhamento profundo, depois produza o plano com base nas respostas.
