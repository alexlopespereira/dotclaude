#!/usr/bin/env bash
set -euo pipefail

# bin/dod-add-bullet-ids.sh — adiciona prefixo [bN] aos bullets do DOD.md (US-01).
#
# Para cada bullet `- [ ] ...` dentro de um bloco `### Tarefa N` ou
# `### DoD-base — Categoria N`, prepende `[bN]` (N reseta a cada heading).
# Em seguida recalcula `bullets_sha256` no `.dod-revision-state.json` para
# todas as 28 entries no MESMO RUN — evita drift silencioso (Ressalva Alta #1).
#
# Idempotente: re-execuções detectam `[b\d+]` no DOD.md e saem com exit 0.
#
# Uso:
#   dod-add-bullet-ids.sh              # aplica migration (default)
#   dod-add-bullet-ids.sh --dry-run    # mostra diff sem mutar
#   dod-add-bullet-ids.sh --help       # esta ajuda
#
# Exit codes:
#   0 — sucesso (migrado, já migrado, ou dry-run)
#   1 — uso inválido / estado inesperado do arquivo
#   3 — lock ocupado após retry

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
REFERENCES_DIR="$SKILL_DIR/references"
DOD_FILE="$REFERENCES_DIR/DOD.md"
STATE_FILE="$REFERENCES_DIR/.dod-revision-state.json"
LOCK_DIR="$REFERENCES_DIR/.dod-add-bullet-ids.lock"

TMP_DOD=""
TMP_BULLETS=""
TMP_STATE=""
TMP_NEXT=""
TMP_STATE_SORTED=""
LOCK_HELD=0

cleanup() {
  [[ -n "$TMP_DOD" && -e "$TMP_DOD" ]] && rm -f "$TMP_DOD"
  [[ -n "$TMP_BULLETS" && -d "$TMP_BULLETS" ]] && rm -rf "$TMP_BULLETS"
  [[ -n "$TMP_STATE" && -e "$TMP_STATE" ]] && rm -f "$TMP_STATE"
  [[ -n "$TMP_NEXT" && -e "$TMP_NEXT" ]] && rm -f "$TMP_NEXT"
  [[ -n "$TMP_STATE_SORTED" && -e "$TMP_STATE_SORTED" ]] && rm -f "$TMP_STATE_SORTED"
  # Só remove o lock se ESTE processo o adquiriu (mesmo padrão dos dod-*.sh).
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

show_help() {
  cat <<'EOF'
dod-add-bullet-ids — adiciona prefixo [bN] aos bullets do DOD.md e
                     resincroniza bullets_sha256 no snapshot.

uso:
  dod-add-bullet-ids.sh              aplica migration (default)
  dod-add-bullet-ids.sh --dry-run    mostra diff sem mutar arquivos
  dod-add-bullet-ids.sh --help       esta ajuda

efeito:
  - DOD.md: cada bullet '- [ ]' dentro de '### Tarefa N' ou
    '### DoD-base — Categoria N' ganha prefixo [bN] (numeração reseta no
    próximo heading).
  - DoD-base Categoria 1 b4 ganha sufixo '(prefix `[US-XX]` aceito quando
    gerado pelo Ralph)' — aprendizado meta do PR #27.
  - .dod-revision-state.json: bullets_sha256 recalculado para as 28 entries.

idempotente: 2º run detecta o prefixo [bN] e sai com exit 0.
EOF
}

DRY_RUN=0
case "${1:-}" in
  ""        ) ;;
  --help|-h ) show_help; exit 0 ;;
  --dry-run ) DRY_RUN=1 ;;
  *         ) echo "uso desconhecido: $1" >&2; show_help >&2; exit 1 ;;
esac

# Lock via mkdir (atomic POSIX; macOS-compatible — fd-lock indisponível no Darwin)
attempts=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  attempts=$((attempts + 1))
  if [[ $attempts -ge 50 ]]; then
    echo "erro: lock $LOCK_DIR ocupado após 5s; rodar de novo após o outro processo liberar" >&2
    exit 3
  fi
  sleep 0.1
done
LOCK_HELD=1

# Idempotência: bullets já têm prefixo [bN] → nada a fazer.
if grep -qE '^- \[ \] \[b[0-9]+\] ' "$DOD_FILE"; then
  echo "já migrado: prefixo [bN] presente em $DOD_FILE"
  exit 0
fi

# Awk-stateful: prepende [bN] aos bullets dentro de cada bloco Tarefa/DoD-base.
# Também aplica AC10 — string-match exato no bullet b4 da DoD-base Cat 1.
TMP_DOD="$(mktemp "$REFERENCES_DIR/.dod-add-bullet-ids.tmp.XXXXXX")"
AC10_OLD="- [ ] [b4] commitado em git com mensagem \`feat(claude): ...\`"
AC10_NEW="- [ ] [b4] commitado em git com mensagem \`feat(claude): ...\` (prefix \`[US-XX]\` aceito quando gerado pelo Ralph)"

awk -v ac10_old="$AC10_OLD" -v ac10_new="$AC10_NEW" '
  BEGIN {
    in_block = 0
    in_cat1_base = 0
    bn = 0
  }
  /^### Tarefa [0-9]+ — / {
    in_block = 1
    in_cat1_base = 0
    bn = 0
    print
    next
  }
  /^### DoD-base — Categoria [0-9]+/ {
    in_block = 1
    in_cat1_base = ($0 ~ /^### DoD-base — Categoria 1 /)
    bn = 0
    print
    next
  }
  /^### / || /^## / {
    in_block = 0
    in_cat1_base = 0
    bn = 0
    print
    next
  }
  {
    if (in_block && match($0, /^- \[ \] /)) {
      bn += 1
      rest = substr($0, RLENGTH + 1)
      new_line = sprintf("- [ ] [b%d] %s", bn, rest)
      if (in_cat1_base && new_line == ac10_old) {
        print ac10_new
      } else {
        print new_line
      }
      next
    }
    print
  }
' "$DOD_FILE" > "$TMP_DOD"

# Validação: contagem de markers no migrado deve casar com a contagem original
# de bullets (170 esperado). AC7 exige ≥100.
orig_bullets=$(grep -cE '^- \[ \] ' "$DOD_FILE" || true)
new_markers=$(grep -cE '^- \[ \] \[b[0-9]+\] ' "$TMP_DOD" || true)
if [[ "$new_markers" -ne "$orig_bullets" ]]; then
  echo "erro: $new_markers bullets marcados, esperado $orig_bullets (drift no awk)" >&2
  exit 1
fi
if [[ "$new_markers" -lt 100 ]]; then
  echo "erro: $new_markers bullets marcados; AC7 exige ≥100" >&2
  exit 1
fi

# AC10 sanity check: o sufixo deve estar presente em exatamente 1 linha.
ac10_hits=$(grep -cF '(prefix `[US-XX]` aceito quando gerado pelo Ralph)' "$TMP_DOD" || true)
if [[ "$ac10_hits" -ne 1 ]]; then
  echo "erro: AC10 sufixo presente em $ac10_hits linhas (esperado 1)" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  diff -u "$DOD_FILE" "$TMP_DOD" || true
  echo "--- dry-run: nada gravado em disco ---"
  exit 0
fi

# Write atômico: mv dentro do mesmo filesystem.
mv "$TMP_DOD" "$DOD_FILE"
TMP_DOD=""

# Snapshot resync — extrai bullets por heading no DOD.md já migrado,
# recalcula sha256, e atualiza .dod-revision-state.json para todas as 28 entries.
TMP_BULLETS="$(mktemp -d -t dod-bullets.XXXXXX)"

awk -v dir="$TMP_BULLETS" '
  function trim(s) { sub(/[ \t]+$/, "", s); return s }
  function flush(   bpath) {
    if (cur_id != "") {
      bpath = dir "/" cur_id ".bullets"
      close(bpath)
    }
    cur_id = ""
    in_bullets = 0
  }
  BEGIN {
    current_cat = ""
    cur_id = ""
    in_bullets = 0
  }
  /^## Categoria [0-9]+ — / {
    flush()
    split($0, parts, " ")
    current_cat = parts[3]
    next
  }
  /^## / {
    flush()
    next
  }
  /^### DoD-base — Categoria [0-9]+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/ {
    flush()
    cur_id = "cat-" current_cat "-base"
    in_bullets = 1
    next
  }
  /^### Tarefa [0-9]+ — .+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/ {
    flush()
    title = $0
    sub(/^### /, "", title)
    sub(/ \(usos: [0-9]+ · desde rev: [0-9]+\)$/, "", title)
    match(title, /^Tarefa [0-9]+/)
    tp = substr(title, RSTART, RLENGTH)
    split(tp, t, " ")
    cur_id = "tarefa-" t[2]
    in_bullets = 1
    next
  }
  /^### / {
    flush()
    next
  }
  {
    if (in_bullets) {
      print trim($0) > (dir "/" cur_id ".bullets")
    }
  }
  END { flush() }
' "$DOD_FILE"

bullet_files=$(find "$TMP_BULLETS" -maxdepth 1 -name '*.bullets' | wc -l | tr -d ' ')
if [[ "$bullet_files" -ne 28 ]]; then
  echo "erro: snapshot resync produziu $bullet_files bullet files (esperado 28)" >&2
  exit 1
fi

# Atualiza snapshot in-place — preserva slug + title_current existentes,
# refresca bullets_sha256 + last_seen_iso para todas as 28 entries.
ISO_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TMP_STATE="$(mktemp "$REFERENCES_DIR/.dod-add-bullet-ids.tmp.XXXXXX")"
cp "$STATE_FILE" "$TMP_STATE"

for bullets_file in "$TMP_BULLETS"/*.bullets; do
  id="$(basename "$bullets_file" .bullets)"
  sha="$(sha256sum "$bullets_file" | cut -d' ' -f1)"
  TMP_NEXT="$(mktemp "$REFERENCES_DIR/.dod-add-bullet-ids.tmp.XXXXXX")"
  jq --arg id "$id" --arg s "$sha" --arg ts "$ISO_NOW" \
    '.[$id].bullets_sha256 = $s | .[$id].last_seen_iso = $ts' \
    "$TMP_STATE" > "$TMP_NEXT"
  mv "$TMP_NEXT" "$TMP_STATE"
  TMP_NEXT=""
done

TMP_STATE_SORTED="$TMP_STATE.sorted"
jq -S . "$TMP_STATE" > "$TMP_STATE_SORTED"
mv "$TMP_STATE_SORTED" "$STATE_FILE"
TMP_STATE_SORTED=""
rm -f "$TMP_STATE"
TMP_STATE=""

final_bn=$(grep -cE '^- \[ \] \[b[0-9]+\] ' "$DOD_FILE" || true)
final_entries=$(jq 'keys | length' "$STATE_FILE")
echo "migrado: $final_bn bullets numerados + $final_entries snapshot entries resincronizadas"
