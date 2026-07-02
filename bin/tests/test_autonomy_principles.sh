#!/usr/bin/env bash
set -u

# test_autonomy_principles.sh — trava a semântica dos princípios de autonomia
# em CLAUDE.global.md (US-01/US-02 do ciclo p5-p15-autonomia; plano-fonte
# .claude/plans/2026-07-01T22-01-22Z-p5-p15-autonomia.md, item R2 do relatório
# de interrupções).
#
# Por que existe: a medição 2026-07-01 (504 interrupções/15d) mostrou que o P5
# antigo ("termina com dúvidas não resolvidas") incentivava fechar turnos
# perguntando. O texto será editado por sessões futuras; este teste afirma as
# âncoras do P5 novo (presença) E a frase antiga (ausência), no idiom da suíte:
# contadores PASS/FAIL, exit != 0 em falha, descoberto por run-all.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GLOBAL_MD="$REPO_ROOT/CLAUDE.global.md"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
# assert_present <file> <fixed-string> <label> — grep -F casa → pass.
assert_present() {
  if grep -qF -- "$2" "$1"; then _pass
  else _fail "$3 :: '$2' AUSENTE de $(basename "$1")"; fi
}
# assert_absent <file> <fixed-string> <label> — grep -F NÃO casa → pass.
assert_absent() {
  if grep -qF -- "$2" "$1"; then
    _fail "$3 :: '$2' PRESENTE em $(basename "$1") (não deveria)"
  else _pass; fi
}

# ─── Pré-condição: fonte-da-verdade existe ───────────────────────────────────
[[ -f "$GLOBAL_MD" ]] || { echo "FAIL: $GLOBAL_MD inexistente" >&2; exit 1; }

# ─── P5 novo: âncoras de presença (AC3) ──────────────────────────────────────
assert_present "$GLOBAL_MD" "registro de incerteza, não pedido de decisão" \
  "P5 âncora 'registro de incerteza, não pedido de decisão'"
assert_present "$GLOBAL_MD" "ação default já tomada" \
  "P5 âncora 'ação default já tomada'"
assert_present "$GLOBAL_MD" "gatilhos (a)–(e) do P15" \
  "P5 âncora 'gatilhos (a)–(e) do P15'"

# ─── P5 novo: origem rastreável no próprio texto (AC5) ───────────────────────
assert_present "$GLOBAL_MD" "medição 2026-07-01" \
  "P5 cita origem 'medição 2026-07-01'"

# ─── P5 antigo: frase-gate ausente (AC4) ─────────────────────────────────────
assert_absent "$GLOBAL_MD" "termina com dúvidas não resolvidas e grau de confiança" \
  "frase antiga do P5 removida"

# ─── P15 emendado: as 3 violações nomeadas (US-02 AC1) ───────────────────────
assert_present "$GLOBAL_MD" "merge sem perguntar" \
  "P15 âncora (i) 'merge sem perguntar'"
assert_present "$GLOBAL_MD" "empacotar + sync é parte da tarefa" \
  "P15 âncora (ii) 'empacotar + sync é parte da tarefa'"
assert_present "$GLOBAL_MD" "recomendação redigida = próximo passo" \
  "P15 âncora (iii) 'recomendação redigida = próximo passo'"

# ─── P15 emendado R4: gates residuais → AskUserQuestion em batch ─────────────
# Origem: R4 de ~/analise-interrupcoes/autonomia-recomendacoes.md — onde a
# pergunta é legítima (gates a–e), trocar prosa por AskUserQuestion estruturada,
# em batch (até 4), recomendada em 1º, máx. 1 turno de perguntas por fase; a
# rubrica do auto-grill-me vale também na execução, não só no planejamento.
assert_present "$GLOBAL_MD" "AskUserQuestion" \
  "P15 R4 âncora 'AskUserQuestion' (formato estruturado nos gates legítimos)"
assert_present "$GLOBAL_MD" "1 turno de perguntas por fase" \
  "P15 R4 âncora 'máx. 1 turno de perguntas por fase' (batch)"
assert_present "$GLOBAL_MD" "vale também na execução" \
  "P15 R4 âncora 'rubrica vale também na execução'"

# ─── P15 termina citando o backstop autonomy-guard.sh (US-03 AC4) ───────────
assert_present "$GLOBAL_MD" '(Backstop determinístico: hook `autonomy-guard.sh`.)' \
  "P15 âncora backstop autonomy-guard.sh"
P15_LINE="$(grep -E '^15\. ' "$GLOBAL_MD" || true)"
case "$P15_LINE" in
  *'(Backstop determinístico: hook `autonomy-guard.sh`.)') _pass ;;
  *) _fail "P15 TERMINA com o backstop :: fim da linha 15 não cita autonomy-guard.sh" ;;
esac

# ─── Teto de tamanho: proxy folgado do DoD b3 (US-02 AC2) ────────────────────
WORDS=$(wc -w < "$GLOBAL_MD" | tr -d ' ')
if [ "$WORDS" -le 1500 ]; then _pass
else _fail "teto de tamanho :: CLAUDE.global.md tem $WORDS palavras (> 1500)"; fi

# ─── Sumário ─────────────────────────────────────────────────────────────────
echo "test_autonomy_principles: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Falhas:$FAILED" >&2
  exit 1
fi
exit 0
