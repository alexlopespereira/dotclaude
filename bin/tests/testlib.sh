#!/usr/bin/env bash
# testlib.sh — helpers compartilhados pelas suítes de bin/tests/.
# Hoje: _days_ago_iso (antes duplicado em test_supply_chain_hook e _e2e com
# assinaturas divergentes — P2). Crescimento futuro: asserts comuns.

_days_ago_iso() { # <dias> [fmt — default %Y-%m-%dT%H:%M:%S.000Z]
  local fmt="${2:-%Y-%m-%dT%H:%M:%S.000Z}"
  date -u -v-"$1"d +"$fmt" 2>/dev/null || date -u -d "$1 days ago" +"$fmt"
}
