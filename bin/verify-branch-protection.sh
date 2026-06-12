#!/usr/bin/env bash
# bin/verify-branch-protection.sh — valida que a branch protection da main bate
# com os invariantes da US-01 (drift-check versionado).
#
# POR QUE EXISTE: a config de branch protection vive no GitHub, não no repo.
# Sem um validador versionado, uma drift remota (alguém troca o required check
# para "tests", liga required reviews, ou desliga allow_auto_merge) não falharia
# nenhum teste e quebraria silenciosamente o auto-merge Boris. Este script
# codifica os invariantes como código executável (ressalva do parecer US-01).
#
# INVARIANTES (US-01 acceptance criteria):
#   AC1  required_status_checks.contexts == ["bin-tests"]   (job id em tests.yml)
#   AC2  required_approving_review_count == 0 ou ausente     (auto-merge solo)
#   AC3  allow_auto_merge == true                            (PR mergeia sozinho)
#   strict == false                                          (não exige rebase)
#
# SEAM DE TESTE: toda I/O externa passa por `gh`, então bin/tests/ faz PATH
# shadow de `gh` com fixtures. BP_REPO sobrescreve a detecção de repo (evita
# `gh repo view` nos testes).
#
# Uso:   bin/verify-branch-protection.sh
# Saída: exit 0 + "OK" se tudo bate; exit 1 + lista de drift em stderr.

set -uo pipefail

EXPECTED_CHECK="bin-tests"
REPO="${BP_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo alexlopespereira/dotclaude)}"

command -v jq >/dev/null 2>&1 || { echo "ERRO: jq não encontrado no PATH." >&2; exit 2; }

protection=$(gh api "repos/$REPO/branches/main/protection" 2>/dev/null) || {
  echo "ERRO: não consegui ler a branch protection de $REPO (precisa de admin/token)." >&2
  exit 2
}
auto_merge=$(gh api "repos/$REPO" --jq .allow_auto_merge 2>/dev/null)

drift=0
fail() { echo "DRIFT: $1" >&2; drift=1; }

# AC1 — required check exato
contexts=$(printf '%s' "$protection" | jq -c '.required_status_checks.contexts // []')
if [ "$contexts" != "[\"$EXPECTED_CHECK\"]" ]; then
  fail "required_status_checks.contexts é $contexts, esperado [\"$EXPECTED_CHECK\"]"
fi

# strict == false
strict=$(printf '%s' "$protection" | jq -r '.required_status_checks.strict // false')
[ "$strict" = "false" ] || fail "required_status_checks.strict é $strict, esperado false"

# AC2 — 0 required approvals (chave ausente é equivalente a 0)
reviews=$(printf '%s' "$protection" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')
[ "$reviews" = "0" ] || fail "required_approving_review_count é $reviews, esperado 0 (deadlock de auto-merge solo)"

# AC3 — allow_auto_merge ligado
[ "$auto_merge" = "true" ] || fail "allow_auto_merge é '$auto_merge', esperado true"

if [ "$drift" -ne 0 ]; then
  echo "Reaplique: bin/verify-branch-protection.sh --help  (regra documentada no README)." >&2
  exit 1
fi

echo "OK: branch protection de $REPO bate com os invariantes US-01 (check=$EXPECTED_CHECK, reviews=0, auto_merge=true, strict=false)."
exit 0
