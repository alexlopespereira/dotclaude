#!/usr/bin/env bash
# vm-paste.sh — Cola a imagem do clipboard do Mac no Claude Code que roda DENTRO da VM.
#
# Por que existe: vm1.sh/vm2.sh rodam o Claude Code NA VM via SSH. O Claude lê
# imagem do clipboard da máquina onde roda (a VM Linux), não do Mac, e terminal/SSH
# não transmite imagem — por isso Cmd+V não funciona. Este script faz a ponte:
# extrai a imagem do clipboard do Mac, manda pro home da VM via scp, e devolve o
# caminho do arquivo no clipboard do Mac. Você cola esse caminho (Cmd+V) no prompt
# do Claude na VM — o Claude Code anexa imagem quando você passa um file path no
# prompt (funciona em qualquer plataforma; é o mesmo mecanismo do `clipssh`).
#
# Uso:
#   ./vm-paste.sh        # VM1 (192.0.2.11 — etl-crm/storefront)
#   ./vm-paste.sh 2      # VM2 (192.0.2.12 — wikiapp)
#
# Fluxo: tira/copia o screenshot (Cmd+Ctrl+Shift+4 vai pro clipboard) → roda este
# script → volta pra aba do Claude na VM e cola (Cmd+V) + Enter.
set -euo pipefail

case "${1:-1}" in
  1) VM_IP="192.0.2.11"; VM_LABEL="VM1" ;;
  2) VM_IP="192.0.2.12"; VM_LABEL="VM2" ;;
  *) echo "Uso: $0 [1|2]   (1=etl-crm/storefront · 2=wikiapp)" >&2; exit 1 ;;
esac
VM_USER="dev"
REMOTE_DIR="/home/${VM_USER}/.claude-pastes"

ts="$(date +%Y%m%d-%H%M%S)"
work="$(mktemp -d -t vm-paste)"
png="${work}/img.png"
trap 'rm -rf "$work"' EXIT

# Extrai a imagem do clipboard do Mac sem dependências externas (osascript nativo).
# Tenta PNG; se o clipboard só tiver TIFF (apps que copiam como TIFF), pega TIFF e
# converte com sips. Retorna PNG | TIFF | NONE.
kind="$(osascript <<APPLESCRIPT 2>/dev/null
try
  set d to (the clipboard as «class PNGf»)
  set f to open for access POSIX file "${png}" with write permission
  set eof f to 0
  write d to f
  close access f
  return "PNG"
on error
  try
    set d to (the clipboard as «class TIFF»)
    set f to open for access POSIX file "${png}.tiff" with write permission
    set eof f to 0
    write d to f
    close access f
    return "TIFF"
  on error
    return "NONE"
  end try
end try
APPLESCRIPT
)"

if [ "${kind:-NONE}" = "NONE" ]; then
  echo "❌ Não há imagem no clipboard do Mac." >&2
  echo "   Copie uma imagem (Cmd+Ctrl+Shift+4 = screenshot pro clipboard) e rode de novo." >&2
  exit 1
fi
if [ "$kind" = "TIFF" ]; then
  sips -s format png "${png}.tiff" --out "$png" >/dev/null
fi

remote_png="${REMOTE_DIR}/${ts}.png"
ssh -o BatchMode=yes "${VM_USER}@${VM_IP}" "mkdir -p '${REMOTE_DIR}'"
scp -q "$png" "${VM_USER}@${VM_IP}:${remote_png}"

# Devolve o path remoto no clipboard do Mac pra você colar como texto no Claude.
printf '%s' "$remote_png" | pbcopy

bytes="$(wc -c < "$png" | tr -d ' ')"
echo "✅ Imagem (${bytes} bytes) → ${VM_LABEL}:${remote_png}"
echo "   O caminho já está no seu clipboard."
echo "   Volte pra aba do Claude na VM, cole (Cmd+V) e dê Enter."
