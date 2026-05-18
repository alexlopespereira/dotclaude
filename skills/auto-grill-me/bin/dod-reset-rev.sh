#!/usr/bin/env bash
set -euo pipefail

# bin/dod-reset-rev.sh — utility for DOD.md "desde rev" counters (US-03).
#
# Comandos:
#   dod-reset-rev.sh                          # --help curto, exit 0
#   dod-reset-rev.sh <dod_id>                 # zera "desde rev" do <dod_id>
#                                             # + atualiza last_seen_iso no snapshot
#   dod-reset-rev.sh --show [--sort=X]        # tabela legível
#                                             # sort: desde-rev (default) | usos | id
#   dod-reset-rev.sh --gc                     # remove entries órfãs do snapshot
#   dod-reset-rev.sh --help | -h              # esta ajuda
#
# macOS-compatible: usa `mkdir <lockdir>` para serialização (fd-lock clássico
# do Linux não existe no Darwin).
#
# Exit codes:
#   0 — sucesso
#   1 — uso inválido (flag desconhecida)
#   2 — dod-id desconhecido
#   3 — lock ocupado após retry

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
REFERENCES_DIR="$SKILL_DIR/references"
DOD_FILE="$REFERENCES_DIR/DOD.md"
STATE_FILE="$REFERENCES_DIR/.dod-revision-state.json"
LOCK_DIR="$REFERENCES_DIR/.dod-reset.lock"

LOCK_HELD=0
TMP_FILE=""

cleanup() {
  [[ -n "$TMP_FILE" && -e "$TMP_FILE" ]] && rm -f "$TMP_FILE"
  # rmdir apenas se este processo realmente adquiriu o lock (evita race
  # com timeout: o `exit 3` apagaria o lockdir do dono real).
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

show_help() {
  cat <<'EOF'
dod-reset-rev — utilitário do contador "desde rev" do DOD.md

uso:
  dod-reset-rev.sh <dod_id>                    zera "desde rev" + atualiza last_seen_iso
  dod-reset-rev.sh --show [--sort=X]           tabela (sort: desde-rev|usos|id; default: desde-rev)
  dod-reset-rev.sh --gc                        remove entries órfãs do snapshot
  dod-reset-rev.sh --help                      esta ajuda

dod_id: tarefa-N (ex: tarefa-5) ou cat-N-base (ex: cat-1-base)
EOF
}

acquire_lock() {
  local attempts=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 50 ]]; then
      echo "erro: lock $LOCK_DIR ocupado após 5s; rodar de novo após o outro processo liberar" >&2
      exit 3
    fi
    sleep 0.1
  done
  LOCK_HELD=1
}

# Emite linhas TSV: dod_id<TAB>usos<TAB>desde_rev<TAB>title_current
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
    /^### DoD-base — Categoria [0-9]+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/ {
      match($0, /usos: [0-9]+/); usos = substr($0, RSTART + 6, RLENGTH - 6)
      match($0, /desde rev: [0-9]+/); rev = substr($0, RSTART + 11, RLENGTH - 11)
      printf "cat-%s-base\t%s\t%s\tDoD-base — Categoria %s\n", current_cat, usos, rev, current_cat
      next
    }
    /^### Tarefa [0-9]+ — .+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/ {
      s = $0
      sub(/^### Tarefa /, "", s)
      sub(/ .*$/, "", s)
      tnum = s
      title = $0
      sub(/^### /, "", title)
      sub(/ \(usos: [0-9]+ · desde rev: [0-9]+\)$/, "", title)
      match($0, /usos: [0-9]+/); usos = substr($0, RSTART + 6, RLENGTH - 6)
      match($0, /desde rev: [0-9]+/); rev = substr($0, RSTART + 11, RLENGTH - 11)
      printf "tarefa-%s\t%s\t%s\t%s\n", tnum, usos, rev, title
      next
    }
  ' "$DOD_FILE"
}

reset_dod() {
  local dod_id="$1"

  # Verifica existência ANTES de adquirir o lock (evita ocupar exclusão mútua
  # à toa quando o id é inválido).
  if ! parse_headings | awk -F'\t' -v t="$dod_id" '$1 == t { found = 1 } END { exit !found }'; then
    echo "dod-id desconhecido: $dod_id" >&2
    exit 2
  fi

  acquire_lock

  TMP_FILE="$(mktemp "$REFERENCES_DIR/.dod-reset.tmp.XXXXXX")"
  awk -v target="$dod_id" '
    BEGIN { current_cat = "" }
    /^## Categoria [0-9]+ — / {
      s = $0
      sub(/^## Categoria /, "", s)
      sub(/ .*$/, "", s)
      current_cat = s
      print
      next
    }
    /^### DoD-base — Categoria [0-9]+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/ {
      line_id = "cat-" current_cat "-base"
      if (line_id == target) sub(/desde rev: [0-9]+/, "desde rev: 0")
      print
      next
    }
    /^### Tarefa [0-9]+ — .+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/ {
      s = $0
      sub(/^### Tarefa /, "", s)
      sub(/ .*$/, "", s)
      line_id = "tarefa-" s
      if (line_id == target) sub(/desde rev: [0-9]+/, "desde rev: 0")
      print
      next
    }
    { print }
  ' "$DOD_FILE" > "$TMP_FILE"

  mv "$TMP_FILE" "$DOD_FILE"
  TMP_FILE=""

  # Atualiza last_seen_iso no snapshot (se a entry existir — pode estar ausente
  # se o snapshot foi gc'd ou nunca migrado; nesse caso só atualiza DOD.md).
  if [[ -f "$STATE_FILE" ]] && jq -e --arg id "$dod_id" 'has($id)' "$STATE_FILE" >/dev/null 2>&1; then
    local iso_now
    iso_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    TMP_FILE="$(mktemp "$REFERENCES_DIR/.dod-reset.tmp.XXXXXX")"
    jq -S --arg id "$dod_id" --arg ts "$iso_now" \
      '.[$id].last_seen_iso = $ts' "$STATE_FILE" > "$TMP_FILE"
    mv "$TMP_FILE" "$STATE_FILE"
    TMP_FILE=""
    echo "reset: $dod_id — desde rev = 0; last_seen_iso = $iso_now"
  else
    echo "reset: $dod_id — desde rev = 0 (snapshot sem entry para este id)"
  fi
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

  local rows sorted
  rows="$(parse_headings)"

  case "$sort_key" in
    desde-rev) sorted="$(printf '%s\n' "$rows" | sort -t$'\t' -k3,3 -n -r)" ;;
    usos)      sorted="$(printf '%s\n' "$rows" | sort -t$'\t' -k2,2 -n -r)" ;;
    id)        sorted="$(printf '%s\n' "$rows" | sort -t$'\t' -k1,1)" ;;
  esac

  # Header + linhas — formato: usos desde-rev dod_id title_current
  # Padding garante que linhas de dados casem regex ^[0-9]+ +[0-9]+ +(tarefa-…|cat-…) +
  # `|| { ec=...; [[ ec==141 ]] || return ec; }`: tolera SIGPIPE (`... | head`)
  # sem suprimir falhas reais. set -e + pipefail transformariam exit 141 em
  # erro do script; SIGPIPE é caso esperado pra output tabular.
  {
    printf '%s\n' "$sorted" | awk -F'\t' '
      BEGIN { printf "%-5s %-10s %-12s %s\n", "usos", "desde-rev", "dod_id", "title_current" }
      NF >= 4 { printf "%-5s %-10s %-12s %s\n", $2, $3, $1, $4 }
    '
  } || { local ec=$?; [[ "$ec" -eq 141 ]] || return "$ec"; }
}

cmd_gc() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "gc: 0 entries órfãs removidas"
    return 0
  fi

  acquire_lock

  local heading_ids snapshot_ids orphans
  heading_ids="$(parse_headings | cut -f1)"
  snapshot_ids="$(jq -r 'keys[]' "$STATE_FILE")"

  # Linhas em snapshot_ids que NÃO estão em heading_ids
  orphans="$(printf '%s\n' "$snapshot_ids" \
    | grep -vxF -f <(printf '%s\n' "$heading_ids") || true)"

  # Acumula órfãs num array bash. NÃO concatenar a chave numa expressão jq:
  # chave do snapshot pode (em tese) conter `"` ou outros chars e injetar
  # código jq. Passamos cada chave como positional arg e iteramos via
  # $ARGS.positional dentro do filtro — seguro contra qualquer chave.
  local -a orphan_args=()
  if [[ -n "$orphans" ]]; then
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      orphan_args+=( "$k" )
    done <<< "$orphans"
  fi

  local count=${#orphan_args[@]}

  if [[ $count -gt 0 ]]; then
    TMP_FILE="$(mktemp "$REFERENCES_DIR/.dod-reset.tmp.XXXXXX")"
    # Atenção: `--args` consome TUDO o que vem depois como positional arg, então
    # o input file DEVE vir antes do separador. Inverter quebra silenciosamente
    # (jq lê de stdin vazio e produz output vazio com exit 0).
    jq -S 'reduce ($ARGS.positional[]) as $k (.; del(.[$k]))' \
      "$STATE_FILE" --args "${orphan_args[@]}" > "$TMP_FILE"
    mv "$TMP_FILE" "$STATE_FILE"
    TMP_FILE=""
  fi

  echo "gc: $count entries órfãs removidas"
}

# Dispatch
if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

case "$1" in
  --help|-h) show_help; exit 0 ;;
  --show)    shift; cmd_show "$@" ;;
  --gc)      cmd_gc ;;
  --*)       echo "uso desconhecido: $1" >&2; show_help >&2; exit 1 ;;
  *)         reset_dod "$1" ;;
esac
