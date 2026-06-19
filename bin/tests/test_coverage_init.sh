#!/usr/bin/env bash
# bin/tests/test_coverage_init.sh — US-02 /coverage-init.
#
# Cobre bin/coverage-init.sh: detecção de linguagem dominante por contagem de
# extensões (fixtures Python/JS/bash/Liquid), cópia idempotente do template de
# config, criação de .coverage-baseline.json (total medido via seam), probe de
# kcov no host (AC7) e idempotência ponta-a-ponta. Também valida o frontmatter
# de commands/coverage-init.md (AC1).
#
# Capture-proof: asserções sobre conteúdo de arquivos e output real, não só rc.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$BIN_DIR/.." && pwd)"
INIT="$BIN_DIR/coverage-init.sh"
CMD_MD="$REPO_DIR/commands/coverage-init.md"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_rc()           { [ "$1" = "$2" ] && _pass || _fail "$3 :: rc=$2 esperado, got $1"; }
assert_contains()     { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' não em output";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' presente, deveria não estar";; *) _pass;; esac; }
assert_file()         { [ -f "$1" ] && _pass || _fail "$2 :: arquivo '$1' ausente"; }
assert_no_file()      { [ -f "$1" ] && _fail "$2 :: arquivo '$1' presente, deveria não estar" || _pass; }

# ── fixture: cria um projeto-alvo com N arquivos de uma extensão ─────────────
make_fixture() {
  # $1 = ext (sem ponto), $2 = quantos. Cria git repo mínimo.
  local ext="$1" n="$2" i
  TARGET=$(mktemp -d)
  git -C "$TARGET" init -q
  i=0
  while [ "$i" -lt "$n" ]; do
    : > "$TARGET/file_$i.$ext"
    i=$((i+1))
  done
}
teardown() { [ -n "${TARGET:-}" ] && rm -rf "$TARGET"; unset TARGET; }

run_init() { ( cd "$TARGET" && "$INIT" "$@" 2>&1 ); }

# ═══════════════════════════════════════════════════════════════════════════
# AC1 — frontmatter da command: allowed-tools explícito (não wildcard) + hint
# ═══════════════════════════════════════════════════════════════════════════
assert_file "$CMD_MD" "(AC1) commands/coverage-init.md existe"
if [ -f "$CMD_MD" ]; then
  FM=$(awk 'NR==1&&/^---/{p=1;next} /^---/{if(p)exit} p' "$CMD_MD")
  assert_contains "$FM" "allowed-tools:" "(AC1) declara allowed-tools"
  assert_contains "$FM" "argument-hint:" "(AC1) declara argument-hint"
  # não pode ser wildcard total (allowed-tools: * ou Bash(*) sozinho)
  AT_LINE=$(printf '%s\n' "$FM" | grep '^allowed-tools:')
  case "$AT_LINE" in
    "allowed-tools: *"|"allowed-tools: Bash(*)") _fail "(AC1) allowed-tools é wildcard total" ;;
    *) _pass ;;
  esac
fi

# ═══════════════════════════════════════════════════════════════════════════
# AC5 — supply-chain: bypass granular documentado + SEM wrapper/subshell
#   (a) bypass granular de cooldown + REASON obrigatório estão documentados;
#   (b) install usa --ignore-scripts (P13b);
#   (c) o arquivo NÃO contém um install via wrapper/subshell (`bash -c "npm install`)
#       — driblar o gate é proibido (P13). A prosa descreve o anti-padrão de forma
#       genérica, sem embutir o comando literal.
# ═══════════════════════════════════════════════════════════════════════════
if [ -f "$CMD_MD" ]; then
  CMD_BODY=$(cat "$CMD_MD")
  assert_contains "$CMD_BODY" "CLAUDE_SC_BYPASS_COOLDOWN" "(AC5) documenta bypass granular de cooldown"
  assert_contains "$CMD_BODY" "CLAUDE_SC_REASON" "(AC5) exige CLAUDE_SC_REASON no bypass"
  assert_contains "$CMD_BODY" "--ignore-scripts" "(AC5) install usa --ignore-scripts (P13b)"
  assert_not_contains "$CMD_BODY" 'bash -c "npm install' "(AC5) NÃO usa wrapper/subshell pra driblar o gate"
  assert_not_contains "$CMD_BODY" 'eval $(npm' "(AC5) NÃO usa eval pra driblar o gate"
fi

# ═══════════════════════════════════════════════════════════════════════════
# AC5/robustez — o script é space-safe: --target com espaços NÃO sofre word-split
#   (regressão do finding de review sobre $ARGUMENTS / paths com espaço)
# ═══════════════════════════════════════════════════════════════════════════
SPACEPARENT=$(mktemp -d)
SPACEDIR="$SPACEPARENT/dir with spaces"
mkdir -p "$SPACEDIR"
git -C "$SPACEDIR" init -q
: > "$SPACEDIR/a.py"; : > "$SPACEDIR/b.py"
OUT=$("$INIT" --target "$SPACEDIR" 2>&1); RC=$?
assert_rc "$RC" 0 "(space) --target com espaços rc=0 (sem word-split)"
assert_contains "$OUT" "python" "(space) detecta lang em path com espaços"
assert_file "$SPACEDIR/.coveragerc" "(space) copia config em path com espaços"
rm -rf "$SPACEPARENT"

# ═══════════════════════════════════════════════════════════════════════════
# AC2 — detecção Python → copia .coveragerc
# ═══════════════════════════════════════════════════════════════════════════
make_fixture py 5
OUT=$(run_init); RC=$?
assert_rc "$RC" 0 "(AC2-py) rc=0"
assert_contains "$OUT" "python" "(AC2-py) reporta lang python"
assert_file "$TARGET/.coveragerc" "(AC2-py) copia .coveragerc"
assert_no_file "$TARGET/.c8rc.json" "(AC2-py) NÃO copia config de outra lang"
# P0-2: vendora coverage-gate.sh em scripts/ci/ do target (sem isso o CI dá
# exit 127 no consumer e trava merge). Co-presente: o .coveragerc acima prova
# que o init de fato rodou neste target.
assert_file "$TARGET/scripts/ci/coverage-gate.sh" "(P0-2) vendora coverage-gate.sh em scripts/ci/"
if [ -x "$TARGET/scripts/ci/coverage-gate.sh" ]; then _pass; else _fail "(P0-2) gate vendorado é executável"; fi
# V2: o CI gerado é parametrizado pela linguagem DETECTADA (python), não bash.
CI=$(cat "$TARGET/.github/workflows/coverage-ci.yml" 2>/dev/null)
assert_contains "$CI" "--lang python" "(V2) CI gerado usa --lang python (linguagem detectada)"
assert_not_contains "$CI" "__LANG__"  "(V2) placeholder __LANG__ totalmente substituído"
# o gate ATIVO (linha não-comentada) roda --lang python, não bash. Comentários
# do template podem citar '--lang bash' (doc) — só a invocação ativa importa.
GATE_RUN=$(printf '%s\n' "$CI" | grep 'coverage-gate.sh --gate' | grep -vE '^[[:space:]]*#')
assert_contains "$GATE_RUN" "--lang python" "(V2) invocação ativa do gate roda --lang python"
assert_not_contains "$GATE_RUN" "bash" "(V2) invocação ativa NÃO é bash num projeto Python"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# V1 — projeto com [tool.coverage] no pyproject: NÃO criar .coveragerc (shadow)
# ═══════════════════════════════════════════════════════════════════════════
make_fixture py 5
printf '[tool.coverage.run]\nsource = ["app"]\n' > "$TARGET/pyproject.toml"
OUT=$(run_init); RC=$?
assert_rc "$RC" 0 "(V1) rc=0"
assert_no_file "$TARGET/.coveragerc" "(V1) NÃO cria .coveragerc (evita shadow do pyproject)"
assert_contains "$OUT" "evita shadow" "(V1) reporta que pulou .coveragerc"
# co-presente: o gate vendorado prova que o init rodou até o fim (não abortou)
assert_file "$TARGET/scripts/ci/coverage-gate.sh" "(V1) init rodou completo (gate vendorado presente)"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# AC2 — detecção JS → copia .c8rc.json
# ═══════════════════════════════════════════════════════════════════════════
make_fixture js 5
OUT=$(run_init); RC=$?
assert_rc "$RC" 0 "(AC2-js) rc=0"
assert_contains "$OUT" "js" "(AC2-js) reporta lang js"
assert_file "$TARGET/.c8rc.json" "(AC2-js) copia .c8rc.json"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# AC2 — detecção bash → copia .simplecov  +  AC7 probe kcov + bashcov line-only
# ═══════════════════════════════════════════════════════════════════════════
make_fixture sh 5
# força kcov "ausente" via seam apontando para binário inexistente
OUT=$(COVERAGE_INIT_KCOV="/nonexistent/kcov-xyz" run_init); RC=$?
assert_rc "$RC" 0 "(AC2-bash) rc=0"
assert_contains "$OUT" "bash" "(AC2-bash) reporta lang bash"
assert_file "$TARGET/.simplecov" "(AC2-bash) copia .simplecov"
assert_contains "$OUT" "branch=n/a" "(AC7) declara bash branch=n/a (line-only)"
assert_contains "$OUT" "kcov" "(AC7) registra probe de kcov"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# AC2 — detecção Liquid → copia .c8rc.json (harness liquid)
# ═══════════════════════════════════════════════════════════════════════════
make_fixture liquid 5
OUT=$(run_init); RC=$?
assert_rc "$RC" 0 "(AC2-liquid) rc=0"
assert_contains "$OUT" "liquid" "(AC2-liquid) reporta lang liquid"
assert_file "$TARGET/.c8rc.json" "(AC2-liquid) copia .c8rc.json"
teardown

# ═══════════════════════════════════════════════════════════════════════════
# AC4 — baseline criado com total medido (via seam) na 1a execução
# ═══════════════════════════════════════════════════════════════════════════
make_fixture py 3
OUT=$(COVERAGE_INIT_MEASURED_TOTAL="42.50" run_init); RC=$?
assert_rc "$RC" 0 "(AC4) rc=0"
assert_file "$TARGET/.coverage-baseline.json" "(AC4) cria .coverage-baseline.json"
BL=$(cat "$TARGET/.coverage-baseline.json")
assert_contains "$BL" "42.5" "(AC4) baseline grava total medido (42.5)"
assert_contains "$BL" "python" "(AC4) baseline registra a linguagem"
# coverage-gate.sh lê .total via jq — o campo precisa existir
if command -v jq >/dev/null 2>&1; then
  T=$(jq -r '.total' "$TARGET/.coverage-baseline.json")
  assert_contains "$T" "42.5" "(AC4) jq .total legível por coverage-gate.sh"
fi
teardown

# ═══════════════════════════════════════════════════════════════════════════
# AC3 — idempotência: 2a execução converge ao mesmo estado
# ═══════════════════════════════════════════════════════════════════════════
make_fixture py 3
OUT1=$(COVERAGE_INIT_MEASURED_TOTAL="10" run_init); RC1=$?
# muda o baseline para um valor ratcheted (simula ciclo que subiu cobertura)
printf '{\n  "total": 80,\n  "lang": "python"\n}\n' > "$TARGET/.coverage-baseline.json"
# 2a execução com OUTRO total medido NÃO pode sobrescrever baseline existente
OUT2=$(COVERAGE_INIT_MEASURED_TOTAL="11" run_init); RC2=$?
assert_rc "$RC1" 0 "(AC3) 1a execução rc=0"
assert_rc "$RC2" 0 "(AC3) 2a execução rc=0"
BL=$(cat "$TARGET/.coverage-baseline.json")
assert_contains "$BL" "80" "(AC3) baseline ratcheted preservado (não sobrescrito)"
assert_contains "$OUT2" "já" "(AC3) 2a execução reporta estado já existente"
# config não duplicada: ainda exatamente 1 .coveragerc
N=$(find "$TARGET" -maxdepth 1 -name '.coveragerc' | wc -l | tr -d ' ')
assert_contains "$N" "1" "(AC3) .coveragerc não duplicada"
teardown

# ── Final report ────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────"
echo "test_coverage_init.sh: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
echo "  ✓ all assertions green"
exit 0
