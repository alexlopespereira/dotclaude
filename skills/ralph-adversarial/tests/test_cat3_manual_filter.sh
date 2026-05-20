#!/bin/bash
# Test fixture: filter [CAT3-MANUAL] em ralph-adversarial.sh
# Cobre 4 cenários da US-01 AC4:
#  (a) AC prefixado com marker → filtrado
#  (b) AC sem marker → mantido
#  (c) AC que MENCIONA marker no meio → mantido (não-prefixo)
#  (d) AC com marker case-mixed → filtrado
#
# Estratégia: roda o mesmo jq filter usado em ralph-adversarial.sh sobre
# uma fixture JSON sintética e verifica o array resultante.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_SH="$SCRIPT_DIR/../ralph-adversarial.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq não instalado"; exit 1; }
[ -f "$RALPH_SH" ] || { echo "FAIL: ralph-adversarial.sh não encontrado em $RALPH_SH"; exit 1; }

# Sanity: o script-alvo precisa conter o marker e o uso de jq como filter.
# Se alguém remover o filtro, o teste falha aqui antes de validar comportamento.
grep -E 'acceptanceCriteria.*test.*CAT3-MANUAL' "$RALPH_SH" >/dev/null \
    || { echo "FAIL: ralph-adversarial.sh não contém o filter jq sobre acceptanceCriteria"; exit 1; }
grep -E 'jq.*CAT3-MANUAL' "$RALPH_SH" >/dev/null \
    || { echo "FAIL: ralph-adversarial.sh não usa jq junto a CAT3-MANUAL"; exit 1; }

# Fixture sintética cobrindo os 4 cenários da AC4.
FIXTURE=$(cat <<'JSON'
{
  "id": "US-TEST",
  "acceptanceCriteria": [
    "AC1: [CAT3-MANUAL] prefixed marker — deve ser filtrado",
    "AC2: sem marker — deve ser mantido",
    "AC3: menciona [CAT3-MANUAL] no meio da string — deve ser mantido",
    "AC4: [cat3-MANUAL] case-mixed prefix — deve ser filtrado"
  ]
}
JSON
)

# Mesmo regex usado em ralph-adversarial.sh. Se divergir, o sanity grep
# acima ainda passa mas este filtro pode dar comportamento diferente —
# mantenha sincronizado intencionalmente.
FILTER='.acceptanceCriteria |= map(select(test("^AC[0-9]+(\\.[a-z])?:\\s*\\[CAT3-MANUAL\\]"; "i") | not))'

OUTPUT=$(echo "$FIXTURE" | jq -c "$FILTER")

has_prefix() {
    local prefix="$1"
    echo "$OUTPUT" | jq -e --arg p "$prefix" '.acceptanceCriteria | map(select(startswith($p))) | length > 0' >/dev/null
}

FAIL=0

# (a) AC1 com marker prefixado → filtrado
if has_prefix "AC1:"; then
    echo "FAIL (a): AC1 prefixado com [CAT3-MANUAL] deveria ser filtrado"
    FAIL=1
fi

# (b) AC2 sem marker → mantido
if ! has_prefix "AC2:"; then
    echo "FAIL (b): AC2 sem marker deveria ser mantido"
    FAIL=1
fi

# (c) AC3 com marker NO MEIO → mantido (regex é ancorada)
if ! has_prefix "AC3:"; then
    echo "FAIL (c): AC3 com [CAT3-MANUAL] no meio (não-prefixo) deveria ser mantido"
    FAIL=1
fi

# (d) AC4 com marker case-mixed prefixado → filtrado
if has_prefix "AC4:"; then
    echo "FAIL (d): AC4 com [cat3-MANUAL] case-mixed deveria ser filtrado"
    FAIL=1
fi

# Integridade (AC11): PRD sem markers retorna mesmo array.
CLEAN_FIXTURE=$(cat <<'JSON'
{
  "id": "US-CLEAN",
  "acceptanceCriteria": [
    "AC1: foo",
    "AC2: bar",
    "AC3: baz"
  ]
}
JSON
)
ORIGINAL=$(echo "$CLEAN_FIXTURE" | jq -c '.acceptanceCriteria')
FILTERED_CLEAN=$(echo "$CLEAN_FIXTURE" | jq -c "$FILTER" | jq -c '.acceptanceCriteria')
if [ "$ORIGINAL" != "$FILTERED_CLEAN" ]; then
    echo "FAIL (integridade): PRD sem markers deveria passar inalterado"
    echo "  original:  $ORIGINAL"
    echo "  filtered:  $FILTERED_CLEAN"
    FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
    echo "PRD CAT3-MANUAL filter test: FAIL"
    exit 1
fi

echo "PASS: filter [CAT3-MANUAL] — (a) prefix filtrado, (b) sem-marker mantido, (c) menção-no-meio mantida, (d) case-mixed filtrado, integridade preservada"
exit 0
