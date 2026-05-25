---
description: Reflexão / supervisão DoD pós-merge — classifica adequação do Definition of Done aplicado a uma PR. Trigger phrases — "reflexão", "supervisão DoD", "retrabalho", "pós-merge", "definition of done review", "retrospectiva". Quatro modos — --baseline (DoD compliance imediato), --retro (algoritmo D1 v2 completo após D+7), --on-failure (auditoria em gate de parada), --learn (LLM consome bundle TDD-chain por US e propõe melhorias DoD/TEST-PATTERNS).
argument-hint: "[pr-number] [--baseline|--retro|--on-failure <N>|--learn] [--quick] [--context-file <path>] [--from-stdin]"
allowed-tools: Bash(git:*), Bash(gh:*), Bash(jq *), Bash(bash *), Bash(mkdir *), Bash(test *), Bash(date *), Bash(find *), Bash(basename *), Bash(dirname *), Bash(cat *), Bash(grep *), Bash(awk *), Bash(sed *), Bash(sort *), Bash(uniq *), Bash(wc *), Bash(ls *), Bash(touch *), Bash(pwd *), Read, Write, Glob, Grep
---

# /reflect — supervisão DoD pós-merge

Audita uma PR mergeada confrontando a Definition of Done aplicada no plano original contra o que o ciclo real expôs (CI checks, commits subsequentes, comentários, decisões marginais do `auto-grill-me`). Saída — relatório `.claude/reflections/<ts>-<slug>-<modo>.md` e, em modo `--retro`, diff atomic proposto cobrindo `docs/definition_of_done.md` (canônico) + `skills/auto-grill-me/references/DOD.md` (lean).

## Preflight (inline bash — pré-computa contexto antes do modelo)

!`pwd`
!`gh pr list --state merged --limit 1 --base main --json number,title,headRefName,mergeCommit,body,mergedAt 2>&1 | head -50`
!`test -d .claude/reflections && ls -lt .claude/reflections 2>/dev/null | head -5 || echo "(sem .claude/reflections — fallback ~/.claude/cache/reflect/<repo>/)"`
!`ls -la ~/.claude/cache/reflect/proposals/ 2>/dev/null | head -5 || echo "(sem proposals/)"`
!`test -f ~/.claude/cache/reflect/reminders.jsonl && echo "reminders.jsonl: $(wc -l < ~/.claude/cache/reflect/reminders.jsonl) entrada(s)" || echo "(sem reminders.jsonl)"`

## Parse de argumentos ($ARGUMENTS = `$ARGUMENTS`)

1. **`$1` numérico** → `PR_NUM=$1`. Se ausente ou começa com `--`, resolve via `gh pr list --state merged --limit 1 --base main --json number --jq '.[0].number // empty'`. Se ainda vazio → erro `nenhuma PR mergeada em main — passe número explicitamente` e aborta.
2. **Modo (exatamente 1)** — default `--retro` em invocação standalone. Default `--baseline` quando ambiente `REFLECT_NESTED=1` (ciclo automático Fase 9 do `/full-cycle*`). Default `--learn` quando ambiente `REFLECT_NESTED=1` **E** `REFLECT_LEARN_GATE=1` (heurística de gate na Fase 9 disparou — vide `commands/full-cycle.md`).
   - `--baseline` → DoD compliance retroativa (sem detecção de retrabalho).
   - `--retro` → algoritmo D1 v2 completo (6 camadas).
   - `--on-failure <N>` → auditoria de fase parada (N ∈ {3,5,6}); exige `--context-file <path>` ou `--from-stdin`.
   - `--learn` → LLM analisa chain `US → DoD bullet → spec TDD → teste implementado → resultado` por user story e propõe melhorias estruturadas em DoD/TEST-PATTERNS. Mutuamente exclusivo com os outros 3.
3. **Modificadores**
   - `--quick` → válido com `--baseline` **e** `--on-failure` (mas não com `--retro`). Subset do algoritmo — em `--baseline` limita comparação à seção da DoD detectada (≤ 30 bullets) e pula fetch de PR comments; em `--on-failure` reduz cross-ref de critérios à categoria da fase parada (sem expansão para DoD-base inteira) e também pula fetch de PR comments. Usado pelo `/full-cycle-simple` (Fase 9 + sugestões em paradas). Combinação `--retro --quick` é rejeitada com erro de parse.
   - `--context-file <path>` / `--from-stdin` → fontes para `--on-failure`.

Erros de parse — mensagem clara em uma linha + aborta com exit non-zero conceitual (slash não tem exit; apenas pare a execução).

## Etapa 0 — GC de proposals antigos (AC20)

Antes de tudo, limpe diffs antigos:

```bash
mkdir -p ~/.claude/cache/reflect/proposals
find ~/.claude/cache/reflect/proposals -maxdepth 1 -type f -name '*.diff' -mtime +90 -print -delete 2>/dev/null || true
```

Anote no relatório quantos foram removidos (linha `gc: N diff(s) > 90d removidos`).

## Etapa 1 — Resolver alvo, paths, plano correlato

```bash
# Variáveis canônicas
PR_NUM=<resolvido acima>
PR_JSON=$(gh pr view "$PR_NUM" --json number,title,headRefName,mergeCommit,body,mergedAt,baseRefName,files)
TITLE=$(jq -r '.title' <<<"$PR_JSON")
MERGE_SHA=$(jq -r '.mergeCommit.oid // empty' <<<"$PR_JSON")
MERGED_AT=$(jq -r '.mergedAt' <<<"$PR_JSON")
BODY=$(jq -r '.body // ""' <<<"$PR_JSON")
PATHS=$(jq -r '.files[].path' <<<"$PR_JSON")
TS=$(date -u +'%Y-%m-%dT%H-%M-%SZ')
SLUG=$(awk '{print tolower($0)}' <<<"$TITLE" | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-50)
REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
```

### Correlação plano↔PR (AC8 — fallback hierárquico)

Tente nesta ordem e pare no primeiro que casar:

1. **Marker explícito no PR body** — regex `plan: \.claude/plans/([^ \n]+\.md)` em `$BODY`. Match → `PLAN_PATH`.
2. **Slug título da PR ↔ filename de plano** — `ls .claude/plans/*.md 2>/dev/null | grep -F "$SLUG"`. Match único → `PLAN_PATH`.
3. **Fuzzy slug ↔ commits da PR (últimos 7d)** — para cada plano em `.claude/plans/` modificado ≤7d antes de `$MERGED_AT`, extrai slug do filename e busca `git log $MERGE_SHA~5..$MERGE_SHA --format='%s' | grep -iF <slug>`. Maior número de matches vence.
4. **Falha em todas** — emite warning `[warn] plano não correlacionado — Camada #1 inativa (AC13); confiabilidade reduzida` e segue (não aborta).

Anote a heurística vencedora no relatório (`plan_match: marker|slug-exact|fuzzy|none`).

### Resolver `session_id` do `auto-grill-me`

Para camada #1, descubra `SESSION_ID`:

```bash
DECISIONS=~/.claude/cache/auto-grill/${REPO}-decisions.jsonl
test -f "$DECISIONS" || DECISIONS=""
# Se PLAN_PATH conhecido, busca por timestamp próximo + cwd
# Heurística — sessão cuja ts é mais próxima de mtime do PLAN_PATH (janela 24h)
```

Se `DECISIONS` vazio ou nenhuma sessão correlaciona, marque `session_correlated: false` e Camada #1 sai inativa no relatório (AC13).

### Path de saída

```bash
if test -d .claude; then
  OUT_DIR=".claude/reflections"
else
  OUT_DIR="$HOME/.claude/cache/reflect/${REPO}"
fi
mkdir -p "$OUT_DIR"
REPORT="${OUT_DIR}/${TS}-${SLUG}-${MODE}.md"
```

> **AC18 (gatilho do fallback):** o fallback só dispara quando `.claude/` **não existe** no cwd. Se `.claude/` existe mas `.claude/reflections/` ainda não, o comando cria o subdiretório — preserva o path local da story.

`MODE` ∈ {`baseline`, `retro`, `failure-<N>`}.

## Etapa 2 — Executar modo

### Modo `--baseline` (AC3)

Foco — **DoD aplicada no plano original vs CI checks reais**. NÃO roda detecção de retrabalho.

1. **DoD aplicada** — se `PLAN_PATH` conhecido, extrai bullets `- [ ]` do plano (todos os checkboxes da seção "Definition of Done"). Se não há plano, anota `dod_source: ausente` e marca o baseline como **degradado** (segue, mas com avisos).
2. **CI checks reais** — `gh pr checks "$PR_NUM" --json name,state,bucket,workflow 2>/dev/null | jq -c '.[]?' || true`. Campos válidos do gh: `name`, `state` (`SUCCESS|FAILURE|PENDING|SKIPPED`), `bucket` (`pass|fail|pending|skipping`). Não use `status` nem `conclusion` (não existem). Se output vier vazio ou plain-text (sem checks configurados), anote `ci_checks: nenhum` no relatório e siga.
3. **Comparação** — identifique lacunas onde a DoD era declarativa mas não foi automatizada em CI. Cada lacuna vira finding `dod_gap`.
4. **`--quick`** — limita comparação à seção "Slash command novo" / "Skill nova" / categoria detectada (≤ 30 bullets) para economia.
5. **Append em reminders.jsonl** (AC10):

```bash
mkdir -p ~/.claude/cache/reflect
RETRO_DUE=$(date -u -v+7d +'%Y-%m-%dT%H-%M-%SZ' 2>/dev/null || date -u -d '+7 days' +'%Y-%m-%dT%H-%M-%SZ')
jq -nc --arg pr "$PR_NUM" --arg created "$TS" --arg due "$RETRO_DUE" --arg repo "$REPO" \
   '{pr:$pr, repo:$repo, created_at:$created, retro_due_at:$due}' \
   >> ~/.claude/cache/reflect/reminders.jsonl
```

6. **Relatório** — `<ts>-<slug>-baseline.md` com seções: Resumo, DoD aplicada vs CI, Lacunas, **Aviso retrospectiva**: `retrospectiva agendada para D+7 — rode /reflect $PR_NUM --retro a partir de $RETRO_DUE`.

### Modo `--retro` (AC4) — algoritmo D1 v2 em 6 camadas

**Contexto de uso da DoD — derivado via fold (US-04 AC4).** Antes das camadas,
derive os contadores `usos`/`desde rev`/`last_seen` por DoD a partir do log
append-only (fonte única pós-US-03). **Nunca** leia o sufixo `(usos…)` do DOD.md
(removido na migração) — derive sempre do fold:

```bash
bash bin/lib/usage-fold.sh --prefix dod 2>/dev/null \
  | awk -F'\t' '{printf "  %-14s usos=%s desde_rev=%s last_seen=%s\n",$1,$2,$3,$4}'
```

Inclua a saída na seção **"DoD usage (derivado via fold)"** do relatório. Os
números são **content-based** (US-02) e idênticos aos que ficavam inline antes da
migração (equivalência provada em US-03 AC5) → o relatório D1 v2 produz os mesmos
números que produziria com o inline equivalente. Sem log no host → seção vazia
(não é erro). Esses contadores são **contexto**, não disparam findings de retrabalho.

Cada camada produz findings independentes. **Aplicar exclusion list (AC12) em todas**:

**Exclusion paths** (negar matching):
- `docs/definition_of_done.md`
- `skills/auto-grill-me/references/DOD.md`
- `docs/rubrica_decisao.md`
- `~/.claude/cache/reflect/**` (paths absolutos pessoais não aparecem em PRs, mas filtre)

**Exclusion subject pattern** — `^(docs\(dod\)|fix\(skill\): auto-grill-me|chore\(reflect\))`.

#### Camada 1 — cross-ref `decisions.jsonl` Tipo 3 marginal (AC6)

Se `session_correlated: false` → pule e anote `Camada #1 inativa` (AC13).

```bash
jq -c --arg sid "$SESSION_ID" \
  'select(.session_id==$sid and .output=="tipo3" and .score_final >= 53)' \
  "$DECISIONS"
```

Cada decisão Tipo 3 score ≥ 53 é candidata. Para cada uma, busque commit subsequente que tocou área correlata (paths do plano) — match indica retrabalho previsto pela rubrica.

#### Camada 2 — `git log paths-touched`

```bash
git log "$MERGE_SHA"..HEAD --format='%H %s' -- $(echo "$PATHS" | tr '\n' ' ')
```

Cada commit pós-merge tocando arquivos da PR é finding (após exclusion).

#### Camada 3 — Conventional Commits strict

```bash
git log "$MERGE_SHA"..HEAD --format='%H %s' \
  | grep -E '^[a-f0-9]+ (fix|hotfix|revert)\('
```

#### Camada 4 — Prefix livre

```bash
git log "$MERGE_SHA"..HEAD --format='%H %s' \
  | grep -E '^[a-f0-9]+ (hotfix|revert|fix): '
```

#### Camada 5 — palavras-chave em qualquer posição

```bash
git log "$MERGE_SHA"..HEAD --format='%H %s' \
  | grep -iE '^[a-f0-9]+ .*\b(fix|correct|revert|bug|broken|missed)\b'
```

#### Camada 6 — PR comments pós-merge com filtro de sentimento

Filtra **dois critérios simultaneamente** — sentimento negativo **E** janela temporal pós-merge (`created_at > $MERGED_AT`). Sem o segundo filtro, comentários pré-merge contendo "should have", "missed" etc. (típicos de revisão) viram falsos findings de retrabalho.

```bash
gh api "repos/{owner}/{repo}/issues/$PR_NUM/comments" --jq '.[] | {user: .user.login, body: .body, created_at: .created_at}' 2>/dev/null \
  | jq -c --arg merged "$MERGED_AT" 'select(.created_at > $merged and (.body | test("missed|should have|bug|wrong|broken|regression"; "i")))'
```

Pula em `--quick`.

#### Deduplicação (AC7)

Após todas as camadas, agregue por `commit_sha`. Findings duplicados (mesmo SHA detectado por múltiplas camadas) são consolidados em **uma única linha** com anotação `detectado_por: [#2, #3, #5]`. Apresentação no relatório usa o set deduplicado.

#### Diff atomic (AC9)

Se findings indicam categoria com DoD subestimada, prepare diff cobrindo ambos paths:

**Regra de extração canônico → lean (documentar no relatório):**

> O agente edita SÓ `docs/definition_of_done.md` (formato narrativo). Para `skills/auto-grill-me/references/DOD.md` (lean): cada bullet `- <texto>` adicionado/modificado no canônico vira `- [ ] <texto>` no lean, preservando agrupamento por categoria/tarefa. Headers (`##`, `###`) são copiados verbatim. Notas em prosa do canônico (parágrafos sem bullet) são **omitidas** do lean.

Diff vai em `~/.claude/cache/reflect/proposals/${TS}.diff`:

```bash
mkdir -p ~/.claude/cache/reflect/proposals
# Construa diff unified (formato `diff -u` ou `git diff`) cobrindo:
# - docs/definition_of_done.md  (edição narrativa)
# - skills/auto-grill-me/references/DOD.md  (extração lean)
# Grava em ~/.claude/cache/reflect/proposals/${TS}.diff
```

**AC11 — Gate humano antes de gravar diff:** se a mudança proposta toca **Categoria 1 / Tarefa 3** (princípio global na `CLAUDE.md`) OU adiciona novo short-circuit/anti-pattern, **pause antes do `Write`** e mostre no chat:

```
=== Diff proposto (Categoria 1 / Tarefa 3 — princípio global) ===
Resumo: <1 linha>
Paths tocados: docs/definition_of_done.md, skills/auto-grill-me/references/DOD.md
Linhas: +N -M

Confirma proposta? [y/N]
```

Aguarde `y`/`yes`/`s`/`sim`. Qualquer outra resposta → **não grava o diff**; relatório registra `proposal_skipped_by_user: true` e segue.

Para mudanças em outras categorias/tarefas — grava direto e anuncia path ao final.

### Modo `--on-failure <N>` (AC5)

Contexto via `--context-file <path>` (lê arquivo) ou `--from-stdin` (lê stdin pipeado). Pelo menos um é obrigatório.

Foco — `qual critério DoD teria capturado essa falha`. Ignore detecção de retrabalho (falha foi pré-merge).

1. Leia contexto da fase parada (parecer adversário, findings P0, output do test runner).
2. Confronte com a DoD aplicada (extraída do plano se disponível).
3. Liste **critérios faltantes**: itens da DoD-base que teriam disparado o gate antes de chegar à fase atual.
4. **`--quick`** — escopo do cross-ref limitado à **categoria da fase parada** (Fase 3 → categoria do plano/parecer; Fase 5 → categoria das stories escaladas; Fase 6 → categoria do test runner output). Não expande para DoD-base inteira. Pula fetch de PR comments. Resultado: relatório mais curto, mesmo formato.
5. Relatório — `<ts>-<slug>-failure-<N>.md` com seções: Resumo da falha, DoD aplicada, Critérios faltantes, Recomendação para próxima iteração. Em `--quick` adicione linha `quick_scope: <categoria>` no front-matter do relatório.

### Modo `--learn` (US-02 — TDD-chain feedback)

Consome a chain rastreável `US → DoD bullet → spec TDD → teste implementado → resultado` por user story e pede a uma LLM (`claude --print --max-turns 1`) propostas estruturadas para evoluir DoD/TEST-PATTERNS. Saída tripla em `~/.claude/cache/reflect/proposals/<ts>-<slug>/`: `report.md` (humano), `proposed.diff` (git-applyable), `proposal.json` (tooling).

> **Gotcha (AC4 — RESSALVA ALTA #2):** o subprocess `claude --print` usa timeout HARD-CODED **600s (10min)** dentro do helper `bin/reflect-learn-bundle.sh`. NÃO herda `RALPH_HANG_TIMEOUT=2700` do Ralph — análise de bundle é tarefa curta (~30s esperado); 45min vira hang silencioso.

> **Gotcha (AC5 — RESSALVA ALTA #3):** `bin/reflect-learn-bundle.sh` grava `raw-llm-output.txt` SEMPRE (sucesso ou falha), e o parser jq é fail-graceful — se a LLM não emite JSON válido, `proposal.json` carrega finding `llm_output_unparseable` apontando pro raw. Smoke test em `bin/tests/test_reflect_learn_bundle.sh`.

**Sub-step 1 — GC de proposals antigos (AC10):**

```bash
mkdir -p ~/.claude/cache/reflect/proposals
find ~/.claude/cache/reflect/proposals -maxdepth 1 -type d -mtime +90 -print -exec rm -rf {} + 2>/dev/null || true
```

Anote `gc: N proposal(s) > 90d removidos` no relatório.

**Sub-step 2 — Itera por user story e invoca o helper:**

```bash
test -f prd.json || { echo "[warn] prd.json ausente no cwd — --learn requer PRD"; exit 0; }
TS=$(date -u +'%Y-%m-%dT%H-%M-%SZ')
PR_SLUG=$(awk '{print tolower($0)}' <<<"$TITLE" | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g' | cut -c1-50)
OUT_DIR="$HOME/.claude/cache/reflect/proposals/${TS}-${PR_SLUG}"
mkdir -p "$OUT_DIR"

# Para cada US do prd.json: monta bundle + chama LLM + gera 3 outputs em subdir.
US_IDS=$(jq -r '.userStories[]?.id // empty' prd.json)
for US in $US_IDS; do
  US_SUBDIR="$OUT_DIR/$US"
  bash ~/.claude/bin/reflect-learn-bundle.sh "$PR_NUM" "$US" --with-llm "$US_SUBDIR" || true
done
```

**Sub-step 3 — Parse de outputs e agregação (AC5 — fail-graceful):**

Cada `proposal.json` de US foi gerado pelo helper com schema `{summary, proposals[], findings[]}`. Quando a LLM falhou ou output não parseou, `findings[]` contém `{type: "llm_output_unparseable", raw_path, llm_exit_code}` — propagar sem mascarar.

**Sub-step 4 — Triplo output agregado (AC8):**

- `report.md` (raiz de `$OUT_DIR`): índice das US analisadas + sumário por US (1 linha) + ponteiro pra subdir.
- `proposed.diff` (raiz): concatenação dos diffs por-US separados por `## US-XX`.
- `proposal.json` (raiz): `{"per_us": {<US-ID>: <proposal>}}` consolidado.

```bash
{
  echo "# Reflect --learn — PR #$PR_NUM"
  echo ""
  echo "Generated: $(date -u +%FT%TZ)"
  echo ""
  echo "| US | Summary | Proposals | Findings |"
  echo "|----|---------|-----------|----------|"
  for US in $US_IDS; do
    PJ="$OUT_DIR/$US/proposal.json"
    [ -f "$PJ" ] || continue
    SUM=$(jq -r '.summary // ""' "$PJ" | head -1)
    NP=$(jq '(.proposals // []) | length' "$PJ")
    NF=$(jq '(.findings // []) | length' "$PJ")
    echo "| $US | ${SUM:0:60} | $NP | $NF |"
  done
  echo ""
  echo "## Detalhes por US"
  for US in $US_IDS; do
    echo ""
    echo "### $US"
    [ -f "$OUT_DIR/$US/report.md" ] && cat "$OUT_DIR/$US/report.md"
  done
} > "$OUT_DIR/report.md"

# Diff agregado
{
  for US in $US_IDS; do
    [ -f "$OUT_DIR/$US/proposed.diff" ] || continue
    echo "## $US"
    cat "$OUT_DIR/$US/proposed.diff"
    echo ""
  done
} > "$OUT_DIR/proposed.diff"

# JSON agregado
jq -n --arg pr "$PR_NUM" --arg ts "$TS" '{pr: $pr, generated_at: $ts, per_us: {}}' > "$OUT_DIR/proposal.json"
for US in $US_IDS; do
  PJ="$OUT_DIR/$US/proposal.json"
  [ -f "$PJ" ] || continue
  TMP="$OUT_DIR/proposal.json.tmp"
  jq --arg us "$US" --slurpfile child <(cat "$PJ") '.per_us[$us] = $child[0]' "$OUT_DIR/proposal.json" > "$TMP" && mv "$TMP" "$OUT_DIR/proposal.json"
done
```

**Sub-step 5 — Logging em reminders.jsonl (anti-fadiga, AC10 do US-01 da PR anterior):**

```bash
jq -nc --arg pr "$PR_NUM" --arg ts "$TS" --arg repo "$REPO" --arg out "$OUT_DIR" \
   '{kind:"learn", pr:$pr, repo:$repo, created_at:$ts, out_dir:$out}' \
   >> ~/.claude/cache/reflect/reminders.jsonl
```

**Sub-step 6 — Reporta ao usuário:**

```
Modo --learn concluído.
Outputs em: $OUT_DIR
- report.md: <N> US analisadas
- proposed.diff: agregado (revise com `git apply --check $OUT_DIR/proposed.diff`)
- proposal.json: jq-parseable
- gc: <N> proposal(s) > 90d removidos
```

**Restrições do modo `--learn`:**
- NÃO aplica o diff — humano revisa com `git apply --check` e decide.
- NÃO commita arquivos.
- NÃO escreve em `docs/definition_of_done.md` ou `skills/auto-grill-me/references/DOD.md` diretamente — apenas em `~/.claude/cache/reflect/proposals/<ts>-<slug>/`.
- Custo recorrente: cada US consome quota da subscription Claude Code; volume baixo esperado (1-3 USs por `/full-cycle`).

## Etapa 3 — Persistir relatório

Estrutura mínima do relatório `.md`:

```markdown
# Reflect — PR #<N>: <título> (modo: <baseline|retro|failure-<N>>)

**Gerado em:** <ts>
**Merged at:** <merged_at>
**Plan match:** <marker|slug-exact|fuzzy|none>
**Session correlated:** <true|false>
**Quick mode:** <true|false>

## Resumo
<1-3 linhas>

## Findings (deduplicados)
| # | Camada(s) | Commit SHA | Subject | Path tocado |
|---|-----------|------------|---------|-------------|
| 1 | #2,#3     | abc1234    | fix: ...| src/foo.ts  |

## Camadas executadas
- Camada #1 (decisions.jsonl): <ativa|inativa — motivo>
- Camada #2 (git log paths): N findings
- Camada #3 (CC strict): N findings
- Camada #4 (prefix livre): N findings
- Camada #5 (palavras-chave): N findings
- Camada #6 (PR comments): N findings | pulada (--quick)

## DoD aplicada vs CI checks (modo baseline)
<comparação>

## DoD usage (derivado via fold — modo retro)
<saída de `bin/lib/usage-fold.sh --prefix dod`: usos/desde_rev/last_seen por dod_id; vazio se sem log>

## Critérios DoD faltantes (modo on-failure)
<lista>

## Diff atomic proposto
- Path: ~/.claude/cache/reflect/proposals/<ts>.diff
- Regra de extração: bullets `- <x>` no canônico → `- [ ] <x>` no lean, agrupamento preservado.
- Gate humano: <aplicado|n/a>; <aprovado|recusado|n/a>

## GC
- gc: <N> diff(s) > 90d removidos

## Próximos passos
<sugestões — ex: aplique diff via `git apply ~/.claude/cache/reflect/proposals/<ts>.diff && /commit-push-pr "docs(dod): ..."`>
```

## Etapa 4 — Reportar ao usuário

Após gravar relatório (e eventualmente diff), imprima no chat:

```
Relatório: <REPORT path>
Diff proposto: <path ou "(nenhum)">
Findings: N (dedup) | M (brutos)
Camadas ativas: N/6
```

## Notas operacionais

- **AC16 (calibragem threshold camada 1):** o limiar `score_final >= 53` é heurístico — recalibrar após 10+ execuções (FATIA-2). Documentado aqui para que o agente futuro não trate como número mágico.
- **AC17 (tracking):** baselines pendentes ficam em `~/.claude/cache/reflect/reminders.jsonl`. O `/morning` consulta esse arquivo e exibe `N baselines aguardando retro (mais antiga: D+X)`. Usuário NÃO precisa lembrar manualmente.
- **AC18 (fallback `.claude/`):** quando cwd não tem `.claude/`, o relatório vai para `~/.claude/cache/reflect/<repo>/`. Detectado pela checagem `test -d .claude` (vide bloco canônico em Etapa 1 — Path de saída, linha 86–90). O subdiretório `.claude/reflections/` é criado on-demand quando `.claude/` existe mas o subdir ainda não.
- **AC19 (auto-tagging):** após aplicação do diff e `/commit-push-pr "docs(dod): ..."`, o subject pattern em AC12 (`^docs\(dod\)`) faz a próxima `/reflect` excluir esse commit automaticamente — sem loop de auto-reflexão.

## Restrições

- **NÃO** comite arquivos. Apenas gera relatório + diff em paths de cache.
- **NÃO** aplica o diff — usuário decide com `git apply` + `/commit-push-pr`.
- **NÃO** pula `--context-file`/`--from-stdin` em `--on-failure` — sem contexto, modo aborta com mensagem clara.
- **NÃO** roda push, commit, force-push, ou qualquer escrita em refs git.
- Em `--baseline`, sempre append em `reminders.jsonl` (mesmo se plano não correlacionou — registra `plan_matched: false`).

## Smoke tests versionados

Execute estes checks antes de tratar o `/reflect` como production-ready (cumpre US-01.AC15 + endereça finding P1 TESTING do Codex Iter 2). Cada bloco é auto-contido.

### S1 — Parsing `reminders.jsonl` (cobre AC10)

```bash
# fixture: 3 entradas válidas + 1 corrompida
F=/tmp/reflect-smoke-reminders.jsonl
cat > "$F" <<'EOF'
{"pr":"20","repo":"dotclaude","created_at":"2026-05-17T23:00:00Z","retro_due_at":"2026-05-24T23:00:00Z"}
{"pr":"21","repo":"dotclaude","created_at":"2026-05-16T10:00:00Z","retro_due_at":"2026-05-23T10:00:00Z"}
{"pr":"22","repo":"storefront","created_at":"2026-05-15T12:00:00Z","retro_due_at":"2026-05-22T12:00:00Z"}
not-json-line-should-skip
EOF

# count válidas + mais antiga (slurp APÓS filtrar inválidas — jq -rs falha em linha não-JSON)
jq -c '.' "$F" 2>/dev/null | wc -l   # esperado: 3
jq -c '.' "$F" 2>/dev/null | jq -rs 'sort_by(.created_at) | .[0] | .pr'   # esperado: 22
rm "$F"
```

### S2 — Fallback `.claude/` ausente (cobre AC18)

```bash
TMP=$(mktemp -d)
( cd "$TMP" && test -d .claude && echo "ERRO: TMP tem .claude/" || echo "OK: cwd sem .claude/, fallback dispara para \$HOME/.claude/cache/reflect/$(basename "$TMP")/" )
rm -rf "$TMP"
```

### S3 — Filtro temporal de PR comments (cobre Camada 6 — fix do Codex Iter 1 P0 CORRECTNESS)

```bash
MERGED=2026-05-17T20:00:00Z
F=/tmp/reflect-smoke-comments.json
cat > "$F" <<'EOF'
[
  {"created_at":"2026-05-17T19:00:00Z","body":"should have caught this earlier","user":{"login":"reviewer"}},
  {"created_at":"2026-05-17T21:00:00Z","body":"missed a bug in foo","user":{"login":"qa"}},
  {"created_at":"2026-05-17T22:00:00Z","body":"LGTM nice work","user":{"login":"dev"}}
]
EOF

# esperado: apenas 1 finding (o comment de 21:00 com "missed"/"bug")
jq --arg merged "$MERGED" '.[] | select(.created_at > $merged and (.body | test("missed|should have|bug|wrong|broken|regression"; "i"))) | .body' "$F"
# saída esperada: "missed a bug in foo"
rm "$F"
```

### S4 — Contadores DoD via fold, não inline (cobre AC4 do US-04)

```bash
# DOD.md SOURCE-PURO (sem sufixo inline) + log semeado → o fold deriva os contadores.
TMP=$(mktemp -d); export USAGE_LOG_HOME="$TMP/home"
DOD="$TMP/DOD.md"
printf '## Categoria 1 — X\n\n### Tarefa 7 — Foo\n\n- [ ] [b1] bar\n' > "$DOD"
SHA=$(bash -c "source bin/lib/usage-fold.sh; dod_bullets_sha '$DOD'" | awk -F'\t' '$1=="tarefa-7"{print $2}')
bash bin/lib/usage-log.sh baseline tarefa-7 --sha "$SHA" --count 2 >/dev/null
bash bin/lib/usage-log.sh use      tarefa-7 --sha "$SHA"           >/dev/null
# esperado: tarefa-7 usos=3 desde_rev=1 (2 do baseline + 1 use; o use está no sha atual)
bash bin/lib/usage-fold.sh --prefix dod --dod-file "$DOD" | awk -F'\t' '{print $1,$2,$3}'
# saída esperada: tarefa-7 3 1
rm -rf "$TMP"; unset USAGE_LOG_HOME
```

Adicionar saída desses 4 blocos no commit message ou em PR description ao alterar este comando — evidência empírica de cobertura AC15.
