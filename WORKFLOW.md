# Workflow: Como Usar o Sistema Multi-Agente

## Comandos Disponíveis

| Comando | Uso |
|---------|-----|
| `/plan [problema]` | Produz plano técnico com ReAct + Feynman |
| `/adversarial-review [plano]` | Revisão adversária de um plano existente |
| `/full-cycle [problema]` | Planejamento + auto-revisão em sequência |
| `/adversarial-research [tema]` | Deep research com 3 provedores |
| `/prd-convert [plano]` | Converte plano aprovado em `prd.json` |
| `/coverage-init` | Provisiona toolchain + config + baseline + template CI de cobertura por linguagem (enforcement do **Objetivo do ciclo** #1) |
| `/ralph-adversarial [--parallel\|--parallel=N] [max_iter]` | Loop de implementação com revisão Codex |
| `/commit-push-pr ["msg"]` | Branch efêmera + commit + push + PR |
| `/ship ["msg"]` | Auto-pipeline de entrega: testes pré-merge (**loop 3x auto-fix**) → PR → auto-merge (ou force-merge soft em repo não-protegido) → deploy (se `.claude/ship.json` configura) → e2e pós-merge contra URL real (**loop 3x hotfix por iteração**) |
| `/force-merge [PR\|branch] [--wait] [--admin]` | Mergeia PR aberto agora. Modos: soft (default), `--wait` aguarda CI até **30min** (override `--wait-timeout=Nm`), `--admin` bypassa proteção (**sempre confirma**). Auto-sync do pool após merge |
| `/export-report` | Exporta última resposta como Markdown |

### Comandos nativos do Claude Code (built-in, v2.1.139–146)

| Comando | Uso |
|---------|-----|
| `/code-review [low\|high]` | Review local multi-agent do diff atual (substitui a skill nativa `simplify`, renomeada em v2.1.146) |
| `/goal <condição>` | Autonomy goal-driven leve — alternativa a `/plan` quando o overhead estruturado é overkill |
| `claude agents` (CLI) | Dashboard unificado de sessions running/blocked/completed |
| `/resume` | Retoma background sessions com modelo/effort/permissions preservados |
| `/schedule` | Cron remoto de agentes recorrentes — alternativa a `/loop` |

### Skills de alinhamento e exploração (Tier 1)

- **`grill-me`** — interview adversário, uma pergunta por vez, até shared understanding. Via `/plan --grill` ou manual.
- **`grill-with-docs`** — superset do grill-me que mantém `CONTEXT.md` (glossário) e `docs/adr/` (decisões hard-to-reverse).
- **`zoom-out`** — mapeia módulos/callers de uma área desconhecida usando o vocabulário do domínio; usado por `/plan` e `/techdebt` quando o contexto de código está raso.
- **`diagnose`** — protocolo de 6 fases (feedback loop → reproduzir → hipotetizar → instrumentar → fix+regressão → cleanup); invocado por `/diagnose` ou pelo Ralph após 2 falhas consecutivas.
- **`git-guardrails-claude-code`** — hook PreToolUse global **secret-scan-only**: bloqueia commit/push com segredos ou arquivos `.env`/`credentials`/`*.pem`/`*.key` no diff; ops destrutivas NÃO são bloqueadas (Princípio 7 cobre só segredos).

## Fluxo de Planejamento

1. `/plan [problema]` → salva em `.claude/plans/`
2. `/adversarial-review .claude/plans/[arquivo].md` → parecer adversário
3. Iterar até aprovação (máx. 3 ciclos)
4. Implementar a Próxima Fatia

Ou use `/full-cycle [problema]` para executar as duas fases em sequência.

**Objetivo do ciclo (metas transversais).** Todo plano declara um ou mais **Objetivo do ciclo** — metas que **toda fatia** satisfaz, independentes da feature. O #1 é **cobertura 100% do código que a fatia introduz**: `react-feynman` emite a seção no plano, a skill `prd` converte em AC de cobertura por user story, `coverage-gate.sh --report` alimenta o reviewer Codex (dimensão COVERAGE, advisory; veredicto binário) e `coverage-gate.sh --gate` é o required check no CI. Rode `/coverage-init` 1x no projeto-alvo para provisionar a toolchain. A estrutura aceita um Objetivo #2 futuro sem redesenho.

## Ralph Adversarial — modo paralelo (Fase 2)

`/ralph-adversarial --parallel` (ou `--parallel=N`) roda múltiplas user stories em paralelo, exigindo um **pool de checkouts** provisionado por `/checkout-init` (layout Boris Cherny — `~/Projects/checkouts/<repo>-{1..N}/`). O slot de invocação atua como orquestrador; os demais slots como workers.

Capacidade (`compute_cap`):

| Pool size | Workers disponíveis | Cap default (`RALPH_PARALLEL_N=4`) |
|-----------|--------------------|-----------------------------------|
| 1         | 0                  | aborta (`pool ≥ 2 slots` exigido) |
| 2         | 1                  | 1                                 |
| 3         | 2                  | 2                                 |
| 5         | 4                  | 4                                 |

Override: `RALPH_PARALLEL_N=2 /ralph-adversarial --parallel`.

### Contrato de delta files (deltas-untracked)

Workers escrevem aprendizados em **arquivos UNTRACKED** no slot de trabalho:

- `progress-<US-ID>.txt` — feedback/gotchas/decisões da iteração
- `agents-delta-<US-ID>.md` — convenções descobertas

**Esses arquivos NÃO são commitados pelo worker.** O orquestrador os captura via filesystem após o COMMIT (`stash_worker_deltas` → `$ORCH/.ralph/delta-stash/<US-ID>/`) e integra ao `progress.txt` / `AGENTS.md` central no merge (`integrate_delta_files` via `merge --amend`).

Defesa em camadas (já automatizada):

1. `IMPL_PROMPT.md` instrui worker a manter delta files untracked
2. Preflight escreve `progress-*.txt` + `agents-delta-*.md` em `.git/info/exclude` de cada slot (`ensure_slot_excludes_deltas`) — bloqueia `git add` acidental
3. `.gitignore` versionado adiciona os mesmos patterns no projeto-alvo via helper

### Setup por projeto-alvo (uma vez)

```bash
bash ~/.claude/skills/ralph-adversarial/apply-gitignore.sh           # aplica em $PWD
bash ~/.claude/skills/ralph-adversarial/apply-gitignore.sh --pool    # + commit/push/pull em slots irmãos do pool
```

Idempotente — rodar 2× não duplica linhas. Em pools Boris Cherny, `--pool` propaga via `git push` no slot atual + `git pull --ff-only` nos slots irmãos.

## Dicas

- Tarefas triviais NÃO ativam ReAct (o CLAUDE.md isenta explicitamente).
- Use `/compact` entre planejar e revisar para simular "olhos frescos".
- Planos sempre vão para `.claude/plans/` (arquivo, não conversa).
- `/ralph-adversarial` (serial) e `/ralph-adversarial --parallel` produzem o mesmo histórico em `main`; o paralelo só acelera a entrega.
