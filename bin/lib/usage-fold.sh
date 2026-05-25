#!/usr/bin/env bash
# bin/lib/usage-fold.sh — Derivador content-based dos contadores de uso de DoD (US-02).
#
# Lê TODOS os logs per-machine (telemetry/<prefix>-usage.*.jsonl) escritos pelo
# writer M1 (usage-log.sh) e agrega por dod_id, emitindo TSV:
#     dod_id<TAB>usos<TAB>desde_rev<TAB>last_seen
# (mesmo shape headerless que `parse_headings` do dod-reset-rev.sh emite hoje —
#  drop-in para o consumidor US-04 --show.)
#
# Sourceable (US-03 migração / US-05 skill reusam dod_bullets_sha) + dual-mode CLI:
#   usage-fold.sh [--prefix P] [--dod-file F]
#
# Regras de derivação (CONTENT-BASED, não time-based — Adv #2; plano F2/M2):
#   • sha_atual  = hash dos bullets do DoD no DOD.md, computado NA HORA (AC3).
#   • usos       = #eventos `use` + Σ(baseline.count)                      (AC2).
#   • desde_rev  = #eventos `use` cujo sha == sha_atual                    (AC3).
#                  NÃO conta baseline nem revision; NÃO usa ordenação por ts
#                  → imune a clock-skew cross-host.
#   • last_seen  = max(ts) entre todos os eventos do dod_id                (AC5).
#
# Sobre baseline e desde_rev (AC3 literal): AC3 enuncia "#eventos use cujo sha ==
# atual". baseline (kind=baseline) NÃO é evento `use` → entra SÓ em usos (AC2),
# nunca em desde_rev; revision também nunca conta como uso. Como o seeder US-03
# preserva o desde_rev pré-migração (p.ex. semeando eventos `use` no sha atual) é
# decisão do US-03, fora do escopo do fold — o fold só implementa a regra AC3.
#
# Determinismo (AC4): usos/desde_rev são somas comutativas, last_seen é max
# comutativo, e a saída é ordenada por dod_id → output idêntico independente da
# ordem dos arquivos/eventos ou da máquina que escreveu cada um.
#
# Test seam: USAGE_LOG_HOME sobrescreve a base ~/.claude (mesmo seam do writer M1).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Reusa _usage_log_home (single source of truth do dir de telemetria). O guard
# dual-mode do usage-log.sh garante que sourcing só define funções.
# shellcheck source=bin/lib/usage-log.sh
source "$SCRIPT_DIR/usage-log.sh"

# Raiz do repo (bin/lib → ../..); resolve os DOD files default. Mesmo layout
# relativo quando instalado em ~/.claude.
_USAGE_FOLD_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# sha256 do arquivo (1º campo). Prefere sha256sum (Linux/VM + este Mac); cai pra
# `shasum -a 256` em macs stock. Mesmo valor de hash (SHA-256 dos mesmos bytes);
# só o wrapper textual difere — `cut -f1` cobre ambos.
_usage_fold_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# dod_bullets_sha <dod_file>
# Emite TSV `dod_id<TAB>sha` para cada DoD do arquivo. Replica BYTE-A-BYTE a
# extração canônica de dod-add-bullet-ids.sh (snapshot resync) — mesma awk +
# sha256sum sobre o mesmo conteúdo → mesmo hash. Validado contra
# .dod-revision-state.json (tarefa-7). Reusável por US-03/05/06.
dod_bullets_sha() {
  local dod_file="$1"
  [ -f "$dod_file" ] || return 0
  local tmpd
  tmpd="$(mktemp -d -t usage-fold-bullets.XXXXXX)"

  awk -v dir="$tmpd" '
    function trim(s) { sub(/[ \t]+$/, "", s); return s }
    function flush(   bpath) {
      if (cur_id != "") { bpath = dir "/" cur_id ".bullets"; close(bpath) }
      cur_id = ""; in_bullets = 0
    }
    BEGIN { current_cat = ""; cur_id = ""; in_bullets = 0 }
    /^## Categoria [0-9]+ — / {
      flush(); split($0, parts, " "); current_cat = parts[3]; next
    }
    /^## / { flush(); next }
    # Sufixo `(usos: N · desde rev: N)` é OPCIONAL: pré-migração (US-03) os
    # headings o carregam; pós-strip (AC4) ficam source puro. dod_bullets_sha
    # hash o CONTEÚDO da seção (não a linha do heading) → o sha por dod_id é
    # idêntico antes e depois do strip; tornar o sufixo opcional é o que garante
    # que o mesmo dod_id (e logo o mesmo sha) seja derivado nos dois estados —
    # base da equivalência US-03 AC5.
    /^### DoD-base — Categoria [0-9]+( \(usos: [0-9]+ · desde rev: [0-9]+\))?$/ {
      flush(); cur_id = "cat-" current_cat "-base"; in_bullets = 1; next
    }
    /^### Tarefa [0-9]+ — .+$/ {
      flush(); title = $0
      sub(/^### /, "", title); sub(/ \(usos: [0-9]+ · desde rev: [0-9]+\)$/, "", title)
      match(title, /^Tarefa [0-9]+/); tp = substr(title, RSTART, RLENGTH)
      split(tp, t, " "); cur_id = "tarefa-" t[2]; in_bullets = 1; next
    }
    /^### / { flush(); next }
    { if (in_bullets) print trim($0) > (dir "/" cur_id ".bullets") }
    END { flush() }
  ' "$dod_file"

  local f id sha
  for f in "$tmpd"/*.bullets; do
    [ -e "$f" ] || continue
    id="$(basename "$f" .bullets)"
    sha="$(_usage_fold_sha256 "$f")"
    printf '%s\t%s\n' "$id" "$sha"
  done

  rm -rf "$tmpd"
}

# Resolve o DOD file default a partir do prefix.
_usage_fold_default_dod_file() {
  case "$1" in
    dod)       printf '%s' "$_USAGE_FOLD_ROOT/skills/auto-grill-me/references/DOD.md" ;;
    test-spec) printf '%s' "$_USAGE_FOLD_ROOT/skills/testing/references/TEST-PATTERNS.md" ;;
    *)         printf '%s' "" ;;
  esac
}

# usage_fold [--prefix P] [--dod-file F]
# Emite o TSV derivado (1 linha por dod_id presente nos logs).
usage_fold() {
  local prefix="dod" dod_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix)     prefix="${2:-}";   shift 2 ;;
      --prefix=*)   prefix="${1#*=}";  shift ;;
      --dod-file)   dod_file="${2:-}"; shift 2 ;;
      --dod-file=*) dod_file="${1#*=}"; shift ;;
      --help|-h)
        sed -n '2,40p' "$SCRIPT_DIR/usage-fold.sh" | sed 's/^# \{0,1\}//'
        return 0 ;;
      *) echo "usage-fold: argumento desconhecido '$1'" >&2; return 2 ;;
    esac
  done

  if [[ ! "$prefix" =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "usage-fold: --prefix inválido '$prefix'" >&2; return 2
  fi
  [ -n "$dod_file" ] || dod_file="$(_usage_fold_default_dod_file "$prefix")"
  if [ -n "$dod_file" ] && [ ! -f "$dod_file" ]; then
    echo "usage-fold: DOD file não encontrado: $dod_file (desde_rev=0 p/ todos)" >&2
  fi

  local home dir
  home="$(_usage_log_home)"
  dir="$home/telemetry"

  # sha_atual por dod_id → objeto JSON {dod_id: sha}. {} se sem DOD file.
  local sha_json
  sha_json="$(dod_bullets_sha "$dod_file" \
    | jq -R -s 'split("\n") | map(select(length>0) | split("\t"))
                | map({(.[0]): .[1]}) | add // {}')"

  # Coleta os logs desta prefix (todas as máquinas). find tolera dir/match ausente.
  local -a logs=()
  if [ -d "$dir" ]; then
    local f
    while IFS= read -r f; do
      [ -n "$f" ] && logs+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f -name "${prefix}-usage.*.jsonl" 2>/dev/null | LC_ALL=C sort)
  fi
  [ ${#logs[@]} -eq 0 ] && return 0   # sem eventos → TSV vazio

  # Agregação content-based. group_by + sort_by(.dod_id) → ordem determinística.
  cat "${logs[@]}" | jq -R -s --argjson sha "$sha_json" -r '
    split("\n")
    | map(select(length > 0) | fromjson)
    | group_by(.dod_id)
    | map({
        dod_id: .[0].dod_id,
        usos: ( map(
                  if .kind == "use" then 1
                  elif .kind == "baseline" then .count
                  else 0 end ) | add ),
        desde_rev: ( map(
                  if .kind == "use" and .sha == $sha[.dod_id] then 1
                  else 0 end ) | add ),
        last_seen: ( map(.ts) | max )
      })
    | sort_by(.dod_id)
    | .[]
    | [ .dod_id, (.usos | tostring), (.desde_rev | tostring), .last_seen ]
    | @tsv
  '
}

# Dual-mode: executado diretamente → roda o fold com os args do CLI.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  usage_fold "$@"
  exit $?
fi
