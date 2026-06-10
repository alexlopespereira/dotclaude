#!/usr/bin/env bash
set -u

# test_vm_oauth.sh — helper de túnel OAuth das VMs (US-04).
#
# Cobre os acceptance criteria automatizáveis de
# "bin/vm-oauth.sh — túnel ssh -L para callback OAuth das VMs":
#   AC1 — validação de args: vm ∈ {1,2}, porta inteiro em 1024–65535;
#         qualquer violação → usage + exit != 0.
#   AC2 — args válidos + VM_OAUTH_SSH=stub → argv é EXATAMENTE
#         `-N -L <porta>:localhost:<porta> dev@<ip>` (1→.4, 2→.2).
#   AC3 — antes de abrir o túnel, imprime qual VM/porta e que Ctrl-C encerra.
#   AC4 — bash -n limpo + script executável.
#
# Estratégia: VM_OAUTH_SSH aponta para um stub que registra todo o argv
# (uma linha por arg) num log e sai 0 — sem abrir SSH de verdade.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/bin/vm-oauth.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }

assert_rc()      { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_rc_ne()   { [ "$1" != "$2" ] && _pass || _fail "$3 :: rc não deveria ser $2"; }
assert_has()     { grep -qxF -- "$2" "$1" && _pass || _fail "$3 :: linha '$2' ausente em:
$(cat "$1")"; }
assert_grep()    { grep -qiF -- "$2" "$1" && _pass || _fail "$3 :: texto '$2' ausente em:
$(cat "$1")"; }
assert_linecount() { local n; n=$(wc -l <"$1" | tr -d ' '); [ "$n" = "$2" ] && _pass || _fail "$3 :: esperado $2 linhas, got $n:
$(cat "$1")"; }
# assert_argv_exact <logfile> <label> <arg...> — o argv capturado (uma linha por
# arg, na ordem) deve ser EXATAMENTE a sequência passada. Fecha o falso-positivo
# de "mesmos tokens reordenados" (AC2 exige ordem: -N -L fwd destino).
assert_argv_exact() {
  local log="$1" label="$2"; shift 2
  printf '%s\n' "$@" > "$TMP/expected-argv.txt"
  if diff -q "$TMP/expected-argv.txt" "$log" >/dev/null 2>&1; then _pass; else _fail "$label :: argv != esperado:
--- esperado
$(cat "$TMP/expected-argv.txt")
--- obtido
$(cat "$log")"; fi
}

[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT inexistente" >&2; exit 1; }

TMP="$(mktemp -d -t vm-oauth.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

SSH_LOG="$TMP/ssh-argv.log"
SSH_STUB="$TMP/ssh-stub.sh"
cat > "$SSH_STUB" <<'EOF'
#!/bin/bash
: > "$SSH_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$SSH_LOG"; done
exit 0
EOF
chmod +x "$SSH_STUB"

# run <args...> — invoca o script com o stub de ssh, captura stdout+rc.
OUT="$TMP/out.txt"
run() {
  rm -f "$SSH_LOG"
  VM_OAUTH_SSH="$SSH_STUB" SSH_LOG="$SSH_LOG" bash "$SCRIPT" "$@" >"$OUT" 2>&1
}

# ── AC1: validação de argumentos ──────────────────────────────────────────────
# Toda violação deve (a) sair != 0 E (b) imprimir o usage COMPLETO: cabeçalho
# "Uso:", a seção "Fluxo OAuth:" e uma linha de exemplo de comando. Asserir só
# rc ou só a substring "OAuth" deixaria passar uma regressão que imprime
# mensagem parcial sem o usage (finding P1 do review iter-8).
assert_invalid() {  # <rc> <label> <args descrição>
  assert_rc_ne "$1" 0 "$2 → exit != 0"
  assert_grep "$OUT" "Uso:"         "$2 → usage tem cabeçalho 'Uso:'"
  assert_grep "$OUT" "Fluxo OAuth:" "$2 → usage tem seção 'Fluxo OAuth:'"
  assert_grep "$OUT" "1 54231"      "$2 → usage tem linha de exemplo"
}
run;             assert_invalid "$?" "AC1a sem args"
run 1;           assert_invalid "$?" "AC1b só vm sem porta"
run 3 5000;      assert_invalid "$?" "AC1c vm inválida (3)"
run 0 5000;      assert_invalid "$?" "AC1d vm inválida (0)"
run 1 1023;      assert_invalid "$?" "AC1e porta < 1024"
run 1 65536;     assert_invalid "$?" "AC1f porta > 65535"
run 1 abc;       assert_invalid "$?" "AC1g porta não-numérica"
run 1 50.5;      assert_invalid "$?" "AC1h porta decimal"
run 1 5000 extra; assert_invalid "$?" "AC1i arg extra"
# Porta numérica ENORME: passa em ^[0-9]+$ mas estoura a aritmética do test
# ([ -lt ] → "integer expression expected" rc=2, tratado como falso na cadeia
# ||) — sem guarda de comprimento o script seguiria e chamaria o ssh com porta
# inválida (finding P0 do review iter-8).
run 1 999999999999999999999999; assert_invalid "$?" "AC1l porta numérica gigante (overflow)"

# limites válidos não devem ser rejeitados (provam que o range é inclusivo)
run 1 1024; assert_rc "$?" 0 "AC1j porta 1024 (limite inf) válida"
run 2 65535; assert_rc "$?" 0 "AC1k porta 65535 (limite sup) válida"

# ── AC2: argv exato do ssh (ORDEM importa) ────────────────────────────────────
# AC2 exige argv EXATAMENTE `-N -L <porta>:localhost:<porta> dev@<ip>`.
# assert_argv_exact compara a sequência inteira por diff — um argv com os
# mesmos 4 tokens em outra ordem (ex: destino antes do -L) falha aqui.
run 1 5500; assert_rc "$?" 0 "AC2 vm1 rc"
assert_argv_exact "$SSH_LOG" "AC2a vm1 argv exato e ordenado" \
  "-N" "-L" "5500:localhost:5500" "dev@192.0.2.11"

run 2 8123; assert_rc "$?" 0 "AC2 vm2 rc"
assert_argv_exact "$SSH_LOG" "AC2b vm2 argv exato e ordenado (.2)" \
  "-N" "-L" "8123:localhost:8123" "dev@192.0.2.12"

# ── AC3: mensagem antes do túnel ──────────────────────────────────────────────
run 1 5500
assert_grep "$OUT" "192.0.2.11" "AC3a mensagem cita o IP da VM"
assert_grep "$OUT" "5500"         "AC3b mensagem cita a porta"
assert_grep "$OUT" "Ctrl-C"       "AC3c mensagem avisa que Ctrl-C encerra"

# ── AC4: bash -n + executável ─────────────────────────────────────────────────
if bash -n "$SCRIPT" 2>/dev/null; then _pass; else _fail "AC4a bash -n falhou em $SCRIPT"; fi
[ -x "$SCRIPT" ] && _pass || _fail "AC4b $SCRIPT não é executável (chmod +x)"

# ── Resultado ─────────────────────────────────────────────────────────────────
echo "test_vm_oauth.sh: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "FALHAS:$FAILED" >&2
  exit 1
fi
