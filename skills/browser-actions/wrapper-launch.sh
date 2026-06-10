#!/bin/bash
# wrapper-launch.sh — Lock multi-slot pro perfil Chrome dedicado (per-slot).
#
# Workflow Boris tem 5 checkouts paralelos; 2+ sessões Claude Code podem
# tentar usar o browser simultaneamente. Chromium ProcessSingleton quebra
# nesse caso (lockfile no perfil + processo zumbi).
#
# Solução: profile separado por slot em ~/.claude/chrome-profile-<slot>/.
# Cada slot é independente — sem fila, sem competição. Custo: re-login
# em cada slot (cookies não compartilhados entre profiles).
#
# Resolução do slot:
#   1. env $CLAUDE_SLOT_NAME se definida (override explícito)
#   2. basename($PWD) se bate <repo>-<N> (pool Boris)
#   3. "default" (repos diretos, worktrees, etc.)
#
# Robustez: lock ainda existe per-profile pra cobrir múltiplas Claude Code
# sessions no MESMO slot (raro, mas possível). Trap limpa em SIGINT/TERM/HUP.
# SIGKILL deixa órfão — acquire_lock detecta via kill -0 no PID gravado.
#
# Invocado pelo MCP em ~/.claude.json (escopo user):
#   playwright -> /Users/dev/.claude/skills/browser-actions/wrapper-launch.sh
#
# Argumentos extras ($@) são repassados ao @playwright/mcp.

set -euo pipefail

# Resolver slot
SLOT="${CLAUDE_SLOT_NAME:-}"
if [ -z "$SLOT" ]; then
  CWD_BASE=$(basename "$PWD")
  if [[ "$CWD_BASE" =~ ^([a-z0-9-]+)-([1-5])$ ]]; then
    SLOT="$CWD_BASE"
  else
    SLOT="default"
  fi
fi

PROFILE_DIR="$HOME/.claude/chrome-profile-${SLOT}"
LOCK_DIR="$PROFILE_DIR/.lock"
PID_FILE="$LOCK_DIR/pid"
mkdir -p "$PROFILE_DIR"

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    return 0
  fi

  # Lock existe — verificar se é órfão.
  local old_pid=""
  [ -f "$PID_FILE" ] && old_pid=$(cat "$PID_FILE" 2>/dev/null || true)

  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    return 1  # dono vivo, lock válido
  fi

  # Órfão — limpar e tentar de novo (race-prone, mas best-effort).
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  return 0
}

if ! acquire_lock; then
  echo "ERRO: outra Claude Code session já está usando o profile do slot '$SLOT'." >&2
  echo "      profile: $PROFILE_DIR" >&2
  echo "      lock:    $LOCK_DIR" >&2
  echo "Aguarde aquela sessão terminar, ou rode reset.sh se for lock órfão." >&2
  exit 99
fi

echo $$ > "$PID_FILE"

cleanup() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup EXIT INT TERM HUP

# Seam de OS pra testabilidade: default $(uname), override via WRAPPER_OS.
WRAPPER_OS="${WRAPPER_OS:-$(uname)}"

# Browser: prefere Google Chrome (channel) quando instalado; senão cai no
# chromium bundled do Playwright (~/.cache/ms-playwright). No Linux sem Chrome
# (ex: só snap chromium, que quebra com --user-data-dir por confinamento
# AppArmor) o bundled é o único confiável. A detecção é gateada por OS: o path
# do .app só existe (e só importa) no macOS; os paths/binários google-chrome
# só no Linux. Sem o gate, rodar o detector num macOS com Chrome.app marcaria
# `chrome` mesmo num cenário Linux simulado.
chrome_present() {
  if [ "$WRAPPER_OS" = "Darwin" ]; then
    [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]
  else
    command -v google-chrome >/dev/null 2>&1 \
      || command -v google-chrome-stable >/dev/null 2>&1 \
      || [ -x "/opt/google/chrome/chrome" ]
  fi
}

BROWSER_FLAG="--browser chrome"
EXTRA_FLAGS=()
if chrome_present; then
  BROWSER_FLAG="--browser chrome"
elif ls -d "$HOME/.cache/ms-playwright/chromium-"* >/dev/null 2>&1; then
  BROWSER_FLAG="--browser chromium"
  # No Linux, o sandbox do chromium usa setuid + user namespaces NÃO
  # privilegiados. Ubuntu 24.04 entrega kernel.apparmor_restrict_unprivileged_userns=1,
  # que NEGA a criação desses namespaces; o chromium então aborta no startup com
  # FATAL "No usable sandbox" (rc=134). --no-sandbox é a mitigação documentada
  # numa VM dev single-tenant. Só no Linux — no macOS o sandbox funciona e a flag
  # seria uma regressão de segurança desnecessária.
  if [ "$WRAPPER_OS" = "Linux" ]; then
    EXTRA_FLAGS+=(--no-sandbox)
  fi
fi

# Sessões tmux do claude-code.service não têm X server (DISPLAY vazio/indefinido);
# um chromium headed não consegue abrir janela e morre. --headless cobre esse caso.
# Restrito ao Linux: no macOS o headed é o fluxo normal (laptop com UI).
if [ "$WRAPPER_OS" = "Linux" ] && [ -z "${DISPLAY:-}" ]; then
  EXTRA_FLAGS+=(--headless)
fi

# Não usa exec — wrapper precisa continuar vivo pra trap rodar e limpar lock.
# Sinais propagam ao filho automaticamente (mesmo grupo de processo).
# Expansão guardada (${arr[@]+...}) pra não disparar "unbound variable" sob
# `set -u` quando EXTRA_FLAGS está vazio no bash 3.2 do macOS.
npx -y @playwright/mcp@latest \
  --user-data-dir "$PROFILE_DIR" \
  $BROWSER_FLAG \
  ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"} \
  "$@"
