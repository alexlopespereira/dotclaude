#!/usr/bin/env bash
# install.sh — Instala o bootstrap da LLM Wiki num repositório alvo.
#
# Uso:
#   ./install.sh /caminho/do/repo-alvo              # instalação nova (não sobrescreve wiki/)
#   ./install.sh /caminho/do/repo-alvo --update     # atualiza AGENTS/lint/workflow (preserva wiki/)
#
# O script NUNCA toca em wiki/ se ele já existe e tiver conteúdo.
# AGENTS.md, wiki-lint.py e .github/workflows/wiki-update.yml são sempre sobrescritos.

set -euo pipefail

die() { echo "erro: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "uso: $0 <repo-alvo> [--update]"
TARGET="$1"
MODE="${2:-install}"

[[ -d "$TARGET" ]] || die "diretório não encontrado: $TARGET"
[[ -d "$TARGET/.git" || -f "$TARGET/.git" ]] || die "não é um repositório git: $TARGET"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">> Instalando LLM Wiki bootstrap em: $TARGET"
echo "   modo: $MODE"
echo "   source: $SRC"
echo

# ─── Sempre copia (sobrescreve) ──────────────────────────────────────
cp "$SRC/AGENTS.md"                        "$TARGET/AGENTS.md"
cp "$SRC/wiki-lint.py"                     "$TARGET/wiki-lint.py"
chmod +x "$TARGET/wiki-lint.py"

mkdir -p "$TARGET/.github/workflows"
cp "$SRC/wiki-update.yml"                  "$TARGET/.github/workflows/wiki-update.yml"

echo "  ok  AGENTS.md"
echo "  ok  wiki-lint.py"
echo "  ok  .github/workflows/wiki-update.yml"

# ─── Só cria wiki/ se não existe ou se modo=install e está vazio ─────
if [[ -d "$TARGET/wiki" ]] && [[ -n "$(ls -A "$TARGET/wiki" 2>/dev/null)" ]]; then
  if [[ "$MODE" == "--update" ]]; then
    echo "  skip wiki/ (preservado em modo --update)"
  else
    echo "  skip wiki/ (já existe com conteúdo; use --update se for intencional)"
  fi
else
  mkdir -p "$TARGET/wiki"
  cp -r "$SRC/wiki/." "$TARGET/wiki/"
  echo "  ok  wiki/ (template inicial)"
fi

echo
echo ">> Próximos passos (rode no repo-alvo):"
echo
echo "  cd $TARGET"
echo
echo "  # 1. Gere OAuth token da subscription (1x por máquina, reusável em todos os repos)"
echo "  claude setup-token"
echo
echo "  # 2. Adicione como secret no GitHub"
echo "  gh secret set CLAUDE_CODE_OAUTH_TOKEN"
echo
echo "  # 3. Bootstrap manual da wiki (Opus 4.7 via subscription)"
echo "  claude -p \"Leia todo o código-fonte deste repositório e popule wiki/ seguindo AGENTS.md. Comece pelo index.md.\""
echo
echo "  # 4. Valide"
echo "  python wiki-lint.py"
echo
echo "  # 5. Commit"
echo "  git add AGENTS.md wiki-lint.py .github/workflows/wiki-update.yml wiki/"
echo "  git commit -m 'feat: install LLM Wiki system'"
echo
