#!/bin/bash
# sync.sh — Sincroniza dotclaude repo ↔ ~/.claude/
#
# Uso:
#   ./sync.sh install    — Copia do repo para ~/.claude/ (primeira vez ou após git pull)
#   ./sync.sh backup     — Copia de ~/.claude/ para o repo (antes de git commit)
#   ./sync.sh sync-logs  — Copia o log de telemetria DESTA máquina para repo/telemetry/
#   ./sync.sh status     — Mostra diferenças entre repo e ~/.claude/

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
# Seam de teste: SYNC_CLAUDE_HOME sobrescreve a base ~/.claude (testes apontam
# para um sandbox p/ não poluir o ~/.claude real). Default: ~/.claude.
CLAUDE_DIR="${SYNC_CLAUDE_HOME:-$HOME/.claude}"

FILES=(
    "CLAUDE.md"
    "WORKFLOW.md"
)

# telemetry/ é deliberadamente AUSENTE daqui: install propaga só source
# (repo→~/.claude). Manter os logs de telemetria DoD/test-spec fora dos DIRS faz
# skills/ ficar source-puro por construção — o estado mutável nunca mais bloqueia
# install (regressão do bug original; plano M8/Decisão #5). A telemetria viaja no
# sentido oposto (~/.claude→repo) via `sync-logs`, não pelo install.
DIRS=(
    "commands"
    "skills"
    "agents"
    "hooks"
    "bin"
)

usage() {
    echo "Uso: $0 {install [--force]|backup [--force]|sync-logs|status}"
    echo ""
    echo "  install          — Copia do repo para ~/.claude/. Aborta se ~/.claude/ tem edits divergentes."
    echo "  install --force  — Sobrescreve ~/.claude/ mesmo com diff. Use APENAS para rollback após git revert."
    echo "  backup           — Copia de ~/.claude/ para o repo. Aborta se ~/.claude/ tem versão STALE (já no histórico)."
    echo "  backup --force   — Sobrescreve repo mesmo com regressão detectada. Use APENAS quando rollback intencional."
    echo "  sync-logs        — Copia o log de telemetria DESTA máquina (~/.claude/telemetry/) → repo/telemetry/."
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

# _register_hook <EVENT> <SUFFIX> <CMD> — garante (idempotente) que um hook está
# registrado em $CLAUDE_DIR/settings.json sob hooks.<EVENT>. SUFFIX é o sufixo do
# command usado pra detectar registro prévio (no-op se já existe). Registrar no
# install (e não por edit manual de host) faz o gatilho ser reproduzível em
# qualquer máquina — sem isso o script existe em ~/.claude/hooks/ mas nunca
# dispara. Best-effort: nunca derruba o install — settings.json inválido / sem
# python3 retorna não-zero (o chamador só emite aviso). Retorna 0 em sucesso.
_register_hook() {
    local event="$1" suffix="$2" cmd="$3"
    local settings="$CLAUDE_DIR/settings.json"
    SETTINGS_PATH="$settings" HOOK_EVENT="$event" HOOK_SUFFIX="$suffix" HOOK_CMD="$cmd" python3 - <<'PY'
import json, os, sys

path = os.environ["SETTINGS_PATH"]
event = os.environ["HOOK_EVENT"]
suffix = os.environ["HOOK_SUFFIX"]
cmd = os.environ["HOOK_CMD"]

try:
    with open(path) as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}
except (ValueError, OSError):
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)

groups = data.setdefault("hooks", {}).setdefault(event, [])

for group in groups:
    for h in group.get("hooks", []):
        if str(h.get("command", "")).endswith(suffix):
            sys.exit(0)  # já registrado → no-op idempotente (não reescreve)

entry = {"type": "command", "command": cmd}
for group in groups:
    if group.get("matcher", "") == "":
        group.setdefault("hooks", []).append(entry)
        break
else:
    groups.append({"matcher": "", "hooks": [entry]})

tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.replace(tmp, path)
PY
}

# Registra o Stop hook (telemetria → git; achado adversário #1).
register_stop_hook() {
    if _register_hook "Stop" "hooks/sync-telemetry-log.sh" "$CLAUDE_DIR/hooks/sync-telemetry-log.sh"; then
        echo "  ✓ Stop hook (telemetria) registrado em settings.json"
    else
        echo "  ⚠ settings.json: registro do Stop hook pulado (JSON inválido / python3 ausente)" >&2
    fi
}

# Registra o Stop hook de telemetria DoD/test-spec DETERMINÍSTICA (emissão de
# eventos `use` parseando marcadores nos planos persistidos). Substitui a emissão
# prompt-driven que nunca disparava. Registrado ANTES do sync-telemetry hook para
# que os eventos da sessão sejam emitidos antes do backup copiá-los ao git.
register_dod_usage_hook() {
    if _register_hook "Stop" "hooks/dod-usage-log.sh" "$CLAUDE_DIR/hooks/dod-usage-log.sh"; then
        echo "  ✓ Stop hook (dod-usage) registrado em settings.json"
    else
        echo "  ⚠ settings.json: registro do dod-usage hook pulado (JSON inválido / python3 ausente)" >&2
    fi
}

# Registra o SessionStart hook híbrido (auto-install gated; Adv #6 / M8 parte 2).
register_session_start_hook() {
    if _register_hook "SessionStart" "hooks/session-start-sync.sh" "$CLAUDE_DIR/hooks/session-start-sync.sh"; then
        echo "  ✓ SessionStart hook (auto-install) registrado em settings.json"
    else
        echo "  ⚠ settings.json: registro do SessionStart hook pulado (JSON inválido / python3 ausente)" >&2
    fi
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
                diff_out=$(diff -rq -x '.DS_Store' "$REPO_DIR/$d" "$CLAUDE_DIR/$d" 2>/dev/null || true)
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
            rsync -a --delete --exclude='.DS_Store' "$REPO_DIR/$d/" "$CLAUDE_DIR/$d/"
            echo "  ✓ $d/"
        fi
    done
    register_dod_usage_hook
    register_stop_hook
    register_session_start_hook
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
            rsync -a --delete --exclude='.DS_Store' "$CLAUDE_DIR/$d/" "$REPO_DIR/$d/"
            echo "  ✓ $d/"
        fi
    done
    echo "=== Backup concluído. Faça git add/commit/push ==="
}

# sync-logs — own-host copy do log de telemetria DESTA máquina → repo/telemetry/.
# Copiar (não merge) é seguro: cada máquina escreve só seu próprio arquivo
# (<prefix>-usage.<machine-id>.jsonl), paths disjuntos nunca colidem no merge git.
# Copia ambos os prefixes (dod e test-spec) desta máquina; ignora logs de outras
# máquinas e arquivos não-telemetria. Sem machine-id ou sem logs → no-op silencioso.
sync_logs() {
    local logdir destdir idfile mid copied=0 src
    logdir="$CLAUDE_DIR/telemetry"
    destdir="$REPO_DIR/telemetry"
    idfile="$CLAUDE_DIR/.machine-id"

    if [ ! -s "$idfile" ]; then
        echo "sync-logs: $idfile ausente — nenhuma telemetria desta máquina ainda. Nada a copiar."
        return 0
    fi
    mid="$(tr -d ' \t\r\n' < "$idfile")"
    if [ -z "$mid" ]; then
        echo "sync-logs: machine-id vazio em $idfile — nada a copiar." >&2
        return 0
    fi

    echo "=== sync-logs: ~/.claude/telemetry/ → repo/telemetry/ (machine $mid) ==="
    mkdir -p "$destdir"
    shopt -s nullglob
    for src in "$logdir"/*-usage."$mid".jsonl; do
        cp "$src" "$destdir/"
        echo "  ✓ $(basename "$src")"
        copied=$((copied + 1))
    done
    shopt -u nullglob

    if [ "$copied" -eq 0 ]; then
        echo "  (nenhum log *-usage.$mid.jsonl em $logdir)"
    fi
    echo "=== sync-logs: $copied arquivo(s) copiado(s) ==="
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
            changes=$(diff -rq -x '.DS_Store' "$REPO_DIR/$d" "$CLAUDE_DIR/$d" 2>/dev/null || true)
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
    install)   sync_to_claude "${2:-}" ;;
    backup)    sync_to_repo "${2:-}" ;;
    sync-logs) sync_logs ;;
    status)    show_status ;;
    *)         usage ;;
esac
