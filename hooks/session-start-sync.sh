#!/usr/bin/env bash
# session-start-sync.sh — SessionStart hook híbrido (plano M8 parte 2 / Adv #6).
#
# Por quê: o source do dotclaude (skills, commands, hooks, bin) é instalado em
# ~/.claude via `sync.sh install`. Sem um gatilho, é fácil dar `git pull` e
# esquecer de instalar → ~/.claude fica stale (foi o que deixou commit-push-pr.sh
# defasado). Este hook fecha o elo no início da sessão.
#
# Gate (AC1): só roda `install` se o checkout dotclaude está num estado seguro —
# working tree LIMPO (source) E na branch `main`. Senão (tree sujo fora de
# telemetry/ ou branch != main) NÃO instala, só imprime aviso de drift no stderr.
# Isso nunca clobbera trabalho local não-commitado nem propaga uma branch de
# feature pra ~/.claude.
#
# Isenção telemetry/ (US-02): o gate usa `git status --porcelain -- . :(exclude)telemetry`
# (pathspec QUOTADO). A telemetria é staged/escrita pelo Stop hook a cada sessão,
# o que sujava o tree e travava o auto-sync indefinidamente nas VMs (deadlock).
# Dirt SÓ em telemetry/ não é drift de source → o gate ignora e instala mesmo
# assim; dirt FORA de telemetry/ ainda bloqueia.
#
# Auto-pull opt-in (US-02): ANTES do install, se o gate está seguro E há opt-in
# (env DOTCLAUDE_AUTO_PULL=1 OU marcador ~/.claude/.vm-profile), o hook faz
# `git pull --ff-only --quiet` (GIT_TERMINAL_PROMPT=0; com `timeout 20` quando
# timeout(1) existe) pra convergir o checkout com origin/main. Pull que falha
# (non-ff, remote inacessível) só emite aviso no stderr — o hook NÃO aborta e o
# install prossegue do estado local. SEM opt-in nenhum pull ocorre (default
# laptop: o usuário controla o `git pull` à mão).
#
# Contrato de hook (AC2): best-effort, NÃO-bloqueante. SEMPRE exit 0. O caminho
# SEM opt-in é rápido (<1s — só checagens git + install escopado); COM opt-in o
# pull adiciona latência de rede (limitada a 20s via timeout) — o contrato <1s
# vale só sem opt-in. Saída só no stderr (stdout de SessionStart vira contexto da
# sessão — mantemos limpo). O install tem seus próprios guards (aborta se
# ~/.claude diverge), então o gate aqui é uma pré-checagem conservadora.
#
# Registrado como SessionStart hook em ~/.claude/settings.json (via sync.sh install).
#
# Seams de teste:
#   DOTCLAUDE_REPO      — repo alvo (default: ~/Projects/dotclaude).
#   SYNC_CLAUDE_HOME    — base ~/.claude (marcador .vm-profile + repassado ao install).
#   DOTCLAUDE_AUTO_PULL — "1" liga o auto-pull (alternativa ao marcador .vm-profile).

# Drena o payload JSON do stdin (formato SessionStart). Não usamos os campos,
# mas consumir evita o hook ficar preso esperando EOF.
cat >/dev/null 2>&1 || true

REPO="${DOTCLAUDE_REPO:-$HOME/Projects/dotclaude}"
SYNC="$REPO/sync.sh"
CLAUDE_HOME="${SYNC_CLAUDE_HOME:-$HOME/.claude}"

# Repo/sync ausente (máquina sem o checkout dotclaude) → no-op silencioso.
[ -x "$SYNC" ] || exit 0

# Gate: estado seguro = repo git + branch main + working tree limpo (source).
# Pathspec `:(exclude)telemetry` (QUOTADO) isenta a telemetria mutável do Stop
# hook — senão o tree nunca fica limpo nas VMs e o auto-sync trava (deadlock).
# git mudo (não é repo / git ausente) → trata como NÃO-seguro → avisa.
branch="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
status="$(git -C "$REPO" status --porcelain -- . ':(exclude)telemetry' 2>/dev/null)"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 && git_ok=1 || git_ok=0

if [ "$git_ok" -eq 1 ] && [ "$branch" = "main" ] && [ -z "$status" ]; then
    # Gate seguro. Opt-in de auto-pull: env OU marcador na base ~/.claude.
    if [ "${DOTCLAUDE_AUTO_PULL:-}" = "1" ] || [ -f "$CLAUDE_HOME/.vm-profile" ]; then
        echo "[dotclaude] SessionStart: opt-in ativo → git pull --ff-only" >&2
        if command -v timeout >/dev/null 2>&1; then
            GIT_TERMINAL_PROMPT=0 timeout 20 git -C "$REPO" pull --ff-only --quiet 2>/dev/null \
                || echo "  • aviso: git pull --ff-only falhou (non-ff / remote inacessível) — install segue do estado local." >&2
        else
            GIT_TERMINAL_PROMPT=0 git -C "$REPO" pull --ff-only --quiet 2>/dev/null \
                || echo "  • aviso: git pull --ff-only falhou (non-ff / remote inacessível) — install segue do estado local." >&2
        fi
    fi
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
