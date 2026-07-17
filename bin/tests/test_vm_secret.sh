#!/usr/bin/env bash
set -u

# test_vm_secret.sh — cola um secret do clipboard do Mac no ~/Projects/.env da VM.
#
# Cobre os acceptance criteria automatizáveis de "vm-secret.sh":
#   AC1 — validação de args: KEY casa ^[A-Za-z_][A-Za-z0-9_]*$; VM ∈ {1,2}
#         (default 1); violação → usage/erro em stderr + exit != 0, SEM tocar ssh.
#   AC2 — clipboard vazio ou multi-linha → erro + exit != 0, SEM tocar ssh (inf6).
#   AC3 — anti-vazamento: o valor NUNCA aparece no argv do ssh (inf1) nem no
#         stdout do script (inf2); vai por STDIN (prova positiva) e o stdout só
#         mostra a máscara last-4.
#   AC4 — argv do ssh: destino EXATO dev@<ip> (1→.4, 2→.2), BatchMode=yes.
#   AC5 — rc do ssh propaga: ssh falha → script sai != 0 (inf3).
#   AC6 — upsert idempotente + chmod 600 no .env "remoto" (inf4/inf5): 2ª execução
#         do mesmo KEY substitui a linha (não duplica); arquivo fica 0600.
#   AC7 — bash -n limpo + script executável.
#
# Estratégia: dois seams. VM_SECRET_PBPASTE aponta pra um stub que emite $PB_OUT.
# VM_SECRET_SSH aponta pra um stub que (a) loga o argv, (b) captura o stdin (o
# secret) e (c) SIMULA o remoto: roda o último arg (o comando remoto) com
# HOME=$FAKE_HOME, alimentando o stdin capturado — assim o upsert real é exercido
# contra um .env sandbox, sem VM de verdade.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/vm-secret.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }

assert_rc()    { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_rc_ne() { [ "$1" != "$2" ] && _pass || _fail "$3 :: rc não deveria ser $2"; }
assert_grep()  { grep -qF -- "$2" "$1" && _pass || _fail "$3 :: texto '$2' ausente em:
$(cat "$1")"; }
assert_no_grep() { grep -qF -- "$2" "$1" && _fail "$3 :: texto '$2' PRESENTE (não deveria) em:
$(cat "$1")" || _pass; }
assert_argv_exact() {
  local log="$1" label="$2"; shift 2
  printf '%s\n' "$@" > "$TMP/expected-argv.txt"
  if diff -q "$TMP/expected-argv.txt" "$log" >/dev/null 2>&1; then _pass; else _fail "$label :: argv != esperado:
--- esperado
$(cat "$TMP/expected-argv.txt")
--- obtido
$(cat "$log")"; fi
}
assert_no_ssh()  { [ ! -f "$SSH_ARGV_LOG" ] && _pass || _fail "$1 :: ssh foi chamado (não deveria); argv:
$(cat "$SSH_ARGV_LOG")"; }
assert_file_grep() { grep -qF -- "$2" "$1" 2>/dev/null && _pass || _fail "$3 :: '$2' ausente em $1:
$(cat "$1" 2>/dev/null)"; }
assert_count()   { local n; n=$(grep -cE -- "$2" "$1" 2>/dev/null || true); [ "$n" = "$3" ] && _pass || _fail "$4 :: esperado $3 linhas '$2' em $1, got $n:
$(cat "$1" 2>/dev/null)"; }

[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT inexistente (esperado na raiz do repo)" >&2; exit 1; }

TMP="$(mktemp -d -t vm-secret.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

SSH_ARGV_LOG="$TMP/ssh-argv.log"
SSH_STDIN_CAP="$TMP/ssh-stdin.cap"
SSH_REMOTE_OUT="$TMP/ssh-remote.out"
export SSH_ARGV_LOG SSH_STDIN_CAP SSH_REMOTE_OUT

# ── Stubs ─────────────────────────────────────────────────────────────────────
PB_STUB="$TMP/pbpaste-stub.sh"
cat > "$PB_STUB" <<'EOF'
#!/bin/bash
printf '%s' "${PB_OUT-}"
EOF
chmod +x "$PB_STUB"

SSH_STUB="$TMP/ssh-stub.sh"
cat > "$SSH_STUB" <<'EOF'
#!/bin/bash
: > "$SSH_ARGV_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$SSH_ARGV_LOG"; done
cat > "$SSH_STDIN_CAP"
# simula o remoto: último arg = comando remoto; roda com HOME sandbox e o
# stdin capturado (o secret) realimentado.
HOME="$FAKE_HOME" bash -c "${@: -1}" < "$SSH_STDIN_CAP" > "$SSH_REMOTE_OUT" 2>&1
rc=$?
exit "${SSH_FORCE_RC:-$rc}"
EOF
chmod +x "$SSH_STUB"

export VM_SECRET_PBPASTE="$PB_STUB" VM_SECRET_SSH="$SSH_STUB"

OUT="$TMP/out.txt"
fresh_home() { FAKE_HOME="$(mktemp -d "$TMP/home.XXXXXX")"; export FAKE_HOME; }

run() {  # run <args...> ; usa $PB_OUT, $SSH_FORCE_RC (opcionais)
  rm -f "$SSH_ARGV_LOG" "$SSH_STDIN_CAP" "$SSH_REMOTE_OUT"
  SSH_FORCE_RC="${SSH_FORCE_RC-}" bash "$SCRIPT" "$@" >"$OUT" 2>&1
}

# ── AC1: validação de args (SEM efeito colateral) ─────────────────────────────
fresh_home
PB_OUT="algum-secret-valido-1234"; export PB_OUT; SSH_FORCE_RC=""

run;                 assert_rc_ne "$?" 0 "AC1a sem args → exit != 0"; assert_no_ssh "AC1a sem ssh"
run "";              assert_rc_ne "$?" 0 "AC1b KEY vazio";            assert_no_ssh "AC1b sem ssh"
run "1abc";          assert_rc_ne "$?" 0 "AC1c KEY começa com dígito"; assert_no_ssh "AC1c sem ssh"
run "foo-bar";       assert_rc_ne "$?" 0 "AC1d KEY com hífen";        assert_no_ssh "AC1d sem ssh"
run 'foo;rm';        assert_rc_ne "$?" 0 "AC1e KEY com metachar";     assert_no_ssh "AC1e sem ssh"
run "GH_TOKEN" 3;    assert_rc_ne "$?" 0 "AC1f VM inválida (3)";      assert_no_ssh "AC1f sem ssh"
run "GH_TOKEN" 0;    assert_rc_ne "$?" 0 "AC1g VM inválida (0)";      assert_no_ssh "AC1g sem ssh"
run "GH_TOKEN" 1 x;  assert_rc_ne "$?" 0 "AC1h arg extra";           assert_no_ssh "AC1h sem ssh"
# usage completo em stderr (não só rc) — regressão de mensagem parcial
run; assert_grep "$OUT" "Uso:" "AC1i usage tem 'Uso:'"

# ── AC2: clipboard vazio / multi-linha → erro, sem ssh (inf6) ─────────────────
fresh_home
PB_OUT=""; export PB_OUT
run "GH_TOKEN" 1; assert_rc_ne "$?" 0 "AC2a clipboard vazio → exit != 0"; assert_no_ssh "AC2a sem ssh"
PB_OUT=$'linha1\nlinha2'; export PB_OUT
run "GH_TOKEN" 1; assert_rc_ne "$?" 0 "AC2b clipboard multi-linha → exit != 0"; assert_no_ssh "AC2b sem ssh"

# ── AC3+AC4: happy path — anti-vazamento + argv + escrita remota ──────────────
# Secret com / + = & _ pra provar que não passa por sed/argv nem quebra quoting.
fresh_home
SECRET='aA1/bB2+cC3=dD4&eE5_end'; export SECRET
PB_OUT="$SECRET"; export PB_OUT; SSH_FORCE_RC=""
run "GH_TOKEN" 1; RC=$?
assert_rc "$RC" 0 "AC3 happy path rc=0"
# inf1: valor NUNCA no argv do ssh
assert_no_grep "$SSH_ARGV_LOG" "$SECRET" "AC3a secret AUSENTE do argv do ssh (inf1)"
# prova positiva: o valor foi por STDIN (senão o assert de ausência é vazio)
assert_file_grep "$SSH_STDIN_CAP" "$SECRET" "AC3b secret PRESENTE no stdin do ssh (prova o canal)"
# inf2: valor NUNCA no stdout; só a máscara last-4 aparece
assert_no_grep "$OUT" "$SECRET" "AC3c secret AUSENTE do stdout (inf2)"
assert_grep "$OUT" "..._end" "AC3d stdout mostra máscara last-4 (prova que mascarou)"
# AC4: destino exato + BatchMode
assert_grep "$SSH_ARGV_LOG" "dev@192.0.2.11" "AC4a argv tem destino VM1 (.4)"
assert_grep "$SSH_ARGV_LOG" "BatchMode=yes"     "AC4b argv tem BatchMode=yes"
# escrita remota: .env sandbox recebeu KEY=valor
assert_file_grep "$FAKE_HOME/Projects/.env" "GH_TOKEN=$SECRET" "AC4c .env remoto tem GH_TOKEN=<secret>"

# VM2 → .2
fresh_home; PB_OUT="$SECRET"; export PB_OUT
run "GH_TOKEN" 2; assert_rc "$?" 0 "AC4 vm2 rc=0"
assert_grep "$SSH_ARGV_LOG" "dev@192.0.2.12" "AC4d argv tem destino VM2 (.2)"

# default de VM = 1 (só KEY)
fresh_home; PB_OUT="$SECRET"; export PB_OUT
run "GH_TOKEN"; assert_rc "$?" 0 "AC4 default vm rc=0"
assert_grep "$SSH_ARGV_LOG" "dev@192.0.2.11" "AC4e sem VM → default VM1 (.4)"

# ── AC5: rc do ssh propaga (inf3) ─────────────────────────────────────────────
fresh_home; PB_OUT="$SECRET"; export PB_OUT
SSH_FORCE_RC=255
run "GH_TOKEN" 1; assert_rc_ne "$?" 0 "AC5 ssh falha → script sai != 0 (inf3)"
SSH_FORCE_RC=""

# ── AC6: upsert idempotente + chmod 600 (inf4/inf5) ───────────────────────────
fresh_home
PB_OUT="valor-antigo-0000"; export PB_OUT
run "GH_TOKEN" 1; assert_rc "$?" 0 "AC6 1ª escrita rc=0"
PB_OUT="valor-novo-9999"; export PB_OUT
run "GH_TOKEN" 1; assert_rc "$?" 0 "AC6 2ª escrita rc=0"
ENVF="$FAKE_HOME/Projects/.env"
assert_count "$ENVF" '^GH_TOKEN=' "1" "AC6a KEY aparece 1x após 2 escritas (upsert, não duplica)"
assert_file_grep "$ENVF" "GH_TOKEN=valor-novo-9999" "AC6b .env tem o valor NOVO"
assert_no_grep   "$ENVF" "valor-antigo-0000"        "AC6c valor antigo foi substituído"
# preserva outras chaves no upsert
fresh_home; ENVF="$FAKE_HOME/Projects/.env"; mkdir -p "$FAKE_HOME/Projects"
printf 'OUTRA=preservar\n' > "$ENVF"
PB_OUT="xyz-token-777"; export PB_OUT
run "GH_TOKEN" 1; assert_rc "$?" 0 "AC6 escrita c/ chave pré-existente rc=0"
assert_file_grep "$ENVF" "OUTRA=preservar"   "AC6d upsert preserva outras chaves"
assert_file_grep "$ENVF" "GH_TOKEN=xyz-token-777" "AC6e upsert adiciona a nova chave"
# chmod 600
PERM="$(stat -c '%a' "$ENVF" 2>/dev/null || stat -f '%Lp' "$ENVF" 2>/dev/null)"
[ "$PERM" = "600" ] && _pass || _fail "AC6f .env remoto deveria ser 600, got '$PERM'"

# ── AC7: bash -n + executável ─────────────────────────────────────────────────
if bash -n "$SCRIPT" 2>/dev/null; then _pass; else _fail "AC7a bash -n falhou em $SCRIPT"; fi
[ -x "$SCRIPT" ] && _pass || _fail "AC7b $SCRIPT não é executável (chmod +x)"
# o fonte NUNCA EXECUTA 'set -x' (vazaria o valor no trace). Ancorado em início
# de linha de comando — menção em comentário ("proíbe set -x") não conta.
if grep -qE '^[[:space:]]*set[[:space:]]+-[a-wyz]*x([[:space:]]|$)' "$SCRIPT"; then _fail "AC7c $SCRIPT executa set -x (vaza secret no trace)"; else _pass; fi

# ── Resultado ─────────────────────────────────────────────────────────────────
echo "test_vm_secret.sh: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "FALHAS:$FAILED" >&2
  exit 1
fi
