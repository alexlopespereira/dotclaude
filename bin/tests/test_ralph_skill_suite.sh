#!/usr/bin/env bash
# bin/tests/test_ralph_skill_suite.sh — wrapper que roda a suíte de testes
# skill-local do Ralph Adversarial e a expõe ao gate de CI.
#
# POR QUÊ: os testes em skills/ralph-adversarial/tests/ eram descobertos só
# manualmente — run-all.sh só varre bin/tests/test_*.sh, então eles NÃO gateavam
# no CI (.github/workflows/tests.yml). Regressões em parse-verdict.sh /
# ralph-adversarial.sh (ex.: extract_review_evidence, is_framework_file, o
# detector de stream-timeout) passavam despercebidas. Este wrapper roda cada um
# em processo próprio e falha (exit 1) se qualquer um falhar, de modo que
# run-all.sh o pega como UMA suíte e o CI passa a cobri-los.
#
# Descoberta é dinâmica (test_*.sh) para novos testes entrarem automaticamente;
# os dois runners nomeados (run.sh = fixtures do parse-verdict; run-quota.sh =
# detect-quota) são adicionados explicitamente por não casarem test_*.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_TESTS_DIR="$REPO_ROOT/skills/ralph-adversarial/tests"

[ -d "$SKILL_TESTS_DIR" ] || { echo "FAIL: dir de testes não encontrado: $SKILL_TESTS_DIR"; exit 1; }

# Coleta: todos os test_*.sh (dinâmico) + os runners nomeados, se existirem.
suites=()
for t in "$SKILL_TESTS_DIR"/test_*.sh; do
    [ -f "$t" ] && suites+=("$t")
done
for r in run.sh run-quota.sh; do
    [ -f "$SKILL_TESTS_DIR/$r" ] && suites+=("$SKILL_TESTS_DIR/$r")
done

[ "${#suites[@]}" -gt 0 ] || { echo "FAIL: nenhuma suíte skill-local encontrada em $SKILL_TESTS_DIR"; exit 1; }

fails=0; total=0
for s in "${suites[@]}"; do
    total=$((total+1))
    out=$(bash "$s" 2>&1); rc=$?
    last=$(printf '%s\n' "$out" | tail -1)
    if [ "$rc" -ne 0 ]; then
        fails=$((fails+1))
        echo "  FAIL(rc=$rc) $(basename "$s")"
        printf '%s\n' "$out" | tail -15 | sed 's/^/    /'
    else
        echo "  ok   $(basename "$s") :: $last"
    fi
done

echo "test_ralph_skill_suite: $((total-fails))/$total suítes skill-local verdes"
[ "$fails" -gt 0 ] && exit 1
exit 0
