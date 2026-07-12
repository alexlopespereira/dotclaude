#!/usr/bin/env bash
# bin/tests/test_workflows_quota.sh — invariantes de billing do tests.yml.
#
# Cobre .github/workflows/tests.yml: o repo é PRIVADO — minutos Linux pagam
# multiplicador 1×; macOS pagava 10× por job (migração P0 flipou o bin-tests
# pra ubuntu-latest). O evento pull_request testa o merge ref, então um trigger
# push na main re-executaria a mesma suíte pós-merge e pagaria em dobro. Este
# teste congela os invariantes anti-desperdício:
#
# Mapa AC → bloco:
#   AC1a on: sem trigger 'push' (dedupe — merge ref do pull_request já cobre)
#   AC1b bloco concurrency com cancel-in-progress: true (mata runs obsoletos)
#   AC1c header honesto: sem claim 'Repo público' nem 'sem custo' (repo privado)
#   AC1d trigger pull_request permanece (a suíte continua rodando no CI)
#   AC4  nomes dos jobs bin-tests e shellcheck inalterados (required checks da
#        branch protection são keyed por nome — renomear = check fantasma)
#   AC5  job bin-tests com runs-on: ubuntu-latest (US-05 P0: congela o ganho
#        10×→1×; regressão pra macos-latest voltaria a pagar multiplicador)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
YML="$REPO_DIR/.github/workflows/tests.yml"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_contains()     { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' não em conteúdo";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' presente, não deveria";; *) _pass;; esac; }
assert_match()        { if printf '%s' "$1" | grep -Eq "$2"; then _pass; else _fail "$3 :: regex '$2' sem match"; fi; }
assert_file()         { [ -f "$1" ] && _pass || _fail "$2 :: arquivo '$1' ausente"; }

assert_file "$YML" "(base) tests.yml existe"
if [ ! -f "$YML" ]; then
  echo "test_workflows_quota.sh: PASS=$PASS FAIL=$FAIL"
  printf '%s\n' "$FAILED"
  exit 1
fi
BODY=$(cat "$YML")

# Bloco 'on:' isolado: da linha 'on:' até a próxima chave top-level (coluna 0).
# Sem isso, o grep de 'push' seria vacuous (acharia 'push' em comentários) e o
# de 'pull_request' passaria mesmo com o trigger movido pra fora do 'on:'.
ON_BLOCK=$(awk '/^on:/{f=1;next} f&&/^[^ ]/{f=0} f' "$YML")
assert_match "$ON_BLOCK" "[^ ]" "(guard) bloco on: extraído não-vazio"

# ═══════════════════════════════════════════════════════════════════════════
# AC1a — sem trigger push: o run pós-merge é duplicado (pull_request já testa
# o merge ref) e paga multiplicador 10× em macOS de repo privado
# ═══════════════════════════════════════════════════════════════════════════
assert_not_contains "$ON_BLOCK" "push" "(AC1a) bloco on: sem trigger push"

# ═══════════════════════════════════════════════════════════════════════════
# AC1b — concurrency com cancel-in-progress: push novo no PR cancela o run
# anterior em vez de pagar os dois até o fim
# ═══════════════════════════════════════════════════════════════════════════
assert_match "$BODY" "^concurrency:" "(AC1b) bloco concurrency top-level presente"
assert_contains "$BODY" "cancel-in-progress: true" "(AC1b) cancel-in-progress: true"

# ═══════════════════════════════════════════════════════════════════════════
# AC1c — header honesto: o repo é privado; a claim antiga 'Repo público →
# minutos macOS sem custo' era falsa e mascarava o custo real
# ═══════════════════════════════════════════════════════════════════════════
assert_not_contains "$BODY" "Repo público" "(AC1c) sem claim 'Repo público'"
assert_not_contains "$BODY" "sem custo" "(AC1c) sem claim 'sem custo'"

# ═══════════════════════════════════════════════════════════════════════════
# AC1d — pull_request permanece: dedupe não pode virar 'CI desligado'
# ═══════════════════════════════════════════════════════════════════════════
assert_contains "$ON_BLOCK" "pull_request" "(AC1d) trigger pull_request presente no on:"

# ═══════════════════════════════════════════════════════════════════════════
# AC4 — nomes dos jobs inalterados (required checks keyed por nome)
# ═══════════════════════════════════════════════════════════════════════════
assert_match "$BODY" "^  bin-tests:" "(AC4) job bin-tests presente com nome intacto"
assert_match "$BODY" "^  shellcheck:" "(AC4) job shellcheck presente com nome intacto"

# ═══════════════════════════════════════════════════════════════════════════
# AC5 — runner do bin-tests: ubuntu-latest (US-05 P0). Bloco do job isolado
# da linha '  bin-tests:' até a próxima chave de 2 espaços (próximo job) —
# sem isso o assert seria vacuous (acharia o runs-on do job shellcheck).
# ═══════════════════════════════════════════════════════════════════════════
BIN_TESTS_BLOCK=$(awk '/^  bin-tests:/{f=1;next} f&&/^  [^ ]/{f=0} f' "$YML")
assert_match "$BIN_TESTS_BLOCK" "[^ ]" "(guard) bloco do job bin-tests extraído não-vazio"
assert_contains "$BIN_TESTS_BLOCK" "runs-on: ubuntu-latest" "(AC5) job bin-tests com runs-on: ubuntu-latest"
# Assert negativo co-presente: substring match sozinho deixaria passar um
# comentário stale 'runs-on: ubuntu-latest' num job flipado de volta pra macOS
# (review holístico #6 — padrão dos asserts negativos do AC1c).
assert_not_contains "$BIN_TESTS_BLOCK" "macos-latest" "(AC5) bloco bin-tests sem macos-latest"

echo "test_workflows_quota.sh: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
