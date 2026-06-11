#!/usr/bin/env bash
set -u

# test_grill_skills_delegation.sh — regressão de PROTOCOLO de US-02:
# grill-me e grill-with-docs viram cascas finas que delegam o comportamento de
# docs à biblioteca domain-docs (US-01).
#
# Por que existe: a mudança é de DOCUMENTAÇÃO (texto de skill). Sem teste, uma
# regressão que (a) reintroduza a cópia das regras de formato nas skills, (b)
# remova a referência à biblioteca, (c) quebre as trigger phrases do frontmatter,
# ou (d) apague a seção de telemetria de DoD passaria silenciosa. Espelha o
# estilo de test_domain_docs_skill_protocol.sh (US-01).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GM="$REPO_ROOT/skills/grill-me/SKILL.md"
GWD="$REPO_ROOT/skills/grill-with-docs/SKILL.md"
LIB="$REPO_ROOT/skills/domain-docs/SKILL.md"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq() { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_present() {
  if grep -qF -- "$2" "$1"; then _pass
  else _fail "$3 :: '$2' AUSENTE de $(basename "$(dirname "$1")")/$(basename "$1")"; fi
}
assert_absent() {
  if grep -qF -- "$2" "$1"; then
    _fail "$3 :: '$2' PRESENTE em $(basename "$(dirname "$1")")/$(basename "$1") (não deveria)"
  else _pass; fi
}

for f in "$GM" "$GWD" "$LIB"; do
  [[ -f "$f" ]] || { echo "FAIL: $f inexistente" >&2; exit 1; }
done

# ─── AC1 — grill-me instrui aplicar o modo inline de domain-docs via referência ──
# Referencia a biblioteca por nome e por path fixo (mecanismo de consumo = Read).
assert_present "$GM" "domain-docs"  "AC1 grill-me referencia a biblioteca domain-docs"
assert_present "$GM" "~/.claude/skills/domain-docs/" "AC1 grill-me cita o path fixo da biblioteca"
assert_present "$GM" "inline"       "AC1 grill-me invoca o modo inline"
# Sem copiar as regras: não reproduz o gate triplo nem o corpo do formato.
assert_absent  "$GM" "Hard to reverse" "AC1 grill-me NÃO copia o gate triplo (regra canônica)"

# ─── AC2 — grill-with-docs delega comportamento de docs mantendo identidade ──
assert_present "$GWD" "domain-docs"  "AC2 grill-with-docs delega à biblioteca domain-docs"
assert_present "$GWD" "~/.claude/skills/domain-docs/" "AC2 grill-with-docs cita o path fixo"
assert_present "$GWD" "inline"       "AC2 grill-with-docs mantém modo inline como default"
# Identidade preservada: especialista em modelagem de domínio.
if grep -qiE "modelagem de domínio|domain model" "$GWD"; then _pass
else _fail "AC2 grill-with-docs mantém identidade de especialista em modelagem de domínio"; fi
# Continua não-invocável espontaneamente.
assert_present "$GWD" "disable-model-invocation" "AC2 grill-with-docs mantém disable-model-invocation"
# Anti-duplicação (fecha o gap que deixou a casca embutir bullets de comportamento):
# o comportamento de docs é DELEGADO, não re-embutido com regra+exemplo. Capture-proof:
# o ponteiro "modo inline" está presente (a varredura não é vácua)...
assert_present "$GWD" "modo inline" "AC2 grill-with-docs aponta pro modo inline da biblioteca (capture-proof)"
# ...e os exemplos instrucionais do modo inline NÃO foram copiados aqui (vivem só na biblioteca).
assert_absent  "$GWD" "seu glossário define" "AC2 grill-with-docs NÃO re-embute o exemplo de desafiar-contra-glossário (delega)"
assert_absent  "$GWD" "Customer ou User"     "AC2 grill-with-docs NÃO re-embute o exemplo de sharpen (delega)"

# ─── AC3 — descriptions semanticamente equivalentes (trigger phrases preservadas) ──
# grill-me: "stress-test a plan", "get grilled on their design", "grill me".
assert_present "$GM" "stress-test a plan"        "AC3 grill-me trigger: stress-test a plan"
assert_present "$GM" "get grilled on their design" "AC3 grill-me trigger: get grilled on their design"
assert_present "$GM" 'mentions "grill me"'       "AC3 grill-me trigger: mentions grill me"
# grill-with-docs: domínio + CONTEXT.md/ADRs + stress-test contra a linguagem do projeto.
assert_present "$GWD" "CONTEXT.md, ADRs"          "AC3 grill-with-docs trigger: CONTEXT.md, ADRs"
assert_present "$GWD" "stress-test a plan against their project's language" "AC3 grill-with-docs trigger: stress-test contra a linguagem do projeto"

# ─── AC4 — nenhuma cópia das regras de formato; canônico só em domain-docs/ ──
# Capture-proof: 'Hard to reverse' EXISTE no canônico (a varredura não é vácua).
assert_present "$LIB" "Hard to reverse" "AC4 canônico domain-docs/SKILL.md tem o gate triplo"
# E NÃO existe em nenhuma das duas cascas.
assert_absent "$GM"  "Hard to reverse" "AC4 grill-me sem cópia do gate triplo"
assert_absent "$GWD" "Hard to reverse" "AC4 grill-with-docs sem cópia do gate triplo"
# grep amplo: todo match em skills/ está sob skills/domain-docs/.
stray="$(cd "$REPO_ROOT" && grep -rlF "Hard to reverse" skills/ 2>/dev/null | grep -v '^skills/domain-docs/' || true)"
if [ -z "$stray" ]; then _pass
else _fail "AC4 'Hard to reverse' fora de skills/domain-docs/: $stray"; fi

# ─── AC5 — seção de telemetria DoD intacta nas duas skills ──
for f in "$GM" "$GWD"; do
  b="$(basename "$(dirname "$f")")"
  assert_present "$f" "## Ao produzir o plano (telemetria de DoD)" "AC5 $b mantém a seção de telemetria DoD"
  assert_present "$f" "<!-- dod-use:" "AC5 $b mantém o marcador dod-use"
  assert_present "$f" "Não chame \`log_event\`" "AC5 $b mantém a regra 'Não chame log_event'"
  assert_present "$f" "DOD-MAPPING.md" "AC5 $b mantém a referência a DOD-MAPPING.md"
done

# ─── Summary ──
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
