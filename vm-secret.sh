#!/usr/bin/env bash
# vm-secret.sh — cola um SECRET do clipboard do Mac no ~/Projects/.env da VM,
# SEM que o valor apareça nos logs/transcript do Claude Code.
#
# Por que existe: é o irmão-secret do vm-paste.sh. vm1.sh/vm2.sh rodam o Claude
# DENTRO da VM; credenciais que a VM precisa (ex.: GH_TOKEN) moram em
# ~/Projects/.env — arquivo que o launcher da VM e o ~/.bashrc já lêem (ver
# CONTEXT.md "arquivo padronizado de secrets da VM"). Este script leva um secret
# que está no clipboard do Mac pra esse .env fazendo upsert `KEY=valor`.
#
# Anti-vazamento (o requisito central, não uma opção): o valor flui
#   clipboard → pbpaste → | ssh (STDIN) → append/awk remoto
# Ele NUNCA entra em argv (invisível em `ps` das duas máquinas), NUNCA em stdout
# (a confirmação mostra só os últimos 4 chars), e o script proíbe `set -x`. Por
# isso é seguro rodar tanto pelo Claude (Bash tool) quanto por você via `!`: só
# o NOME da var (não-secreto) e a máscara entram no log.
#
# Uso:
#   ./vm-secret.sh GH_TOKEN         # lê o clipboard → VM1:~/Projects/.env
#   ./vm-secret.sh GH_TOKEN 2       # idem, VM2
# Fluxo: copie o secret (Cmd+C) → rode este script no Mac. O KEY já existente é
# substituído (upsert); o .env fica chmod 600. Nada a encerrar (one-shot).
#
# Seams de teste: VM_SECRET_PBPASTE (default pbpaste), VM_SECRET_SSH (default ssh).

set -u

PBPASTE="${VM_SECRET_PBPASTE:-pbpaste}"
SSH="${VM_SECRET_SSH:-ssh}"

# Mapping VM→IP e user vêm da lib comum (fonte única — P2 dedup).
_SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _lib in "$_SD/bin/lib/vm-common.sh" "$HOME/.claude/bin/lib/vm-common.sh"; do
  # shellcheck source=/dev/null  # caminho resolvido em runtime (lib no repo ou em ~/.claude)
  [ -f "$_lib" ] && { . "$_lib"; break; }
done
command -v vm_ip >/dev/null 2>&1 || { echo "ERRO: bin/lib/vm-common.sh não encontrada." >&2; exit 3; }
VM_USER="$VM_COMMON_USER"

usage() {
  cat >&2 <<EOF
Uso: $0 <KEY> [1|2]
  KEY   nome da env var (^[A-Za-z_][A-Za-z0-9_]*$) — o VALOR vem do clipboard
  1|2   VM destino (default 1) — 1=192.0.2.11, 2=192.0.2.12

Fluxo:
  1. Copie o secret pro clipboard (Cmd+C).
  2. No Mac: $0 <KEY> [1|2]
  3. O secret vai por STDIN do ssh pro ~/Projects/.env da VM (upsert, chmod 600).
     O valor nunca aparece no argv nem no stdout — só a máscara last-4.

Exemplos:
  $0 GH_TOKEN
  $0 GH_PAT_TOKEN 2
EOF
  exit 2
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage
KEY="$1"
VM="${2:-1}"

# KEY validado por forma ANTES de compor qualquer comando remoto: só
# [A-Za-z_][A-Za-z0-9_]* — sem metacaracteres que possam injetar no shell/regex
# remoto. Rejeita vazio, começar com dígito, hífen, ';', etc.
[[ "$KEY" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "❌ KEY inválido: '$KEY' (esperado ^[A-Za-z_][A-Za-z0-9_]*$)" >&2; usage; }

IP="$(vm_ip "$VM")" || { echo "❌ VM inválida: '$VM' (use 1 ou 2)" >&2; usage; }
DEST="${VM_USER}@${IP}"

# Lê o valor do clipboard. Command substitution → o valor fica numa var local
# (não em argv, não em `ps`, não no transcript). Trailing newlines são aparados.
VALUE="$("$PBPASTE")"

[ -n "$VALUE" ] || { echo "❌ Clipboard vazio — copie o secret (Cmd+C) e rode de novo." >&2; exit 1; }
case "$VALUE" in
  *$'\n'*) echo "❌ Clipboard tem múltiplas linhas — um secret de .env é linha única." >&2; exit 1 ;;
esac

# Comando remoto: heredoc NÃO-quotado só para injetar o KEY (já validado, seguro);
# tudo que deve expandir na VM (\$HOME, \$f, \$(...)) vai escapado. O valor NÃO
# aparece aqui — ele chega por STDIN e é lido por `cat` no append final.
#   1. remove linha(s) existentes do KEY (upsert → não duplica)
#   2. append `KEY=<stdin>` — valor nunca toca argv
REMOTE_CMD=$(cat <<REMOTE
set -eu
f="\$HOME/Projects/.env"
mkdir -p "\$(dirname "\$f")"
touch "\$f"; chmod 600 "\$f"
tmp="\$(mktemp "\$(dirname "\$f")/.env-rw.XXXXXX")"
grep -vE '^(export[[:space:]]+)?${KEY}=' "\$f" > "\$tmp" 2>/dev/null || true
mv "\$tmp" "\$f"
{ printf '%s=' '${KEY}'; cat; printf '\n'; } >> "\$f"
chmod 600 "\$f"
REMOTE
)

# printf é builtin → o valor não passa por argv de processo externo. rc do ssh
# propaga (falha nunca vira caminho feliz).
if ! printf '%s' "$VALUE" | "$SSH" -o BatchMode=yes "$DEST" "$REMOTE_CMD"; then
  echo "❌ Falha ao gravar na VM${VM} (${DEST}). O secret NÃO foi enviado." >&2
  exit 1
fi

# Confirmação mascarada: política da browser-secrets (só os últimos 4 chars).
if [ "${#VALUE}" -le 10 ]; then MASKED='****'; else MASKED="...${VALUE: -4}"; fi
echo "✅ ${KEY} → VM${VM}:~/Projects/.env  (${MASKED})"
echo "   Upsert feito (chmod 600). O valor não passou pelo argv nem pelo stdout."
