#!/bin/bash
# sync.sh — Sincroniza dotclaude repo ↔ ~/.claude/
#
# Uso:
#   ./sync.sh install   — Copia do repo para ~/.claude/ (primeira vez ou após git pull)
#   ./sync.sh backup    — Copia de ~/.claude/ para o repo (antes de git commit)
#   ./sync.sh status    — Mostra diferenças entre repo e ~/.claude/

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

FILES=(
    "CLAUDE.md"
    "WORKFLOW.md"
)

DIRS=(
    "commands"
    "skills"
    "agents"
)

usage() {
    echo "Uso: $0 {install|backup|status}"
    echo ""
    echo "  install  — Copia do repo para ~/.claude/"
    echo "  backup   — Copia de ~/.claude/ para o repo"
    echo "  status   — Mostra diferenças"
    exit 1
}

sync_to_claude() {
    echo "=== Instalando: repo → ~/.claude/ ==="
    for f in "${FILES[@]}"; do
        if [ -f "$REPO_DIR/$f" ]; then
            cp "$REPO_DIR/$f" "$CLAUDE_DIR/$f"
            echo "  ✓ $f"
        fi
    done
    for d in "${DIRS[@]}"; do
        if [ -d "$REPO_DIR/$d" ]; then
            mkdir -p "$CLAUDE_DIR/$d"
            rsync -a --delete "$REPO_DIR/$d/" "$CLAUDE_DIR/$d/"
            echo "  ✓ $d/"
        fi
    done
    echo "=== Instalação concluída ==="
}

sync_to_repo() {
    echo "=== Backup: ~/.claude/ → repo ==="
    for f in "${FILES[@]}"; do
        if [ -f "$CLAUDE_DIR/$f" ]; then
            cp "$CLAUDE_DIR/$f" "$REPO_DIR/$f"
            echo "  ✓ $f"
        fi
    done
    for d in "${DIRS[@]}"; do
        if [ -d "$CLAUDE_DIR/$d" ]; then
            rsync -a --delete "$CLAUDE_DIR/$d/" "$REPO_DIR/$d/"
            echo "  ✓ $d/"
        fi
    done
    echo "=== Backup concluído. Faça git add/commit/push ==="
}

show_status() {
    echo "=== Diferenças: repo vs ~/.claude/ ==="
    local has_diff=false
    for f in "${FILES[@]}"; do
        if [ -f "$REPO_DIR/$f" ] && [ -f "$CLAUDE_DIR/$f" ]; then
            if ! diff -q "$REPO_DIR/$f" "$CLAUDE_DIR/$f" > /dev/null 2>&1; then
                echo "  ≠ $f (diferente)"
                has_diff=true
            else
                echo "  = $f (igual)"
            fi
        elif [ -f "$REPO_DIR/$f" ]; then
            echo "  + $f (só no repo)"
            has_diff=true
        elif [ -f "$CLAUDE_DIR/$f" ]; then
            echo "  - $f (só em ~/.claude/)"
            has_diff=true
        fi
    done
    for d in "${DIRS[@]}"; do
        if [ -d "$REPO_DIR/$d" ] && [ -d "$CLAUDE_DIR/$d" ]; then
            local changes
            changes=$(diff -rq "$REPO_DIR/$d" "$CLAUDE_DIR/$d" 2>/dev/null || true)
            if [ -n "$changes" ]; then
                echo "  ≠ $d/ (diferente)"
                echo "$changes" | sed 's/^/      /'
                has_diff=true
            else
                echo "  = $d/ (igual)"
            fi
        elif [ -d "$REPO_DIR/$d" ]; then
            echo "  + $d/ (só no repo)"
            has_diff=true
        elif [ -d "$CLAUDE_DIR/$d" ]; then
            echo "  - $d/ (só em ~/.claude/)"
            has_diff=true
        fi
    done
    if [ "$has_diff" = false ]; then
        echo "  Tudo sincronizado!"
    fi
}

case "${1:-}" in
    install) sync_to_claude ;;
    backup)  sync_to_repo ;;
    status)  show_status ;;
    *)       usage ;;
esac
