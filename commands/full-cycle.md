---
description: Ciclo end-to-end — planejamento + revisão adversária + conversão em prd.json + execução Ralph Adversarial
allowed-tools: Read, Write, Glob, Grep, Bash(find *), Bash(bash *), Bash(chmod *), Bash(cat *), Bash(jq *), Bash(git *), Bash(ls *), Bash(wc *), Bash(awk *), Bash(grep *), Bash(sed *)
argument-hint: [descrição do problema ou feature]
---

Execute as seis fases em sequência para: $ARGUMENTS

## Fase 1 — Planejamento

1. Leia `~/.claude/skills/react-feynman/SKILL.md`.
2. Assuma o papel de **Agente Planejador**.
3. Execute o ciclo ReAct completo.
4. Produza o plano usando o Template: Plano.
5. Salve o plano em `.claude/plans/[slug-do-titulo].md`. Guarde esse caminho como `PLAN_PATH` para uso nas fases seguintes.

## Fase 2 — Revisão Adversária

1. Troque para o papel de **Agente Revisor Adversário**.
2. Releia o plano com olhos frescos.
3. Para cada decisão, tente refutar. Aplique Teste Feynman.
4. Produza o parecer usando o Template: Revisão Adversária.
5. Adicione o parecer ao final do mesmo `PLAN_PATH`, sob `---` separador.

## Fase 3 — Portão de Aprovação

Determine o veredicto da Fase 2:

- **REPROVADO**: destaque os 3 pontos mais críticos, escale para o humano e **encerre o ciclo**. Não prossiga para as fases seguintes.
- **APROVADO COM RESSALVAS**: liste as ressalvas de severidade alta e pergunte ao usuário: "Deseja prosseguir, revisar o plano, ou abortar?" — aguarde resposta antes de seguir.
- **APROVADO**: prossiga automaticamente para a Fase 4.

## Fase 4 — Conversão para prd.json

1. Use a skill `prd` para converter `PLAN_PATH` em `prd.json` na raiz do repositório.
2. Mostre ao usuário o `prd.json` gerado (projectName, branchName, quantidade de stories, títulos).
3. Pergunte: "Revisar prd.json antes de executar Ralph? (s/N)" — se `s`, pare aqui e aguarde ajustes do usuário.
4. Caso contrário, prossiga para a Fase 5.

## Fase 5 — Execução Ralph Adversarial

1. Verifique pré-requisitos: `jq`, `claude`, `codex` no PATH, e `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md`. Se faltar algo, reporte e **pare** — não improvise.
2. Capture o estado inicial para o relatório:
   - `RALPH_START_TS=$(date -Iseconds)`
   - `RALPH_START_COMMIT=$(git rev-parse HEAD)`
   - `RALPH_BRANCH=$(jq -r '.branchName' prd.json)`
3. Execute o loop:
   ```bash
   chmod +x ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   bash ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh 2>&1 | tee .claude/ralph-run.log
   ```
4. Capture o estado final:
   - `RALPH_END_TS=$(date -Iseconds)`
   - `RALPH_END_COMMIT=$(git rev-parse HEAD)`

## Fase 6 — Relatório Consolidado Final

Gere um relatório abrangente sintetizando todas as fases. Use os comandos abaixo para coletar cada métrica e **apresente o relatório na íntegra ao usuário** (também salve em `.claude/reports/full-cycle-[slug]-[timestamp].md`).

### Dados a coletar

**Do plano (Fase 1-3):**
- Título, `PLAN_PATH`, veredicto da revisão adversária, contagem de `[ASSUMPTION]` no plano (`grep -c '\[ASSUMPTION\]' "$PLAN_PATH"`), contagem de issues do parecer adversário.

**Do prd.json (Fase 4):**
- `PROJECT_NAME=$(jq -r '.projectName' prd.json)`
- `BRANCH=$(jq -r '.branchName' prd.json)`
- `TOTAL_STORIES=$(jq '.userStories | length' prd.json)`

**Da execução Ralph (Fase 5):**
- `PASSED=$(jq '[.userStories[] | select(.passes == true)] | length' prd.json)`
- `PENDING=$(jq '[.userStories[] | select(.passes == false)] | length' prd.json)`
- `ESCALATED=$(jq '[.userStories[] | select(.passes == "ESCALATED")] | length' prd.json)`
- Iterações usadas: conte `--- Iteração` em `.claude/ralph-run.log` ou a última linha `Iterações usadas: N`.
- Duração: diff entre `RALPH_START_TS` e `RALPH_END_TS`.

**Do git (Fase 5):**
- Commits criados: `git log --oneline "$RALPH_START_COMMIT..$RALPH_END_COMMIT"`
- Arquivos tocados: `git diff --stat "$RALPH_START_COMMIT..$RALPH_END_COMMIT"`
- Linhas adicionadas/removidas: última linha de `git diff --shortstat "$RALPH_START_COMMIT..$RALPH_END_COMMIT"`
- Arquivos de teste criados/modificados: `git diff --name-only "$RALPH_START_COMMIT..$RALPH_END_COMMIT" | grep -E '(test|spec)\.(ts|js|py|tsx|jsx)$'`

**Das revisões Codex:**
- Liste `.claude/research/review-*.txt` do run. Para cada, extraia `"verdict"` e agregue contagem P0/P1/P2/P3 via `grep -oE '"severity":"P[0-3]"'`.

**Aprendizados:**
- `progress.txt`: últimas 30 linhas OU só entradas deste run (filtrando por timestamp >= `RALPH_START_TS`).
- Diff de `AGENTS.md` durante o run: `git diff "$RALPH_START_COMMIT..$RALPH_END_COMMIT" -- AGENTS.md`.

### Estrutura do relatório

```markdown
# Relatório Consolidado — [Título do Plano]

**Comando:** /full-cycle $ARGUMENTS
**Início:** $RALPH_START_TS · **Fim:** $RALPH_END_TS · **Duração:** [HH:MM:SS]
**Projeto:** $PROJECT_NAME · **Branch:** $BRANCH

## 1. Resumo Executivo
- [1-3 linhas declarando o resultado: stories aprovadas/pendentes/escaladas, sucesso geral]
- [Se houve bloqueios críticos, declare aqui em 1 linha]

## 2. Planejamento
- **Plano:** $PLAN_PATH
- **Veredicto adversário:** [APPROVED / APPROVED WITH CAVEATS]
- **[ASSUMPTION]s no plano:** N
- **Issues encontradas pelo revisor:** N (Critical/High/Medium/Low agregados)

## 3. Stories (prd.json)
| ID | Título | Prioridade | Resultado | Iterações |
|----|--------|------------|-----------|-----------|
| US-01 | ... | 1 | PASSED | 1 |
| US-02 | ... | 2 | ESCALATED | 2 |
| ... |

## 4. Execução
- **Iterações usadas:** N / MAX
- **Commits criados:** N
- **Arquivos tocados:** N (+X -Y linhas)
- **Arquivos de teste:** N criados/modificados

## 5. Revisões Codex Agregadas
| Severidade | Count | Top issues (exemplos) |
|-----------|-------|------------------------|
| P0 | 0 | — |
| P1 | 2 | [resumo 1-linha de cada] |
| P2 | 5 | [agrupados por tipo] |
| P3 | N | [informativos] |

## 6. Commits
[saída de git log --oneline do range]

## 7. Cobertura por Acceptance Criteria
- Parse ac_trace dos commits. Mostre table: story → AC → file:linha → teste → status.

## 8. Aprendizados e Gotchas
- Entradas relevantes de `progress.txt` (só do run atual).
- Diff de `AGENTS.md`, se houver — sinaliza padrões descobertos que viraram convenção.

## 9. Itens Escalados / Pendentes
- Para cada story com `passes: "ESCALATED"` ou `false`: ID, título, motivo (última entrada correspondente em progress.txt), sugestão de próximo passo.

## 10. Próximas Fatias Sugeridas
- Se o plano original tinha Próxima Fatia, aponte-a.
- Se surgiram novas fatias dos aprendizados, liste-as como bullets com estimativa qualitativa (S/M/L).

## 11. Artefatos
- Plano: $PLAN_PATH
- PRD: prd.json
- Log de execução: .claude/ralph-run.log
- Revisões individuais: .claude/research/review-US-*.txt
- Este relatório: .claude/reports/full-cycle-[slug]-[ts].md
```

### Regras para o relatório

1. **Sem prosa genérica.** Números concretos, caminhos reais, commits por hash curto.
2. Se uma fase foi pulada (ex: usuário abortou na Fase 3 com "APROVADO COM RESSALVAS"), emita relatório parcial com as fases executadas e declare explicitamente as que foram puladas.
3. Se a Fase 5 não rodou (ex: usuário pediu revisão do prd.json na Fase 4), o relatório se encerra após a seção 3 e marca seções 4+ como `N/A — execução não iniciada`.
4. Salve o relatório com `Write` em `.claude/reports/full-cycle-[slug]-YYYYMMDD-HHMMSS.md` e apresente o conteúdo inteiro na resposta final.

## Guardrails gerais

- **Nenhum código em produção antes do veredicto APROVADO/APROVADO COM RESSALVAS com confirmação humana.**
- Humano pode interromper a qualquer fase (o Ralph respeita Ctrl-C — o loop para após a iteração atual).
- Se qualquer pré-requisito falhar (binário ausente, rubrica faltando), reporte status e **pare** — não improvise substitutos.
