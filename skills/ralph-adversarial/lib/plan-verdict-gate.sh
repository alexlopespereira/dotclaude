#!/usr/bin/env bash
# plan-verdict-gate.sh — Backstop determinístico do choke point plano → prd.json.
#
# PROBLEMA QUE RESOLVE: o ciclo de revisão adversária do harness é ADITIVO —
# anexa o parecer no rodapé do plano (sob `---`) e transforma ressalvas em ACs,
# mas NUNCA reescreve o CORPO. O prd-convert lê só o corpo. Logo, uma decisão
# condenada pelo Revisor sobrevive no corpo e vira user story executável.
# Incidente-fonte (vm1/etl-crm-3, 2026-07-17): corpo com "criar CMDT
# HumanQueue default false" (condenado nos Ciclos 1–2) + veredito no rodapé →
# a story gerada secaria a fila humana em produção.
#
# Este gate recusa converter quando o corpo não reflete o veredito FINAL:
#   - REPROVADO                → nunca converte (escale para humano).
#   - APROVADO COM RESSALVAS   → exige o marcador <!-- plan-reconciled --> que o
#                                produtor carimba SÓ depois de reescrever o corpo
#                                (remover/corrigir cada finding Crítica/Alta).
#   - APROVADO / sem parecer   → OK (corpo limpo ou plano nunca revisado, ex.:
#                                /full-cycle-simple, que pula a Fase adversária).
#
# Usage:
#   plan-verdict-gate.sh <plano.md>
#
# Exit codes:
#   0 — OK converter
#   1 — BLOQUEIO (REPROVADO, ou ressalvas sem reconciliação do corpo)
#   2 — usage (sem arg / arquivo inexistente)
#
# Bash 3.2 compatível (macOS). Sem deps: grep/sed puro, sem jq.

set -u

RECONCILE_MARKER='<!-- plan-reconciled'

PLAN="${1:-}"
if [ -z "$PLAN" ]; then
    echo "ERROR: caminho do plano requerido. Uso: plan-verdict-gate.sh <plano.md>" >&2
    exit 2
fi
if [ ! -f "$PLAN" ]; then
    echo "ERROR: plano não encontrado: $PLAN" >&2
    exit 2
fi

# ── Extrai o ÚLTIMO veredito real (ignora o placeholder do template) ──────
# Linha de veredito: "**Veredicto:** <status>". O placeholder do template
# react-feynman é "**Veredicto:** [APROVADO / APROVADO COM RESSALVAS / REPROVADO]"
# — reconhecível pelos `/` separando as três opções entre colchetes; não é um
# veredito preenchido, então é descartado.
verdict_line=$(grep -i '\*\*Veredicto:\*\*' "$PLAN" 2>/dev/null \
    | grep -v '/.*/' \
    | tail -1)

# Sem veredito preenchido: plano nunca revisado (ou só o template). Converter é
# permitido — não dá para distinguir "nunca revisado" de "revisão incompleta" de
# forma determinística, e /full-cycle-simple legitimamente pula a revisão.
if [ -z "$verdict_line" ]; then
    echo "plan-verdict-gate: sem veredito adversário preenchido em $PLAN — OK converter (plano não passou por revisão, ou só template)."
    exit 0
fi

# Normaliza para uppercase para classificar (case-insensitive).
verdict_uc=$(printf '%s' "$verdict_line" | tr '[:lower:]' '[:upper:]')

# Ordem de teste importa: REPROVADO antes de APROVADO (não são substring um do
# outro, mas a ordem deixa a intenção explícita); RESSALVAS antes de APROVADO-só.
case "$verdict_uc" in
    *REPROVADO*)
        echo "BLOQUEIO: veredito final é REPROVADO em $PLAN." >&2
        echo "  Não converta um plano reprovado. Escale para humano (sugestão: /reflect --on-failure 3)." >&2
        exit 1
        ;;
    *RESSALVAS*)
        if grep -qF "$RECONCILE_MARKER" "$PLAN"; then
            echo "plan-verdict-gate: APROVADO COM RESSALVAS + corpo reconciliado ($RECONCILE_MARKER presente) — OK converter."
            exit 0
        fi
        echo "BLOQUEIO: veredito é APROVADO COM RESSALVAS mas o CORPO não foi reconciliado em $PLAN." >&2
        echo "  Falta o marcador '$RECONCILE_MARKER -->'. O parecer no rodapé NÃO reescreve o corpo;" >&2
        echo "  prd-convert lê o corpo. Reconcilie ANTES de converter:" >&2
        echo "    1. Para cada finding Crítica/Alta abaixo, edite/remova a decisão condenada no CORPO do plano." >&2
        echo "    2. Carimbe '$RECONCILE_MARKER: <verdict-slug> -->' no topo do corpo." >&2
        echo "    3. Rode este gate de novo." >&2
        # Guia: ecoa as linhas Crítica/Alta da tabela "Falhas Encontradas".
        criticas=$(grep -iE '^\|.*\|.*(Crítica|Critica|Alta).*\|' "$PLAN" 2>/dev/null)
        if [ -n "$criticas" ]; then
            echo "  Findings bloqueantes a reconciliar no corpo:" >&2
            printf '%s\n' "$criticas" | sed 's/^/    /' >&2
        fi
        exit 1
        ;;
    *APROVADO*)
        echo "plan-verdict-gate: veredito APROVADO (sem ressalvas) em $PLAN — OK converter."
        exit 0
        ;;
    *)
        # Linha de veredito presente mas status irreconhecível: conservador —
        # não bloqueia (pode ser variação de redação), mas avisa.
        echo "plan-verdict-gate: veredito não classificável ('$verdict_line') em $PLAN — OK converter (aviso: revise manualmente)." >&2
        exit 0
        ;;
esac
