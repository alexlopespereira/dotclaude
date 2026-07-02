#!/usr/bin/env bash
# gate-e3.sh — Gate de complexidade E3 do /full-cycle-simple (US-02).
#
# O QUE FAZ
#   Avalia um plano (.claude/plans/<slug>.md) contra os 6 triggers de
#   complexidade T1-T6 — antes embutidos inline na Fase 1.5 de
#   commands/full-cycle-simple.md, agora com fonte única aqui — e reporta se a
#   feature estourou o envelope "simples". Suporta override auditável por
#   marcador HTML-comment no PRÓPRIO plano (fica versionado com ele):
#
#     <!-- gate-e3-override: TN motivo não-vazio -->
#
#   O marcador suprime SOMENTE o trigger TN (T4 suprimido não silencia T2).
#   T6 (hasFinancialCost, Princípio 11e) NÃO é suprimível — gate humano de
#   custo é classe segurança; marcador T6 vira aviso em stderr e T6 dispara.
#   Motivo vazio/whitespace = marcador inválido = trigger dispara normalmente
#   (fail-closed) + aviso em stderr. Supressão efetiva imprime em stdout:
#     GATE_E3_SUPPRESSED: TN — <motivo>
#   Limitação do formato: o motivo não pode conter '>' (fecha o comment).
#
# QUANDO USAR
#   Fase 1.5 do /full-cycle-simple, logo após salvar o plano e o .flags.
#
# INVOCAÇÃO
#   bash $HOME/Projects/dotclaude/bin/gate-e3.sh <plan-file> [flags-file]
#
# SAÍDA / EXIT
#   GATE_E3_CLEAN            + exit 0 — nenhum trigger efetivo
#   GATE_E3_TRIGGERED + list + exit 1 — triggers efetivos ("  - TN: ...")
#   usage em stderr          + exit 2 — args inválidos / plano inexistente
#
#   flags-file ausente é tolerado (T6 simplesmente não dispara) — preserva a
#   semântica do `2>/dev/null` do bloco inline original: o gate não pode
#   quebrar quando a Fase 1 não gerou o .flags.

set -u

usage() { echo "Uso: gate-e3.sh <plan-file> [flags-file]" >&2; }

[ $# -ge 1 ] && [ $# -le 2 ] || { usage; exit 2; }
PLAN_FILE="$1"
FLAGS_FILE="${2:-}"
[ -f "$PLAN_FILE" ] || { usage; echo "gate-e3: plano inexistente: $PLAN_FILE" >&2; exit 2; }

# ── Overrides: <!-- gate-e3-override: TN motivo --> ─────────────────────────
# OV[n] = primeiro motivo válido para Tn (vazio = sem override). O padrão exige
# separador entre TN e o motivo: "T42" não vira override de T4 (fail-closed).
OV=("" "" "" "" "" "" "")
while IFS= read -r marker; do
  [ -n "$marker" ] || continue
  # sed ANCORADO no início do marcador (^<!--…): o .* greedy sem âncora casava
  # a ÚLTIMA ocorrência de 'gate-e3-override:' — motivo contendo o literal
  # 'gate-e3-override: T2' suprimia T2 em vez do TN real (code-review 2026-07-02).
  tn=$(printf '%s' "$marker" | sed -E 's/^<!--[[:space:]]*gate-e3-override:[[:space:]]*T([1-6]).*/\1/')
  motivo=$(printf '%s' "$marker" \
    | sed -E 's/^<!--[[:space:]]*gate-e3-override:[[:space:]]*T[1-6]//; s/-->$//' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  # T6 = hasFinancialCost (Princípio 11e) — gate humano de custo é classe
  # segurança e NÃO é auto-suprimível pelo agente que escreveu o próprio plano.
  if [ "$tn" = "6" ]; then
    echo "gate-e3: T6 (custo financeiro, P11e) não é suprimível por override — T6 dispara normalmente" >&2
    continue
  fi
  if [ -n "$motivo" ]; then
    [ -z "${OV[$tn]}" ] && OV[$tn]="$motivo"
  else
    echo "gate-e3: marcador de override inválido (motivo vazio) — T$tn dispara normalmente" >&2
  fi
done <<EOF
$(grep -oE '<!--[[:space:]]*gate-e3-override:[[:space:]]*T[1-6]([[:space:]][^>]*)?-->' "$PLAN_FILE")
EOF

# ── Triggers T1-T6 (mesma semântica do bloco inline original) ───────────────
TRIG_N=(); TRIG_DESC=()
fire() { TRIG_N+=("$1"); TRIG_DESC+=("$2"); }

# T1 — Plan tem >3 user stories/fatias
SLICES=$(grep -ciE '^(##+[[:space:]]+(Fatia|Slice|Story|US-?[0-9]))|^- \*\*(Fatia|Slice|Story|US-?[0-9])' "$PLAN_FILE") || SLICES=0
if [ "$SLICES" -gt 3 ]; then
  fire 1 "Plan tem $SLICES fatias/stories (>3)"
fi

# T2 — schema migration
if grep -iqE 'migration|alter table|create table|add column|drop column|schema change|alembic|prisma migrate|knex migrate' "$PLAN_FILE"; then
  fire 2 "Plan menciona schema migration"
fi

# T3 — nova dependência externa
if grep -iqE 'npm i(nstall)? |yarn add |pnpm add |pip install |poetry add |cargo add |go get |bundle add ' "$PLAN_FILE"; then
  fire 3 "Plan adiciona nova dependência externa"
fi

# T4 — auth/permissions/security
if grep -iqE '\b(auth|authentication|permission|role|token|session|csrf|cors|rbac|jwt|oauth|sso)\b' "$PLAN_FILE"; then
  fire 4 "Plan toca auth/permissions/security"
fi

# T5 — >5 arquivos tocados (procura por listas de arquivos no plano)
FILES_MENTIONED=$(grep -oE '[a-zA-Z0-9_./\-]+\.(ts|tsx|js|jsx|py|rb|go|rs|java|kt|swift|md|yaml|yml|json|toml|sql|html|css|scss|vue|svelte)' "$PLAN_FILE" | sort -u | wc -l | tr -d ' ')
if [ "$FILES_MENTIONED" -gt 5 ]; then
  fire 5 "Plan menciona $FILES_MENTIONED arquivos (>5)"
fi

# T6 — hasFinancialCost true (flags-file ausente → não dispara)
if [ -n "$FLAGS_FILE" ] && grep -q 'HAS_FINANCIAL_COST=true' "$FLAGS_FILE" 2>/dev/null; then
  fire 6 "hasFinancialCost=true (Princípio 11e)"
fi

# ── Aplica overrides e reporta ──────────────────────────────────────────────
EFFECTIVE=()
if [ ${#TRIG_N[@]} -gt 0 ]; then
  i=0
  while [ "$i" -lt ${#TRIG_N[@]} ]; do
    n="${TRIG_N[$i]}"
    if [ -n "${OV[$n]}" ]; then
      echo "GATE_E3_SUPPRESSED: T$n — ${OV[$n]}"
    else
      EFFECTIVE+=("T$n: ${TRIG_DESC[$i]}")
    fi
    i=$((i+1))
  done
fi

if [ ${#EFFECTIVE[@]} -gt 0 ]; then
  echo "GATE_E3_TRIGGERED"
  printf '  - %s\n' "${EFFECTIVE[@]}"
  exit 1
fi
echo "GATE_E3_CLEAN"
exit 0
