#!/usr/bin/env bash
set -u

# test_us04_skill_integration.sh — regressão de PROTOCOLO de US-04:
# auto-grill-me e react-feynman integrados à biblioteca domain-docs (US-01).
#
# Por que existe: a mudança é de DOCUMENTAÇÃO (texto de skill). Sem teste, uma
# regressão que (a) faça auto-grill-me escrever assunção silenciosa no glossário,
# (b) remova a seção '## ADRs propostos' do Template: Plano do react-feynman,
# (c) apague a regra de transbordo HST, ou (d) reintroduza cópia das regras de
# formato nas skills passaria silenciosa. Espelha test_grill_skills_delegation.sh
# (US-02) e test_us03_command_docs.sh (US-03).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGM="$REPO_ROOT/skills/auto-grill-me/SKILL.md"
RF="$REPO_ROOT/skills/react-feynman/SKILL.md"
LIB="$REPO_ROOT/skills/domain-docs/SKILL.md"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_present() {
  if grep -qF -- "$2" "$1"; then _pass
  else _fail "$3 :: '$2' AUSENTE de $(basename "$(dirname "$1")")/$(basename "$1")"; fi
}
assert_absent() {
  if grep -qF -- "$2" "$1"; then
    _fail "$3 :: '$2' PRESENTE em $(basename "$(dirname "$1")")/$(basename "$1") (não deveria)"
  else _pass; fi
}

for f in "$AGM" "$RF" "$LIB"; do
  [[ -f "$f" ]] || { echo "FAIL: $f inexistente" >&2; exit 1; }
done

# ─── AC1 — auto-grill-me escreve no CONTEXT.md só p/ pergunta respondida (Tipo 1);
#           assunção silenciosa (score baixo/médio) fica fora do glossário ──────
assert_present "$AGM" "domain-docs"  "AC1 auto-grill-me referencia a biblioteca domain-docs"
assert_present "$AGM" "~/.claude/skills/domain-docs/" "AC1 auto-grill-me cita o path fixo da biblioteca"
assert_present "$AGM" "inline"       "AC1 auto-grill-me invoca o modo inline"
# Regra positiva: Tipo 1 (pergunta respondida pelo usuário) → CONTEXT.md inline.
assert_present "$AGM" "Tipo 1"       "AC1 a regra distingue o Tipo 1 (pergunta respondida)"
assert_present "$AGM" "pergunta efetivamente respondida pelo usuário" "AC1 só a pergunta respondida vira termo (verbatim AC)"
# Regra negativa (capture-proof, co-presente com a positiva acima): assunção
# silenciosa de score baixo/médio NÃO entra no glossário.
assert_present "$AGM" "Assunção silenciosa não é decisão do usuário" "AC1 assunção silenciosa NÃO vai pro CONTEXT.md (regra explícita)"
assert_present "$AGM" "Tipo 2 / Tipo 3" "AC1 a regra nomeia os tipos de assunção silenciosa (score baixo/médio)"

# ─── AC2 — react-feynman Template: Plano inclui a seção '## ADRs propostos' ──────
# (texto integral dos ADRs + gates de materialização, por referência à biblioteca)
assert_present "$RF" "## ADRs propostos" "AC2 Template: Plano inclui a seção '## ADRs propostos'"
assert_present "$RF" "texto integral"    "AC2 a seção carrega o texto INTEGRAL de cada ADR"
assert_present "$RF" "materializ"        "AC2 a seção referencia os gates de materialização"
assert_present "$RF" "<!-- adr-materialized -->" "AC2 cita o marcador de quitação por referência à biblioteca"

# ─── AC3 — react-feynman Modo HST contém a regra de transbordo ───────────────────
# Fase 1 (System Intent) em store próprio; termo de domínio → CONTEXT.md;
# restrição global no gate triplo → ADR proposto na Fase 6 (Roadmap).
assert_present "$RF" "transbordo"   "AC3 Modo HST documenta a regra de transbordo"
assert_present "$RF" "System Intent" "AC3 transbordo cita a Fase 1 System Intent"
assert_present "$RF" "store próprio" "AC3 System Intent permanece em store próprio (não vai pro CONTEXT.md)"
assert_present "$RF" "gate triplo"  "AC3 restrição global que passa no gate triplo"
assert_present "$RF" "ADR proposto" "AC3 restrição global vira ADR proposto"
assert_present "$RF" "Roadmap"      "AC3 ADR proposto materializa na Fase 6 (Roadmap)"

# ─── AC4 — ambas referenciam skills/domain-docs/ por caminho, sem duplicar formato ─
assert_present "$RF" "~/.claude/skills/domain-docs/" "AC4 react-feynman referencia a biblioteca por caminho"
# Canônico (capture-proof: a varredura não é vácua — o gate triplo EXISTE na biblioteca).
assert_present "$LIB" "Hard to reverse" "AC4 canônico domain-docs/SKILL.md tem o gate triplo"
# E NÃO é copiado em nenhuma das duas skills consumidoras.
assert_absent "$AGM" "Hard to reverse" "AC4 auto-grill-me sem cópia do gate triplo"
assert_absent "$RF"  "Hard to reverse" "AC4 react-feynman sem cópia do gate triplo"

# ─── Summary ──
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
