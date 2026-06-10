#!/usr/bin/env bash
# backlog-dispatch.sh — drena uma fila de backlog entre repos despachando
# ciclos /full-cycle-simple headless em slots livres do pool (US-07).
#
# SCHEMA DA FILA  (~/.claude/cache/backlog/<repo>.jsonl, append-only)
#   Mesmo pattern de reminders.jsonl: arquivo por repo, uma linha JSON por evento.
#   ITEM:    {"id","repo","kind":"plan"|"command","ref","created_at",
#             "human_gate":bool,"reason"}
#            - id:        chave estável usada para dedup por markers.
#            - kind/ref:  ref é o alvo do ciclo (path de plano OU slash command).
#                         A 1ª versão SEMPRE despacha /full-cycle-simple <ref>.
#            - human_gate: true ⇒ NUNCA despachado automaticamente (gate humano).
#   MARKER:  {"marker":"dispatched"|"done"|"failed","id","created_at","rc"}
#            Linhas com o campo `marker` são estado, não itens.
#
# ESTADO POR MARKERS (append-only, sem mutação in-place)
#   - dispatched: gravado ANTES de lançar o claude (visibilidade de in-flight).
#   - done:       rc==0 ⇒ ciclo concluiu (PR aberto). Item não re-despacha.
#   - failed:     rc!=0. >=3 markers failed ⇒ skip permanente (anti-loop).
#
# FLUXO PONTA-A-PONTA
#   1. Lock atômico (mkdir .dispatch.lock) — uma instância por vez.
#   2. Para cada <repo>.jsonl: seleciona itens sem human_gate, sem done, com
#      <3 failed (oldest-first por created_at).
#   3. Acha um slot livre no pool (<repo>-N): clean + na branch main + sem
#      dispatch ativo (um slot mid-ciclo está dirty ou fora de main, logo é
#      rejeitado pelo próprio check clean+main).
#   4. Lança `claude -p "<prompt>" --dangerously-skip-permissions` confinado por
#      timeout chain (timeout→gtimeout→aviso, idêntico a reflect-retro-due.sh).
#   5. RESSALVA R2 (bloqueante): o prompt instrui o ciclo a PARAR no PR aberto
#      SEM auto-merge — nada é integrado sem humano. O headless usa
#      --dangerously-skip-permissions; os hooks determinísticos (secret-scan e
#      supply-chain) permanecem como backstop fail-closed.
#   6. Grava marker done/failed e segue (non-blocking: falha de um item não
#      derruba os demais nem propaga exit != 0).
#
# QUANDO USAR
#   Invocado pelo bin/auto-morning.sh no login (non-blocking, --max 2). Também
#   rodável à mão: `bin/backlog-dispatch.sh --max 1 [--repo X] [--dry-run]`.
#
# SEAMS DE TESTE (env) — pattern de bin/reflect-retro-due.sh:
#   BD_CLAUDE        binário claude (default: command -v claude → ~/.local/bin)
#   BD_TIMEOUT       binário timeout
#   BD_BACKLOG_DIR   diretório da fila (default ~/.claude/cache/backlog)
#   BD_POOL_BASE     raiz dos slots do pool (default ~/Projects/checkouts)
#   BD_MAIN_BRANCH   branch considerada "livre" (default main)
#   BD_NOW           timestamp "agora" (formato 2026-06-10T12-00-00Z)

set -u

# ── seams / defaults ─────────────────────────────────────────────────────────
BACKLOG_DIR="${BD_BACKLOG_DIR:-$HOME/.claude/cache/backlog}"
POOL_BASE="${BD_POOL_BASE:-$HOME/Projects/checkouts}"
MAIN_BRANCH="${BD_MAIN_BRANCH:-main}"
NOW="${BD_NOW:-$(date -u +%Y-%m-%dT%H-%M-%SZ)}"
BACKLOG_TIMEOUT_SECS=3600

# timeout é GNU coreutils — macOS puro NÃO tem (brew instala gtimeout).
# Cadeia: BD_TIMEOUT → timeout → gtimeout → vazio (roda sem teto, com aviso).
if [ -n "${BD_TIMEOUT:-}" ]; then
  TIMEOUT_BIN="$BD_TIMEOUT"
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
else
  TIMEOUT_BIN=""
fi

# claude resolvido com fallback ~/.local/bin (shell ssh não-login: PATH básico).
if [ -n "${BD_CLAUDE:-}" ]; then
  CLAUDE="$BD_CLAUDE"
elif command -v claude >/dev/null 2>&1; then
  CLAUDE="$(command -v claude)"
elif [ -x "$HOME/.local/bin/claude" ]; then
  CLAUDE="$HOME/.local/bin/claude"
else
  CLAUDE="claude"
fi

# ── usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Uso: backlog-dispatch.sh [--max N] [--repo X] [--dry-run] [--help]

Drena a fila de backlog (~/.claude/cache/backlog/<repo>.jsonl) despachando
ciclos /full-cycle-simple headless em slots livres do pool. PARA no PR aberto
SEM auto-merge — nada é integrado sem humano.

  --max N     no máximo N dispatches por run (default 2; 1..999).
  --repo X    limita à fila X.jsonl (default: todas as filas).
  --dry-run   imprime o plano de dispatch (item→slot) sem efeitos colaterais.
  --help      esta ajuda.

Seleção: itens sem human_gate, sem marker done, com <3 markers failed.
Slot:    <repo>-N no pool, clean + na branch main + sem dispatch ativo.
EOF
}

die_usage() { usage >&2; exit 2; }

# ── parse args ───────────────────────────────────────────────────────────────
MAX=2
REPO_FILTER=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1 ;;
    --max)
      shift
      [ $# -gt 0 ] || die_usage
      MAX_ARG="$1"
      # Valida FORMA e COMPRIMENTO antes de qualquer aritmética: um número
      # gigante estouraria `[ N -lt M ]` (rc=2) e viraria caminho feliz num ||.
      case "$MAX_ARG" in
        ''|*[!0-9]*) die_usage ;;
      esac
      [ "${#MAX_ARG}" -gt 3 ] && die_usage
      [ "$MAX_ARG" -ge 1 ] || die_usage
      MAX="$MAX_ARG"
      ;;
    --repo)
      shift
      [ $# -gt 0 ] || die_usage
      # nome de fila: sem barras (evita traversal); basename defensivo.
      case "$1" in */*) die_usage ;; esac
      REPO_FILTER="$1"
      ;;
    *) die_usage ;;
  esac
  shift
done

# ── helpers ──────────────────────────────────────────────────────────────────
# Emite só linhas JSON válidas (linhas corrompidas viram no-op).
clean_jsonl() { # <file>
  local line
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    printf '%s\n' "$line" | jq -c '.' 2>/dev/null || true
  done < "$1"
}

# Append de marker (jq-parseable) na fila do repo.
append_marker() { # <qfile> <marker> <id> <rc>
  jq -cn --arg marker "$2" --arg id "$3" --arg created_at "$NOW" --argjson rc "$4" \
    '{marker:$marker,id:$id,created_at:$created_at,rc:$rc}' >> "$1"
}

# Seleção: status\tid\tref por item (oldest-first por created_at).
# status ∈ {eligible, human-gate, skip-done, skip-permanent}
select_items() { # <qfile>
  clean_jsonl "$1" | jq -rs '
    . as $all
    | [ $all[] | select(.marker=="done") | .id ] as $done
    | ( reduce ($all[] | select(.marker=="failed") | .id) as $i ({}; .[$i] += 1) ) as $failed
    | [ $all[]
        | select(.marker == null)
        | select(.id != null) ]
    | unique_by(.id)
    | map( .id as $iid | ($failed[$iid] // 0) as $f
           | { id, ref:(.ref // ""), created_at:(.created_at // ""),
               status:(
                 if (.human_gate == true) then "human-gate"
                 elif ($done | index($iid)) then "skip-done"
                 elif ($f >= 3) then "skip-permanent"
                 else "eligible" end) } )
    | sort_by(.created_at, .id)
    | .[] | [.status, .id, .ref] | @tsv
  '
}

# Acha um slot livre p/ o repo: clean + na branch main + ainda não usado neste
# run. Ecoa o path e retorna 0; sem candidato → 1. USED_SLOTS é global.
find_free_slot() { # <repo>
  local repo="$1" slot name branch dirty
  for slot in "$POOL_BASE/$repo"-*; do
    [ -d "$slot" ] || continue
    case " $USED_SLOTS " in *" $slot "*) continue ;; esac
    git -C "$slot" rev-parse --git-dir >/dev/null 2>&1 || continue
    branch="$(git -C "$slot" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    [ "$branch" = "$MAIN_BRANCH" ] || continue
    dirty="$(git -C "$slot" status --porcelain 2>/dev/null | head -1)"
    [ -z "$dirty" ] || continue
    printf '%s' "$slot"
    return 0
  done
  return 1
}

# Constrói o prompt do ciclo. RESSALVA R2: instrui PARAR no PR sem integrar.
# CRÍTICO: nunca emitir a string literal "gh pr merge" (o backlog NÃO mergeia).
build_prompt() { # <ref>
  cat <<EOF
Execute /full-cycle-simple para o item de backlog: $1

RESSALVA BLOQUEANTE: PARE assim que o Pull Request for aberto. NÃO faça merge e
NÃO habilite auto-merge — nenhuma integração acontece sem revisão humana. Deixe
o PR aberto aguardando review. Os hooks determinísticos (secret-scan e
supply-chain) seguem ativos como backstop.
EOF
}

# ── lock atômico + descoberta de filas (após validar args; pula em dry-run) ──
LOCK="$BACKLOG_DIR/.dispatch.lock"
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$BACKLOG_DIR"
  if ! mkdir "$LOCK" 2>/dev/null; then
    echo "outra instância de backlog-dispatch em andamento ($LOCK) — saindo sem despachar."
    exit 0
  fi
  # Remove o lock ao final mesmo em erro. Set SÓ após adquirir (a 2ª instância
  # nunca remove o lock da 1ª).
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
fi

if [ ! -d "$BACKLOG_DIR" ]; then
  echo "fila inexistente ($BACKLOG_DIR) — nada a despachar."
  exit 0
fi

QUEUES=()
if [ -n "$REPO_FILTER" ]; then
  [ -f "$BACKLOG_DIR/$REPO_FILTER.jsonl" ] && QUEUES+=("$BACKLOG_DIR/$REPO_FILTER.jsonl")
else
  for qf in "$BACKLOG_DIR"/*.jsonl; do
    [ -f "$qf" ] && QUEUES+=("$qf")
  done
fi

if [ "${#QUEUES[@]}" -eq 0 ]; then
  echo "nada na fila — nenhum item de backlog a despachar."
  exit 0
fi

# ── loop de dispatch ─────────────────────────────────────────────────────────
USED_SLOTS=""
count=0
HUMAN_GATE_REPORT=""
echo "═══ backlog-dispatch (max=$MAX${REPO_FILTER:+ repo=$REPO_FILTER}${DRY_RUN:+}$([ "$DRY_RUN" -eq 1 ] && echo ' dry-run')) ═══"

for qf in "${QUEUES[@]}"; do
  repo="$(basename "$qf" .jsonl)"
  while IFS=$'\t' read -r status id ref; do
    [ -n "$id" ] || continue
    case "$status" in
      human-gate)
        HUMAN_GATE_REPORT="${HUMAN_GATE_REPORT}
  - $id ($repo): $ref"
        continue ;;
      skip-done)
        echo "skip (done): $id ($repo) — já concluído, não re-despacha."
        continue ;;
      skip-permanent)
        echo "skip permanente: $id ($repo) — >=3 markers failed, não re-tenta."
        continue ;;
      eligible) ;;
      *) continue ;;
    esac

    if [ "$count" -ge "$MAX" ]; then
      echo "cap atingido (--max $MAX): $id ($repo) adiado."
      continue
    fi

    if ! slot="$(find_free_slot "$repo")"; then
      echo "sem slot livre para $repo: $id adiado (nenhum slot clean+$MAIN_BRANCH disponível)."
      continue
    fi
    USED_SLOTS="$USED_SLOTS $slot"
    count=$((count+1))

    if [ "$DRY_RUN" -eq 1 ]; then
      echo "dry-run: $id ($repo) → $slot  [/full-cycle-simple $ref]"
      continue
    fi

    echo "dispatch: $id ($repo) → $slot"
    append_marker "$qf" "dispatched" "$id" 0
    PROMPT="$(build_prompt "$ref")"
    if [ -n "$TIMEOUT_BIN" ]; then
      ( cd "$slot" && "$TIMEOUT_BIN" "$BACKLOG_TIMEOUT_SECS" "$CLAUDE" \
          -p "$PROMPT" --dangerously-skip-permissions )
      rc=$?
    else
      echo "  AVISO: timeout/gtimeout ausentes — rodando sem teto de ${BACKLOG_TIMEOUT_SECS}s." >&2
      ( cd "$slot" && "$CLAUDE" -p "$PROMPT" --dangerously-skip-permissions )
      rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
      append_marker "$qf" "done" "$id" 0
      echo "  → done ($id) — PR aberto aguardando review."
    else
      append_marker "$qf" "failed" "$id" "$rc"
      echo "  → failed rc=$rc ($id) — segue para o próximo (non-blocking)."
    fi
  done <<EOF
$(select_items "$qf")
EOF
done

if [ -n "$HUMAN_GATE_REPORT" ]; then
  echo ""
  echo "── human-gate (NÃO despachados — exigem decisão humana) ──$HUMAN_GATE_REPORT"
fi

exit 0
