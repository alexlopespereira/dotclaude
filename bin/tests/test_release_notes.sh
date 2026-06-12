#!/usr/bin/env bash
# bin/tests/test_release_notes.sh — cobre a lógica pura de bin/release-notes.sh.
#
# Razão de existir (US-09 / TDD): a versão CalVer e o agrupamento de release
# notes precisam ser provados sem rede e sem criar tags de verdade. O script
# expõe funções puras (compute_tag, next_calver, group_commits) que este teste
# sourceia e exercita diretamente — o `run` (que faz git/gh) fica fora do teste
# via guard ${BASH_SOURCE[0]} == ${0}.
#
# AC2: compute_tag é idempotente — se o commit corrente já tem tag v*, devolve
#      vazio (não cria duplicata); em colisão no mesmo dia, sufixa -N.
# AC3: group_commits agrupa por tipo de Conventional Commit (feat/fix/docs/
#      refactor/ci), em ordem fixa, ignorando tipos fora do conjunto.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$BIN_DIR/release-notes.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq()       { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_contains() { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' not found in: $1";; esac; }
assert_before()   { # $1 haystack, $2 needle-A, $3 needle-B, $4 msg — A deve vir antes de B
  local a b; a=$(printf '%s' "$1" | grep -n -F "$2" | head -1 | cut -d: -f1)
  b=$(printf '%s' "$1" | grep -n -F "$3" | head -1 | cut -d: -f1)
  { [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; } && _pass || _fail "$4 :: '$2'(@$a) não vem antes de '$3'(@$b)"
}

# Sourceia o script sob teste — o guard impede que main/run dispare.
# shellcheck source=/dev/null
. "$SCRIPT"

# ── AC2: compute_tag <today> <current_sha> <tag\tsha-lines> ──────────────────

# Sem tags no repo → tag base.
out=$(compute_tag "2026.06.12" "aaa111" "")
assert_eq "$out" "v2026.06.12" "AC2 repo sem tags → tag base do dia"

# Base já existe num OUTRO commit → sufixo -1 (colisão no mesmo dia).
out=$(compute_tag "2026.06.12" "newsha" "$(printf 'v2026.06.12\toldsha')")
assert_eq "$out" "v2026.06.12-1" "AC2 colisão no mesmo dia → sufixo -1"

# Base e -1 já existem → -2.
out=$(compute_tag "2026.06.12" "newsha" "$(printf 'v2026.06.12\ts1\nv2026.06.12-1\ts2')")
assert_eq "$out" "v2026.06.12-2" "AC2 colisão dupla → sufixo -2"

# IDEMPOTÊNCIA: o commit corrente JÁ está taggeado → saída vazia (não duplica).
out=$(compute_tag "2026.06.12" "samesha" "$(printf 'v2026.06.12\tsamesha')")
assert_eq "$out" "" "AC2 idempotente: re-run no mesmo commit não gera tag nova"

# Idempotência também quando a tag do commit é de um dia anterior.
out=$(compute_tag "2026.06.12" "samesha" "$(printf 'v2026.06.11\tsamesha')")
assert_eq "$out" "" "AC2 idempotente: commit já taggeado (dia anterior) não re-tagga"

# next_calver isolada: nenhuma tag base → base.
out=$(next_calver "2026.01.05" "")
assert_eq "$out" "v2026.01.05" "next_calver sem colisão"

# ── AC3: group_commits (stdin: subjects) ────────────────────────────────────

subjects=$(cat <<'EOF'
feat: add release workflow
fix(scope): correct off-by-one
docs: update readme
refactor: extract helper
ci: add shellcheck job
chore: bump deps
feat!: breaking change
EOF
)
notes=$(printf '%s\n' "$subjects" | group_commits)

assert_contains "$notes" "### Features"          "AC3 seção Features presente"
assert_contains "$notes" "- add release workflow" "AC3 feat vira bullet"
assert_contains "$notes" "- breaking change"      "AC3 feat! (breaking) agrupado em Features"
assert_contains "$notes" "### Fixes"             "AC3 seção Fixes presente"
assert_contains "$notes" "- correct off-by-one"  "AC3 fix(scope) tem escopo removido do bullet"
assert_contains "$notes" "### Docs"              "AC3 seção Docs presente"
assert_contains "$notes" "### Refactor"          "AC3 seção Refactor presente"
assert_contains "$notes" "### CI"                "AC3 seção CI presente"
case "$notes" in *chore*) _fail "AC3 'chore' (fora do conjunto) não deve aparecer";; *) _pass;; esac

# Ordem fixa: Features < Fixes < Docs < Refactor < CI.
assert_before "$notes" "### Features" "### Fixes"    "AC3 ordem Features<Fixes"
assert_before "$notes" "### Fixes"    "### Docs"     "AC3 ordem Fixes<Docs"
assert_before "$notes" "### Docs"     "### Refactor" "AC3 ordem Docs<Refactor"
assert_before "$notes" "### Refactor" "### CI"       "AC3 ordem Refactor<CI"

# Tipo ausente não gera seção vazia.
notes2=$(printf 'feat: só uma feature\n' | group_commits)
case "$notes2" in *"### Fixes"*) _fail "AC3 seção Fixes não deve existir sem fixes";; *) _pass;; esac

echo "── test_release_notes: $PASS passaram, $FAIL falharam ──"
[ "$FAIL" -gt 0 ] && { printf '%s\n' "$FAILED"; exit 1; }
exit 0
