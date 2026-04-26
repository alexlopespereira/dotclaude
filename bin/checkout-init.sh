#!/usr/bin/env bash
# checkout-init.sh — Provisiona N checkouts paralelos do mesmo repositório.
# Modelo: trunk-based, sem branches por feature. Cada slot é uma cópia física do main.
#
# Uso:
#   checkout-init.sh <repo-url-ou-path> [--slots=N] [--no-install] [--copy-env]
#
# Default: 5 slots (workflow Boris Cherny).

set -euo pipefail

CHECKOUT_BASE="$HOME/Projects/checkouts"
SLOTS=5
NO_INSTALL=false
COPY_ENV=false
SOURCE=""

usage() {
  cat <<EOF
Uso: $(basename "$0") <repo-url-ou-path> [--slots=N] [--no-install] [--copy-env]

Provisiona N checkouts paralelos em ~/Projects/checkouts/<repo>-{1..N}.

Opções:
  --slots=N      Número de checkouts (default: 5).
  --no-install   Pula instalação de dependências.
  --copy-env     Copia .env, .env.local, .env.development do source local.
  -h, --help     Mostra esta mensagem.
EOF
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage ;;
    --slots=*) SLOTS="${1#*=}" ;;
    --no-install) NO_INSTALL=true ;;
    --copy-env) COPY_ENV=true ;;
    -*) echo "Flag desconhecida: $1" >&2; exit 1 ;;
    *) [ -z "$SOURCE" ] && SOURCE="$1" || echo "Arg extra ignorado: $1" >&2 ;;
  esac
  shift
done

[ -z "$SOURCE" ] && { echo "ERRO: passe a URL ou path do repo. -h para ajuda." >&2; exit 1; }
[ "$SLOTS" -ge 1 ] && [ "$SLOTS" -le 10 ] || { echo "ERRO: --slots deve estar entre 1 e 10." >&2; exit 1; }

# Resolver fonte e nome do repo
if [ -d "$SOURCE/.git" ] || git -C "$SOURCE" rev-parse --git-dir >/dev/null 2>&1; then
  REPO_ROOT=$(git -C "$SOURCE" rev-parse --show-toplevel)
  REPO_NAME=$(basename "$REPO_ROOT")
  CLONE_URL=$(git -C "$SOURCE" remote get-url origin 2>/dev/null) || CLONE_URL="$SOURCE"
  LOCAL_REF="$REPO_ROOT"
else
  REPO_NAME=$(basename "$SOURCE" .git)
  CLONE_URL="$SOURCE"
  LOCAL_REF=""
fi

[[ "$REPO_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "ERRO: nome de repo inválido '$REPO_NAME'." >&2; exit 1; }

mkdir -p "$CHECKOUT_BASE"

# Verificar conflitos antes de criar nada
for i in $(seq 1 "$SLOTS"); do
  SLOT_PATH="$CHECKOUT_BASE/${REPO_NAME}-${i}"
  if [ -e "$SLOT_PATH" ]; then
    echo "ERRO: $SLOT_PATH já existe. Aborte ou remova manualmente." >&2
    exit 1
  fi
done

# Clonar
for i in $(seq 1 "$SLOTS"); do
  SLOT_PATH="$CHECKOUT_BASE/${REPO_NAME}-${i}"
  echo "→ Clonando slot $i em $SLOT_PATH"
  if [ -n "$LOCAL_REF" ]; then
    git clone --reference-if-able "$LOCAL_REF" "$CLONE_URL" "$SLOT_PATH" || { echo "Falha no clone slot $i" >&2; exit 1; }
  else
    git clone "$CLONE_URL" "$SLOT_PATH" || { echo "Falha no clone slot $i" >&2; exit 1; }
  fi
done

# Copiar .env se solicitado
if [ "$COPY_ENV" = "true" ] && [ -n "$LOCAL_REF" ]; then
  for i in $(seq 1 "$SLOTS"); do
    SLOT_PATH="$CHECKOUT_BASE/${REPO_NAME}-${i}"
    for envfile in .env .env.local .env.development; do
      [ -f "$LOCAL_REF/$envfile" ] && cp "$LOCAL_REF/$envfile" "$SLOT_PATH/$envfile"
    done
  done
  echo "→ Arquivos .env copiados"
fi

# Instalar dependências
if [ "$NO_INSTALL" != "true" ]; then
  FIRST="$CHECKOUT_BASE/${REPO_NAME}-1"
  PM=""
  if [ -f "$FIRST/pnpm-lock.yaml" ]; then PM="pnpm install --frozen-lockfile"
  elif [ -f "$FIRST/yarn.lock" ]; then PM="yarn install --frozen-lockfile"
  elif [ -f "$FIRST/bun.lockb" ] || [ -f "$FIRST/bun.lock" ]; then PM="bun install --frozen-lockfile"
  elif [ -f "$FIRST/package-lock.json" ]; then PM="npm ci"
  elif [ -f "$FIRST/package.json" ]; then PM="npm install"
  fi

  if [ -n "$PM" ]; then
    for i in $(seq 1 "$SLOTS"); do
      SLOT_PATH="$CHECKOUT_BASE/${REPO_NAME}-${i}"
      echo "→ Instalando deps no slot $i: $PM"
      ( cd "$SLOT_PATH" && eval "$PM" ) || echo "AVISO: install falhou no slot $i"
    done
  else
    echo "→ Sem package manager Node detectado — pule install ou rode manualmente."
  fi
fi

# Metadata
cat > "$CHECKOUT_BASE/.${REPO_NAME}.pool" <<EOF
repo_name=$REPO_NAME
clone_url=$CLONE_URL
slots=$SLOTS
created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

cat <<EOF

Pool '$REPO_NAME' provisionado:
  slots:   $SLOTS em $CHECKOUT_BASE/${REPO_NAME}-{1..$SLOTS}
  modelo:  trunk-based (sem branches por feature; trabalho direto em main)

Próximos passos:
  /checkout-launch $REPO_NAME            # abre $SLOTS abas no terminal
  /checkout-sync-all $REPO_NAME          # sincroniza todos os slots com origin/main
EOF
