#!/usr/bin/env bash
# vm-oauth.sh — túnel SSH local para o callback OAuth do `claude` login das VMs.
#
# Problema: `claude` login dentro da VM UTM sobe um servidor HTTP efêmero em
# http://localhost:<porta> e imprime uma URL de callback. O browser que conclui
# o OAuth roda no Mac (host) — e o `localhost` do Mac NÃO é o `localhost` da VM,
# então o callback nunca alcança o servidor de login. Este helper abre um túnel
# `ssh -L` que faz o `localhost:<porta>` do Mac apontar para o `localhost:<porta>`
# de dentro da VM.
#
# Fluxo OAuth ponta-a-ponta:
#   1. Na VM (via ./vm1.sh / ./vm2.sh), inicie `claude` e dispare o login.
#   2. Leia a porta na URL impressa (ex: http://localhost:54231/...).
#   3. NO MAC, em outro terminal: ./bin/vm-oauth.sh <1|2> <porta>
#   4. Abra a URL impressa no browser do Mac — o callback agora chega na VM.
#   5. Concluído o login, Ctrl-C aqui fecha o túnel.
#
# Uso:
#   ./bin/vm-oauth.sh 1 54231     # VM1 = 192.0.2.11
#   ./bin/vm-oauth.sh 2 54231     # VM2 = 192.0.2.12
#
# Seam de teste: VM_OAUTH_SSH (default: ssh).

set -u

SSH="${VM_OAUTH_SSH:-ssh}"

# Mapping VM→IP e user vêm da lib comum (fonte única — P2 dedup).
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _lib in "$_SD/lib/vm-common.sh" "$HOME/.claude/bin/lib/vm-common.sh"; do
  # shellcheck source=/dev/null  # caminho resolvido em runtime (lib ao lado ou em ~/.claude)
  [ -f "$_lib" ] && { . "$_lib"; break; }
done
command -v vm_ip >/dev/null 2>&1 || { echo "ERRO: bin/lib/vm-common.sh não encontrada." >&2; exit 3; }
VM_USER="$VM_COMMON_USER"

usage() {
  cat >&2 <<EOF
Uso: $0 <1|2> <porta>
  1     VM1 (192.0.2.11)
  2     VM2 (192.0.2.12)
  porta inteiro em 1024–65535 — a porta do callback OAuth impressa pelo login

Fluxo OAuth:
  1. Na VM, inicie 'claude' e dispare o login; leia a porta na URL impressa.
  2. No Mac: $0 <1|2> <porta>
  3. Abra a URL no browser do Mac; conclua o login.
  4. Ctrl-C aqui fecha o túnel.

Exemplos:
  $0 1 54231
  $0 2 54231
EOF
  exit 2
}

[ $# -eq 2 ] || usage
VM="$1"
PORT="$2"

IP="$(vm_ip "$VM")" || { echo "❌ VM inválida: '$VM' (use 1 ou 2)" >&2; usage; }

# {1,5} dígitos ANTES da aritmética: número maior que isso estoura o `[ -lt ]`
# do bash ("integer expression expected" rc=2), que numa cadeia `||` é tratado
# como falso e deixaria a porta inválida passar. Limitando o comprimento no
# regex, a comparação numérica só roda com valores ≤ 99999 (sempre seguros).
if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
  echo "❌ porta inválida: '$PORT' (inteiro em 1024–65535)" >&2
  usage
fi

echo "🔌 Túnel OAuth → VM${VM} (${VM_USER}@${IP}) : localhost:${PORT} ↔ VM:${PORT}"
echo "   Abra http://localhost:${PORT}/... no browser do Mac. Ctrl-C encerra o túnel."

exec "$SSH" -N -L "${PORT}:localhost:${PORT}" "${VM_USER}@${IP}"
