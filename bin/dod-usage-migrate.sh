#!/usr/bin/env bash
set -euo pipefail

# bin/dod-usage-migrate.sh — migra a telemetria DoD de contador-inline para o log
# append-only (US-03 / M6+M3+M7). Passo HARD-TO-REVERSE: o git é o backup.
#
# Ordem (deploy → migrar → strip): reconcilia → semeia → strip → remove snapshot.
#   1. reconcilia (AC3): max() dos contadores inline entre o repo, o install
#      acessível em $(_usage_log_home)/<rel> (~/.claude por default) e quaisquer
#      --reconcile-extra — para não perder deriva in-flight (correção adv. #4).
#   2. semeia (AC1): por DoD, 1 baseline {count: usos-desde_rev} + (desde_rev)
#      eventos `use` @ sha atual + 1 revision @ sha atual. O baseline carrega
#      count = usos - desde_rev (NÃO usos) porque o fold US-02 deriva desde_rev
#      use-only: para reproduzir desde_rev=M (AC5) é preciso M eventos `use` no
#      sha atual; o baseline cobre só o piso restante de usos. usos = (usos-M) +
#      M = usos; desde_rev = M. Equivalência exata (AC5).
#   3. strip (AC4): remove o sufixo ` (usos: N · desde rev: N)` dos headings —
#      source puro.
#   4. remove (AC6): apaga o snapshot .json.
#
# Idempotente (AC2): o baseline carrega "migrated_from":"inline"; se o log já tem
# um baseline com essa marca, a semeadura é pulada (rodar 2x não duplica). O
# strip e o rm são idempotentes por construção.
#
# Uso:
#   dod-usage-migrate.sh [--prefix dod|test-spec]
#                        [--dod-file F] [--state-file J] [--reconcile-extra F]...
#                        [--dry-run]
#
# Defaults por prefix (no repo):
#   dod       → skills/auto-grill-me/references/{DOD.md,.dod-revision-state.json}
#   test-spec → skills/testing/references/{TEST-PATTERNS.md,.test-spec-revision-state.json}
#
# Reusa as libs M1/M2 (não reimplementa writer/fold/hash): log_event,
# dod_bullets_sha, _usage_log_home vêm de bin/lib/usage-fold.sh (que sourceia
# usage-log.sh). Test seam USAGE_LOG_HOME controla onde o log é escrito E onde o
# install é procurado p/ reconcile — mantém os testes herméticos.
#
# bash 3.2 (macOS): sem `declare -A`; o reconcile/assemble roda em awk.
#
# Exit codes: 0 sucesso (inclui "já migrado"); 1 uso inválido.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/usage-fold.sh
source "$SCRIPT_DIR/lib/usage-fold.sh"

MIGRATED_FROM_MARK="inline"

PREFIX="dod"
DOD_FILE_OVERRIDE=""
STATE_FILE_OVERRIDE=""
DRY_RUN=0
RECONCILE_EXTRA=()

TMPD=""
cleanup() {
  if [ -n "$TMPD" ] && [ -d "$TMPD" ]; then rm -rf "$TMPD"; fi
}
trap cleanup EXIT

show_help() {
  cat <<'EOF'
dod-usage-migrate — semeia o log append-only a partir dos contadores inline,
                    depois remove o sufixo inline e apaga o snapshot .json.

uso:
  dod-usage-migrate.sh [--prefix dod|test-spec] [--dod-file F] [--state-file J]
                       [--reconcile-extra F]... [--dry-run]

ordem: reconcilia (max) → semeia (idempotente) → strip headings → rm snapshot.
EOF
}

# ── Contadores inline → TSV dod_id\tusos\tdesde_rev ──────────────────────────
# Reusa a awk canônica de dod-reset-rev.sh (exige o sufixo). Um arquivo já
# stripado emite zero linhas → não contribui para o max() do reconcile.
parse_inline_counters() {
  [ -f "$1" ] || return 0
  awk '
    BEGIN { current_cat = "" }
    /^## Categoria [0-9]+ — / {
      s = $0; sub(/^## Categoria /, "", s); sub(/ .*$/, "", s); current_cat = s; next
    }
    /^### DoD-base — Categoria [0-9]+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/ {
      match($0, /usos: [0-9]+/);      u = substr($0, RSTART + 6,  RLENGTH - 6)
      match($0, /desde rev: [0-9]+/); r = substr($0, RSTART + 11, RLENGTH - 11)
      printf "cat-%s-base\t%s\t%s\n", current_cat, u, r; next
    }
    /^### Tarefa [0-9]+ — .+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/ {
      s = $0; sub(/^### Tarefa /, "", s); sub(/ .*$/, "", s); tnum = s
      match($0, /usos: [0-9]+/);      u = substr($0, RSTART + 6,  RLENGTH - 6)
      match($0, /desde rev: [0-9]+/); r = substr($0, RSTART + 11, RLENGTH - 11)
      printf "tarefa-%s\t%s\t%s\n", tnum, u, r; next
    }
  ' "$1"
}

# Reconcile (AC3) — max() por campo via awk. Emite id\tusos\tdesde_rev.
reconcile_counters_tsv() {
  local f
  for f in "$@"; do
    if [ -n "$f" ]; then parse_inline_counters "$f"; fi
  done | awk -F'\t' '
    { u=$2+0; r=$3+0; if (u>U[$1]) U[$1]=u; if (r>R[$1]) R[$1]=r; seen[$1]=1 }
    END { for (k in seen) printf "%s\t%s\t%s\n", k, U[k], R[k] }
  '
}

# Reconcile last_seen (AC3 — o .json). Emite id\tlast_seen (max lexical ISO-8601).
reconcile_lastseen_tsv() {
  local j
  for j in "$@"; do
    if [ -n "$j" ] && [ -f "$j" ]; then
      jq -r 'to_entries[] | "\(.key)\t\(.value.last_seen_iso // "")"' "$j"
    fi
  done | awk -F'\t' '
    { if ($2!="" && $2>LS[$1]) LS[$1]=$2; seen[$1]=1 }
    END { for (k in seen) printf "%s\t%s\n", k, LS[k] }
  '
}

# Junta sha (autoritativo do repo) com os contadores reconciliados + last_seen.
# stdin: id\tsha (dod_bullets_sha). Emite id\tsha\tusos\trev\tlast_seen, com
# rev capado a usos (invariante desde_rev ⊆ usos).
assemble_plan() {
  awk -F'\t' -v cf="$TMPD/cnt.tsv" -v lf="$TMPD/ls.tsv" -v now="$NOW" '
    BEGIN {
      while ((getline ln < cf) > 0) { split(ln, a, "\t"); U[a[1]]=a[2]; R[a[1]]=a[3] }
      while ((getline ln < lf) > 0) { split(ln, b, "\t"); LS[b[1]]=b[2] }
    }
    {
      id=$1; sha=$2
      usos=(id in U)?U[id]+0:0
      rev=(id in R)?R[id]+0:0
      if (rev>usos) rev=usos
      ls=((id in LS) && LS[id]!="")?LS[id]:now
      printf "%s\t%s\t%s\t%s\t%s\n", id, sha, usos, rev, ls
    }
  '
}

# ── Strip do sufixo inline (AC4). Idempotente: sem sufixo → linha intacta. ────
strip_inline() {
  local file="$1" tmp
  [ -f "$file" ] || return 0
  tmp="$(mktemp "${file}.migrate.XXXXXX")"
  awk '
    /^### DoD-base — Categoria [0-9]+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/ {
      sub(/ \(usos: [0-9]+ · desde rev: [0-9]+\)$/, ""); print; next
    }
    /^### Tarefa [0-9]+ — .+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/ {
      sub(/ \(usos: [0-9]+ · desde rev: [0-9]+\)$/, ""); print; next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# ── Arg parse ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)            PREFIX="${2:-}"; shift 2 ;;
    --prefix=*)          PREFIX="${1#*=}"; shift ;;
    --dod-file)          DOD_FILE_OVERRIDE="${2:-}"; shift 2 ;;
    --dod-file=*)        DOD_FILE_OVERRIDE="${1#*=}"; shift ;;
    --state-file)        STATE_FILE_OVERRIDE="${2:-}"; shift 2 ;;
    --state-file=*)      STATE_FILE_OVERRIDE="${1#*=}"; shift ;;
    --reconcile-extra)   RECONCILE_EXTRA+=("${2:-}"); shift 2 ;;
    --reconcile-extra=*) RECONCILE_EXTRA+=("${1#*=}"); shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --help|-h)           show_help; exit 0 ;;
    *) echo "dod-usage-migrate: argumento desconhecido '$1'" >&2; exit 1 ;;
  esac
done

case "$PREFIX" in
  dod)       REL_DOD="skills/auto-grill-me/references/DOD.md"
             REL_STATE="skills/auto-grill-me/references/.dod-revision-state.json" ;;
  test-spec) REL_DOD="skills/testing/references/TEST-PATTERNS.md"
             REL_STATE="skills/testing/references/.test-spec-revision-state.json" ;;
  *) echo "dod-usage-migrate: --prefix inválido '$PREFIX' (dod|test-spec)" >&2; exit 1 ;;
esac

DOD_FILE="${DOD_FILE_OVERRIDE:-$_USAGE_FOLD_ROOT/$REL_DOD}"
STATE_FILE="${STATE_FILE_OVERRIDE:-$_USAGE_FOLD_ROOT/$REL_STATE}"
INSTALL_HOME="$(_usage_log_home)"
INSTALL_DOD="$INSTALL_HOME/$REL_DOD"
INSTALL_STATE="$INSTALL_HOME/$REL_STATE"

if [ ! -f "$DOD_FILE" ]; then
  echo "dod-usage-migrate: DOD file não encontrado: $DOD_FILE" >&2; exit 1
fi

# ── Idempotência (AC2): a marca migrated_from no log → já semeado. ───────────
MID="$(_usage_log_machine_id)"
LOGFILE="$INSTALL_HOME/telemetry/${PREFIX}-usage.${MID}.jsonl"
already_seeded() {
  [ -f "$LOGFILE" ] || return 1
  jq -e -s --arg m "$MIGRATED_FROM_MARK" \
    'any(.[]; .kind=="baseline" and .migrated_from==$m)' "$LOGFILE" >/dev/null 2>&1
}

# ── 1. Reconcile (AC3) → TSVs no TMPD ────────────────────────────────────────
TMPD="$(mktemp -d -t dod-migrate.XXXXXX)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

CNT_SOURCES=("$DOD_FILE")
if [ -f "$INSTALL_DOD" ] && [ "$INSTALL_DOD" != "$DOD_FILE" ]; then
  CNT_SOURCES+=("$INSTALL_DOD")
fi
if [ "${#RECONCILE_EXTRA[@]}" -gt 0 ]; then
  for extra in "${RECONCILE_EXTRA[@]}"; do
    if [ -n "$extra" ]; then CNT_SOURCES+=("$extra"); fi
  done
fi

LS_SOURCES=()
if [ -f "$STATE_FILE" ]; then LS_SOURCES+=("$STATE_FILE"); fi
if [ -f "$INSTALL_STATE" ] && [ "$INSTALL_STATE" != "$STATE_FILE" ]; then
  LS_SOURCES+=("$INSTALL_STATE")
fi

reconcile_counters_tsv "${CNT_SOURCES[@]}" > "$TMPD/cnt.tsv"
if [ "${#LS_SOURCES[@]}" -gt 0 ]; then
  reconcile_lastseen_tsv "${LS_SOURCES[@]}" > "$TMPD/ls.tsv"
else
  : > "$TMPD/ls.tsv"
fi

# Plano de semeadura (id\tsha\tusos\trev\tlast_seen) por DoD presente no repo.
PLAN="$(dod_bullets_sha "$DOD_FILE" | assemble_plan)"

# ── 2. Seed (AC1) / dry-run / idempotência (AC2) ─────────────────────────────
if already_seeded; then
  echo "migrate[$PREFIX]: log já semeado (migrated_from=$MIGRATED_FROM_MARK) — skip seed"
elif [ "$DRY_RUN" -eq 1 ]; then
  echo "migrate[$PREFIX] DRY-RUN — plano de semeadura (sem escrever):"
  while IFS=$'\t' read -r id sha usos rev ls; do
    [ -n "$id" ] || continue
    printf '  %-12s baseline{count:%s} + %s use + 1 revision  @sha=%.12s ts=%s\n' \
      "$id" "$(( usos - rev ))" "$rev" "$sha" "$ls"
  done <<< "$PLAN"
else
  seeded=0
  while IFS=$'\t' read -r id sha usos rev ls; do
    [ -n "$id" ] || continue
    log_event baseline "$id" --prefix "$PREFIX" --sha "$sha" \
      --count "$(( usos - rev ))" --migrated-from "$MIGRATED_FROM_MARK" --ts "$ls"
    i=0
    while (( i < rev )); do
      log_event use "$id" --prefix "$PREFIX" --sha "$sha" \
        --migrated-from "$MIGRATED_FROM_MARK" --ts "$ls"
      i=$(( i + 1 ))
    done
    log_event revision "$id" --prefix "$PREFIX" --sha "$sha" \
      --migrated-from "$MIGRATED_FROM_MARK" --ts "$ls"
    seeded=$(( seeded + 1 ))
  done <<< "$PLAN"
  echo "migrate[$PREFIX]: $seeded DoDs semeados → $LOGFILE"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "migrate[$PREFIX] DRY-RUN — strip de $DOD_FILE e rm de $STATE_FILE seriam aplicados."
  exit 0
fi

# ── 3. Strip inline (AC4) ────────────────────────────────────────────────────
strip_inline "$DOD_FILE"
echo "migrate[$PREFIX]: headings de $DOD_FILE sem sufixo inline (source puro)"

# ── 4. Remove snapshot (AC6) ─────────────────────────────────────────────────
if [ -f "$STATE_FILE" ]; then
  rm -f "$STATE_FILE"
  echo "migrate[$PREFIX]: snapshot removido: $STATE_FILE"
else
  echo "migrate[$PREFIX]: snapshot já ausente: $STATE_FILE"
fi
