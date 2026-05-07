#!/usr/bin/env bash
# graphify-init.sh — Bootstrap Graphify (knowledge graph) num repo.
# Executa os passos shell-puros do bootstrap (passos 2-6 do ADR 0001):
#   1. graphify claude install     (CLAUDE.md section + .claude/settings.json hook PreToolUse)
#   2. graphify hook install       (git hooks post-commit + post-checkout, AST-only)
#   3. .gitignore append           (manifest.json, cost.json, cache/)
#   4. .gitattributes append       (graph.json merge=theirs)
#   5. git commit                  (sem push)
#
# IMPORTANTE: o build inicial (passo 1 do ADR) é responsabilidade do agente
# que invoca /graphify-init — `graphify .` é slash command de agente AI, não
# CLI shell. Este script roda APÓS o agente ter rodado /graphify . (skill).
# Pre-flight: aborta se graphify-out/graph.json não existir.
#
# Uso:
#   graphify-init.sh [--allow-dirty]
#     --allow-dirty   pula pre-flight check de working tree dirty

set -euo pipefail

ALLOW_DIRTY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --allow-dirty) ALLOW_DIRTY=true ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Flag desconhecida: $1" >&2; exit 1 ;;
  esac
  shift
done

# 1. Detectar CLI graphify
if ! command -v graphify >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERRO: 'graphify' CLI não está instalado.

Instale 1× por máquina (Princípio 4: instalação requer aprovação humana —
este script não instala automaticamente):

  uv tool install graphifyy
  graphify install

Depois rode /graphify-init de novo.
EOF
  exit 1
fi

# 2. Verificar repo git
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERRO: cwd não é um repositório git." >&2
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

# 3. Pre-flight: graphify-out/graph.json deve existir (gerado pelo agente via /graphify .)
if [ ! -f "graphify-out/graph.json" ]; then
  cat >&2 <<'EOF'
ERRO: graphify-out/graph.json não encontrado.

Este script roda APÓS o build inicial. O build inicial é zero-cost via
subscription Claude Code (subagents) — invoque o slash command no agente AI:

  /graphify .

Depois rode este script (ou /graphify-init, que orquestra os dois passos).
EOF
  exit 1
fi

# 4. Pre-flight: working tree dirty em paths que vamos modificar?
DIRTY_RELEVANT=""
for p in CLAUDE.md .gitignore .gitattributes .claude/settings.json; do
  if [ -e "$p" ] && ! git diff --quiet -- "$p" 2>/dev/null; then
    DIRTY_RELEVANT="$DIRTY_RELEVANT $p"
  fi
  if git diff --cached --quiet -- "$p" 2>/dev/null; then :; else
    [ -e "$p" ] && DIRTY_RELEVANT="$DIRTY_RELEVANT $p (staged)"
  fi
done
if [ -n "$DIRTY_RELEVANT" ] && [ "$ALLOW_DIRTY" != "true" ]; then
  echo "ERRO: working tree tem mudanças não-commitadas em paths que serão modificados:" >&2
  echo "  $DIRTY_RELEVANT" >&2
  echo "" >&2
  echo "Commite/stashe primeiro, ou rode com --allow-dirty pra arrastar essas mudanças" >&2
  echo "pro commit Graphify (decisão consciente sua)." >&2
  exit 1
fi

# 5. Executar passos shell-puros
echo "→ graphify claude install"
graphify claude install

echo "→ graphify hook install"
graphify hook install

# .gitignore append (idempotente)
echo "→ .gitignore: append regras Graphify (idempotente)"
touch .gitignore
for line in 'graphify-out/manifest.json' 'graphify-out/cost.json' 'graphify-out/cache/'; do
  grep -qxF "$line" .gitignore 2>/dev/null || echo "$line" >> .gitignore
done

# .gitattributes append (idempotente)
echo "→ .gitattributes: append merge=theirs (idempotente)"
touch .gitattributes
ATTR_LINE='graphify-out/graph.json merge=theirs'
grep -qxF "$ATTR_LINE" .gitattributes 2>/dev/null || echo "$ATTR_LINE" >> .gitattributes

# 6. git add — só os 5 paths esperados, pulando os gitignored
echo "→ Coletando paths pra commit (skip se gitignored)"
TO_ADD=()
SKIPPED=()
for path in graphify-out/ .gitignore .gitattributes CLAUDE.md .claude/settings.json; do
  if [ ! -e "$path" ]; then
    continue
  fi
  if git check-ignore -q "$path" 2>/dev/null; then
    SKIPPED+=("$path")
    continue
  fi
  TO_ADD+=("$path")
done

for s in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do
  echo "  ⚠ $s gitignored — pulando (esperado em repos onde .claude/ é ephemeral)"
done

if [ ${#TO_ADD[@]} -eq 0 ]; then
  echo ""
  echo "AVISO: nenhum path elegível pra adicionar."
  exit 0
fi

git add "${TO_ADD[@]}"

# Idempotência: re-rodar sem mudanças não cria commit vazio
if git diff --cached --quiet; then
  echo ""
  echo "✓ Sem mudanças staged — repo já estava sincronizado com Graphify."
  exit 0
fi

# 7. Commit (sem push)
git commit -m "$(cat <<'EOF'
feat: install Graphify knowledge graph

graphify-out/ versionado (padrão upstream README:183-197).
.gitignore: manifest.json, cost.json, cache/ excluídos.
.gitattributes: graph.json merge=theirs (resolve conflitos pós-pull).
Hooks: post-commit + post-checkout (AST-only, zero LLM cost).
CLAUDE.md + .claude/settings.json: PreToolUse hook per-repo.
EOF
)"

cat <<EOF

✓ Graphify instalado neste repo.

Próximos passos:
  /commit-push-pr            # cria branch efêmera + push + PR

Notas:
  - Hook post-commit é background-detached (lag de 1 commit aceito por design).
  - Conflitos em graph.json resolvem automaticamente via merge=theirs.
  - /sync (após este push) regenera graph.json em cada slot pós-pull.
EOF
