#!/usr/bin/env bash
# vm-doctor.sh — detecta e saneia units systemd órfãs (WorkingDirectory/ExecStart
# apontando para path inexistente), tipicamente crash-loops deixados por scripts
# deletados nas VMs UTM (telegram-bot, agent-heartbeat, etc.).
#
# Quando usar: rodar na máquina (VM ou laptop) — diretamente ou via
#   ssh <vm> 'bash -s' < bin/vm-doctor.sh [--fix]
# para listar units órfãs (default = report-only) ou saneá-las (--fix:
# stop + disable/mask + stop/disable do .timer homônimo + reset-failed).
#
# Critério órfã: (WorkingDirectory não-vazio e inexistente) OU (path= do ExecStart
# não-vazio e inexistente). NRestarts>50, failed, ou activating/auto-restart são
# CORROBORANTES (sozinhos = warn, nunca fix automático). Units LoadState=not-found
# (pulseaudio/pipewire fantasmas) são puladas.
#
# Ramo system precisa de sudo (sudo -n true); sem ele, degrada para report-only
# com aviso, sem erro fatal. O journal disk-usage é reportado e o comando de
# vacuum é SUGERIDO, nunca executado.
#
# Seams de teste (env):
#   VM_DOCTOR_SYSTEMCTL  — binário systemctl (default: systemctl)
#   VM_DOCTOR_JOURNALCTL — binário journalctl (default: journalctl)
#   VM_DOCTOR_SUDO       — binário sudo (default: sudo)

set -u

SYSTEMCTL="${VM_DOCTOR_SYSTEMCTL:-systemctl}"
JOURNALCTL="${VM_DOCTOR_JOURNALCTL:-journalctl}"
SUDO="${VM_DOCTOR_SUDO:-sudo}"
# --fix só atua em órfãs cujo path quebrado vive sob estes roots (separados por
# espaço). Leftovers de projeto deletado moram em /home|/root; units de OS
# (quotaon, rc-local…) apontam para /usr|/etc — ficam report-only para sempre.
FIX_ROOTS="${VM_DOCTOR_FIX_ROOTS:-/home /root}"

FIX=0

# ── Estado acumulado (arrays indexados — compatível com bash 3.2) ─────────────
ALL_UNIT_NAMES=()          # "scope:unit" de toda a união enumerada
ORPH_UNIT=(); ORPH_SCOPE=(); ORPH_UFS=(); ORPH_REASON=(); ORPH_FIXABLE=()
WARN_MSG=()
USED_SCOPES=""
SYSTEM_OK=0

# ── Invocação de systemctl: read (sem sudo) vs mutate (sudo no system) ────────
sctl_read() {   # scope, args...
  local scope="$1"; shift
  if [ "$scope" = user ]; then "$SYSTEMCTL" --user "$@"; else "$SYSTEMCTL" "$@"; fi
}
sctl_mutate() { # scope, args...
  local scope="$1"; shift
  if [ "$scope" = user ]; then "$SYSTEMCTL" --user "$@"; else "$SUDO" "$SYSTEMCTL" "$@"; fi
}

# ── Parser key-based de `systemctl show -p ...` — tolerante a ordem e ausência ─
# Lê stdin; popula P_* globais. ExecStart tem a forma `{ path=/x ; argv[]=... }`;
# extraímos só o `path=`.
parse_show() {
  P_LoadState=""; P_WorkingDirectory=""; P_ExecStartPath=""
  P_NRestarts=""; P_ActiveState=""; P_SubState=""; P_UnitFileState=""
  local line key val p
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    key="${line%%=*}"
    val="${line#*=}"
    # Names é pedido no -p p/ completude, mas não entra no critério → ignorado.
    case "$key" in
      LoadState)         P_LoadState="$val" ;;
      WorkingDirectory)  P_WorkingDirectory="$val" ;;
      NRestarts)         P_NRestarts="$val" ;;
      ActiveState)       P_ActiveState="$val" ;;
      SubState)          P_SubState="$val" ;;
      UnitFileState)     P_UnitFileState="$val" ;;
      ExecStart)
        if [ "${val#*path=}" != "$val" ]; then
          p="${val#*path=}"      # tudo após o primeiro path=
          # Corta no separador REAL ' ; ' — a format string do systemd
          # (exec_command_dump) garante `path=<p> ; argv[]=...`. Cortar no 1º
          # espaço truncava paths com espaço ('/opt/my app' → '/opt/my') →
          # falso órfão → --fix desabilitaria unit saudável (review Fase 5.5).
          p="${p%%' ; '*}"
          P_ExecStartPath="$p"
        fi
        ;;
    esac
  done
}

# ── Classificação: usa P_* → seta IS_ORPHAN, ORPHAN_REASON, CORROB ────────────
classify_unit() {
  IS_ORPHAN=0; ORPHAN_REASON=""; CORROB=""
  # Units fantasma (not-found) são puladas do check de path.
  [ "$P_LoadState" = "not-found" ] && return 0
  local reasons="" n=0
  # Prefixos especiais do systemd no WorkingDirectory (vistos live em units
  # GNOME geradas, ex: `!/home/dev`): '-' = missing é TOLERADO por design
  # (não é critério de órfã); '!' = marcador de privilégio — o path real vem
  # depois. Sem o strip, ~14 units `app-*@autostart` saudáveis viravam falso
  # órfão por VM e --fix pararia serviços de desktop.
  local wd="$P_WorkingDirectory"
  case "$wd" in
    -*)   wd="" ;;
    '!'*) wd="${wd#!}" ;;
  esac
  if [ -n "$wd" ] && [ ! -d "$wd" ]; then
    IS_ORPHAN=1
    reasons="WorkingDirectory inexistente ($P_WorkingDirectory)"
  fi
  # Só paths ABSOLUTOS: systemd aceita ExecStart relativo (find, sh, udevadm…)
  # resolvido via search-path interno — testá-lo contra o cwd marcava dezenas
  # de units core (systemd-tmpfiles, udev) como órfãs nas VMs reais.
  if [ -n "$P_ExecStartPath" ] && [ "${P_ExecStartPath#/}" != "$P_ExecStartPath" ] \
     && [ ! -e "$P_ExecStartPath" ]; then
    IS_ORPHAN=1
    reasons="${reasons:+$reasons; }ExecStart inexistente ($P_ExecStartPath)"
  fi
  ORPHAN_REASON="$reasons"
  # Elegível para --fix? Algum path quebrado sob FIX_ROOTS (leftover de projeto).
  ORPHAN_FIXABLE=0
  if [ "$IS_ORPHAN" = 1 ]; then
    local root bad
    for bad in "$wd" "$P_ExecStartPath"; do
      [ -n "$bad" ] && [ ! -e "$bad" ] || continue
      for root in $FIX_ROOTS; do
        case "$bad" in "$root"/*) ORPHAN_FIXABLE=1 ;; esac
      done
    done
  fi
  [[ "$P_NRestarts" =~ ^[0-9]+$ ]] && n="$P_NRestarts"
  [ "$n" -gt 50 ] && CORROB="${CORROB:+$CORROB; }NRestarts=$P_NRestarts (>50)"
  [ "$P_ActiveState" = "failed" ] && CORROB="${CORROB:+$CORROB; }failed"
  if [ "$P_ActiveState" = "activating" ] && [ "$P_SubState" = "auto-restart" ]; then
    CORROB="${CORROB:+$CORROB; }activating/auto-restart"
  fi
  return 0
}

# ── Enumeração: UNIÃO de list-units --all + list-unit-files (nomes únicos) ─────
collect_units() { # scope
  local scope="$1"
  { sctl_read "$scope" list-units --all --plain --no-legend --no-pager 2>/dev/null
    sctl_read "$scope" list-unit-files --no-legend --no-pager --plain 2>/dev/null
  } | awk '{print $1}' | grep -E '\.(service|timer)$' | sort -u
}

unit_known() { # scope name → 0 se presente na união enumerada
  local target="$1:$2" x
  for x in ${ALL_UNIT_NAMES[@]+"${ALL_UNIT_NAMES[@]}"}; do
    [ "$x" = "$target" ] && return 0
  done
  return 1
}

scan_scope() { # scope
  local scope="$1" units name show
  units=$(collect_units "$scope")
  [ -z "$units" ] && return 0
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    ALL_UNIT_NAMES+=("$scope:$name")
  done <<< "$units"
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    case "$name" in *.service) ;; *) continue ;; esac
    show=$(sctl_read "$scope" show \
      -p Names,LoadState,WorkingDirectory,ExecStart,NRestarts,ActiveState,SubState,UnitFileState \
      "$name" 2>/dev/null)
    parse_show <<< "$show"
    classify_unit
    if [ "$IS_ORPHAN" = 1 ]; then
      ORPH_UNIT+=("$name"); ORPH_SCOPE+=("$scope"); ORPH_UFS+=("$P_UnitFileState")
      ORPH_FIXABLE+=("$ORPHAN_FIXABLE")
      ORPH_REASON+=("$ORPHAN_REASON${CORROB:+ | corroboração: $CORROB}")
    elif [ -n "$CORROB" ]; then
      WARN_MSG+=("[$scope] $name — corroboração sem critério de path: $CORROB")
    fi
  done <<< "$units"
}

# ── Saneamento (--fix) ────────────────────────────────────────────────────────
apply_fix() {
  local i unit scope ufs base timer
  if [ "${#ORPH_UNIT[@]}" -gt 0 ]; then
    for i in "${!ORPH_UNIT[@]}"; do
      unit="${ORPH_UNIT[$i]}"; scope="${ORPH_SCOPE[$i]}"; ufs="${ORPH_UFS[$i]}"
      # Ramo system sem sudo não muta (degrade para report-only).
      if [ "$scope" = system ] && [ "$SYSTEM_OK" != 1 ]; then
        echo "  (system sem sudo: $unit não saneada — report-only)" >&2
        continue
      fi
      # Path quebrado fora de FIX_ROOTS = unit de OS, não leftover de projeto —
      # nunca mutar automaticamente (mask em systemd-tmpfiles/quotaon quebraria
      # o sistema). Saneamento manual se realmente desejado.
      if [ "${ORPH_FIXABLE[$i]}" != 1 ]; then
        echo "  ($unit: path fora de $FIX_ROOTS — report-only; saneie manualmente)" >&2
        continue
      fi
      # Units generated/transient vivem em /run e são recriadas pelo gerador a
      # cada boot — stop/disable/mask nelas é inócuo ou nocivo. Só mutamos
      # estados de unit-file persistentes.
      case "$ufs" in
        enabled|disabled|static) : ;;
        *)
          echo "  ($unit: UnitFileState='${ufs:-?}' não-persistente — report-only)" >&2
          continue
          ;;
      esac
      sctl_mutate "$scope" stop "$unit"
      if [ "$ufs" = static ]; then
        sctl_mutate "$scope" mask "$unit"
      else
        sctl_mutate "$scope" disable "$unit"
      fi
      base="${unit%.service}"; timer="$base.timer"
      if unit_known "$scope" "$timer"; then
        sctl_mutate "$scope" stop "$timer"
        sctl_mutate "$scope" disable "$timer"
      fi
    done
  fi
  # reset-failed ao final, por scope efetivamente saneado.
  local s
  for s in $USED_SCOPES; do
    [ "$s" = system ] && [ "$SYSTEM_OK" != 1 ] && continue
    sctl_mutate "$s" reset-failed
  done
}

# ── Relatórios ────────────────────────────────────────────────────────────────
report_findings() {
  echo "=== vm-doctor: scan de units systemd órfãs ==="
  if [ "${#ORPH_UNIT[@]}" -gt 0 ]; then
    local i
    for i in "${!ORPH_UNIT[@]}"; do
      local tag=""
      [ "${ORPH_FIXABLE[$i]}" != 1 ] && tag=" [--fix: fora do escopo]"
      echo "ÓRFÃ [${ORPH_SCOPE[$i]}] ${ORPH_UNIT[$i]} (${ORPH_UFS[$i]:-?}) — ${ORPH_REASON[$i]}${tag}"
    done
  else
    echo "Nenhuma unit órfã encontrada."
  fi
  if [ "${#WARN_MSG[@]}" -gt 0 ]; then
    local w
    for w in "${WARN_MSG[@]}"; do echo "WARN $w"; done
  fi
}

report_journal() {
  echo "Journal disk usage:"
  local u s
  u=$("$JOURNALCTL" --user --disk-usage 2>/dev/null) || u=""
  [ -n "$u" ] && echo "  user: $u"
  echo "  Sugestão (não executado): journalctl --user --vacuum-size=200M"
  if [ "$SYSTEM_OK" = 1 ]; then
    s=$("$SUDO" "$JOURNALCTL" --disk-usage 2>/dev/null) || s=""
    [ -n "$s" ] && echo "  system: $s"
    echo "  Sugestão (não executado): sudo journalctl --vacuum-size=500M"
  fi
}

usage() {
  cat <<'EOF'
Uso: vm-doctor.sh [--fix] [-h|--help]
  (sem flags)  report-only: lista units órfãs + journal disk-usage.
  --fix        saneia: stop + disable/mask + stop/disable do .timer + reset-failed.
EOF
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --fix) FIX=1 ;;
      -h|--help) usage; return 0 ;;
      *) echo "vm-doctor: argumento desconhecido: $1" >&2; usage >&2; return 2 ;;
    esac
    shift
  done

  if "$SUDO" -n true 2>/dev/null; then
    SYSTEM_OK=1
  else
    echo "AVISO: sudo -n indisponível; ramo system degrada para report-only." >&2
    SYSTEM_OK=0
  fi

  scan_scope user
  USED_SCOPES="user"
  scan_scope system
  USED_SCOPES="$USED_SCOPES system"

  report_findings
  if [ "$FIX" = 1 ]; then
    echo "--- aplicando --fix ---"
    apply_fix
  else
    echo "(report-only — use --fix para sanear)"
  fi
  report_journal
  return 0
}

# Só roda main quando executado diretamente; quando sourceado (testes), expõe as
# funções parse_show/classify_unit sem efeitos colaterais. Via stdin
# (`ssh vm 'bash -s' < vm-doctor.sh` — o modo documentado no header)
# BASH_SOURCE[0] é UNSET e `set -u` explodiria — vazio ⇒ execução direta.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  main "$@"
  exit $?
fi
