#!/usr/bin/env bash
# bin/tests/test_browser_secrets_lifecycle.sh — US-04 do ciclo R9 (ciclo de
# vida de secrets): doutrina de renovação/rotação na skill browser-secrets.
#
# Mapa AC → bloco de asserts (contrato de cobertura do plano
# .claude/plans/2026-07-02T12-53-27Z-r9-secrets-lifecycle.md):
#   AC1  seção de renovação reativa: tiering explícito (free-low sem
#        perguntar; paid/zona3 confirma 1×) + regra "renovar e reportar
#        mascarado, não devolver a tarefa"                                → bloco AC1
#   AC2  seção de rotação: âncora literal "probe OK antes de revogar a
#        antiga" + propagação dirigida pelo campo consumers do inventário → bloco AC2
#   AC3  bin/secrets-expiry.sh add obrigatório pós-provisão/renovação +
#        bin/secret-capture.sh como captura fora do transcript            → bloco AC3
#   AC4  description do frontmatter com triggers renovar/rotacionar/
#        expirada (asserido SÓ no valor de description)                   → bloco AC4
#   AC5  Gotchas: revogação prematura citando o incidente real
#        (auto-pull VM1) — asserido DENTRO da seção Gotchas               → bloco AC5
#   AC6  regressão: skills/browser-secrets/bin/test-skill-content.sh
#        executado por esta suíte e verde                                 → bloco AC6
#   AC7  cobertura documental = cada regra nova introduzida pela US tem
#        âncora assertada nos blocos AC1–AC5 (esta suíte É a cobertura).
#
# Âncoras section-scoped: regras de renovação/rotação/gotcha são asseridas
# DENTRO da seção certa (não em qualquer lugar do arquivo), pra uma regressão
# que apague a seção não passar por menção incidental em outro trecho.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_DIR="$REPO_ROOT/skills/browser-secrets"
SKILL_MD="$SKILL_DIR/SKILL.md"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_contains() { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: âncora '$2' ausente";; esac; }

[ -f "$SKILL_MD" ] || { echo "FATAL: $SKILL_MD ausente" >&2; exit 1; }

# Extrai o corpo de uma seção "## <heading>" (case-insensitive, regex no
# heading) até o próximo "## ".
section() {
  awk -v pat="$1" 'BEGIN{IGNORECASE=1}
    !f && tolower($0) ~ pat {f=1; next} f && /^## /{exit} f{print}' "$SKILL_MD"
}

SKILL_ALL="$(cat "$SKILL_MD")"

# ─── AC1: renovação reativa autônoma (tiered) ───────────────────────────────
RENOV="$(section '^## .*renova')"
if [ -z "$RENOV" ]; then
  _fail "AC1 :: seção '## Renovação reativa' ausente no SKILL.md"
else
  _pass
  assert_contains "$RENOV" "401/403" "AC1 gatilho 401/403 mid-task na seção de renovação"
  assert_contains "$RENOV" "expirada" "AC1 gatilho credencial expirada na seção de renovação"
  assert_contains "$RENOV" "escada" "AC1 renovação segue a escada do P12 (não pula pro browser)"
  assert_contains "$RENOV" "free-low" "AC1 tier free-low presente na seção de renovação"
  assert_contains "$RENOV" "sem perguntar" "AC1 free-low renova sem perguntar"
  assert_contains "$RENOV" "confirma 1×" "AC1 paid/zona3/produção confirma 1×"
  assert_contains "$RENOV" "paid" "AC1 tier paid no tiering de renovação"
  assert_contains "$RENOV" "zona3" "AC1 tier zona3 no tiering de renovação"
  assert_contains "$RENOV" "renovar e reportar mascarado, não devolver a tarefa" \
    "AC1 regra literal 'renovar e reportar mascarado, não devolver a tarefa'"
fi

# ─── AC2: rotação (higiene) — ordem canônica + consumers ───────────────────
ROT="$(section '^## .*rota')"
if [ -z "$ROT" ]; then
  _fail "AC2 :: seção '## Rotação' ausente no SKILL.md"
else
  _pass
  assert_contains "$ROT" "probe OK antes de revogar a antiga" \
    "AC2 âncora literal da ordem canônica"
  assert_contains "$ROT" "criar" "AC2 passo 'criar a nova' na ordem canônica"
  assert_contains "$ROT" "SÓ ENTÃO revogar" "AC2 'SÓ ENTÃO revogar' na ordem canônica"
  assert_contains "$ROT" "consumers" "AC2 propagação dirigida pelo campo consumers"
  assert_contains "$ROT" "inventário" "AC2 consumers vêm do inventário"
  assert_contains "$ROT" "probe-endpoints.md" "AC2 links do catálogo probe-endpoints.md"
  assert_contains "$ROT" "secrets-expiry.sh add" "AC2 passo final: registrar no inventário"
  assert_contains "$ROT" "auto-pull" "AC2 incidente-fonte (auto-pull VM1) citado na rotação"
  assert_contains "$ROT" "VM1" "AC2 incidente-fonte nomeia a VM1"
fi

# ─── AC3: secrets-expiry.sh add obrigatório + secret-capture.sh ─────────────
assert_contains "$SKILL_ALL" "bin/secrets-expiry.sh add" \
  "AC3 caminho completo bin/secrets-expiry.sh add citado"
assert_contains "$SKILL_ALL" "passo obrigatório pós-provisão/renovação" \
  "AC3 registro no inventário é passo obrigatório pós-provisão/renovação"
assert_contains "$SKILL_ALL" "bin/secret-capture.sh" \
  "AC3 caminho completo bin/secret-capture.sh citado"
assert_contains "$SKILL_ALL" "fora do transcript" \
  "AC3 secret-capture.sh é o caminho de captura fora do transcript"

# ─── AC4: triggers de renovação/rotação/expiração no description ────────────
DESC="$(awk '/^---$/{c++; next} c>=2{exit} c==1 && /^description:/{sub(/^description:[[:space:]]*/,""); print}' "$SKILL_MD")"
if [ -z "$DESC" ]; then
  _fail "AC4 :: valor de description ausente no frontmatter"
else
  _pass
  for trigger in renovar rotacionar expirada; do
    assert_contains "$DESC" "$trigger" "AC4 trigger '$trigger' NO VALOR de description"
  done
fi

# ─── AC5: gotcha de revogação prematura DENTRO de Gotchas ───────────────────
GOTCHAS="$(section '^## *gotchas')"
if [ -z "$GOTCHAS" ]; then
  _fail "AC5 :: seção '## Gotchas' ausente/vazia"
else
  _pass
  assert_contains "$GOTCHAS" "evogação prematura" "AC5 gotcha 'Revogação prematura' em Gotchas"
  assert_contains "$GOTCHAS" "auto-pull" "AC5 incidente auto-pull citado no gotcha"
  assert_contains "$GOTCHAS" "VM1" "AC5 incidente nomeia a VM1 no gotcha"
  assert_contains "$GOTCHAS" "1 semana" "AC5 duração real do incidente (~1 semana) no gotcha"
fi

# ─── AC6: regressão — test-skill-content.sh executado e verde ───────────────
REG="$SKILL_DIR/bin/test-skill-content.sh"
if [ ! -f "$REG" ]; then
  _fail "AC6 :: $REG ausente"
else
  REG_OUT="$(bash "$REG" 2>&1)"; REG_RC=$?
  if [ "$REG_RC" -eq 0 ]; then
    _pass
  else
    _fail "AC6 :: test-skill-content.sh vermelho (rc=$REG_RC): $(printf '%s' "$REG_OUT" | tail -3)"
  fi
fi

# ─── Sumário ─────────────────────────────────────────────────────────────────
if [ "$FAIL" -gt 0 ]; then
  echo "test_browser_secrets_lifecycle.sh: FAIL ($FAIL falhas, $PASS ok)$FAILED" >&2
  exit 1
fi
echo "test_browser_secrets_lifecycle.sh: PASS ($PASS asserts)"
