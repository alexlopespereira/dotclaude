#!/usr/bin/env bash
# apply-gitignore.sh — adiciona patterns Ralph ao .gitignore de um projeto.
#
# Uso:
#   ./apply-gitignore.sh                    # aplica em $PWD (raiz do repo)
#   ./apply-gitignore.sh /path/to/repo      # aplica em projeto específico
#   ./apply-gitignore.sh --pool             # aplica no projeto atual + reflete
#                                           # em todos os slots irmãos do pool
#                                           # (Boris Cherny layout: ../$repo-N/)
#
# O que faz:
#   1. Se a raiz do repo não tem .gitignore, cria com os patterns.
#   2. Se já tem .gitignore, faz append SOMENTE dos patterns ainda ausentes
#      (idempotente — rodar 2× não duplica linhas).
#   3. Em modo --pool: depois do commit em um slot, propaga via 'git push'
#      seguido de 'git pull' nos demais slots irmãos.
#
# Patterns adicionados (todos relacionados a artefatos do framework Ralph
# Adversarial — NUNCA devem ser versionados; ver IMPL_PROMPT.md):
#   - .DS_Store          (macOS junk)
#   - .claude/           (research outputs locais, planos de sessão)
#   - progress*.txt      (delta files do worker + outputs do run serial)
#   - progress*.jsonl    (progress.jsonl do run serial + per-story .jsonl)
#   - agents-delta-*.md  (delta files do worker — capturados via stash)
#   - .ralph/            (stash dir do orquestrador)
#   - .ralph-review-*/   (worktrees efêmeros do reviewer Codex)
#
# Defesa em camadas:
#   Layer 1 (este script): .gitignore versionado — propaga via git para todos
#                          os colaboradores e clones.
#   Layer 2 (auto, ralph): .git/info/exclude por slot — escrito por
#                          ensure_slot_excludes_deltas() em preflight_slot.
#                          Não versionado, garante exclusão mesmo em pools
#                          provisionados antes deste script existir.
#
# Saída: imprime o que mudou + status do commit (se aplicado).

set -euo pipefail

POOL_MODE=0
TARGET="${1:-$PWD}"
if [ "$TARGET" = "--pool" ]; then
    POOL_MODE=1
    TARGET="$PWD"
fi

if ! git -C "$TARGET" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "ERRO: '$TARGET' não é um repo git." >&2
    exit 1
fi
TARGET=$(git -C "$TARGET" rev-parse --show-toplevel)

PATTERNS=(
    ".DS_Store"
    ".claude/"
    "progress*.txt"
    "progress*.jsonl"
    "agents-delta-*.md"
    ".ralph/"
    ".ralph-review-*/"
)

GITIGNORE="$TARGET/.gitignore"
ADDED=()

if [ ! -f "$GITIGNORE" ]; then
    {
        echo "# Ralph Adversarial framework artifacts (added by apply-gitignore.sh)"
        printf '%s\n' "${PATTERNS[@]}"
    } > "$GITIGNORE"
    ADDED=("${PATTERNS[@]}")
else
    # Header só é emitido se houver pelo menos uma adição — evita poluir
    # .gitignore com cabeçalhos vazios em runs idempotentes.
    needs_header=0
    for p in "${PATTERNS[@]}"; do
        if ! grep -qxF "$p" "$GITIGNORE" 2>/dev/null; then
            needs_header=1
            break
        fi
    done
    if [ "$needs_header" = "1" ]; then
        # Garante newline antes do header — append seguro mesmo se o arquivo
        # não termina em \n (raro mas acontece em arquivos editados à mão).
        if [ -n "$(tail -c1 "$GITIGNORE")" ]; then
            echo "" >> "$GITIGNORE"
        fi
        echo "" >> "$GITIGNORE"
        echo "# Ralph Adversarial framework artifacts (added by apply-gitignore.sh)" >> "$GITIGNORE"
    fi
    for p in "${PATTERNS[@]}"; do
        if ! grep -qxF "$p" "$GITIGNORE" 2>/dev/null; then
            echo "$p" >> "$GITIGNORE"
            ADDED+=("$p")
        fi
    done
fi

if [ "${#ADDED[@]}" -eq 0 ]; then
    echo "✓ $TARGET/.gitignore já contém todos os patterns (idempotente)."
    if [ "$POOL_MODE" = "1" ]; then
        echo "  (modo --pool: nada para propagar)"
    fi
    exit 0
fi

echo "✓ Adicionado ao $TARGET/.gitignore:"
printf '    %s\n' "${ADDED[@]}"

if [ "$POOL_MODE" = "0" ]; then
    echo ""
    echo "Próximo passo (manual): git add .gitignore && git commit -m 'chore: ignore Ralph framework artifacts'"
    echo "  Para propagar a outros slots do pool: rode novamente com --pool"
    exit 0
fi

# Modo --pool: commit + push + pull nos slots irmãos.
echo ""
echo "→ Modo --pool: commit local + push + pull nos slots irmãos..."

git -C "$TARGET" add .gitignore
git -C "$TARGET" commit -m "chore: ignore Ralph framework artifacts" -q

# Detecta o pool layout: ../<repo>-<N>/ (Boris Cherny). Slots irmãos têm
# o mesmo basename-prefix; o slot atual termina com -<N>.
slot_basename=$(basename "$TARGET")
pool_base=$(dirname "$TARGET")
if ! [[ "$slot_basename" =~ ^(.+)-([0-9]+)$ ]]; then
    echo "AVISO: slot atual ($slot_basename) não casa com layout pool '<repo>-<N>'."
    echo "  Commit local feito; propagação para outros slots foi pulada."
    echo "  Rode 'git push' manualmente se quiser publicar."
    exit 0
fi
repo_prefix="${BASH_REMATCH[1]}"
this_n="${BASH_REMATCH[2]}"

remote_name=$(git -C "$TARGET" remote 2>/dev/null | head -1)
if [ -z "$remote_name" ]; then
    echo "AVISO: slot atual não tem remote configurado — pulando push."
else
    branch=$(git -C "$TARGET" symbolic-ref --short HEAD 2>/dev/null || echo "main")
    git -C "$TARGET" push -q "$remote_name" "$branch"
    echo "  ✓ push de $branch via $remote_name"

    # Pull em cada slot irmão.
    for slot_path in "$pool_base/$repo_prefix"-*; do
        [ -d "$slot_path" ] || continue
        slot_n_basename=$(basename "$slot_path")
        if [ "$slot_n_basename" = "$slot_basename" ]; then
            continue
        fi
        if git -C "$slot_path" pull --ff-only -q "$remote_name" "$branch" 2>/dev/null; then
            echo "  ✓ $slot_n_basename atualizado"
        else
            echo "  ⚠ $slot_n_basename: pull falhou (slot pode estar dirty / em outra branch)"
        fi
    done
fi

echo ""
echo "Concluído."
