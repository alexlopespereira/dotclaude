#!/usr/bin/env bash
# bin/tests/test_branch_protection.sh — cobre bin/verify-branch-protection.sh.
#
# Razão de existir: o parecer US-01 apontou que a branch protection vivia só no
# GitHub, sem nenhum artefato versionado que falhasse em drift. Estes testes
# provam que o validador rejeita exatamente os cenários de drift citados
# (contexto "tests" em vez de "bin-tests", required reviews > 0, auto_merge off)
# e aceita o estado correto.
#
# Estratégia: PATH shadow de `gh`. O mock dispatch por $* e responde com
# fixtures vindas de env vars ($FIX_PROTECTION, $FIX_AUTO_MERGE), permitindo
# que cada caso injete um estado remoto diferente sem rede.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$BIN_DIR/verify-branch-protection.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_rc()       { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_contains() { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' not found";; esac; }

MOCK_DIR=$(mktemp -d)
cat > "$MOCK_DIR/gh" <<'MOCK'
#!/usr/bin/env bash
# Dispatch: `gh api repos/X/branches/main/protection` → $FIX_PROTECTION
#           `gh api repos/X --jq .allow_auto_merge`     → $FIX_AUTO_MERGE
case "$*" in
  *branches/main/protection*) printf '%s' "$FIX_PROTECTION"; exit 0 ;;
  *--jq\ .allow_auto_merge*)   printf '%s' "$FIX_AUTO_MERGE"; exit 0 ;;
  *repo\ view*)                echo "owner/repo"; exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCK_DIR/gh"

# Fixture base: estado CORRETO (espelha o estado live aplicado pela US-01).
GOOD_PROTECTION='{"required_status_checks":{"strict":false,"contexts":["bin-tests"]}}'

run() {
  # $1 = protection JSON, $2 = auto_merge value
  PATH="$MOCK_DIR:$PATH" BP_REPO="owner/repo" \
    FIX_PROTECTION="$1" FIX_AUTO_MERGE="$2" \
    bash "$SCRIPT" 2>&1
}

# 1. Estado correto → exit 0
out=$(run "$GOOD_PROTECTION" "true"); rc=$?
assert_rc "$rc" 0 "estado correto passa"
assert_contains "$out" "OK" "estado correto imprime OK"

# 2. Drift: contexto "tests" em vez de "bin-tests" → exit 1 (cenário do parecer)
out=$(run '{"required_status_checks":{"strict":false,"contexts":["tests"]}}' "true"); rc=$?
assert_rc "$rc" 1 "contexto 'tests' é drift"
assert_contains "$out" "contexts" "drift de contexto reportado"

# 3. Drift: required reviews > 0 → exit 1 (deadlock de auto-merge solo)
out=$(run '{"required_status_checks":{"strict":false,"contexts":["bin-tests"]},"required_pull_request_reviews":{"required_approving_review_count":1}}' "true"); rc=$?
assert_rc "$rc" 1 "required reviews > 0 é drift"
assert_contains "$out" "approving_review_count" "drift de reviews reportado"

# 4. Drift: allow_auto_merge desligado → exit 1
out=$(run "$GOOD_PROTECTION" "false"); rc=$?
assert_rc "$rc" 1 "auto_merge off é drift"
assert_contains "$out" "allow_auto_merge" "drift de auto_merge reportado"

# 5. Drift: strict=true → exit 1
out=$(run '{"required_status_checks":{"strict":true,"contexts":["bin-tests"]}}' "true"); rc=$?
assert_rc "$rc" 1 "strict=true é drift"

# 6. reviews ausente é equivalente a 0 (não é drift) — coberto pelo GOOD; reforço explícito
out=$(run '{"required_status_checks":{"strict":false,"contexts":["bin-tests"]}}' "true"); rc=$?
assert_rc "$rc" 0 "required_pull_request_reviews ausente == 0 approvals"

rm -rf "$MOCK_DIR"

echo "── test_branch_protection: $PASS passaram, $FAIL falharam ──"
[ "$FAIL" -gt 0 ] && { printf '%s\n' "$FAILED"; exit 1; }
exit 0
