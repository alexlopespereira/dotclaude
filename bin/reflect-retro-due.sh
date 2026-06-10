#!/usr/bin/env bash
# reflect-retro-due.sh — drena retrospectivas /reflect vencidas, headless.
#
# O QUE FAZ
#   Lê ~/.claude/cache/reflect/reminders.jsonl, seleciona as retrospectivas
#   vencidas (baseline com retro_due_at <= agora) ainda não executadas, resolve
#   o checkout local correlato e roda `claude -p "/reflect <pr> --retro"`
#   headless e confinado (--allowedTools + timeout). Grava um marcador de
#   conclusão (retro_done) ou de falha (retro_attempt) no próprio arquivo.
#
# QUANDO USAR
#   Invocado pelo bin/auto-morning.sh no login (non-blocking). Também rodável à
#   mão para drenar a fila: `bin/reflect-retro-due.sh --max 1`.
#
# FLUXO PONTA-A-PONTA
#   - Pré-condição: reminders.jsonl existe e tem entradas baseline vencidas; o
#     repo de cada par repo+pr tem um checkout local resolvível (ver Resolução).
#   - Invocação canônica: `bin/reflect-retro-due.sh [--max N]` (default N=2).
#   - Encerra sozinho (exit 0) após processar até N retros; falha de uma retro
#     não interrompe as demais nem propaga exit != 0 (non-blocking).
#
# SELEÇÃO
#   Entradas com kind ausente OU kind=="baseline" (entradas antigas não têm o
#   campo), retro_due_at não-null e <= agora. Comparação lexicográfica é correta
#   porque o formato (2026-05-25T03-15-17Z, traços na hora) é posicional e
#   idêntico ao gerado por `date -u +%Y-%m-%dT%H-%M-%SZ`.
#
# DEDUP
#   - Par repo+pr com marcador kind=="retro_done" → pulado.
#   - Baselines duplicadas do mesmo par → consolidadas em UMA execução.
#   - Par com >=3 marcadores kind=="retro_attempt" → skip permanente (anti-loop).
#
# CAP
#   --max N (default 2): no máximo N execuções por run, as de retro_due_at mais
#   antigo primeiro. Skips (path não resolvido / permanente) NÃO consomem o cap.
#
# RESOLUÇÃO DE PATH (o campo `repo` é nome de SLOT)
#   ~/Projects/checkouts/<repo> → ~/Projects/<repo> → (strip do sufixo -N)
#   ~/Projects/checkouts/<base>-1 → ~/Projects/<base>. Sem match → skip logado
#   SEM marcador (re-tentável quando o clone existir).
#
# SEAMS DE TESTE (env) — pattern de bin/vm-provision.sh:
#   RRD_CLAUDE       binário claude (default: command -v claude → ~/.local/bin)
#   RRD_TIMEOUT      binário timeout
#   RRD_REMINDERS    path do reminders.jsonl
#   RRD_NOW          timestamp "agora" (formato 2026-05-25T03-15-17Z)
#   RRD_PROJECTS_DIR raiz dos checkouts (default ~/Projects)

set -u

# ── Seams / defaults ─────────────────────────────────────────────────────────
TIMEOUT_BIN="${RRD_TIMEOUT:-timeout}"
REMINDERS="${RRD_REMINDERS:-$HOME/.claude/cache/reflect/reminders.jsonl}"
PROJECTS_DIR="${RRD_PROJECTS_DIR:-$HOME/Projects}"
NOW="${RRD_NOW:-$(date -u +%Y-%m-%dT%H-%M-%SZ)}"
RETRO_TIMEOUT_SECS=900
ALLOWED_TOOLS="Bash(git:*),Bash(gh:*),Bash(mkdir:*),Read,Glob,Grep,Write,Edit"

# claude resolvido com fallback ~/.local/bin (shell ssh não-login tem PATH básico).
if [ -n "${RRD_CLAUDE:-}" ]; then
  CLAUDE="$RRD_CLAUDE"
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
Uso: reflect-retro-due.sh [--max N] [--help]

Drena retrospectivas /reflect vencidas (headless) do reminders.jsonl.

  --max N    no máximo N execuções por run (default 2; 1..999).
  --help     esta ajuda.

Seleção:   entradas kind ausente|baseline com retro_due_at <= agora.
Dedup:     pula pares repo+pr com retro_done; consolida baselines duplicadas;
           pula pares com >=3 retro_attempt (skip permanente).
Cap:       --max limita execuções por run (oldest-first).
Resolução: campo `repo` é nome de SLOT — cascata
           ~/Projects/checkouts/<repo> → ~/Projects/<repo> →
           ~/Projects/checkouts/<base>-1 → ~/Projects/<base>.
EOF
}

die_usage() { usage >&2; exit 2; }

# ── parse args ───────────────────────────────────────────────────────────────
MAX=2
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --max)
      shift
      [ $# -gt 0 ] || die_usage
      MAX_ARG="$1"
      # Valida FORMA e COMPRIMENTO antes de qualquer aritmética (cat-9 b4):
      # um número gigante estouraria `[ N -lt M ]` (rc=2) e poderia virar
      # caminho feliz numa cadeia ||.
      case "$MAX_ARG" in
        ''|*[!0-9]*) die_usage ;;
      esac
      [ "${#MAX_ARG}" -gt 3 ] && die_usage
      [ "$MAX_ARG" -ge 1 ] || die_usage
      MAX="$MAX_ARG"
      ;;
    *) die_usage ;;
  esac
  shift
done

# ── helpers ──────────────────────────────────────────────────────────────────
# Emite só linhas JSON válidas (linhas corrompidas viram no-op; jq por linha
# protege o slurp seguinte de abortar no arquivo inteiro).
clean_jsonl() {
  local line
  [ -f "$REMINDERS" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    printf '%s\n' "$line" | jq -c '.' 2>/dev/null || true
  done < "$REMINDERS"
}

# Resolve o checkout local de um slot. Ecoa o path e retorna 0; sem match → 1.
resolve_repo_path() {
  local repo="$1" base cand
  for cand in "$PROJECTS_DIR/checkouts/$repo" "$PROJECTS_DIR/$repo"; do
    [ -d "$cand" ] && { printf '%s' "$cand"; return 0; }
  done
  base="${repo%-[0-9]*}"
  if [ "$base" != "$repo" ]; then
    for cand in "$PROJECTS_DIR/checkouts/$base-1" "$PROJECTS_DIR/$base"; do
      [ -d "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
  fi
  return 1
}

# Append de marcador (jq-parseable) no reminders.jsonl.
append_marker() { # kind repo pr rc
  jq -cn --arg kind "$1" --arg repo "$2" --arg pr "$3" \
        --arg created_at "$NOW" --argjson rc "$4" \
        '{kind:$kind,pr:$pr,repo:$repo,created_at:$created_at,rc:$rc}' >> "$REMINDERS"
}

# ── seleção: due\trepo\tpr\tattempts (deduped, sem retro_done, oldest-first) ──
CANDS="$(clean_jsonl | jq -rs --arg now "$NOW" '
  . as $all
  | [ $all[] | select(.kind=="retro_done") | (.repo|tostring)+"|"+(.pr|tostring) ] as $done
  | ( reduce ($all[] | select(.kind=="retro_attempt") | (.repo|tostring)+"|"+(.pr|tostring)) as $k
        ({}; .[$k] += 1) ) as $att
  | [ $all[]
      | select((.kind==null) or (.kind=="baseline"))
      | select(.retro_due_at != null and .retro_due_at <= $now)
      | {repo:(.repo|tostring), pr:(.pr|tostring), due:.retro_due_at} ]
  | unique_by(.repo+"|"+.pr)
  | map(select( (.repo+"|"+.pr) as $k | ($done | index($k)) | not ))
  | sort_by(.due)
  | .[]
  | [.due, .repo, .pr, (($att[(.repo+"|"+.pr)]) // 0 | tostring)] | @tsv
')"

if [ -z "$CANDS" ]; then
  echo "nada vencido — nenhuma retrospectiva a executar."
  exit 0
fi

# ── loop de execução ─────────────────────────────────────────────────────────
count=0
while IFS=$'\t' read -r due repo pr att; do
  [ -n "$repo" ] || continue
  [ "$count" -ge "$MAX" ] && break

  if [ "$att" -ge 3 ]; then
    echo "skip permanente: $repo#$pr ($att tentativas falhas) — não re-tenta."
    continue
  fi

  if ! path="$(resolve_repo_path "$repo")"; then
    echo "skip (sem checkout local): $repo#$pr — nenhum candidato em $PROJECTS_DIR (sem marcador, re-tentável)."
    continue
  fi

  count=$((count+1))
  echo "retro: $repo#$pr (due $due) em $path"
  ( cd "$path" && "$TIMEOUT_BIN" "$RETRO_TIMEOUT_SECS" "$CLAUDE" \
      -p "/reflect $pr --retro" --allowedTools "$ALLOWED_TOOLS" )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    append_marker "retro_done" "$repo" "$pr" 0
    echo "  → retro_done ($repo#$pr)"
  else
    append_marker "retro_attempt" "$repo" "$pr" "$rc"
    echo "  → retro_attempt rc=$rc ($repo#$pr) — segue para o próximo (non-blocking)."
  fi
done <<EOF
$CANDS
EOF

exit 0
