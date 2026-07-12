#!/usr/bin/env bash
set -u

# test_wrapper_launch.sh — hardening do wrapper-launch.sh (US-03).
#
# Cobre os acceptance criteria automatizáveis da story
# "Hardening do wrapper-launch.sh — --no-sandbox e --headless com gate de OS":
#   AC1 — WRAPPER_OS=Linux, sem google-chrome no PATH, chromium bundled presente
#         → argv do npx contém `--browser chromium` E `--no-sandbox`.
#   AC2 — WRAPPER_OS=Linux + DISPLAY vazio/indefinido → argv contém `--headless`;
#         com DISPLAY=:0 → NÃO contém `--headless`.
#   AC3 — WRAPPER_OS=Darwin sem DISPLAY → argv NÃO contém `--no-sandbox` nem
#         `--headless` (comportamento macOS preservado).
#   AC4 — args extras ($@) repassados ao npx APÓS as flags novas (arg sentinela).
#   AC5 — bash -n limpo + slot/lock inalterados (profile per-slot ainda criado).
#   AC7 — google-chrome REAL instalado (caso runner ubuntu-latest) → --browser
#         chrome, sem --no-sandbox; WRAPPER_CHROME=0 força o cenário chromium.
#   AC8 — sem setsid disponível (caso macOS: util-linux ausente) → wrapper ainda
#         sobe o npx (WRAPPER_SETSID=0 simula no Linux; regressão do rc=127 #115).
#
# Estratégia: stub `npx` no início do PATH captura argv num log (uma linha por
# arg). HOME apontado para sandbox (perfis/locks/fixture chromium isolados).
# `env -i` dá controle sobre DISPLAY. Presença/ausência de google-chrome NÃO é
# controlável por PATH (o runner ubuntu tem /usr/bin/google-chrome real e filtro
# de dir do PATH é proibido — usrmerge): usa o seam WRAPPER_CHROME=0|1. Um stub
# google-chrome fica SEMPRE no PATH pra reproduzir o runner em qualquer máquina.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$REPO_ROOT/skills/browser-actions/wrapper-launch.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }

assert_rc()      { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_has()     { grep -qxF -- "$2" "$1" && _pass || _fail "$3 :: linha '$2' ausente em argv:
$(cat "$1")"; }
assert_hasnot()  { grep -qxF -- "$2" "$1" && _fail "$3 :: linha '$2' NÃO deveria estar em argv:
$(cat "$1")" || _pass; }
assert_dir()     { [ -d "$1" ] && _pass || _fail "$2 :: dir ausente: $1"; }
assert_order()   { # $1=log $2=before $3=after $4=msg
  local lb la
  lb=$(grep -nxF -- "$2" "$1" | head -1 | cut -d: -f1)
  la=$(grep -nxF -- "$3" "$1" | head -1 | cut -d: -f1)
  if [ -n "$lb" ] && [ -n "$la" ] && [ "$lb" -lt "$la" ]; then _pass
  else _fail "$4 :: '$2'(L$lb) não precede '$3'(L$la)"; fi
}

[[ -f "$WRAPPER" ]] || { echo "FAIL: $WRAPPER inexistente" >&2; exit 1; }

TMP="$(mktemp -d -t wrap-launch.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
STUB_DIR="$TMP/bin"
NPX_LOG="$TMP/npx-argv.log"
mkdir -p "$HOME_DIR" "$STUB_DIR"

# Stub npx: registra todo o argv (uma linha por arg) e sai 0.
cat > "$STUB_DIR/npx" <<'EOF'
#!/bin/bash
: > "$NPX_LOG"
for a in "$@"; do printf '%s\n' "$a" >> "$NPX_LOG"; done
exit 0
EOF
chmod +x "$STUB_DIR/npx"

# Stub google-chrome: reproduz o runner ubuntu-latest (google-chrome real em
# /usr/bin) em toda máquina. Os cenários chromium ignoram-no via WRAPPER_CHROME=0.
printf '#!/bin/bash\nexit 0\n' > "$STUB_DIR/google-chrome"
chmod +x "$STUB_DIR/google-chrome"

# Fixture: chromium bundled presente (só o dir precisa existir p/ o glob casar).
mkdir -p "$HOME_DIR/.cache/ms-playwright/chromium-1148/chrome-linux"

# run <os> <display-mode> <chrome:0|1> [VAR=VAL ...] [extra args...]
#   display-mode: "unset" = sem DISPLAY no env; qualquer outro = DISPLAY=<valor>
#   chrome: valor do seam WRAPPER_CHROME (0 = cenário chromium bundled)
#   VAR=VAL: env extra repassada ao wrapper (ex.: WRAPPER_SETSID=0)
run() {
  local os="$1" disp="$2" chrome="$3"; shift 3
  rm -f "$NPX_LOG"
  rm -rf "$HOME_DIR/.claude"   # reset profiles/locks entre runs
  local -a env_args=(HOME="$HOME_DIR" PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
                     CLAUDE_SLOT_NAME=tslot NPX_LOG="$NPX_LOG" WRAPPER_OS="$os"
                     WRAPPER_CHROME="$chrome")
  [ "$disp" != "unset" ] && env_args+=(DISPLAY="$disp")
  while [ $# -gt 0 ] && [[ "$1" == [A-Z_]*=* ]]; do env_args+=("$1"); shift; done
  env -i "${env_args[@]}" bash "$WRAPPER" "$@"
}

# ── AC1: Linux + chromium bundled → --browser chromium E --no-sandbox ──────────
run Linux unset 0; rc=$?
assert_rc "$rc" 0 "AC1 rc"
assert_has "$NPX_LOG" "--browser"   "AC1a --browser flag presente"
assert_has "$NPX_LOG" "chromium"    "AC1b browser é chromium"
assert_has "$NPX_LOG" "--no-sandbox" "AC1c --no-sandbox presente"

# ── AC2: --headless quando DISPLAY vazio/indefinido; ausente com DISPLAY=:0 ────
run Linux unset 0 >/dev/null 2>&1
assert_has "$NPX_LOG" "--headless" "AC2a DISPLAY indefinido → --headless"

run Linux "" 0 >/dev/null 2>&1           # DISPLAY definido mas vazio
assert_has "$NPX_LOG" "--headless" "AC2b DISPLAY vazio → --headless"

run Linux ":0" 0 >/dev/null 2>&1
assert_hasnot "$NPX_LOG" "--headless" "AC2c DISPLAY=:0 → sem --headless"
assert_has    "$NPX_LOG" "--no-sandbox" "AC2d DISPLAY=:0 ainda tem --no-sandbox (Linux)"

# ── AC3: Darwin sem DISPLAY → sem --no-sandbox nem --headless ──────────────────
# Capture-proof PRIMEIRO: assert_hasnot trata grep em log vazio/ausente como pass,
# então um ramo Darwin que retornasse 0 ANTES de chamar npx passaria nos asserts de
# ausência sem nunca ter capturado argv. `--user-data-dir` é emitido em todo ramo/OS
# (wrapper-launch.sh:125), logo sua presença prova que o npx foi de fato invocado.
run Darwin unset 1 >/dev/null 2>&1; rc=$?
assert_rc "$rc" 0 "AC3 rc"
assert_has    "$NPX_LOG" "--user-data-dir" "AC3z Darwin: npx foi invocado (captura válida)"
assert_hasnot "$NPX_LOG" "--no-sandbox" "AC3a Darwin sem --no-sandbox"
assert_hasnot "$NPX_LOG" "--headless"   "AC3b Darwin sem --headless"

# ── AC4: args extras repassados APÓS as flags novas ───────────────────────────
run Linux unset 0 --SENTINEL-XYZ >/dev/null 2>&1
assert_has   "$NPX_LOG" "--SENTINEL-XYZ" "AC4a sentinela repassada ao npx"
assert_order "$NPX_LOG" "--no-sandbox" "--SENTINEL-XYZ" "AC4b --no-sandbox precede sentinela"
assert_order "$NPX_LOG" "--headless"   "--SENTINEL-XYZ" "AC4c --headless precede sentinela"

# ── AC5: bash -n limpo + slot/lock inalterados (profile per-slot criado) ───────
if bash -n "$WRAPPER" 2>/dev/null; then _pass; else _fail "AC5a bash -n falhou em $WRAPPER"; fi
run Linux unset 0 >/dev/null 2>&1
assert_dir "$HOME_DIR/.claude/chrome-profile-tslot" "AC5b profile per-slot resolvido/criado"

# ── AC6: slot ocupado por sessão viva → fallback efêmero, NÃO mata a conexão ───
# Regressão do bug "playwright não funciona em 2 sessões ao mesmo tempo": o lock
# per-slot fazia exit 99 → MCP "Connection closed". Agora a 2ª sessão cai para
# um profile efêmero -pid<N> e segue (rc=0), permitindo browser em paralelo.
rm -f "$NPX_LOG"
rm -rf "$HOME_DIR/.claude"
mkdir -p "$HOME_DIR/.claude/chrome-profile-tslot/.lock"
sleep 60 & LIVE_PID=$!
printf '%s\n' "$LIVE_PID" > "$HOME_DIR/.claude/chrome-profile-tslot/.lock/pid"
env -i HOME="$HOME_DIR" PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
  CLAUDE_SLOT_NAME=tslot NPX_LOG="$NPX_LOG" WRAPPER_OS=Linux \
  bash "$WRAPPER" >/dev/null 2>"$TMP/ac6.err"; rc=$?
kill "$LIVE_PID" 2>/dev/null
assert_rc "$rc" 0 "AC6a slot ocupado não mata conexão (rc=0, não 99)"
assert_has "$NPX_LOG" "--user-data-dir" "AC6b npx foi invocado no fallback"
if grep -qE "chrome-profile-tslot-pid[0-9]+$" "$NPX_LOG"; then _pass
else _fail "AC6c argv deve usar profile efêmero -pid<N>, não o slot ocupado:
$(cat "$NPX_LOG")"; fi
if grep -qi "profile efêmero" "$TMP/ac6.err"; then _pass
else _fail "AC6d aviso de fallback emitido no stderr"; fi

# ── AC7: google-chrome instalado (runner ubuntu-latest) → chrome, sem sandbox ──
# Regressão da falha do run 29198669636: o runner tem /usr/bin/google-chrome
# real, chrome_present() era true e o ramo chromium/--no-sandbox nunca rodava.
# Com o stub google-chrome no PATH + WRAPPER_CHROME=1, o cenário é determinístico
# em qualquer máquina.
run Linux unset 1 >/dev/null 2>&1; rc=$?
assert_rc "$rc" 0 "AC7 rc"
assert_has    "$NPX_LOG" "chrome"       "AC7a google-chrome presente → --browser chrome"
assert_hasnot "$NPX_LOG" "chromium"     "AC7b não usa chromium bundled"
assert_hasnot "$NPX_LOG" "--no-sandbox" "AC7c sem --no-sandbox no ramo chrome"
assert_has    "$NPX_LOG" "--headless"   "AC7d --headless independe do browser (Linux sem DISPLAY)"

# ── AC8: sem setsid → wrapper ainda sobe o npx (regressão do rc=127 no macOS) ──
# #115 assumiu setsid incondicional; macOS não tem util-linux e o launch morria
# na linha do exec. WRAPPER_SETSID=0 simula a ausência do binário no Linux
# (doutrina: seam env var, nunca filtro de PATH — usrmerge).
run Linux unset 0 WRAPPER_SETSID=0 >/dev/null 2>&1; rc=$?
assert_rc "$rc" 0 "AC8 rc (fallback sem setsid não pode ser rc=127)"
assert_has "$NPX_LOG" "--user-data-dir" "AC8a npx invocado sem setsid"
assert_has "$NPX_LOG" "--no-sandbox"    "AC8b flags preservadas no fallback"

# ── Resultado ─────────────────────────────────────────────────────────────────
echo "test_wrapper_launch.sh: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "FALHAS:$FAILED" >&2
  exit 1
fi
