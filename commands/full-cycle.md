---
description: Ciclo end-to-end — planejamento + revisão adversária + PRD + Ralph + PR/merge
allowed-tools: Read, Write, Glob, Grep, Bash(find *), Bash(bash *), Bash(chmod *), Bash(cat *), Bash(jq *), Bash(git *), Bash(gh *), Bash(ls *), Bash(pwd), Bash(cd *), Bash(echo *), Bash(test *)
argument-hint: [descrição do problema ou feature]
---

Executa o ciclo completo de entrega no cwd atual: planejamento → revisão adversária → PRD → Ralph → PR/merge.

**Gestão de worktree é explícita e fica com o usuário.** Este comando NÃO cria nem remove worktrees. Se você quiser isolar a feature, rode `/create-worktree <slug>` antes e `cd` para o worktree. Após o merge, remova manualmente com `/delete-worktree`.

Para apenas planejar (sem executar/merge), use `/full-planning-cycle`.

## Fase 1 — Planejamento (Agente Planejador)

1. Leia `~/.claude/skills/react-feynman/SKILL.md`.
2. Assuma o papel de **Agente Planejador**.
3. Execute o ciclo ReAct completo para: $ARGUMENTS
4. Produza o plano usando o Template: Plano.
5. Salve o plano em `.claude/plans/<slug>.md` (relativo ao cwd).

## Fase 2 — Revisão Adversária (Agente Revisor)

1. Troque para o papel de **Agente Revisor Adversário**.
2. Releia o plano com olhos frescos.
3. Para cada decisão, tente refutar. Aplique Teste Feynman.
4. Produza o parecer usando o Template: Revisão Adversária.
5. Adicione o parecer ao mesmo arquivo do plano, sob `---` separador.

## Fase 3 — Gate de Aprovação

**Se REPROVADO:**
- Destaque os 3 pontos mais críticos.
- **PARE AQUI** — escale para o humano. NÃO prossiga para PRD/Ralph/PR.

**Se APROVADO COM RESSALVAS:**
- Liste as ressalvas bloqueantes (severidade Crítica/Alta).
- Pergunte: "Há N ressalvas de alta severidade. Deseja (a) prosseguir, (b) revisar o plano primeiro, ou (c) abortar?"
- Se (a), prossiga. Se (b)/(c), PARE.

**Se APROVADO:** prossiga para Fase 4.

## Fase 4 — Conversão em PRD

1. Leia `~/.claude/skills/prd/SKILL.md`.
2. Converta o plano em `prd.json` no cwd atual seguindo a skill `prd`:
   - 1 fatia = 1 user story
   - AC testáveis
   - [SUPOSIÇÕES] viram AC de validação
3. Mostre o `prd.json` ao usuário.
4. Pergunte: "prd.json criado com N stories. Revisar antes de executar Ralph? (y/N)"
   - Se "y": **PARE**. Usuário ajusta e depois roda `/ralph-adversarial` ou continua.
   - Se "N" ou enter: prossiga para Fase 5.

## Fase 5 — Execução Ralph Adversarial

1. Leia `~/.claude/skills/ralph-adversarial/SKILL.md`.
2. Verifique pré-requisitos: `jq`, `CODE_REVIEW.md`, e os CLIs necessários conforme os papéis:
   - Default: `claude` implementa, `codex` revisa → ambos precisam existir.
   - Se `PRIMARY_AGENT` / `REVIEWER_AGENT` estiverem definidos no ambiente, valide apenas os CLIs escolhidos.
3. Execute no cwd atual, **propagando as env vars de papéis** se estiverem definidas:
   ```bash
   chmod +x ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   PRIMARY_AGENT="${PRIMARY_AGENT:-claude}" REVIEWER_AGENT="${REVIEWER_AGENT:-codex}" \
     bash ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   ```
   Para inverter os papéis, o usuário lança o Claude Code com as vars no shell:
   `PRIMARY_AGENT=codex REVIEWER_AGENT=claude claude` — depois invoca `/full-cycle`.
4. Após conclusão, apresente resumo: stories completas/pendentes/escaladas, findings P0/P1, progress.txt.

**Gate:** Se houver stories escaladas ou findings P0 não resolvidos, **PARE** e escale para humano. NÃO prossiga para PR.

## Fase 6 — Testes finais

Antes de abrir PR, rode a suíte de testes do projeto no cwd atual:
```bash
# Detecte o runner (package.json, pytest, go test...) e execute
```

Se falhar, **PARE** e escale — não abra PR com testes vermelhos.

## Fase 7 — PR + Merge

Execute o fluxo de `/pr` no cwd atual: push do branch, criação do PR, watch de checks, merge com `--delete-branch`.

Se merge falhar (proteção, reviews pendentes), **PARE** e reporte ao usuário.

## Guardrails

- Nenhum código de produção é escrito antes do veredicto APROVADO.
- Humano pode interromper em qualquer fase.
- Se qualquer fase falhar, reporte o status e PARE — não improvise.
- **Gestão de worktree é responsabilidade do usuário.** Este comando não cria nem remove worktrees. Se estiver trabalhando em worktree, rode `/delete-worktree` manualmente após confirmar o merge.
