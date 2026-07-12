#!/usr/bin/env bash
# test_gate_e3.sh — US-02: Gate E3 extraído para bin/gate-e3.sh com override auditável.
#
# Prova FUNCIONAL (fixtures reais executando o script), não âncora de texto:
#   AC2 — cada trigger T1-T6 dispara exatamente o seu; plano limpo → GATE_E3_CLEAN.
#   AC3 — override válido suprime SÓ o trigger citado (T4 suprimido, T5 segue) e
#         imprime linha de supressão com trigger + motivo.
#   AC4 — marcador sem motivo é inválido → trigger dispara normalmente (fail-closed).
#   AC5 — override de trigger não-disparado em plano limpo é inerte (GATE_E3_CLEAN).
#   AC6 — commands/full-cycle-simple.md invoca o script na Fase 1.5; bloco inline
#         T1-T6 removido; doc de quando emitir o marcador presente (caso 2026-07-02).
#   AC7 — cat-9-base: shebang + set -u; args inválidos → usage em stderr + exit 2;
#         executável; flags-file ausente tolerado (semântica do 2>/dev/null original);
#         idempotência (2ª execução converge).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE="$REPO_ROOT/bin/gate-e3.sh"
FCS="$REPO_ROOT/commands/full-cycle-simple.md"

TMP="$(mktemp -d -t gate_e3.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_rc()          { [ "$1" -eq "$2" ] && _pass || _fail "$3 :: exit esperado $2, obtido $1"; }
assert_contains()    { printf '%s\n' "$1" | grep -qF -- "$2" && _pass || _fail "$3 :: '$2' ausente"; }
assert_not_contains(){ printf '%s\n' "$1" | grep -qF -- "$2" && _fail "$3 :: '$2' NÃO deveria aparecer" || _pass; }
assert_file_grep()   { grep -qE -- "$2" "$1" && _pass || _fail "$3 :: padrão '$2' ausente em $1"; }
assert_file_nogrep() { grep -qE -- "$2" "$1" && _fail "$3 :: padrão '$2' NÃO deveria aparecer em $1" || _pass; }

OUT=""; ERR=""; RC=0
run_gate() {
  OUT="$(bash "$GATE" "$@" 2>"$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}

echo "=== gate-e3 tests (US-02) ==="

[ -f "$FCS" ] || { echo "FAIL: $FCS inexistente" >&2; exit 1; }

# ── Fixtures ────────────────────────────────────────────────────────────────
cat > "$TMP/clean.md" <<'EOF'
# Plano exemplo
## Fatia 1 — mudança pequena
Prosa neutra descrevendo a mudança, sem termos que disparem o gate.
EOF

cat > "$TMP/t1.md" <<'EOF'
# Plano
## Fatia 1 — a
## Fatia 2 — b
## Fatia 3 — c
## Fatia 4 — d
EOF

cat > "$TMP/t2.md" <<'EOF'
# Plano
## Fatia 1 — x
Precisa de schema migration na base de pedidos.
EOF

cat > "$TMP/t3.md" <<'EOF'
# Plano
## Fatia 1 — x
Rodar npm install left-pad antes de começar.
EOF

cat > "$TMP/t4.md" <<'EOF'
# Plano
## Fatia 1 — x
O plano toca auth de leve.
EOF

cat > "$TMP/t5.md" <<'EOF'
# Plano
## Fatia 1 — x
Arquivos: src/a.ts src/b.ts src/c.py lib/d.go docs/e.md conf/f.json
EOF

echo "HAS_FINANCIAL_COST=true"  > "$TMP/cost-true.flags"
echo "HAS_FINANCIAL_COST=false" > "$TMP/cost-false.flags"

# ── AC7: usage/args inválidos → usage em stderr + exit 2 ──────────────────
run_gate
assert_rc "$RC" 2                       "AC7a sem args → exit 2"
assert_contains "$ERR" "Uso:"           "AC7b sem args → usage em stderr"

run_gate "$TMP/clean.md" "$TMP/cost-false.flags" extra-arg
assert_rc "$RC" 2                       "AC7c 3 args → exit 2"

run_gate "$TMP/nao-existe.md"
assert_rc "$RC" 2                       "AC7d plano inexistente → exit 2"
assert_contains "$ERR" "Uso:"           "AC7e plano inexistente → usage em stderr"

# ── AC7: shebang + set -u + executável ─────────────────────────────────────
if [ -f "$GATE" ]; then
  assert_rc "$(head -1 "$GATE" | grep -c '^#!/usr/bin/env bash')" 1 "AC7f shebang bash"
  assert_file_grep "$GATE" '^set -u' "AC7g set -u presente"
  [ -x "$GATE" ] && _pass || _fail "AC7h gate-e3.sh executável (chmod +x)"
else
  _fail "AC7f-h bin/gate-e3.sh inexistente"
fi

# ── AC2: plano limpo → GATE_E3_CLEAN + exit 0 ──────────────────────────────
run_gate "$TMP/clean.md" "$TMP/cost-false.flags"
assert_rc "$RC" 0                          "AC2-clean exit 0"
assert_contains "$OUT" "GATE_E3_CLEAN"     "AC2-clean stdout GATE_E3_CLEAN"
assert_not_contains "$OUT" "GATE_E3_TRIGGERED" "AC2-clean sem GATE_E3_TRIGGERED"

# ── AC7/cat-9 spec-7: idempotência — 2ª execução converge ─────────────────
OUT1="$OUT"
run_gate "$TMP/clean.md" "$TMP/cost-false.flags"
[ "$OUT" = "$OUT1" ] && _pass || _fail "AC7i idempotência: 2ª execução difere da 1ª"

# ── AC7: flags-file ausente é tolerado (semântica original do 2>/dev/null) ─
run_gate "$TMP/clean.md" "$TMP/flags-que-nao-existe.flags"
assert_rc "$RC" 0                          "AC7j flags ausente tolerado → exit 0"
assert_contains "$OUT" "GATE_E3_CLEAN"     "AC7k flags ausente → GATE_E3_CLEAN"

# ── AC2: cada trigger T1-T6 dispara EXATAMENTE o seu ───────────────────────
check_single_trigger() { # $1=n $2=plan $3=flags(opcional)
  local n="$1" plan="$2" ntrig
  if [ $# -ge 3 ]; then run_gate "$plan" "$3"; else run_gate "$plan"; fi
  assert_rc "$RC" 1                              "AC2-T$n exit 1"
  assert_contains "$OUT" "GATE_E3_TRIGGERED"     "AC2-T$n stdout GATE_E3_TRIGGERED"
  assert_contains "$OUT" "T$n:"                  "AC2-T$n linha 'T$n:' presente"
  ntrig=$(printf '%s\n' "$OUT" | grep -c '^  - T')
  assert_rc "$ntrig" 1                           "AC2-T$n dispara exatamente 1 trigger (obtido $ntrig)"
}
check_single_trigger 1 "$TMP/t1.md"
check_single_trigger 2 "$TMP/t2.md"
check_single_trigger 3 "$TMP/t3.md"
check_single_trigger 4 "$TMP/t4.md"
check_single_trigger 5 "$TMP/t5.md"
check_single_trigger 6 "$TMP/clean.md" "$TMP/cost-true.flags"

# ── AC3: override válido suprime SÓ o trigger citado ───────────────────────
cat > "$TMP/t45-override.md" <<'EOF'
# Plano
## Fatia 1 — x
O plano menciona auth como tema do texto.
Arquivos: src/a.ts src/b.ts src/c.py lib/d.go docs/e.md conf/f.json
<!-- gate-e3-override: T4 payload textual, não toca auth -->
EOF
run_gate "$TMP/t45-override.md"
assert_rc "$RC" 1                                       "AC3a T5 ainda dispara → exit 1"
assert_contains "$OUT" "GATE_E3_TRIGGERED"              "AC3b GATE_E3_TRIGGERED presente"
assert_contains "$OUT" "T5:"                            "AC3c T5 na lista"
assert_not_contains "$OUT" "  - T4:"                    "AC3d T4 FORA da lista (suprimido)"
assert_contains "$OUT" "GATE_E3_SUPPRESSED: T4"         "AC3e linha de supressão cita T4"
assert_contains "$OUT" "payload textual, não toca auth" "AC3f linha de supressão cita o motivo"

# ── AC4: marcador sem motivo é inválido → fail-closed ──────────────────────
cat > "$TMP/t4-invalid.md" <<'EOF'
# Plano
## Fatia 1 — x
O plano toca auth de leve.
<!-- gate-e3-override: T4 -->
EOF
run_gate "$TMP/t4-invalid.md"
assert_rc "$RC" 1                               "AC4a marcador sem motivo → T4 dispara (exit 1)"
assert_contains "$OUT" "T4:"                    "AC4b T4 na lista de triggers"
assert_not_contains "$OUT" "GATE_E3_SUPPRESSED" "AC4c sem linha de supressão"

# motivo só-whitespace também é inválido
cat > "$TMP/t4-invalid-ws.md" <<'EOF'
# Plano
## Fatia 1 — x
O plano toca auth de leve.
<!-- gate-e3-override: T4     -->
EOF
run_gate "$TMP/t4-invalid-ws.md"
assert_rc "$RC" 1                               "AC4d motivo whitespace-only → T4 dispara"
assert_contains "$OUT" "T4:"                    "AC4e T4 na lista de triggers"

# ── AC5: override de trigger não-disparado é inerte ────────────────────────
cat > "$TMP/clean-override.md" <<'EOF'
# Plano exemplo
## Fatia 1 — mudança pequena
Prosa neutra descrevendo a mudança.
<!-- gate-e3-override: T2 motivo qualquer registrado no plano -->
EOF
run_gate "$TMP/clean-override.md"
assert_rc "$RC" 0                            "AC5a override inerte → exit 0"
assert_contains "$OUT" "GATE_E3_CLEAN"       "AC5b GATE_E3_CLEAN presente"

# ── FIX code-review 2026-07-02: marcador aninhado no motivo não suprime o
# trigger errado (sed greedy ancorado — verifier reproduziu tn=2 p/ override
# de T4 cujo motivo continha 'gate-e3-override: T2') ─────────────────────────
cat > "$TMP/t4-nested.md" <<'EOF'
# Plano
## Fatia 1 — x
O plano toca auth de leve.
Precisa de schema migration na base de pedidos.
<!-- gate-e3-override: T4 mesmo racional do gate-e3-override: T2 acima -->
EOF
run_gate "$TMP/t4-nested.md"
assert_rc "$RC" 1                                "FIXn-a T2 ainda dispara → exit 1"
assert_contains "$OUT" "T2:"                     "FIXn-b T2 na lista (NÃO suprimido pelo motivo aninhado)"
assert_contains "$OUT" "GATE_E3_SUPPRESSED: T4"  "FIXn-c supressão registrada para T4 (o marcador real)"
assert_not_contains "$OUT" "  - T4:"             "FIXn-d T4 fora da lista"

# ── FIX code-review 2026-07-02: T6 (P11e, custo financeiro) NÃO é suprimível
# — gate humano de custo é classe segurança; override vira aviso + trigger ──
cat > "$TMP/t6-override.md" <<'EOF'
# Plano exemplo
## Fatia 1 — mudança pequena
Prosa neutra descrevendo a mudança.
<!-- gate-e3-override: T6 custo é apenas mencionado no texto -->
EOF
run_gate "$TMP/t6-override.md" "$TMP/cost-true.flags"
assert_rc "$RC" 1                                "FIXt6-a T6 dispara mesmo com override (exit 1)"
assert_contains "$OUT" "T6:"                     "FIXt6-b T6 na lista"
assert_not_contains "$OUT" "GATE_E3_SUPPRESSED: T6" "FIXt6-c sem supressão de T6"
assert_contains "$ERR" "T6"                      "FIXt6-d stderr avisa que T6 não é suprimível"

# ── AC6: full-cycle-simple.md invoca o script; bloco inline removido ───────
assert_file_grep   "$FCS" 'bash \$HOME/Projects/dotclaude/bin/gate-e3\.sh' "AC6a Fase 1.5 invoca bin/gate-e3.sh por path absoluto"
assert_file_nogrep "$FCS" 'TRIGGERS\+=\('                                  "AC6b bloco shell inline T1-T6 removido"
assert_file_nogrep "$FCS" 'grep -ciE'                                      "AC6c contagem inline de fatias removida"
assert_file_grep   "$FCS" 'gate-e3-override'                               "AC6d doc do marcador de override presente"
assert_file_grep   "$FCS" '2026-07-02'                                     "AC6e caso real de falso-positivo textual citado"

echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:$FAILED"
  exit 1
fi
exit 0
