#!/usr/bin/env bash
set -euo pipefail

# bin/dod-reset-rev.sh — utilitário do contador "desde rev" do DOD.md (US-04).
#
# Pós-migração (US-03) os contadores NÃO ficam mais inline no DOD.md — são
# DERIVADOS do log append-only via o fold (bin/lib/usage-fold.sh, US-02),
# content-based (por sha). Este script é um consumidor do fold:
#
#   dod-reset-rev.sh                          # --help curto, exit 0
#   dod-reset-rev.sh <dod_id>                 # "reset": emite 1 evento revision
#                                             # @ sha atual dos bullets do DoD
#   dod-reset-rev.sh --show [--sort=X]        # tabela derivada via fold
#                                             # sort: desde-rev (default) | usos | id
#   dod-reset-rev.sh --help | -h              # esta ajuda
#
# Seams de teste (mesma convenção de usage-log.sh/usage-fold.sh):
#   --dod-file F   sobrescreve o DOD.md alvo
#   --prefix P     namespace do log (default dod)
#   USAGE_LOG_HOME sobrescreve a base ~/.claude onde o log vive
#
# O subcomando --gc foi APOSENTADO (AC5): sem snapshot .json (removido US-03),
# não há entradas órfãs a coletar. O "reset" não edita mais contador inline nem
# escreve .json de estado — apenas faz append (lockless, O_APPEND atômico) de um
# evento `revision`; daí não há mais lock `mkdir`.
#
# Exit codes:
#   0 — sucesso
#   1 — uso inválido (flag desconhecida)
#   2 — dod-id desconhecido

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
REFERENCES_DIR="$SKILL_DIR/references"
DOD_FILE="$REFERENCES_DIR/DOD.md"
PREFIX="dod"

# Lib compartilhada (US-01/US-02): log_event + usage_fold + dod_bullets_sha.
# Mesmo layout relativo no repo e em ~/.claude (sync.sh instala bin/ e skills/
# lado a lado). ATENÇÃO: usage-fold.sh redefine SCRIPT_DIR ao ser sourceado —
# por isso DOD_FILE/SKILL_DIR já foram derivados ACIMA, antes do source.
# shellcheck source=bin/lib/usage-fold.sh
source "$SCRIPT_DIR/../../../bin/lib/usage-fold.sh"

show_help() {
  cat <<'EOF'
dod-reset-rev — utilitário do contador "desde rev" do DOD.md (derivado via fold)

uso:
  dod-reset-rev.sh <dod_id>                    "reset": emite evento revision @ sha atual
  dod-reset-rev.sh --show [--sort=X]           tabela derivada (sort: desde-rev|usos|id; default: desde-rev)
  dod-reset-rev.sh --help                      esta ajuda

seams: [--dod-file F] [--prefix P] (USAGE_LOG_HOME p/ a base do log)
dod_id: tarefa-N (ex: tarefa-5) ou cat-N-base (ex: cat-1-base)
EOF
}

# Emite linhas TSV: dod_id<TAB>title_current. A regex casa o heading SEM o sufixo
# `(usos: N · desde rev: N)` (removido na migração US-03); o sufixo é opcional
# (`( \(usos:…\))?`) só p/ backward-compat com arquivos pré-strip. Os contadores
# NÃO saem daqui — vêm do fold (AC1/AC3).
parse_headings() {
  awk '
    BEGIN { current_cat = "" }
    /^## Categoria [0-9]+ — / {
      s = $0
      sub(/^## Categoria /, "", s)
      sub(/ .*$/, "", s)
      current_cat = s
      next
    }
    /^### DoD-base — Categoria [0-9]+( \(usos: [0-9]+ · desde rev: [0-9]+\))?$/ {
      printf "cat-%s-base\tDoD-base — Categoria %s\n", current_cat, current_cat
      next
    }
    /^### Tarefa [0-9]+ — .+$/ {
      s = $0
      sub(/^### Tarefa /, "", s)
      sub(/ .*$/, "", s)
      tnum = s
      title = $0
      sub(/^### /, "", title)
      sub(/ \(usos: [0-9]+ · desde rev: [0-9]+\)$/, "", title)
      printf "tarefa-%s\t%s\n", tnum, title
      next
    }
  ' "$DOD_FILE"
}

# "reset" no mundo derivado (AC2): emite 1 evento `revision` carregando o sha
# ATUAL dos bullets do DoD (content-based, US-02). NÃO edita contador inline (não
# existe mais) nem snapshot (removido US-03). O append é lockless.
reset_dod() {
  local dod_id="$1"

  # Existência via heading (regex sem sufixo).
  if ! parse_headings | awk -F'\t' -v t="$dod_id" '$1 == t { found = 1 } END { exit !found }'; then
    echo "dod-id desconhecido: $dod_id" >&2
    exit 2
  fi

  # Captura todo o output ANTES de filtrar: um `exit` no awk fecharia o pipe e
  # daria SIGPIPE em dod_bullets_sha (fatal sob pipefail). Command-substitution
  # lê o stream inteiro → sem pipe a quebrar.
  local sha all_sha
  all_sha="$(dod_bullets_sha "$DOD_FILE")"
  sha="$(awk -F'\t' -v t="$dod_id" '$1 == t { print $2 }' <<< "$all_sha")"
  if [[ -z "$sha" ]]; then
    echo "erro: não foi possível derivar o sha dos bullets de $dod_id" >&2
    exit 1
  fi

  log_event revision "$dod_id" --prefix "$PREFIX" --sha "$sha"
  echo "reset: $dod_id — evento revision emitido @ sha=${sha:0:12}"
}

cmd_show() {
  local sort_key="desde-rev"
  if [[ $# -gt 0 ]]; then
    case "$1" in
      --sort=desde-rev) sort_key="desde-rev" ;;
      --sort=usos)      sort_key="usos" ;;
      --sort=id)        sort_key="id" ;;
      *) echo "uso: --show [--sort=desde-rev|usos|id]" >&2; exit 1 ;;
    esac
  fi

  # Contadores derivados via fold (US-02): TSV dod_id\tusos\tdesde_rev\tlast_seen.
  # Títulos vêm do heading (parse_headings). Left-join por dod_id: TODO heading
  # aparece; usos/desde_rev default 0 quando o dod_id não tem eventos no log
  # (tabela idêntica à pré-migração — AC1).
  local fold_tsv headings_tsv rows sorted
  fold_tsv="$(usage_fold --prefix "$PREFIX" --dod-file "$DOD_FILE")"
  headings_tsv="$(parse_headings)"

  rows="$(awk -F'\t' '
    NR == FNR { U[$1] = $2; R[$1] = $3; next }
    {
      id = $1; title = $2
      u = (id in U) ? U[id] : 0
      r = (id in R) ? R[id] : 0
      printf "%s\t%s\t%s\t%s\n", id, u, r, title
    }
  ' <(printf '%s\n' "$fold_tsv") <(printf '%s\n' "$headings_tsv"))"

  case "$sort_key" in
    desde-rev) sorted="$(printf '%s\n' "$rows" | sort -t$'\t' -k3,3 -n -r)" ;;
    usos)      sorted="$(printf '%s\n' "$rows" | sort -t$'\t' -k2,2 -n -r)" ;;
    id)        sorted="$(printf '%s\n' "$rows" | sort -t$'\t' -k1,1)" ;;
  esac

  # Header + linhas — formato: usos desde-rev dod_id title_current
  # `|| { ec=...; [[ ec==141 ]] || return ec; }`: tolera SIGPIPE (`... | head`)
  # sem suprimir falhas reais (set -e + pipefail transformariam exit 141 em erro).
  {
    printf '%s\n' "$sorted" | awk -F'\t' '
      BEGIN { printf "%-5s %-10s %-12s %s\n", "usos", "desde-rev", "dod_id", "title_current" }
      NF >= 4 { printf "%-5s %-10s %-12s %s\n", $2, $3, $1, $4 }
    '
  } || { local ec=$?; [[ "$ec" -eq 141 ]] || return "$ec"; }
}

# ── Pré-parse de seams (--dod-file/--prefix podem vir em qualquer posição) ────
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dod-file)   DOD_FILE="${2:-}"; shift 2 ;;
    --dod-file=*) DOD_FILE="${1#*=}"; shift ;;
    --prefix)     PREFIX="${2:-}"; shift 2 ;;
    --prefix=*)   PREFIX="${1#*=}"; shift ;;
    *)            ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

# Dispatch
if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

case "$1" in
  --help|-h) show_help; exit 0 ;;
  --show)    shift; cmd_show "$@" ;;
  --*)       echo "uso desconhecido: $1" >&2; show_help >&2; exit 1 ;;
  *)         reset_dod "$1" ;;
esac
