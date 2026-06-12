#!/usr/bin/env bash
# vm1.sh — SSH na VM1 já dentro do Claude Code, no slot escolhido.
#          Repos disponíveis: etl-crm e storefront (slots 1–5 cada).
#          X11 forwarding habilitado (ssh -Y): apps gráficos da VM (chromium, xeyes,
#          Playwright headed) aparecem no Mac — requer XQuartz instalado e rodando.
#
# Uso:
#   ./vm1.sh storefront-3
#   ./vm1.sh etl-crm-2
#
set -euo pipefail

# IP/usuário vêm da lib comum (fonte única — P2 dedup). Ver bin/lib/vm-common.sh.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/bin/lib/vm-common.sh"
command -v vm_ip >/dev/null 2>&1 || { echo "ERRO: bin/lib/vm-common.sh não encontrada." >&2; exit 3; }

VM_IP="$(vm_ip 1)"
VM_USER="$VM_COMMON_USER"
CHECKOUTS="/home/dev/Projects/checkouts"

usage() {
    echo "Uso: $0 <repo>-<slot>"
    echo "  repo : etl-crm | storefront"
    echo "  slot : 1–5"
    echo "Exemplos:"
    echo "  $0 storefront-3"
    echo "  $0 etl-crm-2"
    exit 1
}

[ $# -eq 1 ] || usage
SLOT="$1"

if [[ ! "$SLOT" =~ ^(etl-crm|storefront)-[1-5]$ ]]; then
    echo "❌ argumento inválido: '$SLOT'"
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
# Locale: a VM1 tem LANG=pt_BR.UTF-8 no /etc/default/locale (via update-locale) e
# pt_BR.UTF-8 gerado, então o shell remoto já resolve UTF-8 + pt-BR nativo sem forçar.
exec ssh -Y -t -o ServerAliveInterval=60 "${VM_USER}@${VM_IP}" \
    "bash -lc 'cd \"${REMOTE_DIR}\" || { echo \"❌ slot inexistente: ${REMOTE_DIR}\"; exit 1; }; exec claude --dangerously-skip-permissions'"
