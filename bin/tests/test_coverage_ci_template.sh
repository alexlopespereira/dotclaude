#!/usr/bin/env bash
# bin/tests/test_coverage_ci_template.sh — US-03 CI required-check template.
#
# Cobre skills/testing/templates/coverage/coverage-ci.yml: o workflow de CI que
# roda a suíte com cobertura e chama coverage-gate.sh --gate. Asserções são
# capture-proof: leem o conteúdo real do YAML (não só "o arquivo existe"), grep
# do job name contra o identificador documentado (anti check-fantasma), e prova
# em dry-run do revert path via `gh api`.
#
# Mapa AC → bloco:
#   AC1 triggers (pull_request + push main) + invoca coverage-gate.sh --gate
#   AC2 versões pinadas (diff-cover, coverage, c8, action SHAs de 40 hex)
#   AC3 job de bash em ubuntu-latest (NÃO macOS) — kcov frágil em macOS
#   AC4 gate é required de verdade: passo do gate sem continue-on-error +
#       teste-de-violação proposital documentado
#   AC5 job name == identificador do check documentado (grep, sem ghost check)
#   AC6 revert path (gh api -X DELETE da branch protection) documentado + dry-run
#   AC7 [SUPOSIÇÃO] bash-no-CI registrada como comentário no template

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$BIN_DIR/.." && pwd)"
YML="$REPO_DIR/skills/testing/templates/coverage/coverage-ci.yml"
INIT="$BIN_DIR/coverage-init.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_contains()     { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' não em conteúdo";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' presente, não deveria";; *) _pass;; esac; }
assert_match()        { if printf '%s' "$1" | grep -Eq "$2"; then _pass; else _fail "$3 :: regex '$2' sem match"; fi; }
assert_file()         { [ -f "$1" ] && _pass || _fail "$2 :: arquivo '$1' ausente"; }
assert_rc()           { [ "$1" = "$2" ] && _pass || _fail "$3 :: rc=$2 esperado, got $1"; }

assert_file "$YML" "(base) coverage-ci.yml existe"
if [ ! -f "$YML" ]; then
  echo "test_coverage_ci_template.sh: PASS=$PASS FAIL=$FAIL"
  printf '%s\n' "$FAILED"
  exit 1
fi
BODY=$(cat "$YML")

# ═══════════════════════════════════════════════════════════════════════════
# AC1 — triggers pull_request + push na main; invoca coverage-gate.sh --gate
# ═══════════════════════════════════════════════════════════════════════════
assert_contains "$BODY" "pull_request" "(AC1) roda em pull_request"
# P1-6: trigger é PR-only. push-to-main daria diff vazio vs origin/main →
# diff-cover passa vacuamente. Precondição (on: existe) co-presente p/ o negativo.
assert_match "$BODY" "^on:" "(AC1) tem bloco on: (precondição do negativo abaixo)"
if printf '%s' "$BODY" | grep -Eq '^[[:space:]]*push:'; then _fail "(P1-6) NAO deve disparar em push-to-main (vacuous pass)"; else _pass; fi
assert_contains "$BODY" "coverage-gate.sh --gate" "(AC1) invoca coverage-gate.sh --gate"
# P0-2: gate via path VENDORADO scripts/ci/, nunca o path interno do dotclaude
# (skills/... não existe no consumer → exit 127 → trava merge p/ sempre).
assert_contains "$BODY" "scripts/ci/coverage-gate.sh --gate" "(P0-2) gate via path vendorado scripts/ci/"
assert_not_contains "$BODY" "skills/ralph-adversarial/lib/coverage-gate.sh" "(P0-2) NAO usa path interno do dotclaude"

# ═══════════════════════════════════════════════════════════════════════════
# AC2 — versões pinadas: diff-cover, coverage, c8 e action SHAs de 40 hex
# ═══════════════════════════════════════════════════════════════════════════
assert_match "$BODY" "diff-cover==[0-9]" "(AC2) diff-cover pinado (==versão)"
assert_match "$BODY" "coverage==[0-9]"   "(AC2) coverage pinado (==versão)"
assert_match "$BODY" "c8@[0-9]"          "(AC2) c8 pinado (@versão)"
# P0-3: gem pina via -v (forma `nome:versao` é inválida no RubyGems → o job de
# bash morre no setup e, como required check, trava merges p/ sempre).
assert_match "$BODY" "gem install.*bashcov -v [0-9]" "(P0-3) bashcov pinado via -v"
assert_not_contains "$BODY" "bashcov:3" "(P0-3) NAO usa forma inválida nome:versao"
# P13: npm install no template usa --ignore-scripts (mata lifecycle hooks).
assert_match "$BODY" "npm install.*--ignore-scripts" "(P13) npm usa --ignore-scripts"
# P2-8: pip NÃO faz upgrade unpinned (--upgrade pip puxa versão arbitrária).
assert_not_contains "$BODY" "pip install --upgrade pip" "(P2-8) sem pip upgrade unpinned"
# actions pinadas a SHA de 40 hex (não @v4 flutuante)
assert_match "$BODY" "uses:[[:space:]]*[a-z0-9./-]+@[0-9a-f]{40}" "(AC2) actions pinadas a SHA de 40 hex"
# Reforço (review-fix): NENHUMA linha `uses:` — ativa OU comentada — pode apontar
# a ref flutuante. O check anterior só rejeitava `actions/checkout@v`; um
# `setup-python@v5` ou `setup-node@v4` passariam batido. Aqui: toda linha que
# referencia uma action DEVE casar @<40 hex>; qualquer outra (e.g. @vN, @main,
# @branch, ou tag) é coletada e reprova o teste com a linha ofensora no relatório.
USES_LINES=$(grep -nE '^[[:space:]#-]*uses:[[:space:]]*[a-zA-Z0-9._/-]+@' "$YML" || true)
UNPINNED=$(printf '%s\n' "$USES_LINES" | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' || true)
UNPINNED=$(printf '%s' "$UNPINNED" | sed '/^$/d')
if [ -z "$UNPINNED" ]; then _pass; else _fail "(AC2) action(s) sem SHA pin de 40 hex: $UNPINNED"; fi
# nenhuma action (qualquer namespace) presa a tag flutuante @vN
assert_not_contains "$BODY" "actions/checkout@v" "(AC2) checkout NÃO usa tag flutuante @v"
if printf '%s\n' "$USES_LINES" | grep -Eq '@v[0-9]'; then
  _fail "(AC2) há action presa a tag flutuante @vN: $(printf '%s\n' "$USES_LINES" | grep -E '@v[0-9]')"
else _pass; fi

# ═══════════════════════════════════════════════════════════════════════════
# AC3 — cobertura de bash em job ubuntu-latest dedicado (NÃO macOS)
# ═══════════════════════════════════════════════════════════════════════════
assert_match "$BODY" "runs-on:[[:space:]]*ubuntu-latest" "(AC3) job roda em ubuntu-latest"
assert_not_contains "$BODY" "macos-latest" "(AC3) bash NÃO roda em macOS (kcov frágil)"
# extrai o bloco do job (parametrizado: coverage-gate) e confirma SEU runner
JOB=$(awk '/^  coverage-gate:/{p=1} p&&/^  [a-z].*:$/&&!/^  coverage-gate:/{exit} p' "$YML")
assert_contains "$JOB" "ubuntu-latest"   "(AC3) o job coverage-gate especifica ubuntu-latest"
assert_contains "$JOB" "--lang __LANG__" "(V2) gate parametrizado por __LANG__ (não --lang bash fixo)"
assert_contains "$JOB" "bashcov"         "(AC3) arm bash do case instala bashcov (cobertura bash em Linux)"

# ═══════════════════════════════════════════════════════════════════════════
# AC4 — required de verdade: passo do gate sem continue-on-error + violação doc.
#   Um required check não pode ter `continue-on-error: true` (viraria advisory).
# ═══════════════════════════════════════════════════════════════════════════
assert_not_contains "$BODY" "continue-on-error: true" "(AC4) gate não é advisory (sem continue-on-error)"
# diff-cover --fail-under=100 é a autoridade que reprova linha nova sem teste:
# está embutido em coverage-gate.sh --gate; o template documenta o teste de
# violação proposital.
assert_contains "$BODY" "VIOLATION-TEST" "(AC4) documenta o teste de violação proposital"
assert_contains "$BODY" "fail-under=100" "(AC4) cita a autoridade fail-under=100 do gate"

# ═══════════════════════════════════════════════════════════════════════════
# AC5 — identificador do check == job name real (grep), anti check-fantasma.
#   O template documenta o nome do required check num comentário; o teste prova
#   que esse literal bate com o `name:` real do job (senão branch protection
#   ficaria esperando um check que nunca roda → merges travados pra sempre).
# ═══════════════════════════════════════════════════════════════════════════
# nome real do job de bash (linha `name:` dentro do job)
JOB_NAME=$(printf '%s\n' "$JOB" | sed -n 's/^[[:space:]]*name:[[:space:]]*//p' | head -1)
assert_match "$JOB_NAME" "." "(AC5) job coverage-gate tem name: explícito"
# identificador documentado no comentário REQUIRED-CHECK
DOC_NAME=$(grep -E '^#[[:space:]]*REQUIRED-CHECK:' "$YML" | sed -n 's/^#[[:space:]]*REQUIRED-CHECK:[[:space:]]*//p' | head -1)
assert_match "$DOC_NAME" "." "(AC5) comentário REQUIRED-CHECK documenta o identificador"
if [ -n "$JOB_NAME" ] && [ -n "$DOC_NAME" ]; then
  [ "$JOB_NAME" = "$DOC_NAME" ] && _pass \
    || _fail "(AC5) identificador documentado ('$DOC_NAME') != job name real ('$JOB_NAME')"
fi

# ═══════════════════════════════════════════════════════════════════════════
# AC6 — revert path documentado (gh api -X DELETE da branch protection) + dry-run
# ═══════════════════════════════════════════════════════════════════════════
assert_contains "$BODY" "gh api -X DELETE" "(AC6) documenta gh api -X DELETE"
assert_contains "$BODY" "branches/main/protection" "(AC6) alvo é a branch protection rule da main"
# regressão issue-1 (review): strict é BOOLEAN ⇒ marcado via -F (typed); com -f
# viraria a string "true" e a API rejeita/ignora silenciosamente.
assert_contains "$BODY" "-F 'strict=true'" "(AC6/issue1) strict marcado via -F (typed boolean)"
assert_not_contains "$BODY" "-f 'strict=" "(AC6/issue1) strict NÃO via -f (raw string)"
# (review-fix) dry-run que EXERCITA o comando real: o anterior só rodava
# `gh api --help` e ficava verde mesmo com endpoint/flag do revert quebrados.
# Agora extrai o comando do template e roda gh com GH_HOST bogus — gh PARSEIA
# flags/subcomando e aborta na expansão do placeholder {owner} ANTES de qualquer
# rede (offline e seguro). Erro de parse reprova; placeholder-error (pós-parse)
# aprova.
_is_parse_err() { case "$1" in *"unknown flag"*|*"unknown shorthand"*|*"unknown command"*) return 0;; *) return 1;; esac; }
if command -v gh >/dev/null 2>&1; then
  # endpoint real do revert DELETE, extraído do template (test rastreia a fonte)
  REVERT_PATH=$(grep -E 'gh api -X DELETE' "$YML" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
  assert_match "$REVERT_PATH" "branches/main/protection" "(AC6) endpoint DELETE extraído do template"
  DEL_ERR=$(GH_HOST=dryrun.invalid GH_TOKEN=dryrun gh api -X DELETE "$REVERT_PATH" \
              -f 'contexts[]=coverage-gate (bash)' 2>&1 || true)
  if _is_parse_err "$DEL_ERR"; then _fail "(AC6) dry-run DELETE: gh rejeitou flags/endpoint → $DEL_ERR"; else _pass; fi
  # idem o PUT que marca required — prova que -F 'strict=true' (typed) parseia
  PUT_PATH=$(grep -E 'gh api -X PUT' "$YML" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
  PUT_ERR=$(GH_HOST=dryrun.invalid GH_TOKEN=dryrun gh api -X PUT "$PUT_PATH" \
              -F 'strict=true' -f 'checks[][context]=coverage-gate (bash)' 2>&1 || true)
  if _is_parse_err "$PUT_ERR"; then _fail "(AC6) dry-run PUT: gh rejeitou flags/endpoint → $PUT_ERR"; else _pass; fi
else
  _pass; _pass; _pass  # gh ausente no host de teste — literais já validados acima
fi

# ═══════════════════════════════════════════════════════════════════════════
# AC7 — [SUPOSIÇÃO] bash-no-CI registrada como comentário no template
# ═══════════════════════════════════════════════════════════════════════════
assert_contains "$BODY" "SUPOSIÇÃO" "(AC7) registra a suposição bash-no-CI no template"
assert_match "$BODY" "kcov|bashcov" "(AC7) comentário cita kcov/bashcov no runner Linux"

# ═══════════════════════════════════════════════════════════════════════════
# Integração — /coverage-init copia o template agora que ele existe (US-02 §5)
# ═══════════════════════════════════════════════════════════════════════════
if [ -x "$INIT" ]; then
  TGT=$(mktemp -d)
  git -C "$TGT" init -q
  : > "$TGT/a.sh"; : > "$TGT/b.sh"
  COVERAGE_INIT_KCOV="/nonexistent" "$INIT" --target "$TGT" >/dev/null 2>&1; RC=$?
  assert_rc "$RC" 0 "(integ) coverage-init rc=0"
  assert_file "$TGT/.github/workflows/coverage-ci.yml" "(integ) init copia coverage-ci.yml"
  rm -rf "$TGT"
fi

# ── Final report ────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "test_coverage_ci_template.sh: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
echo "  ✓ all assertions green"
exit 0
