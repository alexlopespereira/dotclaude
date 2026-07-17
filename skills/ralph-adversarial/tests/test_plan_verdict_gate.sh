#!/usr/bin/env bash
# test_plan_verdict_gate.sh — cobre plan-verdict-gate.sh (../lib/plan-verdict-gate.sh).
#
# O gate é o backstop determinístico do choke point plano→prd.json: recusa
# converter um plano cujo CORPO ainda não reflete o veredito adversário final.
# Origem: incidente vm1/etl-crm-3 (2026-07-17) — parecer apenso no
# rodapé, corpo com decisão condenada ("CMDT HumanQueue default false"), prd
# gerado secaria a fila humana em prod.
#
# Convenção: cria planos temporários em fixtures ad-hoc, roda o gate, assere
# exit code. Sem deps externas além de jq-free (o gate é grep/sed puro).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SCRIPT_DIR/../lib/plan-verdict-gate.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/plan-verdict-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # <descrição> <esperado-rc> <arquivo>
    local desc="$1" want="$2" file="$3"
    bash "$GATE" "$file" >/dev/null 2>&1; local got=$?
    if [ "$got" = "$want" ]; then
        printf "  PASS  %-52s (rc=%s)\n" "$desc" "$got"; pass=$((pass+1))
    else
        printf "  FAIL  %-52s want=%s got=%s\n" "$desc" "$want" "$got"; fail=$((fail+1))
    fi
}

# ── Corpo comum (o que prd-convert consome) ──────────────────────────────
BODY='# Plano: sincronizar fila

## Decisões técnicas
| # | Decisão |
|---|---------|
| 1 | criar CMDT HumanQueue default false |

## Próxima Fatia
Implementar a CMDT.
'

# 1. Plano sem parecer nenhum (nunca revisado — /full-cycle-simple) → PASS (rc 0)
printf '%s' "$BODY" > "$TMP/sem-parecer.md"
check "sem parecer adversário" 0 "$TMP/sem-parecer.md"

# 2. APROVADO limpo → PASS
{ printf '%s\n---\n' "$BODY"
  printf '## Revisão Adversária: fila\n**Veredicto:** APROVADO\n'; } > "$TMP/aprovado.md"
check "veredito APROVADO limpo" 0 "$TMP/aprovado.md"

# 3. REPROVADO → BLOCK (rc 1) — nunca converter plano reprovado
{ printf '%s\n---\n' "$BODY"
  printf '## Revisão Adversária: fila\n**Veredicto:** REPROVADO\n'; } > "$TMP/reprovado.md"
check "veredito REPROVADO" 1 "$TMP/reprovado.md"

# 4. APROVADO COM RESSALVAS SEM marcador de reconciliação → BLOCK (o incidente)
{ printf '%s\n---\n' "$BODY"
  printf '## Revisão Adversária: fila\n**Veredicto:** APROVADO COM RESSALVAS\n'
  printf '### Falhas Encontradas\n| # | Tipo | Descrição | Severidade | Sugestão |\n'
  printf '| 1 | Risco | CMDT default false seca a fila | Crítica | não criar |\n'; } > "$TMP/ressalvas-sem-marcador.md"
check "APROVADO COM RESSALVAS sem <!-- plan-reconciled -->" 1 "$TMP/ressalvas-sem-marcador.md"

# 5. APROVADO COM RESSALVAS COM marcador (corpo reconciliado) → PASS
{ printf '<!-- plan-reconciled: aprovado-com-ressalvas -->\n%s\n---\n' "$BODY"
  printf '## Revisão Adversária: fila\n**Veredicto:** APROVADO COM RESSALVAS\n'; } > "$TMP/ressalvas-reconciliado.md"
check "APROVADO COM RESSALVAS com marcador" 0 "$TMP/ressalvas-reconciliado.md"

# 6. Múltiplos ciclos: pega o ÚLTIMO veredito (Ciclo 3 REPROVADO vence Ciclo 1 APROVADO)
{ printf '%s\n---\n' "$BODY"
  printf '## Revisão Adversária (Ciclo 1)\n**Veredicto:** APROVADO COM RESSALVAS\n\n---\n'
  printf '## Revisão Adversária (Ciclo 3)\n**Veredicto:** REPROVADO\n'; } > "$TMP/multi-ciclo.md"
check "multi-ciclo usa o último veredito (REPROVADO)" 1 "$TMP/multi-ciclo.md"

# 7. Placeholder do template (não preenchido) não é veredito real → PASS
{ printf '%s\n---\n' "$BODY"
  printf '## Template: Revisão Adversária\n'
  printf '**Veredicto:** [APROVADO / APROVADO COM RESSALVAS / REPROVADO]\n'; } > "$TMP/placeholder.md"
check "placeholder do template ignorado" 0 "$TMP/placeholder.md"

# 8. Usage: arquivo inexistente → rc 2
check "arquivo inexistente" 2 "$TMP/nao-existe.md"

# 9. Usage: sem argumento → rc 2
bash "$GATE" >/dev/null 2>&1; got=$?
if [ "$got" = 2 ]; then printf "  PASS  %-52s (rc=2)\n" "sem argumento"; pass=$((pass+1))
else printf "  FAIL  %-52s want=2 got=%s\n" "sem argumento" "$got"; fail=$((fail+1)); fi

echo
echo "test_plan_verdict_gate: $pass/$((pass+fail)) pass"
[ "$fail" -gt 0 ] && exit 1
exit 0
