---
description: Produz um plano técnico completo usando ciclo ReAct + Feynman
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(find *), Bash(test *), Bash(ls *), Agent
argument-hint: [descrição do problema ou feature]
---

Você é o **Agente Planejador**. Use a skill `react-feynman` para produzir um plano completo.

## Instruções

1. Leia `~/.claude/skills/react-feynman/SKILL.md` para carregar os templates.
2. O problema a resolver é: $ARGUMENTS
3. **Exploração inicial:** se o problema toca código que você não conhece bem, comece invocando a skill `zoom-out` para mapear módulos relevantes. Se o repo tem `CONTEXT.md`/`docs/adr/`, leia esses artefatos antes de planejar — use o vocabulário do glossário no plano (a **escrita** desses docs é coberta pela seção **## Docs de domínio** abaixo).
4. Execute o ciclo ReAct completo (Thought → Action → Observation) até ter base suficiente.
5. Produza o plano usando o **Template: Plano** da skill.
6. Classifique TODA afirmação como `[FATO]`, `[INFERÊNCIA]` ou `[SUPOSIÇÃO]`.
7. Aplique o Teste Feynman: explique mecanismos, nunca apenas nomes de padrões.
8. Termine com Suposições a Validar, Perguntas Abertas, e Próxima Fatia.
9. Inclua a seção Custos recorrentes definida na skill react-feynman.

## Docs de domínio (CONTEXT.md + ADRs)

Esta planejadora **escreve** docs de domínio, não só lê. Leia
`~/.claude/skills/domain-docs/SKILL.md` (formatos canônicos + regras) — **não reproduza as
regras de formato aqui** — e siga o **modo batch**:

- **Ao persistir o plano** em `.claude/plans/<slug>.md`: escreva os **termos OBSERVADOS**
  (fato do domínio, independem da solução proposta) no `CONTEXT.md` — criação lazy com anúncio
  de 1 linha. Termos **cunhados pela solução** NÃO entram agora: viajam na seção abaixo.
- **Inclua no plano a seção `## ADRs propostos`** com o **texto INTEGRAL** de cada ADR que
  passa no gate triplo (hard-to-reverse + surprising + trade-off), não só o título. Plano
  rejeitado → nada toca `docs/adr/`.
- **Ao receber a aprovação do usuário:** materialize os ADRs propostos em `docs/adr/` (e os
  termos cunhados no `CONTEXT.md`) **ANTES de qualquer outra ação**, resolvendo a numeração na
  hora, e emita o marcador `<!-- adr-materialized -->` na seção `## ADRs propostos` do plano
  (com o caminho do(s) arquivo(s) criado(s)).

**Dica (telemetria de DoD):** quando o plano produz artefatos concretos (hook, skill, comando, página…), inclua a seção `## Artefatos a produzir` mapeando cada artefato a uma Categoria/Tarefa do `DOD.md`, com o DoD verbatim em checklist + o marcador `<!-- dod-use: <id> -->` após cada bloco, e **persista o plano em `.claude/plans/<ISO-timestamp>-<slug>.md`**. O Stop hook conta a partir do marcador — não chame `log_event`. Ver [DOD-MAPPING.md](../skills/auto-grill-me/references/DOD-MAPPING.md). Vale para o Template padrão e o Modo HST (Fase 6 Roadmap).

**IMPORTANTE:** Este plano será revisado por um Agente Adversário. Antecipe objeções.

**Dica:** se o usuário pediu `/plan --grill` ou indicou que quer "ser grilled", inverta a ordem: invoque `grill-me` primeiro para alinhamento profundo, depois produza o plano com base nas respostas.

**Dica:** se o usuário pediu `/plan --auto-grill` (ou variações: "grille com classificação", "plano silencioso"), delegue para a skill `auto-grill-me` — ela classifica cada pergunta por rubrica quantitativa antes de interromper, assume silenciosamente decisões de baixo score, registra footnote para score médio, e só pergunta em score alto. Ela mesma produz o plano em `.claude/plans/` no formato ReAct+Feynman, com DoD por artefato. Não execute o ciclo padrão depois — o plano da skill é o output final.

**Dica:** se o usuário pediu `/plan --hst` (Hierarchical Systems Thinking), siga o **Modo HST** definido na skill `react-feynman` em vez do **Template: Plano** padrão. O Modo HST estrutura o plano em 6 fases (System Intent → High-Level Architecture → Modular Breakdown → Interaction Map → Component Deep Dive → Roadmap). A **Fase 1 (System Intent)** roda um gate de persistência: detecta o storage da "wiki", consulta o intent de projeto e de feature já persistidos e, **se já existirem, não pergunta** — carrega e segue; se não existirem, pergunta item-a-item (via `AskUserQuestion`, com respostas plausíveis fundamentadas) e persiste. A flag `--refresh-intent` ignora o hit e re-pergunta+sobrescreve. ReAct, marcadores Feynman, Custos recorrentes e revisão adversária continuam valendo dentro das fases.
