---
description: Ciclo end-to-end — worktree + planejamento + revisão adversária + PRD + Ralph + PR/merge + cleanup
allowed-tools: Read, Write, Glob, Grep, Bash(find *), Bash(bash *), Bash(chmod *), Bash(cat *), Bash(jq *), Bash(git *), Bash(gh *), Bash(ls *), Bash(mkdir *), Bash(basename *), Bash(pwd), Bash(realpath *), Bash(cd *), Bash(echo *), Bash(test *), Bash(rm *)
argument-hint: [descrição do problema ou feature]
---

Executa o ciclo completo de entrega em worktree isolado: criação do worktree → planejamento → revisão adversária → PRD → Ralph → PR/merge → cleanup.

Use este comando quando já existe confiança no workflow e o objetivo é entregar código isoladamente. Para apenas planejar (sem executar/merge), use `/full-planning-cycle`.

## Fase 0 — Criação do Worktree

1. **Derive um slug** a partir de `$ARGUMENTS` (kebab-case, ≤40 chars, apenas `[a-z0-9-]`).
   - Exemplo: "adicionar dark mode no settings" → `add-dark-mode-settings`
2. **Execute `/worktree-start <slug>`** (ou equivalente inline):
   ```bash
   REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
   WORKTREE_PATH="$HOME/Projects/worktrees/${REPO_NAME}-${SLUG}"
   mkdir -p "$HOME/Projects/worktrees"
   git fetch origin main --quiet || true
   git worktree add "$WORKTREE_PATH" -b "$SLUG" origin/main 2>/dev/null \
     || git worktree add "$WORKTREE_PATH" -b "$SLUG" main
   ```
3. **Se a criação falhar** (worktree já existe, branch duplicado), **PARE** e peça instruções ao usuário.
4. **A partir daqui, TODAS as operações de Fase 1–5 ocorrem dentro de `$WORKTREE_PATH`.**
   - Use `cd "$WORKTREE_PATH"` antes de comandos shell.
   - Arquivos criados devem ter caminhos absolutos baseados em `$WORKTREE_PATH`.

## Fase 1 — Planejamento (Agente Planejador)

1. Leia `~/.claude/skills/react-feynman/SKILL.md`.
2. Assuma o papel de **Agente Planejador**.
3. Execute o ciclo ReAct completo para: $ARGUMENTS
4. Produza o plano usando o Template: Plano.
5. Salve o plano em `$WORKTREE_PATH/.claude/plans/<slug>.md`.

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
- O worktree permanece para revisão. Cleanup pode ser feito depois com `/worktree-cleanup <slug>`.

**Se APROVADO COM RESSALVAS:**
- Liste as ressalvas bloqueantes (severidade Crítica/Alta).
- Pergunte: "Há N ressalvas de alta severidade. Deseja (a) prosseguir, (b) revisar o plano primeiro, ou (c) abortar?"
- Se (a), prossiga. Se (b)/(c), PARE (worktree preservado).

**Se APROVADO:** prossiga para Fase 4.

## Fase 4 — Conversão em PRD

1. Leia `~/.claude/skills/prd/SKILL.md`.
2. Converta o plano em `$WORKTREE_PATH/prd.json` seguindo a skill `prd`:
   - 1 fatia = 1 user story
   - AC testáveis
   - [SUPOSIÇÕES] viram AC de validação
3. Mostre o `prd.json` ao usuário.
4. Pergunte: "prd.json criado com N stories. Revisar antes de executar Ralph? (y/N)"
   - Se "y": **PARE** (worktree preservado). Usuário ajusta e depois roda `/ralph-adversarial` ou continua.
   - Se "N" ou enter: prossiga para Fase 5.

## Fase 5 — Execução Ralph Adversarial

1. Leia `~/.claude/skills/ralph-adversarial/SKILL.md`.
2. Verifique pré-requisitos: `jq`, `claude`, `codex`, `CODE_REVIEW.md`.
3. Execute **dentro do worktree**:
   ```bash
   cd "$WORKTREE_PATH"
   chmod +x ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   bash ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   ```
4. Após conclusão, apresente resumo: stories completas/pendentes/escaladas, findings P0/P1, progress.txt.

**Gate:** Se houver stories escaladas ou findings P0 não resolvidos, **PARE** (worktree preservado) e escale para humano. NÃO prossiga para PR.

## Fase 6 — Testes finais

Antes de abrir PR, rode a suíte de testes do projeto **dentro do worktree**:
```bash
cd "$WORKTREE_PATH"
# Detecte o runner (package.json, pytest, go test...) e execute
```

Se falhar, **PARE** e escale — não abra PR com testes vermelhos.

## Fase 7 — PR + Merge

Execute o fluxo de `/pr` **dentro do worktree**:
- `cd "$WORKTREE_PATH"`
- push do branch, criação do PR, watch de checks, merge com `--delete-branch`.

Se merge falhar (proteção, reviews pendentes), **PARE** (worktree preservado) e reporte ao usuário.

## Fase 8 — Cleanup do Worktree

Após merge bem-sucedido:
1. Execute `/worktree-cleanup "$WORKTREE_PATH"` (ou inline):
   ```bash
   # Validar que está merged (gh pr já confirmou na Fase 7)
   git worktree remove "$WORKTREE_PATH"
   git worktree prune
   git branch -d "$SLUG" 2>/dev/null || true
   ```
2. Retorne ao repo principal: `cd "$(git rev-parse --show-toplevel)"` (ou ao diretório original).
3. Reporte: "Ciclo completo. PR #N merged. Worktree removido."

## Guardrails

- Nenhum código de produção é escrito antes do veredicto APROVADO.
- Humano pode interromper em qualquer fase. Worktree é **preservado** em toda interrupção — só é removido após merge bem-sucedido na Fase 8.
- Se qualquer fase falhar, reporte o status e PARE — não improvise nem force cleanup.
- **NUNCA** remova o worktree se testes falharem, PR não for merged, ou stories estiverem pendentes.
