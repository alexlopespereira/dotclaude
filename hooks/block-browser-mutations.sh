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
# Fail-closed em DEPENDÊNCIA/erro de processo, fail-open em payload inválido
# (ressalva R3 / US-02): no contrato PreToolUse só exit 2 bloqueia. Se o
# interpretador python3 some ou o wrapper bash falha, o hook BLOQUEIA (exit 2)
# em vez de liberar silenciosamente — `set -u` + `trap ... exit 2 ERR` garantem
# que nenhum erro interno vire exit 1/0. Já um payload JSON malformado de uma
# tool não-alvo continua FAIL-OPEN (o Python sai 0): não faz sentido travar
# todo o browsing por lixo de entrada — a defesa em profundidade vem do modelo
# + revisão humana.
#
# Detalhes: ~/.claude/skills/browser-actions/SKILL.md
# Triggers canônicos: ~/.claude/skills/browser-actions/blocklist.json
# (este script duplica subset MVP por simplicidade; sync manual).
#
# Allowlist por sessão: BBM_ALLOW_TRIGGERS="comprar,pay" remove esses termos
# (case-insensitive, trim) dos triggers ANTES do match — caso de uso: e2e
# Playwright contra loja em ambiente de teste, onde clicar "Comprar" é o
# fluxo sob teste e não uma mutação real (FP observado na análise de logs
# 2026-06-09). Env ausente/vazia = comportamento estrito inalterado.

set -u
# shellcheck disable=SC2154  # rc é atribuído (rc=$?) no início da própria string do trap
trap 'rc=$?; echo "BLOQUEADO (hook error): block-browser-mutations.sh falhou internamente (rc=$rc) — fail-closed (Princípio 12 / Zona 3). Verifique python3 e o ambiente antes de prosseguir." >&2; exit 2' ERR

# Dependência obrigatória: python3. Seam BBM_PYTHON permite o teste apontar
# para um caminho inexistente e provar o fail-closed (python ausente → exit 2).
PYBIN="${BBM_PYTHON:-/usr/bin/python3}"
if ! command -v "$PYBIN" >/dev/null 2>&1; then
  echo "BLOQUEADO (dependency missing): python3 não encontrado ('$PYBIN') — block-browser-mutations.sh precisa de python3 para avaliar o click. Fail-closed por segurança (Zona 3)." >&2
  exit 2
fi

PYCODE=$(cat <<'PYEOF'
import json
import os
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

# BBM_ALLOW_TRIGGERS: termos liberados nesta sessão (e2e em ambiente de
# teste). Só remove matches exatos da lista — os demais triggers seguem ativos.
_allow = {
    t.strip().lower()
    for t in os.environ.get("BBM_ALLOW_TRIGGERS", "").split(",")
    if t.strip()
}
active_triggers = [t for t in CRITICAL_TRIGGERS if t.lower() not in _allow]

for trigger in active_triggers:
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

exec "$PYBIN" -c "$PYCODE"
