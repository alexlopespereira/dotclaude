#!/usr/bin/env bash
# sync-telemetry-log.sh — Stop hook: leva o log de telemetria DESTA máquina ao
# repo dotclaude automaticamente (plano M8 / Adv #1).
#
# Por quê: a telemetria DoD/test-spec é escrita em ~/.claude/telemetry/ (local).
# Sem um gatilho automático, esse log NUNCA chega ao git e o requisito de
# telemetria "compartilhada entre máquinas" falha silenciosamente (achado
# adversário #1 — o buraco maior do plano). Este hook fecha o elo: a cada Stop,
# copia o log da máquina para repo/telemetry/ e o stageia, pra que o próximo
# commit/PR do dotclaude o carregue — sem ação manual.
#
# Contrato de hook: best-effort e não-bloqueante. SEMPRE exit 0 (nunca trava a
# sessão), rápido (só cp + git add escopado em telemetry/). O stage é limitado a
# telemetry/ — nunca mexe no resto do working tree do usuário.
#
# Registrado como Stop hook em ~/.claude/settings.json.
#
# Seams de teste:
#   DOTCLAUDE_REPO    — repo alvo (default: ~/Projects/dotclaude).
#   SYNC_CLAUDE_HOME  — base ~/.claude (repassado a sync.sh sync-logs via env).

# Drena o payload JSON do stdin (formato Stop). Não usamos os campos, mas
# consumir evita o hook ficar preso esperando EOF.
cat >/dev/null 2>&1 || true

REPO="${DOTCLAUDE_REPO:-$HOME/Projects/dotclaude}"
SYNC="$REPO/sync.sh"

# Repo/sync ausente (ex: máquina sem o checkout dotclaude) → no-op silencioso.
[ -x "$SYNC" ] || exit 0

# Copia o log desta máquina (dod + test-spec) → repo/telemetry/.
bash "$SYNC" sync-logs >/dev/null 2>&1 || exit 0

# Stage escopado: só telemetry/ entra no index, pro próximo commit do dotclaude
# levar a telemetria ao git. Best-effort — se não é repo git ou git falha, ignora.
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$REPO" add telemetry/ >/dev/null 2>&1 || true
fi

exit 0
