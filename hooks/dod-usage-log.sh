#!/usr/bin/env bash
# hooks/dod-usage-log.sh — Stop hook: emissão DETERMINÍSTICA de eventos `use` de
# telemetria DoD/test-spec, parseando MARCADORES nos planos persistidos.
#
# POR QUÊ: a emissão era prompt-driven (a skill mandava o LLM rodar `log_event`
# no meio da sessão). Empiricamente NUNCA disparou — 0 eventos reais em 11-15
# dias nas 3 máquinas; tudo no log era seed da migração. Este hook tira o LLM do
# loop: enquanto a skill escrever o plano (seu output primário) com 1 marcador
# por inserção de DoD, o hook reconstrói a telemetria a partir do artefato.
#
# MARCADOR canônico (ASCII, invisível no render — ver DOD-MAPPING.md):
#   <!-- dod-use: <dod_id> -->         (prefix dod;       sha de DOD.md)
#   <!-- test-spec-use: <dod_id> -->   (prefix test-spec; sha de TEST-PATTERNS.md)
#
# CONTRATO: best-effort, NÃO-bloqueante, SEMPRE exit 0. Idempotente via ledger
# per-marcador (não re-emite o que já emitiu, mesmo se o plano for editado/
# appendado depois). Anti-backfill via pré-seed lazy por escopo (1ª vez registra
# os marcadores existentes SEM emitir → só planos novos contam; evita duplo-cont
# com o seed da migração).
#
# SEAMS (env): DOTCLAUDE_REPO (default ~/Projects/dotclaude — libs + DOD/TEST
# canônicos), USAGE_LOG_HOME (default ~/.claude — telemetria + ledger + mid),
# CLAUDE_PROJECT_DIR (default $PWD — projeto da sessão), DOD_USAGE_PLANS_DIR
# (override do dir de planos), DOD_USAGE_DEBUG (1 → traços em stderr).
#
# Registrado como Stop hook em ~/.claude/settings.json (via sync.sh).

set -u

_dbg() { [ -n "${DOD_USAGE_DEBUG:-}" ] && printf 'dod-usage-log: %s\n' "$*" >&2 || true; }

# ── Drena stdin + guard stop_hook_active (re-entrância → no-op) ──────────────
payload="$(cat 2>/dev/null || true)"
if command -v jq >/dev/null 2>&1; then
  active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
else
  if printf '%s' "$payload" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    active=true; else active=false; fi
fi
[ "$active" = "true" ] && { _dbg "stop_hook_active=true → no-op"; exit 0; }

# ── Path resolution ABSOLUTO do repo dotclaude (libs + DOD/TEST canônicos) ───
REPO="${DOTCLAUDE_REPO:-$HOME/Projects/dotclaude}"
if [ ! -f "$REPO/bin/lib/usage-fold.sh" ]; then
  _dbg "sem checkout dotclaude em $REPO → no-op"; exit 0
fi
# usage-fold.sh sourceia usage-log.sh (log_event, _usage_log_machine_id,
# _usage_log_home, _usage_fold_sha256, dod_bullets_sha). Guard dual-mode garante
# que sourcing só define funções.
# shellcheck source=bin/lib/usage-fold.sh
source "$REPO/bin/lib/usage-fold.sh" 2>/dev/null || { _dbg "falha ao sourcear libs"; exit 0; }

DOD_CANON="$REPO/skills/auto-grill-me/references/DOD.md"
TS_CANON="$REPO/skills/testing/references/TEST-PATTERNS.md"

# ── Planos do projeto da SESSÃO (qualquer projeto, não o repo dotclaude) ─────
PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
PLANS_DIR="${DOD_USAGE_PLANS_DIR:-$PROJ/.claude/plans}"

# ── Ledger per-machine (local-only em cache/; nunca colide no sync git) ──────
HOME_BASE="$(_usage_log_home)"
MID="$(_usage_log_machine_id)"
LEDGER_DIR="$HOME_BASE/cache/telemetry"
LEDGER="$LEDGER_DIR/processed-plans.$MID"
mkdir -p "$LEDGER_DIR" 2>/dev/null || { _dbg "mkdir ledger falhou"; exit 0; }
touch "$LEDGER" 2>/dev/null || exit 0

# ── Caches de sha-por-id dos arquivos canônicos (1× por execução) ───────────
DOD_TSV="$(mktemp -t dod-usage-dod.XXXXXX)" || exit 0
TS_TSV="$(mktemp -t dod-usage-ts.XXXXXX)"   || { rm -f "$DOD_TSV"; exit 0; }
trap 'rm -f "$DOD_TSV" "$TS_TSV"' EXIT
[ -f "$DOD_CANON" ] && dod_bullets_sha "$DOD_CANON" > "$DOD_TSV" 2>/dev/null
[ -f "$TS_CANON" ]  && dod_bullets_sha "$TS_CANON"  > "$TS_TSV"  2>/dev/null

# _lookup_sha <tsv> <id> → sha (rc 1 se ausente)
_lookup_sha() {
  awk -F'\t' -v id="$2" '$1==id { print $2; found=1 } END { exit !found }' "$1"
}

# _emit_markers <file> <marker> <prefix> <sha_tsv> <mode>
# Para cada ocorrência do marcador no arquivo (na ordem), monta a chave
# <file>\t<prefix>\t<id>\t<ordinal> e: em mode=emit, emite log_event se ainda
# não registrada; em mode=preseed, só registra (sem emitir). Ordinal preserva
# multiplicidade de tarefa-N; awk numera (portável a bash 3.2 — sem assoc array).
_emit_markers() {
  local file="$1" marker="$2" prefix="$3" sha_tsv="$4" mode="$5"
  local id ord key sha
  while IFS="$(printf '\t')" read -r id ord; do
    [ -n "$id" ] || continue
    case "$id" in *[!A-Za-z0-9._-]*) continue ;; esac   # casa o regex de log_event
    key="$(printf '%s\t%s\t%s\t%s' "$file" "$prefix" "$id" "$ord")"
    grep -qxF "$key" "$LEDGER" && continue
    if [ "$mode" = emit ]; then
      sha="$(_lookup_sha "$sha_tsv" "$id")" || { _dbg "skip $prefix/$id (sem sha)"; continue; }
      [ -n "$sha" ] || continue
      log_event use "$id" --sha "$sha" --prefix "$prefix" >/dev/null 2>&1 \
        || { _dbg "log_event falhou $prefix/$id"; continue; }
      _dbg "emit $prefix/$id @ ${sha:0:12}"
    fi
    printf '%s\n' "$key" >> "$LEDGER"
  done < <(grep -oE "<!-- $marker: [A-Za-z0-9._-]+ -->" "$file" 2>/dev/null \
             | sed -E "s/<!-- $marker: (.*) -->/\1/" \
             | awk '{ c[$0]++; printf "%s\t%d\n", $0, c[$0] }')
}

# _scope_mode <scope_path> → "emit" ou "preseed" (e marca a sentinela depois)
_has_sentinel() { grep -qxF "# preseeded:$1" "$LEDGER"; }
_write_sentinel() { printf '# preseeded:%s\n' "$1" >> "$LEDGER"; }

# ── Escopo 1: planos do projeto (markers dod-use E test-spec-use) ────────────
if [ -d "$PLANS_DIR" ]; then
  if _has_sentinel "$PLANS_DIR"; then mode=emit; else mode=preseed; fi
  _dbg "escopo planos=$PLANS_DIR mode=$mode"
  for plan in "$PLANS_DIR"/*.md; do
    [ -e "$plan" ] || continue
    _emit_markers "$plan" "dod-use"       "dod"       "$DOD_TSV" "$mode"
    _emit_markers "$plan" "test-spec-use" "test-spec" "$TS_TSV"  "$mode"
  done
  [ "$mode" = preseed ] && _write_sentinel "$PLANS_DIR"
fi

# ── Escopo 2: TEST-PATTERNS.md canônico (Ramo 2 do /test-spec) ───────────────
if [ -f "$TS_CANON" ]; then
  if _has_sentinel "$TS_CANON"; then mode=emit; else mode=preseed; fi
  _dbg "escopo test-patterns=$TS_CANON mode=$mode"
  _emit_markers "$TS_CANON" "test-spec-use" "test-spec" "$TS_TSV" "$mode"
  [ "$mode" = preseed ] && _write_sentinel "$TS_CANON"
fi

exit 0
