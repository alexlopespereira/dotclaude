#!/usr/bin/env bash
# test_vm_provision.sh — testes para bin/vm-provision.sh (US-02).
#
# Cobre os acceptance criteria automatizáveis (AC10 é [CAT3-MANUAL], fora daqui):
#   AC1 — --help documenta os 3 modos; argumento inválido / --vm fora de {1,2} → exit != 0.
#   AC2 — fase user na ORDEM tmux kill-server → edit MCP → relançar launcher (call-log).
#   AC3 — edit MCP idempotente: já-aponta-pro-wrapper → skip SEM kill-server; senão
#         remove (tolerante a falha) + add-json; 2ª execução não erra.
#   AC4 — smoke test do chromium: falha gera WARN + sugestão e NÃO aborta a fase user.
#   AC5 — guard da fase root: uname != Linux OU user != dev → aborta antes de mutar.
#   AC6 — fase root idempotente: unit só instala se cmp difere; daemon-reload idem;
#         usermod só se id -nG não contém docker.
#   AC7 — fase root roda apt-get install dos 3 pacotes + aviso de grupo novo/restart.
#   AC8 — fase user relata pendências root (docker/python/unit) — um status por linha.
#   Host mode — --vm N [--root] monta scp + ssh (-t quando --root) contra o IP certo.
#
# Estratégia: stubs de tmux/claude/sudo/systemctl/ssh/scp que logam argv num
# call-log compartilhado; fixtures controlam o que `claude mcp get` devolve e se
# o chromium bundled "falha". Pattern de test_vm_doctor.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROV="$REPO_ROOT/bin/vm-provision.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_eq()   { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_grep() { printf '%s' "$1" | grep -qE -- "$2" && _pass || _fail "$3 :: padrão '$2' ausente em: $1"; }
assert_nogrep(){ printf '%s' "$1" | grep -qE -- "$2" && _fail "$3 :: padrão '$2' NÃO deveria aparecer em: $1" || _pass; }
assert_rc()   { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_lt()   { # a b msg — prova a < b (ordem no call-log)
  { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; } && _pass || _fail "$3 :: esperado $1 < $2"; }

[ -f "$PROV" ] || { echo "FAIL: $PROV inexistente" >&2; exit 1; }
bash -n "$PROV" || { echo "FAIL: bash -n sujo em $PROV" >&2; exit 1; }

TMP="$(mktemp -d -t vm-prov.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ── systemd source versionado (fixture) ──────────────────────────────────────
SD="$TMP/systemd"; mkdir -p "$SD"
cat > "$SD/claude-code.service" <<'EOF'
[Unit]
Description=Claude Code
[Service]
ExecStart=/home/dev/.local/bin/claude-sessions.sh
[Install]
WantedBy=multi-user.target
EOF

# ── Stubs (logam argv num call-log) ──────────────────────────────────────────
mkstub() { # path, "prefixo de log"
  cat > "$1" <<EOF
#!/usr/bin/env bash
echo "$2 \$*" >> "\$VM_PROV_CALLLOG"
exit 0
EOF
  chmod +x "$1"
}

TMUX_STUB="$TMP/tmux.sh";       mkstub "$TMUX_STUB" "tmux"
SUDO_STUB="$TMP/sudo.sh";       mkstub "$SUDO_STUB" "sudo"
SYSCTL_STUB="$TMP/systemctl.sh"; mkstub "$SYSCTL_STUB" "systemctl"
SSH_STUB="$TMP/ssh.sh";         mkstub "$SSH_STUB" "ssh"
SCP_STUB="$TMP/scp.sh";         mkstub "$SCP_STUB" "scp"

# claude stub: `mcp get` ecoa o fixture apontado por VM_PROV_TEST_MCPGET; `mcp remove`
# devolve VM_PROV_TEST_REMOVE_RC (testa tolerância a falha); resto loga e sai 0.
CLAUDE_STUB="$TMP/claude.sh"
cat > "$CLAUDE_STUB" <<'EOF'
#!/usr/bin/env bash
echo "claude $*" >> "$VM_PROV_CALLLOG"
if [ "${1:-}" = mcp ] && [ "${2:-}" = get ]; then
  cat "${VM_PROV_TEST_MCPGET:-/dev/null}" 2>/dev/null
  exit 0
fi
if [ "${1:-}" = mcp ] && [ "${2:-}" = remove ]; then
  exit "${VM_PROV_TEST_REMOVE_RC:-0}"
fi
if [ "${1:-}" = mcp ] && [ "${2:-}" = add-json ]; then
  exit "${VM_PROV_TEST_ADDJSON_RC:-0}"
fi
exit 0
EOF
chmod +x "$CLAUDE_STUB"

# sudo stub que FALHA no apt-get (testa fail-fast da fase root) — loga argv.
SUDO_FAILAPT_STUB="$TMP/sudo-failapt.sh"
cat > "$SUDO_FAILAPT_STUB" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$VM_PROV_CALLLOG"
[ "${1:-}" = apt-get ] && exit 100
exit 0
EOF
chmod +x "$SUDO_FAILAPT_STUB"

# launcher stub (claude-sessions.sh) — loga relançamento no call-log.
mk_home() { # cria HOME fake com launcher; ecoa o path do HOME
  local h="$1"
  mkdir -p "$h/.local/bin"
  cat > "$h/.local/bin/claude-sessions.sh" <<'EOF'
#!/usr/bin/env bash
echo "claude-sessions relaunch" >> "$VM_PROV_CALLLOG"
exit 0
EOF
  chmod +x "$h/.local/bin/claude-sessions.sh"
}

# fixtures de `claude mcp get`
MCP_HAS="$TMP/mcp-has.txt"
printf 'playwright:\n  command: /home/dev/.claude/skills/browser-actions/wrapper-launch.sh\n' > "$MCP_HAS"
MCP_NONE="$TMP/mcp-none.txt"
printf 'playwright:\n  command: npx @playwright/mcp@latest --browser chrome\n' > "$MCP_NONE"

# chromium bundled: dir com chrome stub que FALHA (AC4) e outro que passa.
CHROME_SUB="chromium-1224/chrome-linux"   # path interno do bundle (1 lugar só)
CHROME_FAIL_DIR="$TMP/cache-fail"
mkdir -p "$CHROME_FAIL_DIR/$CHROME_SUB"
cat > "$CHROME_FAIL_DIR/$CHROME_SUB/chrome" <<'EOF'
#!/usr/bin/env bash
echo "chrome $*" >> "${VM_PROV_CALLLOG:-/dev/null}"
exit 1
EOF
chmod +x "$CHROME_FAIL_DIR/$CHROME_SUB/chrome"

CHROME_OK_DIR="$TMP/cache-ok"
mkdir -p "$CHROME_OK_DIR/$CHROME_SUB"
cat > "$CHROME_OK_DIR/$CHROME_SUB/chrome" <<'EOF'
#!/usr/bin/env bash
echo "chrome $*" >> "${VM_PROV_CALLLOG:-/dev/null}"
exit 0
EOF
chmod +x "$CHROME_OK_DIR/$CHROME_SUB/chrome"

echo "=== vm-provision tests ==="

# =============================================================================
# AC1 — help + argumentos
# =============================================================================
OUT=$(bash "$PROV" --help); rc=$?
assert_rc "$rc" "0" "AC1a --help exit 0"
assert_grep "$OUT" "sem args" "AC1b help documenta fase user (sem args)"
assert_grep "$OUT" "--root" "AC1c help documenta --root"
assert_grep "$OUT" "--vm" "AC1d help documenta --vm"

OUT=$(bash "$PROV" --frobnicate 2>&1); rc=$?
assert_rc "$rc" "2" "AC1e argumento inválido → exit 2"

OUT=$(VM_PROV_SSH="$SSH_STUB" VM_PROV_SCP="$SCP_STUB" bash "$PROV" --vm 3 2>&1); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC1f --vm 3 → exit != 0 (rc=$rc)"

# =============================================================================
# AC2 — ordem da fase user: kill-server → edit MCP → relançar launcher
# =============================================================================
H="$TMP/home-ac2"; mk_home "$H"
LOG="$TMP/log.ac2"; : > "$LOG"
OUT=$(VM_PROV_TMUX="$TMUX_STUB" VM_PROV_CLAUDE="$CLAUDE_STUB" \
      VM_PROV_HOME="$H" VM_PROV_CHROME_DIR="$TMP/none" \
      VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_ETC_UNIT="$SD/claude-code.service" \
      VM_PROV_DOCKER_BIN="docker" VM_PROV_PYTHON_BIN="python" \
      VM_PROV_TEST_MCPGET="$MCP_NONE" VM_PROV_CALLLOG="$LOG" \
      bash "$PROV"); rc=$?
assert_rc "$rc" "0" "AC2a fase user exit 0 (edit path)"
NUM=$(grep -nE "tmux kill-server|claude mcp add-json|claude-sessions relaunch" "$LOG")
ln_kill=$(printf '%s\n' "$NUM" | grep -E "tmux kill-server" | head -1 | cut -d: -f1)
ln_add=$(printf '%s\n'  "$NUM" | grep -E "claude mcp add-json" | head -1 | cut -d: -f1)
ln_relaunch=$(printf '%s\n' "$NUM" | grep -E "claude-sessions relaunch" | head -1 | cut -d: -f1)
assert_lt "$ln_kill" "$ln_add" "AC2b kill-server antes do edit MCP"
assert_lt "$ln_add" "$ln_relaunch" "AC2c edit MCP antes do relançamento"

# =============================================================================
# AC3 — idempotência do edit MCP
# =============================================================================
# (a) já aponta pro wrapper → skip SEM kill-server
H="$TMP/home-ac3a"; mk_home "$H"
LOG="$TMP/log.ac3a"; : > "$LOG"
OUT=$(VM_PROV_TMUX="$TMUX_STUB" VM_PROV_CLAUDE="$CLAUDE_STUB" \
      VM_PROV_HOME="$H" VM_PROV_CHROME_DIR="$TMP/none" \
      VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_ETC_UNIT="$SD/claude-code.service" \
      VM_PROV_TEST_MCPGET="$MCP_HAS" VM_PROV_CALLLOG="$LOG" \
      bash "$PROV"); rc=$?
assert_rc "$rc" "0" "AC3a skip path exit 0"
assert_nogrep "$(cat "$LOG")" "tmux kill-server" "AC3b skip NÃO mata o tmux server"
assert_nogrep "$(cat "$LOG")" "claude mcp add-json" "AC3c skip NÃO chama add-json"
assert_grep "$OUT" "skip" "AC3d skip imprime aviso"

# (b) edit path com remove FALHANDO → add-json mesmo assim (tolerância)
H="$TMP/home-ac3b"; mk_home "$H"
LOG="$TMP/log.ac3b"; : > "$LOG"
OUT=$(VM_PROV_TMUX="$TMUX_STUB" VM_PROV_CLAUDE="$CLAUDE_STUB" \
      VM_PROV_HOME="$H" VM_PROV_CHROME_DIR="$TMP/none" \
      VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_ETC_UNIT="$SD/claude-code.service" \
      VM_PROV_TEST_MCPGET="$MCP_NONE" VM_PROV_TEST_REMOVE_RC=1 \
      VM_PROV_CALLLOG="$LOG" bash "$PROV"); rc=$?
assert_rc "$rc" "0" "AC3e remove falha não aborta (exit 0)"
assert_grep "$(cat "$LOG")" "claude mcp remove playwright -s user" "AC3f remove tentado"
assert_grep "$(cat "$LOG")" "claude mcp add-json playwright" "AC3g add-json roda apesar do remove falhar"

# (c) segunda execução (estado já-wrapper) não erra
LOG="$TMP/log.ac3c"; : > "$LOG"
VM_PROV_TMUX="$TMUX_STUB" VM_PROV_CLAUDE="$CLAUDE_STUB" \
  VM_PROV_HOME="$H" VM_PROV_CHROME_DIR="$TMP/none" \
  VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_ETC_UNIT="$SD/claude-code.service" \
  VM_PROV_TEST_MCPGET="$MCP_HAS" VM_PROV_CALLLOG="$LOG" bash "$PROV" >/dev/null 2>&1
assert_rc "$?" "0" "AC3h 2ª execução idempotente exit 0"

# =============================================================================
# Hotfix pós-merge #52 — resolução do claude fora do PATH (ssh não-login)
# =============================================================================
# Via `ssh vm 'bash script'` o shell NÃO é login → PATH básico sem ~/.local/bin
# e `claude` dá 127. Visto na execução real (VM1/VM2): add-json falhou rc=127 e
# o check mcp_already_wrapper tratou 127 como "não-wrapper" (kill-server espúrio).
# Sem VM_PROV_CLAUDE e sem claude no PATH, o script deve usar o fallback
# canônico $HOME/.local/bin/claude.
H="$TMP/home-fallback"; mk_home "$H"
cp "$CLAUDE_STUB" "$H/.local/bin/claude"
LOG="$TMP/log.fallback"; : > "$LOG"
OUT=$(env PATH="/usr/bin:/bin" \
      VM_PROV_TMUX="$TMUX_STUB" \
      VM_PROV_HOME="$H" VM_PROV_CHROME_DIR="$TMP/none" \
      VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_ETC_UNIT="$SD/claude-code.service" \
      VM_PROV_TEST_MCPGET="$MCP_NONE" VM_PROV_CALLLOG="$LOG" \
      bash "$PROV" 2>&1); rc=$?
assert_rc "$rc" "0" "FB-a claude fora do PATH → fallback ~/.local/bin/claude (exit 0)"
assert_grep "$(cat "$LOG")" "claude mcp add-json playwright" "FB-b add-json roda via fallback"
assert_nogrep "$OUT" "command not found" "FB-c sem 'command not found' no output"

# =============================================================================
# AC4 — smoke test do browser falha → WARN + sugestão, NÃO aborta
# =============================================================================
H="$TMP/home-ac4"; mk_home "$H"
LOG="$TMP/log.ac4"; : > "$LOG"
OUT=$(VM_PROV_TMUX="$TMUX_STUB" VM_PROV_CLAUDE="$CLAUDE_STUB" \
      VM_PROV_HOME="$H" VM_PROV_CHROME_DIR="$CHROME_FAIL_DIR" \
      VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_ETC_UNIT="$SD/claude-code.service" \
      VM_PROV_DOCKER_BIN="/nonexistent/docker" VM_PROV_PYTHON_BIN="/nonexistent/python" \
      VM_PROV_TEST_MCPGET="$MCP_HAS" VM_PROV_CALLLOG="$LOG" \
      bash "$PROV" 2>&1); rc=$?
assert_rc "$rc" "0" "AC4a smoke falha NÃO aborta fase user (exit 0)"
assert_grep "$OUT" "WARN" "AC4b smoke falho emite WARN"
assert_grep "$OUT" "npx playwright install chromium" "AC4c sugestão de reinstalar chromium"
assert_grep "$(cat "$LOG")" "chrome .*--headless.*--no-sandbox.*--dump-dom about:blank" "AC4d chrome chamado com as flags"
assert_grep "$OUT" "pend" "AC4e fase user segue até o relatório de pendências"

# =============================================================================
# AC5 — guard da fase root (protege o laptop macOS)
# =============================================================================
LOG="$TMP/log.ac5a"; : > "$LOG"
ERR=$(VM_PROV_SUDO="$SUDO_STUB" VM_PROV_SYSTEMCTL="$SYSCTL_STUB" \
      VM_PROV_UNAME="Darwin" VM_PROV_ID_UN="dev" VM_PROV_ID_NG="staff" \
      VM_PROV_HOME="$TMP/h5a" VM_PROV_SYSTEMD_SRC="$SD" \
      VM_PROV_ETC_UNIT="$SD/claude-code.service" VM_PROV_CALLLOG="$LOG" \
      bash "$PROV" --root 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC5a uname!=Linux aborta (rc=$rc)"
assert_grep "$ERR" "Linux" "AC5b mensagem cita exigência de Linux"
assert_nogrep "$(cat "$LOG")" "(apt-get|usermod|cp|daemon-reload)" "AC5c nenhuma mutação antes do abort (Darwin)"

LOG="$TMP/log.ac5b"; : > "$LOG"
ERR=$(VM_PROV_SUDO="$SUDO_STUB" VM_PROV_SYSTEMCTL="$SYSCTL_STUB" \
      VM_PROV_UNAME="Linux" VM_PROV_ID_UN="root" VM_PROV_ID_NG="root docker" \
      VM_PROV_HOME="$TMP/h5b" VM_PROV_SYSTEMD_SRC="$SD" \
      VM_PROV_ETC_UNIT="$SD/claude-code.service" VM_PROV_CALLLOG="$LOG" \
      bash "$PROV" --root 2>&1 >/dev/null); rc=$?
[ "$rc" != 0 ] && _pass || _fail "AC5d user!=dev aborta (rc=$rc)"
assert_nogrep "$(cat "$LOG")" "(apt-get|usermod|cp|daemon-reload)" "AC5e nenhuma mutação antes do abort (user root)"

# =============================================================================
# AC6 — fase root idempotente
# =============================================================================
# (a) unit /etc IDÊNTICA + já no grupo docker → sem daemon-reload, sem cp p/ /etc, sem usermod
ETC_SAME="$TMP/etc-same.service"; cp "$SD/claude-code.service" "$ETC_SAME"
H="$TMP/home-ac6a"; mkdir -p "$H"
LOG="$TMP/log.ac6a"; : > "$LOG"
OUT=$(VM_PROV_SUDO="$SUDO_STUB" VM_PROV_SYSTEMCTL="$SYSCTL_STUB" \
      VM_PROV_UNAME="Linux" VM_PROV_ID_UN="dev" VM_PROV_ID_NG="dev docker" \
      VM_PROV_HOME="$H" VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_ETC_UNIT="$ETC_SAME" \
      VM_PROV_CALLLOG="$LOG" bash "$PROV" --root 2>&1); rc=$?
assert_rc "$rc" "0" "AC6a fase root idêntica exit 0"
assert_nogrep "$(cat "$LOG")" "daemon-reload" "AC6b unit idêntica → SEM daemon-reload"
assert_nogrep "$(cat "$LOG")" "cp .*$ETC_SAME" "AC6c unit idêntica → SEM cp p/ /etc"
assert_nogrep "$(cat "$LOG")" "usermod" "AC6d já no grupo docker → SEM usermod"

# (b) unit /etc DIFERENTE + fora do grupo docker → cp + daemon-reload + usermod
ETC_DIFF="$TMP/etc-diff.service"; printf 'DIFERENTE\n' > "$ETC_DIFF"
H="$TMP/home-ac6b"; mkdir -p "$H"
LOG="$TMP/log.ac6b"; : > "$LOG"
OUT=$(VM_PROV_SUDO="$SUDO_STUB" VM_PROV_SYSTEMCTL="$SYSCTL_STUB" \
      VM_PROV_UNAME="Linux" VM_PROV_ID_UN="dev" VM_PROV_ID_NG="dev sudo" \
      VM_PROV_HOME="$H" VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_ETC_UNIT="$ETC_DIFF" \
      VM_PROV_CALLLOG="$LOG" bash "$PROV" --root 2>&1); rc=$?
assert_rc "$rc" "0" "AC6e fase root diferente exit 0"
assert_grep "$(cat "$LOG")" "cp .*$ETC_DIFF" "AC6f unit diferente → cp p/ /etc"
assert_grep "$(cat "$LOG")" "daemon-reload" "AC6g unit diferente → daemon-reload"
assert_grep "$(cat "$LOG")" "usermod -aG docker dev" "AC6h fora do grupo docker → usermod"
# cópia stale ~/claude-code.service foi atualizada
[ -f "$H/claude-code.service" ] && cmp -s "$SD/claude-code.service" "$H/claude-code.service" \
  && _pass || _fail "AC6i cópia stale ~/claude-code.service atualizada"

# =============================================================================
# AC7 — apt-get install dos 3 pacotes + aviso de grupo novo
# =============================================================================
assert_grep "$(cat "$TMP/log.ac6b")" "apt-get install -y docker.io docker-compose-v2 python-is-python3" "AC7a apt-get instala os 3 pacotes"
assert_grep "$OUT" "sess.o nova" "AC7b aviso: grupos novos só valem em sessão nova"
assert_grep "$OUT" "restart" "AC7c aviso: restart da unit"

# =============================================================================
# AC8 — relatório de pendências da fase root (um status por linha)
# =============================================================================
DOCKER_OK="$TMP/docker-ok"; : > "$DOCKER_OK"; chmod +x "$DOCKER_OK"
H="$TMP/home-ac8"; mk_home "$H"
ETC_DIFF8="$TMP/etc-diff8.service"; printf 'OUTRO\n' > "$ETC_DIFF8"
LOG="$TMP/log.ac8"; : > "$LOG"
OUT=$(VM_PROV_TMUX="$TMUX_STUB" VM_PROV_CLAUDE="$CLAUDE_STUB" \
      VM_PROV_HOME="$H" VM_PROV_CHROME_DIR="$TMP/none" \
      VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_ETC_UNIT="$ETC_DIFF8" \
      VM_PROV_DOCKER_BIN="$DOCKER_OK" VM_PROV_PYTHON_BIN="/nonexistent/python" \
      VM_PROV_TEST_MCPGET="$MCP_HAS" VM_PROV_CALLLOG="$LOG" \
      bash "$PROV" 2>&1); rc=$?
assert_rc "$rc" "0" "AC8a fase user exit 0"
assert_grep "$OUT" "docker: OK" "AC8b docker presente → OK"
assert_grep "$OUT" "python: FALTA" "AC8c python ausente → FALTA"
assert_grep "$OUT" "unit: DIFERE" "AC8d unit /etc difere da versionada → DIFERE"

# unit FALTA: ETC inexistente
LOG="$TMP/log.ac8b"; : > "$LOG"
OUT=$(VM_PROV_TMUX="$TMUX_STUB" VM_PROV_CLAUDE="$CLAUDE_STUB" \
      VM_PROV_HOME="$H" VM_PROV_CHROME_DIR="$TMP/none" \
      VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_ETC_UNIT="$TMP/nope.service" \
      VM_PROV_DOCKER_BIN="$DOCKER_OK" VM_PROV_PYTHON_BIN="$DOCKER_OK" \
      VM_PROV_TEST_MCPGET="$MCP_HAS" VM_PROV_CALLLOG="$LOG" \
      bash "$PROV" 2>&1)
assert_grep "$OUT" "unit: FALTA" "AC8e unit /etc ausente → FALTA"
assert_grep "$OUT" "python: OK" "AC8f python presente → OK"

# =============================================================================
# Host mode — scp + ssh (-t quando --root) contra o IP correto
# =============================================================================
LOG="$TMP/log.host1"; : > "$LOG"
OUT=$(VM_PROV_SSH="$SSH_STUB" VM_PROV_SCP="$SCP_STUB" \
      VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_CALLLOG="$LOG" \
      bash "$PROV" --vm 1 --root 2>&1); rc=$?
assert_rc "$rc" "0" "HOST-a --vm 1 --root exit 0"
assert_grep "$(cat "$LOG")" "ssh -t .*dev@192.0.2.11" "HOST-b --root usa ssh -t contra IP da VM1"
assert_grep "$(cat "$LOG")" "scp .*claude-code.service .*dev@192.0.2.11" "HOST-c scp da unit p/ VM1 no modo root"

LOG="$TMP/log.host2"; : > "$LOG"
OUT=$(VM_PROV_SSH="$SSH_STUB" VM_PROV_SCP="$SCP_STUB" \
      VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_CALLLOG="$LOG" \
      bash "$PROV" --vm 2 2>&1); rc=$?
assert_rc "$rc" "0" "HOST-d --vm 2 (user) exit 0"
assert_grep "$(cat "$LOG")" "scp .*dev@192.0.2.12" "HOST-e scp contra IP da VM2"
assert_nogrep "$(cat "$LOG")" "ssh -t " "HOST-f fase user NÃO usa ssh -t"

# =============================================================================
# FIX (review 2026-06-09T20:59): regressões do parecer REVIEW_REQUEST_CHANGES
# =============================================================================
# FIX1 — host user mode leva a unit versionada e seta VM_PROV_SYSTEMD_SRC remoto
#        (senão o report remoto compara fonte inexistente e imprime DIFERE falso).
LOG="$TMP/log.fix1"; : > "$LOG"
OUT=$(VM_PROV_SSH="$SSH_STUB" VM_PROV_SCP="$SCP_STUB" \
      VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_CALLLOG="$LOG" \
      bash "$PROV" --vm 1 2>&1); rc=$?
assert_rc "$rc" "0" "FIX1a host user (--vm 1) exit 0"
assert_grep "$(cat "$LOG")" "scp .*claude-code.service .*dev@192.0.2.11" "FIX1b host user copia a unit versionada"
assert_grep "$(cat "$LOG")" "VM_PROV_SYSTEMD_SRC=.*bash .*vm-provision.sh" "FIX1c host user passa VM_PROV_SYSTEMD_SRC ao remoto"

# FIX1d — local: fonte versionada ausente → report NÃO mente DIFERE
H="$TMP/home-srcmiss"; mk_home "$H"
LOG="$TMP/log.srcmiss"; : > "$LOG"
OUT=$(VM_PROV_TMUX="$TMUX_STUB" VM_PROV_CLAUDE="$CLAUDE_STUB" \
      VM_PROV_HOME="$H" VM_PROV_CHROME_DIR="$TMP/none" \
      VM_PROV_SYSTEMD_SRC="$TMP/nonexistent-systemd" VM_PROV_ETC_UNIT="$SD/claude-code.service" \
      VM_PROV_DOCKER_BIN="$DOCKER_OK" VM_PROV_PYTHON_BIN="$DOCKER_OK" \
      VM_PROV_TEST_MCPGET="$MCP_HAS" VM_PROV_CALLLOG="$LOG" \
      bash "$PROV" 2>&1)
assert_nogrep "$OUT" "unit: DIFERE" "FIX1d fonte versionada ausente → NÃO reporta DIFERE falso"
assert_grep "$OUT" "fonte versionada ausente" "FIX1e fonte ausente → status honesto"

# FIX2 — fase root é fail-fast: apt-get falha → aborta antes de usermod/unit, exit != 0.
H="$TMP/home-aptfail"; mkdir -p "$H"
ETC_DIFF_A="$TMP/etc-aptfail.service"; printf 'X\n' > "$ETC_DIFF_A"
LOG="$TMP/log.aptfail"; : > "$LOG"
OUT=$(VM_PROV_SUDO="$SUDO_FAILAPT_STUB" VM_PROV_SYSTEMCTL="$SYSCTL_STUB" \
      VM_PROV_UNAME="Linux" VM_PROV_ID_UN="dev" VM_PROV_ID_NG="dev" \
      VM_PROV_HOME="$H" VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_ETC_UNIT="$ETC_DIFF_A" \
      VM_PROV_CALLLOG="$LOG" bash "$PROV" --root 2>&1); rc=$?
[ "$rc" != 0 ] && _pass || _fail "FIX2a apt-get falha → fase root exit != 0 (rc=$rc)"
assert_grep "$OUT" "ERRO" "FIX2b apt-get falha emite ERRO"
assert_nogrep "$(cat "$LOG")" "usermod" "FIX2c apt-get falha → aborta antes de usermod"
assert_nogrep "$(cat "$LOG")" "daemon-reload" "FIX2d apt-get falha → aborta antes de instalar unit"

# FIX3 — add-json falha → fase user exit != 0 (não termina 0 com MCP quebrada),
#        mas ainda relança o launcher (não deixa as sessões mortas pelo kill-server).
H="$TMP/home-addfail"; mk_home "$H"
LOG="$TMP/log.addfail"; : > "$LOG"
OUT=$(VM_PROV_TMUX="$TMUX_STUB" VM_PROV_CLAUDE="$CLAUDE_STUB" \
      VM_PROV_HOME="$H" VM_PROV_CHROME_DIR="$TMP/none" \
      VM_PROV_SYSTEMD_SRC="$SD" VM_PROV_ETC_UNIT="$SD/claude-code.service" \
      VM_PROV_TEST_MCPGET="$MCP_NONE" VM_PROV_TEST_ADDJSON_RC=1 \
      VM_PROV_CALLLOG="$LOG" bash "$PROV" 2>&1); rc=$?
[ "$rc" != 0 ] && _pass || _fail "FIX3a add-json falha → fase user exit != 0 (rc=$rc)"
assert_grep "$OUT" "ERRO" "FIX3b add-json falha emite ERRO"
assert_grep "$(cat "$LOG")" "claude-sessions relaunch" "FIX3c add-json falha ainda relança launcher (sessões voltam)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:$FAILED"
  exit 1
fi
exit 0
