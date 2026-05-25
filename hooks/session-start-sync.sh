#!/usr/bin/env bash
# session-start-sync.sh — SessionStart hook híbrido (plano M8 parte 2 / Adv #6).
#
# Por quê: o source do dotclaude (skills, commands, hooks, bin) é instalado em
# ~/.claude via `sync.sh install`. Sem um gatilho, é fácil dar `git pull` e
# esquecer de instalar → ~/.claude fica stale (foi o que deixou commit-push-pr.sh
# defasado). Este hook fecha o elo no início da sessão.
#
# Gate (AC1): só roda `install` se o checkout dotclaude está num estado seguro —
# working tree LIMPO (`git status --porcelain` vazio) E na branch `main`. Senão
# (tree sujo ou branch != main) NÃO instala, só imprime aviso de drift no stderr.
# Isso nunca clobbera trabalho local não-commitado nem propaga uma branch de
# feature pra ~/.claude. Tradeoff deliberado: telemetria staged (pelo Stop hook)
# também deixa o tree sujo → o hook avisa até o commit landar; o caso-alvo é o
# momento pós-`git pull` limpo, quando o tree ESTÁ limpo em main.
#
# Contrato de hook (AC2): best-effort, NÃO-bloqueante. SEMPRE exit 0; rápido
# (<1s — só checagens git + um install escopado). Saída só no stderr (stdout de
# SessionStart vira contexto da sessão — mantemos limpo). O install tem seus
# próprios guards (aborta se ~/.claude diverge), então o gate aqui é uma
# pré-checagem conservadora, não a única defesa.
#
# Registrado como SessionStart hook em ~/.claude/settings.json (via sync.sh install).
#
# Seams de teste:
#   DOTCLAUDE_REPO   — repo alvo (default: ~/Projects/dotclaude).
#   SYNC_CLAUDE_HOME — base ~/.claude (repassado a sync.sh install via env).

# Drena o payload JSON do stdin (formato SessionStart). Não usamos os campos,
# mas consumir evita o hook ficar preso esperando EOF.
cat >/dev/null 2>&1 || true

REPO="${DOTCLAUDE_REPO:-$HOME/Projects/dotclaude}"
SYNC="$REPO/sync.sh"

# Repo/sync ausente (máquina sem o checkout dotclaude) → no-op silencioso.
[ -x "$SYNC" ] || exit 0

# Gate: estado seguro = repo git + branch main + working tree limpo.
# git mudo (não é repo / git ausente) → trata como NÃO-seguro → avisa.
branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
status="$(git -C "$REPO" status --porcelain 2>/dev/null)"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 && git_ok=1 || git_ok=0

if [ "$git_ok" -eq 1 ] && [ "$branch" = "main" ] && [ -z "$status" ]; then
    echo "[dotclaude] SessionStart: checkout limpo em main → sync.sh install" >&2
    bash "$SYNC" install >/dev/null 2>&1 || true
else
    echo "[dotclaude] SessionStart: drift detectado — install PULADO (não clobbera estado local)." >&2
    if [ "$git_ok" -ne 1 ]; then
        echo "  • '$REPO' não é um repositório git acessível." >&2
    else
        [ "$branch" != "main" ] && echo "  • branch atual: '${branch:-?}' (esperado: main)" >&2
        [ -n "$status" ] && echo "  • working tree sujo ($(printf '%s\n' "$status" | grep -c .) item(ns) pendente(s))" >&2
    fi
    echo "  • rode './sync.sh install' manualmente quando o checkout estiver limpo em main." >&2
fi

exit 0
