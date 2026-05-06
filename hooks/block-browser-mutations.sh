#!/bin/bash
# block-browser-mutations.sh — Hook PreToolUse pra blocklist crítica de Zona 3.
#
# Intercepta mcp__playwright__browser_click. Coleta toda string em
# tool_input recursivamente e faz match case-insensitive contra subset
# crítico de trigger words irreversíveis (delete, pay, transfer, etc.,
# PT+EN). Match = bloqueia (exit 2) com mensagem em stderr. Modelo é
# responsável pelo resto da blocklist (modais, formas de pagamento,
# domínios sensíveis — exigem snapshot/contexto que o hook não tem).
#
# Input: JSON via stdin (formato hook PreToolUse do Claude Code).
# Output: exit 0 (libera) ou exit 2 (bloqueia + mensagem em stderr).
#
# Fail-open por desenho: bug no hook não trava browsing (exit 0 em parse
# error). A defesa em profundidade vem do modelo + da revisão humana.
#
# Detalhes: ~/.claude/skills/browser-actions/SKILL.md
# Triggers canônicos: ~/.claude/skills/browser-actions/blocklist.json
# (este script duplica subset MVP por simplicidade; sync manual).

PYCODE=$(cat <<'PYEOF'
import json
import re
import sys

CRITICAL_TRIGGERS = [
    "delete", "excluir", "remover", "remove",
    "pay", "pagar", "buy", "comprar", "purchase", "confirm purchase",
    "subscribe", "assinar", "unsubscribe",
    "cancel subscription", "cancelar assinatura",
    "transfer", "transferir", "withdraw", "sacar",
    "make public", "tornar publico", "tornar público",
    "publish", "publicar",
]


def collect_strings(obj):
    out = []
    if isinstance(obj, str):
        out.append(obj)
    elif isinstance(obj, dict):
        for v in obj.values():
            out.extend(collect_strings(v))
    elif isinstance(obj, list):
        for item in obj:
            out.extend(collect_strings(item))
    return out


try:
    payload = json.load(sys.stdin)
except Exception as e:
    print(
        f"[block-browser-mutations] JSON parse error: {e}",
        file=sys.stderr,
    )
    sys.exit(0)

if payload.get("tool_name") != "mcp__playwright__browser_click":
    sys.exit(0)

tool_input = payload.get("tool_input") or {}
strings = collect_strings(tool_input)
haystack = " | ".join(strings).lower()

for trigger in CRITICAL_TRIGGERS:
    pattern = r"\b" + re.escape(trigger.lower()) + r"\b"
    if re.search(pattern, haystack, flags=re.UNICODE):
        print(
            f"BLOQUEADO pelo hook block-browser-mutations: trigger word "
            f"'{trigger}' detectada no elemento alvo do click. Acao "
            f"potencialmente irreversivel (Zona 3 / Principio 12 / skill "
            f"browser-actions). Pause e confirme com o humano em texto antes "
            f"de prosseguir. Elemento: {haystack[:200]}",
            file=sys.stderr,
        )
        sys.exit(2)

sys.exit(0)
PYEOF
)

exec /usr/bin/python3 -c "$PYCODE"
