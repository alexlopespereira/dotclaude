#!/usr/bin/env bash
# bin/lib/supply-chain/audit.sh — JSONL audit log para decisões do hook.
# Schema por linha:
#   { ts: ISO8601, cwd: string, decision: "allow"|"block"|"bypass",
#     command: string, reason: string|null }
#
# Path: ${SC_AUDIT_LOG:-${SC_CACHE_DIR:-$HOME/.claude/cache/supply-chain}/audit.jsonl}
# Rotação: quando audit.jsonl > 10 MiB → mantém até 5 históricos
#   (audit-1.jsonl..audit-5.jsonl, mais velho descartado).

_sc_audit_path() {
  echo "${SC_AUDIT_LOG:-${SC_CACHE_DIR:-$HOME/.claude/cache/supply-chain}/audit.jsonl}"
}

# sc_audit_log <decision> <command> <reason-or-empty>
#   - reason="" é gravado como JSON null
#   - append é atomic em POSIX para lines < PIPE_BUF (4 KiB) — JSONL típica
#     ocupa <500 B, então printf >> não interleave.
sc_audit_log() {
  local decision="$1" command="$2" reason="$3"
  local path; path=$(_sc_audit_path)
  local dir; dir=$(dirname "$path")
  mkdir -p "$dir"

  sc_audit_log_rotate_if_needed "$path"

  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n -c \
    --arg ts "$ts" --arg cwd "$PWD" --arg d "$decision" \
    --arg cmd "$command" --arg r "$reason" \
    '{ts:$ts, cwd:$cwd, decision:$d, command:$cmd, reason:(if $r == "" then null else $r end)}' \
    >> "$path"
}

# Internal: rotate if active log exceeds threshold.
sc_audit_log_rotate_if_needed() {
  local active="$1"
  local max_bytes="${SC_AUDIT_MAX_BYTES:-10485760}"  # 10 MiB
  [ -f "$active" ] || return 0
  local size
  # Dual GNU-first (doutrina do CONTEXT.md, "stat -f GNU vs BSD"): BSD stat -c
  # falha limpo; a ordem inversa só funcionava por acidente de parsing da flag
  # colada -f%z — a forma espaçada faria o GNU imprimir filesystem-status e
  # corromper a comparação numérica (review holístico #2).
  size=$(stat -c%s "$active" 2>/dev/null || stat -f%z "$active" 2>/dev/null)
  [ -z "$size" ] && return 0
  [ "$size" -lt "$max_bytes" ] && return 0
  sc_audit_rotate "$active"
}

# Manual rotation (useful for tests and forced rotations).
sc_audit_rotate() {
  local active="${1:-$(_sc_audit_path)}"
  local dir base
  dir=$(dirname "$active")
  base=$(basename "$active" .jsonl)

  # Drop oldest (5 → discard)
  [ -f "$dir/${base}-5.jsonl" ] && rm -f "$dir/${base}-5.jsonl"
  # Shift up: 4→5, 3→4, 2→3, 1→2
  local i
  for i in 4 3 2 1; do
    [ -f "$dir/${base}-${i}.jsonl" ] && mv "$dir/${base}-${i}.jsonl" "$dir/${base}-$((i+1)).jsonl"
  done
  # Current → historic-1
  [ -f "$active" ] && mv "$active" "$dir/${base}-1.jsonl"
  # Restart fresh
  : > "$active"
}
