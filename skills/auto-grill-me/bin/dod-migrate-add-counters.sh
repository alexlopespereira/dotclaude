#!/usr/bin/env bash
set -euo pipefail

# bin/dod-migrate-add-counters.sh — one-shot idempotent migration (US-02).
#
# Reescreve os 8 `### DoD-base` headings + 20 `### Tarefa N` headings de
# references/DOD.md no padrão `### <kind> — <título> (usos: 0 · desde rev: 0)`
# e cria references/.dod-revision-state.json com 28 entries (sha256 do bullet
# block + metadata). macOS-compatible: usa `mkdir <lockdir>` para serialização
# porque o utilitário fd-lock clássico não existe no Darwin.
#
# Exit codes:
#   0 — sucesso (migrado ou já migrado)
#   1 — estado parcial detectado (alguns headings migrados, outros não)
#   3 — lock ocupado após retry
#   4/5 — falha interna pós-migração (não deve acontecer em uso normal)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
REFERENCES_DIR="$SKILL_DIR/references"
DOD_FILE="$REFERENCES_DIR/DOD.md"
STATE_FILE="$REFERENCES_DIR/.dod-revision-state.json"
LOCK_DIR="$REFERENCES_DIR/.dod-migrate.lock"
ANCHOR_SCAN_LOG="/tmp/anchor-scan.log"

TMP_DOD=""
TMP_BULLETS=""
LOCK_HELD=0
cleanup() {
  [[ -n "$TMP_DOD" && -e "$TMP_DOD" ]] && rm -f "$TMP_DOD"
  [[ -n "$TMP_BULLETS" && -d "$TMP_BULLETS" ]] && rm -rf "$TMP_BULLETS"
  # Só remove o lock se ESTE processo o adquiriu; caso contrário, um exit por
  # timeout (linha do "exit 3") apagaria o lock do dono real e quebraria a
  # exclusão mútua (achado revisor: race no cleanup).
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

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

# AC13 — pré-commit anchor scan; warn (não aborta — US-04 cobre a reescrita)
{
  grep -rn '#dod-base-todas-as-tarefas\|#tarefa-[0-9]' \
    /Users/dev/Projects/dotclaude/ /Users/dev/.claude/ --include='*.md' 2>/dev/null || true
} > "$ANCHOR_SCAN_LOG"

if [[ -s "$ANCHOR_SCAN_LOG" ]]; then
  match_count=$(wc -l < "$ANCHOR_SCAN_LOG" | tr -d ' ')
  echo "warning: $match_count anchor link(s) legado(s) detectados em $ANCHOR_SCAN_LOG (US-04 cobre reescrita)"
fi

# Detecção de estado — total de headings (28) é invariante; migrated_count varia
MIGRATED_PATTERN='^### (Tarefa [0-9]+|DoD-base) — .+ \(usos: [0-9]+ · desde rev: [0-9]+\)$'
ALL_DOD_BASE_PATTERN='^### DoD-base'
ALL_TAREFA_PATTERN='^### Tarefa [0-9]+ — '

total_dod_base=$(grep -cE "$ALL_DOD_BASE_PATTERN" "$DOD_FILE" || true)
total_tarefa=$(grep -cE "$ALL_TAREFA_PATTERN" "$DOD_FILE" || true)
total_headings=$((total_dod_base + total_tarefa))
migrated_count=$(grep -cE "$MIGRATED_PATTERN" "$DOD_FILE" || true)
pending_count=$((total_headings - migrated_count))

if [[ "$total_headings" -ne 28 ]]; then
  echo "estado parcial detectado: $total_headings headings totais (esperado 28: 8 DoD-base + 20 Tarefa)" >&2
  exit 1
fi

if [[ "$migrated_count" -eq 28 ]]; then
  echo "migrado: skip"
  exit 0
fi

if [[ "$migrated_count" -ne 0 ]]; then
  echo "estado parcial detectado: $migrated_count migrado(s), $pending_count pendente(s) (esperado: 0/28 antes da migração ou 28/0 depois)" >&2
  exit 1
fi

# Migração — reescreve headings num arquivo temporário no mesmo filesystem (mv atomic)
TMP_DOD="$(mktemp "$REFERENCES_DIR/.dod-migrate.tmp.XXXXXX")"

awk '
BEGIN { current_cat = "" }
/^## Categoria [0-9]+ — / {
  split($0, parts, " ")
  current_cat = parts[3]
  print
  next
}
/^### DoD-base$/ || /^### DoD-base \(todas as tarefas\)$/ {
  printf "### DoD-base — Categoria %s (usos: 0 · desde rev: 0)\n", current_cat
  next
}
/^### Tarefa [0-9]+ — / {
  printf "%s (usos: 0 · desde rev: 0)\n", $0
  next
}
{ print }
' "$DOD_FILE" > "$TMP_DOD"

new_migrated_count=$(grep -cE "$MIGRATED_PATTERN" "$TMP_DOD" || true)
if [[ "$new_migrated_count" -ne 28 ]]; then
  echo "erro interno: migração produziu $new_migrated_count headings migrados (esperado 28)" >&2
  exit 4
fi

# Build snapshot — extrai bullet block (heading exclusive até próximo ### / ## / EOF)
TMP_BULLETS="$(mktemp -d -t dod-bullets.XXXXXX)"

awk -v dir="$TMP_BULLETS" '
function trim(s) { sub(/[ \t]+$/, "", s); return s }
function flush(   tpath, bpath) {
  if (cur_id != "") {
    tpath = dir "/" cur_id ".title"
    bpath = dir "/" cur_id ".bullets"
    print cur_title > tpath
    close(tpath)
    close(bpath)
  }
  cur_id = ""; cur_title = ""; in_bullets = 0
}
BEGIN { current_cat = ""; cur_id = ""; cur_title = ""; in_bullets = 0 }
/^## Categoria [0-9]+ — / {
  flush()
  split($0, parts, " ")
  current_cat = parts[3]
  next
}
/^## / { flush(); next }
/^### DoD-base — Categoria [0-9]+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/ {
  flush()
  cur_id = "cat-" current_cat "-base"
  cur_title = "DoD-base — Categoria " current_cat
  in_bullets = 1
  next
}
/^### Tarefa [0-9]+ — .+ \(usos: [0-9]+ · desde rev: [0-9]+\)$/ {
  flush()
  title = $0
  sub(/^### /, "", title)
  sub(/ \(usos: [0-9]+ · desde rev: [0-9]+\)$/, "", title)
  cur_title = title
  match(title, /^Tarefa [0-9]+/)
  tp = substr(title, RSTART, RLENGTH)
  split(tp, t, " ")
  cur_id = "tarefa-" t[2]
  in_bullets = 1
  next
}
/^### / { flush(); next }
{
  if (in_bullets) {
    line = trim($0)
    bpath = dir "/" cur_id ".bullets"
    print line > bpath
  }
}
END { flush() }
' "$TMP_DOD"

bullet_count=$(find "$TMP_BULLETS" -maxdepth 1 -name '*.bullets' | wc -l | tr -d ' ')
title_count=$(find "$TMP_BULLETS" -maxdepth 1 -name '*.title' | wc -l | tr -d ' ')
if [[ "$bullet_count" -ne 28 || "$title_count" -ne 28 ]]; then
  echo "erro interno: $bullet_count bullets + $title_count titles (esperado 28+28)" >&2
  exit 5
fi

ISO_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

slugify() {
  LC_ALL=C echo "$1" | tr '[:upper:]' '[:lower:]' | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

JSON='{}'
for bullets_file in "$TMP_BULLETS"/*.bullets; do
  id="$(basename "$bullets_file" .bullets)"
  title_file="$TMP_BULLETS/$id.title"
  title="$(cat "$title_file")"
  sha="$(sha256sum "$bullets_file" | cut -d' ' -f1)"
  slug="$(slugify "$title")"
  JSON="$(jq --arg id "$id" --arg slug "$slug" --arg t "$title" --arg s "$sha" --arg ts "$ISO_NOW" \
    '. + {($id): {slug: $slug, title_current: $t, bullets_sha256: $s, last_seen_iso: $ts}}' \
    <<< "$JSON")"
done

# Escreve outputs — snapshot via jq -S (ordenação determinística), DOD via mv atomic
echo "$JSON" | jq -S . > "$STATE_FILE"
mv "$TMP_DOD" "$DOD_FILE"
TMP_DOD=""

final_migrated=$(grep -cE "$MIGRATED_PATTERN" "$DOD_FILE" || true)
final_entries=$(jq 'keys | length' "$STATE_FILE")
echo "migrado: $final_migrated headings + $final_entries snapshot entries"
