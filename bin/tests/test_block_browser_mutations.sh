#!/usr/bin/env bash
# test_block_browser_mutations.sh — allowlist BBM_ALLOW_TRIGGERS (US-02 quick wins).
#
# Cobre:
#   AC1 — payload com 'Comprar agora': sem env → exit 2; com BBM_ALLOW_TRIGGERS=comprar
#         → exit 0; allowlist não vaza ('delete' segue bloqueado).
#   AC2 — normalização: 'Comprar , PAY' (espaços/maiúsculas) libera ambos;
#         lista vazia/só-vírgulas = default.
#   AC5 — fail-open preservado: stdin não-JSON → exit 0.
#
# Estratégia: invoca o hook real com payload via stdin (formato PreToolUse).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-browser-mutations.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_rc() { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }

[ -f "$HOOK" ] || { echo "FAIL: $HOOK inexistente" >&2; exit 1; }

payload() { # texto do elemento clicado
  printf '{"tool_name":"mcp__playwright__browser_click","tool_input":{"element":"%s","ref":"e42"}}' "$1"
}

# AC1a — sem env, 'Comprar agora' bloqueia (exit 2)
payload "Comprar agora" | env -u BBM_ALLOW_TRIGGERS bash "$HOOK" 2>/dev/null; assert_rc "$?" "2" "AC1a sem env bloqueia 'comprar'"

# AC1b — com allowlist, libera (exit 0)
payload "Comprar agora" | BBM_ALLOW_TRIGGERS=comprar bash "$HOOK" 2>/dev/null; assert_rc "$?" "0" "AC1b allowlist libera 'comprar'"

# AC1c — allowlist não vaza: 'delete' segue bloqueado com a mesma env
payload "Delete account" | BBM_ALLOW_TRIGGERS=comprar bash "$HOOK" 2>/dev/null; assert_rc "$?" "2" "AC1c 'delete' segue bloqueado"

# AC2a — normalização de espaços/maiúsculas libera os dois termos
payload "Comprar agora" | BBM_ALLOW_TRIGGERS='Comprar , PAY' bash "$HOOK" 2>/dev/null; assert_rc "$?" "0" "AC2a 'Comprar ' (trim+case) libera comprar"
payload "Pay now" | BBM_ALLOW_TRIGGERS='Comprar , PAY' bash "$HOOK" 2>/dev/null; assert_rc "$?" "0" "AC2b ' PAY' (trim+case) libera pay"

# AC2c — lista vazia / só vírgulas = default (bloqueia)
payload "Comprar agora" | BBM_ALLOW_TRIGGERS='' bash "$HOOK" 2>/dev/null; assert_rc "$?" "2" "AC2c env vazia = default"
payload "Comprar agora" | BBM_ALLOW_TRIGGERS=' , ,' bash "$HOOK" 2>/dev/null; assert_rc "$?" "2" "AC2d só vírgulas = default"

# AC5a — fail-open: stdin não-JSON → exit 0
printf 'not-json' | BBM_ALLOW_TRIGGERS=comprar bash "$HOOK" 2>/dev/null; assert_rc "$?" "0" "AC5a parse error = fail-open exit 0"

# AC5b — tool diferente passa direto
printf '{"tool_name":"Bash","tool_input":{"command":"comprar"}}' | bash "$HOOK" 2>/dev/null; assert_rc "$?" "0" "AC5b outra tool não é interceptada"

echo "test_block_browser_mutations.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && { echo "FALHAS:$FAILED" >&2; exit 1; }
exit 0
