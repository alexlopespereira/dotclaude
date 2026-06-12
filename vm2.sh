#!/usr/bin/env bash
# vm2.sh — SSH na VM2 já dentro do Claude Code, no slot escolhido.
#          Repo: wikiapp (slots 1–5).
#          X11 forwarding habilitado (ssh -Y): apps gráficos da VM (chromium, xeyes,
#          Playwright headed) aparecem no Mac — requer XQuartz instalado e rodando.
#
# Uso:
#   ./vm2.sh 3          # → wikiapp-3
#   ./vm2.sh wikiapp-3   # equivalente
#
set -euo pipefail

# IP/usuário vêm da lib comum (fonte única — P2 dedup). Ver bin/lib/vm-common.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/bin/lib/vm-common.sh"
command -v vm_ip >/dev/null 2>&1 || { echo "ERRO: bin/lib/vm-common.sh não encontrada." >&2; exit 3; }

VM_IP="$(vm_ip 2)"
VM_USER="$VM_COMMON_USER"
CHECKOUTS="/home/dev/Projects/checkouts"

usage() {
    echo "Uso: $0 <slot>"
    echo "  slot : 1–5  (ou wikiapp-1 … wikiapp-5)"
    echo "Exemplos:"
    echo "  $0 3"
    echo "  $0 wikiapp-3"
    exit 1
}

[ $# -eq 1 ] || usage
ARG="$1"

if [[ "$ARG" =~ ^[1-5]$ ]]; then
    SLOT="wikiapp-${ARG}"
elif [[ "$ARG" =~ ^wikiapp-[1-5]$ ]]; then
    SLOT="$ARG"
else
    echo "❌ argumento inválido: '$ARG'"
    usage
fi

REMOTE_DIR="${CHECKOUTS}/${SLOT}"

echo "🔌 SSH → ${VM_USER}@${VM_IP} : ${REMOTE_DIR}  (X11 -Y · Claude Code)"

# Espera de prontidão SSH — sobrevive à corrida de boot no login (utm-autostart
# dorme 8s + boot do Linux). VM já no ar (uso manual) passa de primeira.
SSH_WAIT_TIMEOUT=120
wait_start=$(date +%s)
until ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=accept-new "${VM_USER}@${VM_IP}" true 2>/dev/null; do
    elapsed=$(( $(date +%s) - wait_start ))
    if [ "$elapsed" -ge "$SSH_WAIT_TIMEOUT" ]; then
        echo "❌ VM ${VM_IP} não respondeu SSH em ${SSH_WAIT_TIMEOUT}s — abortando." >&2
        echo "   (a VM subiu? cheque: /Applications/UTM.app/Contents/MacOS/utmctl list)" >&2
        exit 1
    fi
    echo "⏳ aguardando VM ${VM_IP} ficar pronta pra SSH… (${elapsed}s/${SSH_WAIT_TIMEOUT}s)"
    sleep 3
done

# -Y: X11 forwarding confiável · -t: força pseudo-tty (Claude é interativo)
# bash -lc: login shell remoto garante claude (~/.local/bin) no PATH
# LC_ALL=en_US.UTF-8: o Mac faz SendEnv LANG LC_* e manda LC_CTYPE=pt_BR.UTF-8
# (locale do host), mas a VM NÃO tem pt_BR.UTF-8 gerado → glibc cai pra ASCII
# (ANSI_X3.4-1968) e corrompe acentuação PT-BR (ç vira mojibake). LC_ALL tem
# precedência sobre o LC_CTYPE herdado e força UTF-8. Mesmo fix do claude-sessions.sh.
exec ssh -Y -t -o ServerAliveInterval=60 "${VM_USER}@${VM_IP}" \
    "bash -lc 'export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; cd \"${REMOTE_DIR}\" || { echo \"❌ slot inexistente: ${REMOTE_DIR}\"; exit 1; }; exec claude --dangerously-skip-permissions'"
