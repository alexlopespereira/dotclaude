#!/usr/bin/env bash
# vm-provision.sh — provisiona as VMs UTM (192.0.2.11 / .2) em duas fases.
#
# Quando usar: provisionar/atualizar uma VM nova ou existente. Roda em 3 modos:
#   (sem args)        FASE USER local, sem sudo (roda NA VM): para sessões tmux,
#                     corrige a config MCP playwright para o wrapper per-slot,
#                     smoke-testa o chromium bundled, relança o launcher e relata
#                     pendências da fase root.
#   --root            FASE ROOT local (exige sudo com senha em tty, roda NA VM):
#                     apt installs (docker.io docker-compose-v2 python-is-python3),
#                     grupo docker, instala/atualiza a unit claude-code.service.
#   --vm 1|2 [--root] modo HOST (roda no laptop): copia este script via scp e
#                     executa via ssh na VM (1=192.0.2.11, 2=192.0.2.12).
#                     Com --root usa `ssh -t` para o prompt de senha do sudo
#                     funcionar — `ssh 'bash -s' < script` consumiria o stdin.
#
# Idempotente: a fase root só instala a unit quando `cmp` detecta diferença; o
# edit MCP é pulado se já aponta para o wrapper. Guard na fase root protege o
# laptop macOS (uname != Linux ou user != dev → aborta antes de qualquer mutação).
#
# Seams de teste (env) — pattern de bin/vm-doctor.sh:
#   VM_PROV_TMUX VM_PROV_CLAUDE VM_PROV_SUDO VM_PROV_SYSTEMCTL  — binários
#   VM_PROV_SSH VM_PROV_SCP VM_PROV_TIMEOUT                      — binários
#   VM_PROV_HOME VM_PROV_UNAME VM_PROV_ID_UN VM_PROV_ID_NG       — valores
#   VM_PROV_CHROME_DIR VM_PROV_DOCKER_BIN VM_PROV_PYTHON_BIN     — paths
#   VM_PROV_SYSTEMD_SRC VM_PROV_ETC_UNIT                         — paths

set -u

# Resolve o diretório do script (para achar systemd/ e para scp do próprio script).
# Via stdin (`ssh vm 'bash -s' < script`) BASH_SOURCE[0] é UNSET — cai no cwd.
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SELF="${BASH_SOURCE[0]}"
else
  SCRIPT_DIR="$(pwd)"
  SELF="$SCRIPT_DIR/vm-provision.sh"
fi

TMUX="${VM_PROV_TMUX:-tmux}"
SUDO="${VM_PROV_SUDO:-sudo}"
SYSTEMCTL="${VM_PROV_SYSTEMCTL:-systemctl}"
SSH="${VM_PROV_SSH:-ssh}"
SCP="${VM_PROV_SCP:-scp}"
TIMEOUT_BIN="${VM_PROV_TIMEOUT:-timeout}"

HOME_DIR="${VM_PROV_HOME:-$HOME}"
UNAME="${VM_PROV_UNAME:-$(uname)}"
ID_UN="${VM_PROV_ID_UN:-$(id -un)}"
ID_NG="${VM_PROV_ID_NG:-$(id -nG 2>/dev/null)}"

# claude: via `ssh vm 'bash script'` o shell remoto NÃO é login → PATH básico
# sem ~/.local/bin e `claude` dá 127 (e o 127 do `mcp get` seria lido como
# "config não aponta pro wrapper", causando kill-server espúrio). Fallback
# explícito pro install canônico do usuário. (Hotfix pós-merge #52.)
if [ -n "${VM_PROV_CLAUDE:-}" ]; then
  CLAUDE="$VM_PROV_CLAUDE"
elif command -v claude >/dev/null 2>&1; then
  CLAUDE="claude"
else
  CLAUDE="$HOME_DIR/.local/bin/claude"
fi

CHROME_DIR="${VM_PROV_CHROME_DIR:-$HOME_DIR/.cache/ms-playwright}"
DOCKER_BIN="${VM_PROV_DOCKER_BIN:-docker}"
PYTHON_BIN="${VM_PROV_PYTHON_BIN:-python}"
# SYSTEMD_SRC: seam > systemd/ relativo ao script > checkout canônico do repo.
# O fallback cobre o caso ~/.claude/bin (sync.sh não propaga systemd/ — P2 do
# code review #52): instalado via sync, $SCRIPT_DIR/../systemd não existe, mas
# ~/Projects/dotclaude/systemd sim.
if [ -n "${VM_PROV_SYSTEMD_SRC:-}" ]; then
  SYSTEMD_SRC="$VM_PROV_SYSTEMD_SRC"
elif [ -d "$SCRIPT_DIR/../systemd" ]; then
  SYSTEMD_SRC="$SCRIPT_DIR/../systemd"
else
  SYSTEMD_SRC="$HOME_DIR/Projects/dotclaude/systemd"
fi
ETC_UNIT="${VM_PROV_ETC_UNIT:-/etc/systemd/system/claude-code.service}"

WRAPPER="$HOME_DIR/.claude/skills/browser-actions/wrapper-launch.sh"
LAUNCHER="$HOME_DIR/.local/bin/claude-sessions.sh"

# ── Fase user: config MCP ─────────────────────────────────────────────────────
# A config user-scope (~/.claude.json) é reescrita pela sessão Claude viva
# (claude-code.service active) — por isso o edit passa pelo CLI oficial, e só
# depois de `tmux kill-server` parar a sessão (Restart=no evita respawn).
mcp_already_wrapper() {
  local cur
  cur="$("$CLAUDE" mcp get playwright -s user 2>/dev/null)" || cur=""
  case "$cur" in *wrapper-launch.sh*) return 0 ;; *) return 1 ;; esac
}

fix_mcp_config() {
  if mcp_already_wrapper; then
    echo "MCP playwright já aponta para wrapper-launch.sh — skip (sem kill-server)."
    return 0
  fi
  echo "MCP playwright desatualizada — apontando para o wrapper per-slot."
  # (1) para a sessão Claude viva ANTES de editar a config (mitiga write concorrente).
  "$TMUX" kill-server 2>/dev/null || true   # tolerante a 'no server running'
  # (2) edit via CLI: remove tolerante a ausência + add-json idempotente.
  "$CLAUDE" mcp remove playwright -s user >/dev/null 2>&1 || true
  local json='{"type":"stdio","command":"'"$WRAPPER"'","args":[],"env":{}}'
  # add-json é a mutação que satisfaz o AC3; seu exit code NÃO pode ser engolido
  # (ressalva do parecer) — senão a fase user terminaria 0 com a MCP quebrada.
  local add_rc=0
  "$CLAUDE" mcp add-json playwright "$json" -s user || add_rc=$?
  # (3) relança o launcher SEMPRE (mesmo se add-json falhou) — não deixar as
  # sessões tmux mortas pelo kill-server do passo 1.
  if [ -f "$LAUNCHER" ]; then
    echo "relançando $LAUNCHER"
    "$LAUNCHER" || true
  else
    echo "launcher $LAUNCHER ausente — pulando relançamento."
  fi
  if [ "$add_rc" != 0 ]; then
    echo "ERRO: 'claude mcp add-json playwright' falhou (rc=$add_rc) — MCP NÃO corrigida." >&2
    return 5
  fi
}

# ── Fase user: smoke test do chromium bundled (não-fatal) ─────────────────────
smoke_test_browser() {
  local chrome
  chrome="$(ls -d "$CHROME_DIR"/chromium-*/chrome-linux/chrome 2>/dev/null | sort -V | tail -1)"
  if [ -z "$chrome" ] || [ ! -x "$chrome" ]; then
    echo "WARN: chromium bundled não encontrado em $CHROME_DIR — sugestão: npx playwright install chromium" >&2
    return 0
  fi
  echo "smoke test do browser: $chrome"
  # Flags numa lista única — os ramos com/sem timeout divergiam fácil (P2).
  local rc=0
  local chrome_args=(--headless --no-sandbox --dump-dom about:blank)
  if command -v "$TIMEOUT_BIN" >/dev/null 2>&1; then
    "$TIMEOUT_BIN" 20 "$chrome" "${chrome_args[@]}" >/dev/null 2>&1 || rc=$?
  else
    "$chrome" "${chrome_args[@]}" >/dev/null 2>&1 || rc=$?
  fi
  if [ "$rc" != 0 ]; then
    echo "WARN: smoke test do chromium falhou (rc=$rc) — sugestão: npx playwright install chromium" >&2
  else
    echo "smoke test do browser OK."
  fi
  return 0
}

# ── Fase user: relatório de pendências da fase root ───────────────────────────
report_root_pendencias() {
  echo "=== pendências da fase root (OK/FALTA/DIFERE) ==="
  if command -v "$DOCKER_BIN" >/dev/null 2>&1; then echo "docker: OK"; else echo "docker: FALTA"; fi
  if command -v "$PYTHON_BIN" >/dev/null 2>&1; then echo "python: OK"; else echo "python: FALTA"; fi
  local src="$SYSTEMD_SRC/claude-code.service"
  if [ ! -f "$src" ]; then
    # Sem a fonte versionada não há base de comparação — reportar DIFERE aqui
    # seria falso (ressalva do parecer p/ o modo host user, que não copiava a unit).
    echo "unit: ? (fonte versionada ausente em $src — não comparável)"
  elif [ ! -f "$ETC_UNIT" ]; then
    echo "unit: FALTA"
  elif cmp -s "$src" "$ETC_UNIT"; then
    echo "unit: OK"
  else
    echo "unit: DIFERE"
  fi
}

fase_user() {
  echo "=== vm-provision: fase user (sem sudo) ==="
  # Propaga falha do edit MCP no exit code, mas segue para smoke/report (úteis
  # como diagnóstico mesmo quando a MCP não pôde ser corrigida).
  local rc=0
  fix_mcp_config || rc=$?
  smoke_test_browser
  report_root_pendencias
  return $rc
}

# ── Fase root ─────────────────────────────────────────────────────────────────
fase_root() {
  echo "=== vm-provision: fase root (sudo) ==="
  # Guard: protege o laptop macOS de instalar unit com paths /home/dev.
  if [ "$UNAME" != Linux ] || [ "$ID_UN" != dev ]; then
    echo "ERRO: fase root exige Linux + usuário dev (uname=$UNAME, user=$ID_UN)." >&2
    echo "      Abortando antes de qualquer mutação." >&2
    return 3
  fi
  local src="$SYSTEMD_SRC/claude-code.service"
  if [ ! -f "$src" ]; then
    echo "ERRO: unit versionada ausente em $src — não há fonte para instalar." >&2
    return 4
  fi

  # apt: idempotente por natureza (já-instalado = no-op). Falha aqui é FATAL —
  # sem docker/python o provisioning não cumpriu o objetivo, então não pode
  # seguir e retornar 0 mascarando o erro (ressalva do parecer).
  if ! "$SUDO" apt-get install -y docker.io docker-compose-v2 python-is-python3; then
    echo "ERRO: 'sudo apt-get install' falhou — docker/python NÃO instalados. Abortando." >&2
    return 5
  fi

  # grupo docker: só adiciona se id -nG ainda não contém docker.
  case " $ID_NG " in
    *" docker "*) echo "usuário dev já no grupo docker — skip usermod." ;;
    *)
      if ! "$SUDO" usermod -aG docker dev; then
        echo "ERRO: 'usermod -aG docker dev' falhou. Abortando." >&2
        return 6
      fi
      ;;
  esac

  # unit: instala só quando difere (cmp). daemon-reload acompanha a instalação.
  if cmp -s "$src" "$ETC_UNIT"; then
    echo "unit em $ETC_UNIT idêntica à versionada — skip install + daemon-reload."
  else
    echo "unit em $ETC_UNIT difere (ou ausente) — instalando + daemon-reload."
    if ! "$SUDO" cp "$src" "$ETC_UNIT"; then
      echo "ERRO: cp da unit para $ETC_UNIT falhou. Abortando." >&2
      return 7
    fi
    if ! "$SUDO" "$SYSTEMCTL" daemon-reload; then
      echo "ERRO: 'systemctl daemon-reload' falhou. Abortando." >&2
      return 8
    fi
  fi

  # cópia stale ~/claude-code.service: atualizada junto (user-owned, sem sudo).
  local stale="$HOME_DIR/claude-code.service"
  if [ -f "$stale" ] && cmp -s "$src" "$stale"; then
    echo "cópia stale $stale já idêntica — skip."
  else
    echo "atualizando cópia stale $stale."
    cp "$src" "$stale"
  fi

  echo ""
  echo "AVISO: grupos novos (docker) só valem em sessão nova. Sessões tmux"
  echo "       existentes (claude-code.service) precisam de restart da unit:"
  echo "         sudo systemctl restart claude-code.service"
}

# ── Modo host: scp + ssh contra a VM ──────────────────────────────────────────
host_mode() { # vm(1|2) want_root(0|1)
  local vm="$1" want_root="$2" ip target _lib
  # Mapping VM→IP via lib comum (fonte única). Só o modo HOST pode depender
  # dela — as fases user/root viajam pra VM num scp de arquivo único (SELF)
  # e não têm bin/lib/ ao lado.
  for _lib in "$SCRIPT_DIR/lib/vm-common.sh" "$HOME/.claude/bin/lib/vm-common.sh"; do
    # shellcheck source=/dev/null  # caminho resolvido em runtime (lib ao lado ou em ~/.claude)
    [ -f "$_lib" ] && { . "$_lib"; break; }
  done
  if ! command -v vm_ip >/dev/null 2>&1; then
    echo "ERRO: bin/lib/vm-common.sh não encontrada — modo --vm exige o dotclaude instalado." >&2
    return 9
  fi
  ip="$(vm_ip "$vm")"
  target="$VM_COMMON_USER@$ip"
  echo "=== vm-provision host → VM$vm ($ip), fase $([ "$want_root" = 1 ] && echo root || echo user) ==="
  "$SCP" "$SELF" "$target:.vm-provision.sh"
  # Leva a unit versionada junto e aponta o SYSTEMD_SRC remoto para ela — em
  # AMBAS as fases. A fase root precisa para instalar; a fase user precisa para
  # o report comparar contra a fonte certa (senão o default remoto $HOME/../systemd
  # é inexistente e o report mente `unit: DIFERE` — ressalva do parecer).
  "$SSH" "$target" mkdir -p .vm-provision-systemd
  "$SCP" "$SYSTEMD_SRC/claude-code.service" "$target:.vm-provision-systemd/claude-code.service"
  if [ "$want_root" = 1 ]; then
    # ssh -t: pseudo-tty para o prompt de senha do sudo funcionar.
    "$SSH" -t "$target" "VM_PROV_SYSTEMD_SRC=\$HOME/.vm-provision-systemd bash \$HOME/.vm-provision.sh --root"
  else
    "$SSH" "$target" "VM_PROV_SYSTEMD_SRC=\$HOME/.vm-provision-systemd bash \$HOME/.vm-provision.sh"
  fi
}

usage() {
  cat <<'EOF'
Uso: vm-provision.sh [--root] | --vm 1|2 [--root] | -h|--help

Modos:
  (sem args)     fase user LOCAL (sem sudo): para sessões tmux, corrige a config
                 MCP playwright para o wrapper per-slot, smoke-testa o chromium
                 bundled, relança o launcher e relata pendências da fase root.
  --root         fase root LOCAL (sudo com senha em tty): apt installs
                 (docker.io docker-compose-v2 python-is-python3), grupo docker,
                 instala/atualiza /etc/systemd/system/claude-code.service.
  --vm 1         executa do HOST contra a VM1 (192.0.2.11) via scp+ssh.
  --vm 2         executa do HOST contra a VM2 (192.0.2.12) via scp+ssh.
  --vm N --root  fase root na VM (ssh -t para o prompt de senha do sudo).
  -h, --help     esta ajuda.
EOF
}

main() {
  local vm="" want_root=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) want_root=1 ;;
      --vm)
        shift
        vm="${1:-}"
        if [ -z "$vm" ]; then
          echo "vm-provision: --vm exige um argumento (1 ou 2)." >&2; usage >&2; return 2
        fi
        ;;
      -h|--help) usage; return 0 ;;
      *) echo "vm-provision: argumento desconhecido: $1" >&2; usage >&2; return 2 ;;
    esac
    shift
  done

  if [ -n "$vm" ]; then
    case "$vm" in
      1|2) ;;
      *) echo "vm-provision: --vm deve ser 1 ou 2 (recebido: $vm)." >&2; usage >&2; return 2 ;;
    esac
    host_mode "$vm" "$want_root"
    return $?
  fi

  if [ "$want_root" = 1 ]; then
    fase_root
  else
    fase_user
  fi
}

# Roda main só quando executado diretamente (ou via stdin); quando sourceado
# pelos testes, expõe as funções sem efeitos colaterais.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  main "$@"
  exit $?
fi
