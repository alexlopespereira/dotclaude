# Fase 1 — Matriz de Exit Codes (US-08 / F8h)

> **Status:** BLOQUEADOR para US-09 / F8. F8 só pode aplicar `set -euo pipefail`
> em `run_parallel` depois que este catálogo estiver aprovado e a sentinela
> (`tests/lib/test_set_e_sentinel.sh`) verde.

## Contexto

- **Decisão #13 (rev5b R25):** `set -euo pipefail` é aplicado **somente dentro
  de `run_parallel()`** — nunca como diretiva global no topo do script. Razão:
  o caminho `run_serial` é o legado da Fase 1 e contém dezenas de comandos
  cujo exit non-zero é semanticamente válido (boolean tests). Aplicar `set -e`
  globalmente quebraria o caminho serial para todos os usuários da Fase 1.

- **Por que parallel-only e não global?** `run_parallel` é código novo escrito
  com o contrato `set -e` em mente: tem tratamento de erro explícito
  (`handle_failed_worker`, `finalize_review`), captura HEAD via `local var; var=$(cmd)`,
  e isola operações git em slots via `with_validated_slot`. `run_serial` foi
  escrito sem `set -e` em mente e usa idioms Bash 3 onde non-zero é boolean
  (`grep -q`, `git diff --quiet`, `kill -0`, condições em `while`/`until`).
  Reescrever `run_serial` para tolerar `set -e` é fora do escopo da Fase 2 e
  não traz benefício — ele já roda em produção há semanas.

- **rev5b R25 — escopo do catálogo:** todo comando do *caminho* `run_serial`
  (corpo da função + helpers que ela chama) cujo exit non-zero é esperado.
  Cada entrada é classificada pelo impacto que `set -e` global teria:
  - **(a)** Já está em `if` / `&&` / `||` / `while` / `until` / com `|| true`
    → `set -e` não afeta, comando continua válido sem alteração.
  - **(b)** Pipeline simples (`a | b | c`) onde algum elemento intermediário
    pode retornar non-zero → adicionar `|| true` no fim do pipeline.
  - **(c)** Captura `var=$(cmd)` ou `local var=$(cmd)` onde `cmd` pode falhar
    legitimamente → refatorar para `local var; var=$(cmd)` (separar declaração
    de atribuição) **com `|| true`** quando o valor vazio for aceitável, ou
    redirecionar via `if cmd > tmp; then var=$(cat tmp); fi` quando não.

  > A armadilha clássica de Bash 3 é `local var=$(cmd)`: o exit code de `cmd`
  > é mascarado pelo sucesso de `local`, então `set -e` **não** dispara.
  > A forma `local var; var=$(cmd)` expõe o exit code de `cmd` ao shell e
  > permite que `set -e` ou `|| true` decidam o destino. Toda captura
  > listada aqui foi auditada nesse ângulo.

## Caminho `run_serial` — corpo (linhas 369-558 de `ralph-adversarial.sh`)

| Linha | Comando (resumo) | Semântica de non-zero | Decisão | Mitigação proposta para F8 |
|---|---|---|---|---|
| 370 | `while [ $ITERATION -lt $MAX_ITERATIONS ]; do` | condição de loop | (a) | nenhuma — `while` neutraliza `set -e` |
| 374 | `PENDING=$(jq '...' prd.json)` | jq raramente falha; mas se falhar é fatal | (c) | `local pending; pending=$(jq …)` *(promovido para `local` se F8 mexer)* |
| 375 | `if [ "$PENDING" -eq 0 ]; then` | comparação aritmética em if | (a) | nenhuma |
| 385 | `STORY_ID=$(jq -r '… .[0].id' prd.json)` | jq retorna `null` se vazio | (c) | mesma de 374 |
| 386 | `STORY_TITLE=$(jq -r --arg id … '.title' prd.json)` | idem | (c) | mesma de 374 |
| 394 | `CURRENT_RETRIES=$(get_retry_count "$STORY_ID")` | função inclui `grep` que pode no-match | (c) | helper `get_retry_count` já encapsula `\|\| true` no pipeline interno (ver linha 353) — chamada externa segura |
| 395 | `if [ "$CURRENT_RETRIES" -ge "$MAX_RETRIES_PER_STORY" ]; then` | comparação | (a) | nenhuma |
| 400 | `jq … > prd.tmp && mv prd.tmp prd.json` | encadeado por `&&` | (a) | nenhuma — `&&` já gates a falha do jq |
| 413 | `STORY_BLOCK=$(jq -r --arg id … 'select(.id == $id)')` | jq pode retornar vazio | (c) | mesma de 374 |
| 414 | `CLAUDE_PROMPT=$(printf '...' "$(cat "$IMPL_PROMPT_FILE")")` | `cat` falha se arquivo ausente | (c) | aceitar — pré-flight (linha 282) já valida |
| 418 | `HEAD_BEFORE=$(git rev-parse HEAD 2>/dev/null \|\| echo none)` | repo sem HEAD retorna 128 | (a) | já mitigado com `\|\| echo none` |
| 419 | `LOGFILE=$(mktemp -t ralph-iter.XXXXXX)` | mktemp falha se TMPDIR ro | (c) | substituir por `mktemp_safe file ralph-iter` (igual a `dispatch_one`) — já é a recomendação rev5b R28 |
| 423 | `if wait_with_timeout "$AGENT_PID" "$TIMEOUT"; then` | função retorna 1 em hang | (a) | nenhuma — em `if` |
| 425 | `tail -20 "$LOGFILE" \|\| true` | `tail` falha se arquivo sumiu | (a) | já mitigado |
| 430 | `kill_agent_pg "$AGENT_PID"` | função interna usa `\|\| true` | (a) | nenhuma — função autocontida |
| 431 | `tail -20 "$LOGFILE" 2>/dev/null \|\| true` | idem 425 | (a) | já mitigado |
| 437 | `HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null \|\| echo none)` | idem 418 | (a) | já mitigado |
| 438 | `LAST_MSG_AFTER_KILL=$(git log -1 --format=%s 2>/dev/null \|\| echo "")` | git log falha em repo vazio | (a) | já mitigado |
| 439 | `if [ "$HEAD_AFTER" != "$HEAD_BEFORE" ] && [[ "$LAST_MSG_AFTER_KILL" == *"$STORY_ID"* ]]; then` | composição de testes | (a) | nenhuma |
| 445 | `if [ -n "$(git status --porcelain 2>/dev/null)" ]; then` | inner `$(...)` em `[ -n ]` | (a) | nenhuma — em `if` |
| 446 | `git stash push -u -m "..." >/dev/null 2>&1 \|\| true` | stash falha se nada a salvar | (a) | já mitigado |
| 453 | `set_retry_count …` | função usa `\|\| true` interno | (a) | nenhuma |
| 459 | `LAST_COMMIT=$(git log -1 --format="%H" 2>/dev/null)` | repo sem HEAD retorna 128 | **(c)** | `local last_commit; last_commit=$(git log -1 --format=%H 2>/dev/null \|\| echo "")` — sem `\|\| echo` o `set -e` aborta a iteração antes do check de FALHA_COMMIT |
| 460 | `LAST_MSG=$(git log -1 --format="%s" 2>/dev/null)` | idem | **(c)** | `local last_msg; last_msg=$(git log -1 --format=%s 2>/dev/null \|\| echo "")` |
| 462 | `if [[ "$LAST_MSG" != *"$STORY_ID"* ]]; then` | glob match em if | (a) | nenhuma |
| 481 | `REVIEW_RESULT=$("$RALPH_REVIEWER_BIN" "..." 2>&1)` dentro de `set +e` | manualmente desabilitado | (a) | manter `set +e/set -e` envolvendo a captura |
| 484 | `REVIEWER_EXIT=$?` | leitura de status | (a) | nenhuma |
| 495 | `REVIEW_RESULT=$(review_with_claude_sonnet …)` | função tem `\|\| printf` interno | (a) | nenhuma — função sempre exit 0 |
| 505 | `REVIEW_RESULT=$(codex exec review … 2>&1)` dentro de `set +e` | manualmente desabilitado | (a) | manter `set +e/-e` |
| 509 | `if is_codex_quota_error "$REVIEW_RESULT"; then` | função em if | (a) | nenhuma |
| 514 | `REVIEW_RESULT=$(review_with_claude_sonnet …)` | função sempre exit 0 | (a) | nenhuma |
| 516 | `REVIEW_RESULT=$(printf '%s\n%s\n' …)` | printf exit 0 | (a) | nenhuma |
| 520 | `echo "$REVIEW_RESULT" \| tail -30` | tail exit 0; pipefail OK | (a) | nenhuma — pipefail só dispara se houver non-zero, não é o caso |
| 523 | `mkdir -p .claude/research 2>/dev/null \|\| true` | (a) | nenhuma — já mitigado |
| 524 | `echo "$REVIEW_RESULT" > "..." 2>/dev/null \|\| true` | (a) | nenhuma — já mitigado |
| 528 | `VERDICT=$(parse_verdict "$REVIEW_RESULT")` | função sempre exit 0 (echo no fim) | (a) | nenhuma |
| 535 | `jq … > prd.tmp && mv prd.tmp prd.json` | (a) | nenhuma |
| 536 | `git add prd.json` | git add falha em índice quebrado | (c) | aceitar — falha aqui é fatal, set -e abortar é correto |
| 537 | `git commit -m "..." --allow-empty` | falha em hook ou índice ruim | (c) | aceitar — mesmo critério de 536 |
| 538 | `set_retry_count "$STORY_ID" 0` | helper safe | (a) | nenhuma |
| 542 | `echo "..." \| grep -o '"evidence":[^,]*' \| head -3 >> progress.txt` | grep no-match retorna 1; com pipefail dispara | **(b)** | adicionar `\|\| true` no fim: `… \| head -3 >> progress.txt \|\| true` |

## Caminho `run_serial` — helpers chamados (lib do mesmo arquivo)

### `wait_with_timeout` (linhas 101-116)

| Linha | Comando | Semântica | Decisão | Mitigação |
|---|---|---|---|---|
| 105 | `start_ts=$(date +%s)` | date sempre exit 0 | (a) | nenhuma |
| 106 | `while kill -0 "$pid" 2>/dev/null; do` | kill -0 retorna 1 quando pid morreu — **é o sinal de saída do loop** | (a) | nenhuma — `while` em torno de `kill -0` é idiom canônico para polling-by-kill-0 |
| 108 | `now=$(date +%s)` | date sempre exit 0 | (a) | nenhuma |
| 109 | `if [ $((now - start_ts)) -gt "$timeout" ]; then` | aritmética em if | (a) | nenhuma |
| 114 | `wait "$pid" 2>/dev/null \|\| true` | `wait` falha se pid já reapeado | (a) | já mitigado |

### `kill_agent_pg` (linhas 119-138)

| Linha | Comando | Semântica | Decisão | Mitigação |
|---|---|---|---|---|
| 122 | `pgid=$(ps -o pgid= -p "$pid" 2>/dev/null \| tr -d ' ')` | ps falha se pid já morto; com pipefail dispara | **(b)** | acrescentar `\|\| true` no fim ou ler em duas etapas: `local raw; raw=$(ps -o pgid= -p "$pid" 2>/dev/null \|\| true); pgid=$(printf '%s' "$raw" \| tr -d ' ')` |
| 123 | `if [ -z "$pgid" ]; then` | teste em if | (a) | nenhuma |
| 127 | `if [ "$pgid" != "$pid" ]; then` | teste em if | (a) | nenhuma |
| 129 | `kill -TERM "$pid" 2>/dev/null \|\| true` | kill no-op se pid morto | (a) | já mitigado |
| 131 | `kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null \|\| true` | composição `&&`+`\|\|` | (a) | já mitigado |
| 133 | `kill -TERM -- "-$pgid" 2>/dev/null \|\| true` | (a) | já mitigado |
| 135 | `kill -0 "$pid" 2>/dev/null && kill -KILL -- "-$pgid" 2>/dev/null \|\| true` | (a) | já mitigado |
| 137 | `wait "$pid" 2>/dev/null \|\| true` | (a) | já mitigado |

### `get_retry_count` / `set_retry_count` (linhas 350-363, compartilhados serial+parallel)

| Linha | Comando | Semântica | Decisão | Mitigação |
|---|---|---|---|---|
| 353 | `count=$(grep "^${story_id}:" "$RETRY_FILE" 2>/dev/null \| tail -1 \| cut -d: -f2)` | grep no-match retorna 1; pipeline com pipefail dispara | **(b)** | acrescentar `\|\| true` no fim do pipeline: `count=$(grep … 2>/dev/null \| tail -1 \| cut -d: -f2 \|\| true)` |
| 354 | `echo "${count:-0}"` | echo exit 0 | (a) | nenhuma |
| 360 | `grep -v "^${story_id}:" "$RETRY_FILE" > "${RETRY_FILE}.tmp" 2>/dev/null \|\| true` | (a) | já mitigado |

### `launch_agent_pgrouped` (linhas 77-97)

| Linha | Comando | Semântica | Decisão | Mitigação |
|---|---|---|---|---|
| 83/90/93 | `… "${SETSID_CMD[@]}" cmd … & AGENT_PID=$!` | comando lançado em background; `$!` sempre OK | (a) | nenhuma |

### `review_with_claude_sonnet` (linhas 233-272)

| Linha | Comando | Semântica | Decisão | Mitigação |
|---|---|---|---|---|
| 238 | `read -r -d '' header <<HEADER \|\| true` | `read -d ''` retorna 1 ao chegar em EOF — esperado | (a) | já mitigado |
| 251 | `read -r -d '' footer <<'FOOTER' \|\| true` | idem | (a) | já mitigado |
| 266 | `rubric=$(cat "$REVIEW_FILE")` | cat falha se arquivo ausente | (c) | aceitar — pré-flight (linha 282) já valida |
| 270 | `claude … "$prompt" 2>&1 \|\| printf '%s\n%s\n' '## Verdict: BLOCK' …` | claude falha → fallback printf | (a) | já mitigado |

## Caminho parallel-mode bootstrap (linhas 158-207, fora de função)

> Este bloco roda **antes** de `run_parallel`/`run_serial` quando `--parallel`
> é passado. Não é "caminho run_serial" stricto sensu, mas é tocado por
> testes de bootstrap (US-05) e precisa continuar verde. Inventariado para
> referência da F8.

| Linha | Comando | Decisão | Notas |
|---|---|---|---|
| 159 | `if ! POOL_INFO=$(parse_pool_from_pwd "$PWD" 2>/dev/null); then` | (a) | em if com `!` |
| 170 | `TOTAL_SLOTS=$(count_pool_slots …)` | (c) | função tem fallback ls — segura |
| 199 | `if ! preflight_slot "$slot_path"; then` | (a) | em if com `!` |

## Diretiva para US-09 / F8

1. F8 introduz `set -euo pipefail` **como primeira linha do corpo de
   `run_parallel()`** (linha imediatamente após o `{`), e em **nenhum outro
   lugar** do script. Verificação: `grep -n '^set -euo pipefail' ralph-adversarial.sh`
   deve retornar exatamente uma linha, e ela deve estar dentro de
   `run_parallel`.

2. F8 **não** mexe nas linhas listadas como (a) — `set -e` não as afeta.

3. F8 **deve** aplicar a mitigação proposta nas linhas marcadas (b) e (c)
   que são chamadas a partir de `run_parallel` (direta ou indiretamente):
   - linha 122 `pgid=$(ps … \| tr …)` — usado por `kill_agent_pg` chamado
     no trap `parallel_cleanup` e em `poll_workers_tick` quando hang detectado.
   - linha 353 `count=$(grep … \| tail \| cut)` — usado por `get_retry_count`
     chamado em `handle_failed_worker`.
   - linha 419 `LOGFILE=$(mktemp -t …)` — substituir por `mktemp_safe file …`
     se for tocado; runtime path do parallel já usa `mktemp_safe`.
   - As demais linhas (c) listadas (374, 385, 386, 413, 414, 459, 460) são
     **exclusivas do caminho `run_serial`** e **não** precisam de mitigação
     em F8 — `set -e` em `run_parallel` não as alcança.

4. Toda alteração de F8 deve preservar a sentinela
   `tests/lib/test_set_e_sentinel.sh` verde (AC4), o que valida que o
   caminho `run_serial` continua intocado.

## Auditoria — comandos especiais mencionados em AC1

> Atualização rápida de presença no caminho `run_serial`:

- `kill -0 $PID` → presente em `wait_with_timeout` (linha 106) e
  `kill_agent_pg` (linhas 131, 135). Todos em `while` ou em
  `&&`/`||` chains. Classe (a) — sem mitigação.
- `[ -f x ]` → não aparece dentro de `run_serial` (a checagem do
  `prd.json` na linha 276 está no setup global, não no caminho serial).
- `git diff --quiet` → não usado neste script. (Será introduzido por
  `merge_and_push_story` na US-09.)
- `grep -q` → não usado em `run_serial`. (`grep` aparece nas linhas 353
  e 542 sem `-q`; ambos com pipefail-relevância — listados acima.)
- comparações em `while`/`until` → linha 370 (`while [ $ITERATION … ]`)
  e 106 (`while kill -0 …`). Ambos classe (a).
