#!/usr/bin/env bash
# test_fase9_reflect_model.sh — US-06 AC4.
#
# Trava a Fase 9 de commands/full-cycle.md e commands/full-cycle-simple.md no
# pattern: subprocess `claude --model claude-fable-5 -p "/reflect ..."` em
# BACKGROUND (& + disown) com falha non-blocking documentada. Regressão que
# voltasse à invocação inline `/reflect` (herda modelo da sessão — impossível
# pinar) faria este teste falhar.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FC="$REPO_ROOT/commands/full-cycle.md"
FCS="$REPO_ROOT/commands/full-cycle-simple.md"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_file_grep()   { grep -qE -- "$2" "$1" && _pass || _fail "$3 :: padrão '$2' ausente em $1"; }
assert_file_nogrep() { grep -qE -- "$2" "$1" && _fail "$3 :: padrão '$2' NÃO deveria aparecer em $1" || _pass; }

echo "=== fase9 reflect --model tests (US-06 AC4) ==="

for f in "$FC" "$FCS"; do
  [ -f "$f" ] || { echo "FAIL: $f inexistente" >&2; exit 1; }
done

# AC4 — subprocess claude --model claude-fable-5 -p "/reflect ..."
assert_file_grep "$FC"  'claude --model claude-fable-5 -p "/reflect' "AC4a full-cycle.md: subprocess claude --model claude-fable-5 -p"
assert_file_grep "$FCS" 'claude --model claude-fable-5 -p "/reflect' "AC4b full-cycle-simple.md: subprocess claude --model claude-fable-5 -p"

# AC4 — invocação em background (linha terminando em & e/ou disown)
assert_file_grep "$FC"  '(&[[:space:]]*$|disown)' "AC4c full-cycle.md: invocação em background (&/disown)"
assert_file_grep "$FCS" '(&[[:space:]]*$|disown)' "AC4d full-cycle-simple.md: invocação em background (&/disown)"

# AC4 — falha non-blocking documentada
assert_file_grep "$FC"  '[Nn]on-blocking' "AC4e full-cycle.md: non-blocking documentado"
assert_file_grep "$FCS" '[Nn]on-blocking' "AC4f full-cycle-simple.md: non-blocking documentado"

# AC4 (anti-regressão) — a chamada de Fase 9 não pode mais ser `/reflect` inline
# (linha começando em `/reflect` ou `&& /reflect`). Note: menções em prosa/flags
# como `/reflect --on-failure` continuam permitidas — checamos só invocação.
assert_file_nogrep "$FCS" '&& /reflect \$PR_NUMBER' "AC4g full-cycle-simple.md: sem invocação inline /reflect \$PR_NUMBER"

echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:$FAILED"
  exit 1
fi
exit 0
