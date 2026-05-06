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
    "hooks"
    "bin"
)

usage() {
    echo "Uso: $0 {install [--force]|backup [--force]|status}"
    echo ""
    echo "  install          — Copia do repo para ~/.claude/. Aborta se ~/.claude/ tem edits divergentes."
    echo "  install --force  — Sobrescreve ~/.claude/ mesmo com diff. Use APENAS para rollback após git revert."
    echo "  backup           — Copia de ~/.claude/ para o repo. Aborta se ~/.claude/ tem versão STALE (já no histórico)."
    echo "  backup --force   — Sobrescreve repo mesmo com regressão detectada. Use APENAS quando rollback intencional."
    echo "  status           — Mostra diferenças"
    exit 1
}

# Retorna 0 se $hash apareceu em alguma versão histórica de $file no repo.
# Usado para detectar stale backup: ~/.claude/ tem conteúdo que JÁ ESTÁ no
# histórico do repo (= cópia antiga, propagar de volta seria regressão).
hash_in_history() {
    local file="$1"
    local hash="$2"
    local commits c h
    commits=$(git -C "$REPO_DIR" log --all --pretty=format:%H -- "$file" 2>/dev/null || true)
    [ -z "$commits" ] && return 1
    for c in $commits; do
        h=$(git -C "$REPO_DIR" rev-parse "$c:$file" 2>/dev/null || true)
        [ "$h" = "$hash" ] && return 0
    done
    return 1
}

# Antes de backup, detecta arquivos em ~/.claude/ cujo conteúdo bate com
# uma versão histórica do mesmo arquivo no repo. Indica drift inverso —
# tipicamente: usuário deu git pull no repo mas esqueceu de rodar
# `./sync.sh install`, depois rodou backup; rsync propagaria a versão
# antiga sobre a nova. Bug observado 3x na fatia F1 (commands/plan.md,
# commands/full-planning-cycle.md, commands/techdebt.md).
detect_stale_backup() {
    local stale_files=()
    local f rel repo_file hash_claude in_scope top
    while IFS= read -r f; do
        rel="${f#$CLAUDE_DIR/}"
        in_scope=0
        for top in "${FILES[@]}" "${DIRS[@]}"; do
            if [ "$rel" = "$top" ] || [[ "$rel" == "$top"/* ]]; then
                in_scope=1
                break
            fi
        done
        [ "$in_scope" -eq 0 ] && continue
        repo_file="$REPO_DIR/$rel"
        [ ! -f "$repo_file" ] && continue
        cmp -s "$f" "$repo_file" && continue
        hash_claude=$(git -C "$REPO_DIR" hash-object "$f" 2>/dev/null || true)
        [ -z "$hash_claude" ] && continue
        if hash_in_history "$rel" "$hash_claude"; then
            stale_files+=("$rel")
        fi
    done < <(find "$CLAUDE_DIR" -type f \( -name "*.md" -o -name "*.sh" -o -name "*.json" \) 2>/dev/null)

    if [ ${#stale_files[@]} -gt 0 ]; then
        echo "" >&2
        echo "ERRO: backup propagaria regressão (${#stale_files[@]} arquivo(s) STALE):" >&2
        printf '  ⚠ %s — ~/.claude/ tem versão histórica do repo\n' "${stale_files[@]}" >&2
        echo "" >&2
        echo "Causa provável: você pulled o repo mas não rodou './sync.sh install'." >&2
        echo "Solução: './sync.sh install --force' para atualizar ~/.claude/ com repo HEAD." >&2
        echo "Bypass:   './sync.sh backup --force' se rollback é intencional." >&2
        return 1
    fi
    return 0
}

sync_to_claude() {
    local force=0
    [ "${1:-}" = "--force" ] && force=1

    if [ "$force" -ne 1 ]; then
        local blocked=0
        for f in "${FILES[@]}"; do
            if [ -f "$REPO_DIR/$f" ] && [ -f "$CLAUDE_DIR/$f" ]; then
                if ! diff -q "$REPO_DIR/$f" "$CLAUDE_DIR/$f" >/dev/null 2>&1; then
                    echo "ERRO: $f difere em ~/.claude/." >&2
                    blocked=1
                fi
            fi
        done
        for d in "${DIRS[@]}"; do
            if [ -d "$REPO_DIR/$d" ] && [ -d "$CLAUDE_DIR/$d" ]; then
                # Filtra só linhas "Files X and Y differ"; ignora "Only in" (skills históricas em ~/.claude/).
                # Capturamos a saída primeiro porque `pipefail` + diff (exit 1 quando há diff) faz
                # `diff -rq | grep -q` retornar não-zero mesmo com match — bug clássico do pipefail.
                local diff_out
                diff_out=$(diff -rq "$REPO_DIR/$d" "$CLAUDE_DIR/$d" 2>/dev/null || true)
                if echo "$diff_out" | grep -q '^Files .* differ$'; then
                    echo "ERRO: $d/ tem arquivos divergentes em ~/.claude/." >&2
                    blocked=1
                fi
            fi
        done
        if [ "$blocked" -eq 1 ]; then
            echo "" >&2
            echo "Use './sync.sh backup' para preservar edits, OU './sync.sh install --force' para sobrescrever (rollback)." >&2
            exit 2
        fi
    fi

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
    local force=0
    [ "${1:-}" = "--force" ] && force=1

    if [ "$force" -ne 1 ]; then
        if ! detect_stale_backup; then
            exit 3
        fi
    fi

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
    install) sync_to_claude "${2:-}" ;;
    backup)  sync_to_repo "${2:-}" ;;
    status)  show_status ;;
    *)       usage ;;
esac
