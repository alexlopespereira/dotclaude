#!/usr/bin/env bash
set -u

# test_test_spec_skill_protocol.sh — testes para o protocolo de telemetria
# test-spec de skills/testing/SKILL.md + commands/test-spec.md (US-06).
#
# Twin de bin/tests/test_auto_grill_skill_protocol.sh (US-05): a mudança é de
# PROTOCOLO (texto da skill/command), então a regressão é verificada em duas
# camadas:
#
#   Parte A (regressão de documentação):
#     - testing/SKILL.md §Lifecycle de Test Specs: contadores DERIVADOS via fold
#       (--prefix test-spec), TEST-PATTERNS.md source-puro (sem sufixo inline),
#       reset emite evento `revision` via test-spec-reset-rev.sh, sem lock
#       `mkdir` e sem snapshot `.test-spec-revision-state.json`, --gc aposentado.
#     - commands/test-spec.md: emite 1 evento `use` via usage-log.sh
#       --prefix test-spec quando materializa a spec (Ramo 2); não edita inline.
#
#   Parte B (integração / anti-phantom): emitir `log_event use <id> --sha
#     $(dod_bullets_sha) --prefix test-spec` faz o fold (US-02) derivar
#     usos/desde_rev; mudar os bullets muda o sha → eventos antigos param de
#     casar → desde_rev re-deriva. Prova que o sistema test-spec reusa as MESMAS
#     libs M1/M2 e que o sha carregado dirige a derivação content-based.
#
# Por que existe: o review de US-05 pediu regressão dedicada das mudanças de
# PROTOCOLO (o commit original atribuiu cobertura a um teste de writer). Este
# arquivo é essa regressão para o twin test-spec.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$REPO_ROOT/skills/testing/SKILL.md"
CMD="$REPO_ROOT/commands/test-spec.md"
TP="$REPO_ROOT/skills/testing/references/TEST-PATTERNS.md"
LIB_FOLD="$REPO_ROOT/bin/lib/usage-fold.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq() { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }

# assert_present <file> <fixed-string> <label> — grep -F casa → pass.
assert_present() {
  if grep -qF -- "$2" "$1"; then _pass
  else _fail "$3 :: '$2' AUSENTE de $(basename "$1") (deveria estar presente)"; fi
}
# assert_absent <file> <fixed-string> <label> — grep -F NÃO casa → pass.
assert_absent() {
  if grep -qF -- "$2" "$1"; then
    _fail "$3 :: '$2' PRESENTE em $(basename "$1") (deveria ter sido removido)"
  else _pass; fi
}

for f in "$SKILL" "$CMD" "$TP" "$LIB_FOLD"; do
  [[ -f "$f" ]] || { echo "FAIL: $f inexistente" >&2; exit 1; }
done

TMP="$(mktemp -d -t test-spec-protocol.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ─── Extrai a §Lifecycle de Test Specs (do heading "## Lifecycle de Test Specs"
# até o próximo heading top-level "## " exclusivo). ──────────────────────────
SECTION="$TMP/lifecycle.md"
awk '/^## Lifecycle de Test Specs/{f=1;print;next} /^## /{if(f)exit} f{print}' "$SKILL" > "$SECTION"
[ -s "$SECTION" ] && _pass || _fail "pré-condição: §Lifecycle de Test Specs não encontrada em SKILL.md"

# ─── Parte A — testing/SKILL.md: contadores derivados via fold (--prefix test-spec) ─
assert_present "$SECTION" 'bin/lib/usage-fold.sh' "A SKILL referencia o fold bin/lib/usage-fold.sh"
assert_present "$SECTION" '--prefix test-spec'    "A SKILL usa --prefix test-spec (mesmas libs M1/M2)"
assert_present "$SECTION" 'source-puro'           "A SKILL afirma TEST-PATTERNS source-puro (sem sufixo inline)"
assert_present "$SECTION" 'evento `revision`'     "A SKILL: reset emite evento revision"
assert_present "$SECTION" 'bin/test-spec-reset-rev.sh' "A SKILL referencia test-spec-reset-rev.sh"
# Negativos (regressão): lock mkdir, --gc, snapshot e edição inline sumiram do §.
assert_absent "$SECTION" 'mkdir <lockdir>'  "A regressão: lock 'mkdir <lockdir>' removido do §Lifecycle"
assert_absent "$SECTION" '--gc` — remove'   "A regressão: --gc descrito como ativo removido"
assert_absent "$SECTION" 'last_seen_iso no snapshot' "A regressão: 'last_seen_iso no snapshot' removido"

# ─── Parte A — commands/test-spec.md: marcador test-spec-use (emissão via hook) ─
assert_present "$CMD" 'hooks/dod-usage-log.sh' "A command referencia o Stop hook emissor"
assert_present "$CMD" '<!-- test-spec-use:'    "A command instrui inserir o marcador test-spec-use"
assert_present "$CMD" 'NÃO chame'              "A command afirma que NÃO chama log_event"
assert_present "$CMD" 'dod_bullets_sha'        "A command: sha vem de dod_bullets_sha (content-based)"
assert_absent "$CMD" 'bin/test-spec-reset-rev.sh --gc' "A regressão: ref a --gc removida do command"

# ─── Parte A — TEST-PATTERNS.md é source-puro de fato (0 sufixos inline) ─────────
assert_eq "$(grep -c ' (usos: ' "$TP")" "0" "A TEST-PATTERNS.md sem nenhum sufixo (usos:...) inline"

# ─── Parte B — o protocolo documentado executa e deriva o esperado ──────────────
export USAGE_LOG_HOME="$TMP/home"
# shellcheck source=bin/lib/usage-fold.sh
source "$LIB_FOLD"

FIX="$TMP/TEST-PATTERNS.md"
printf '%s\n' \
  '# Fixture TEST-PATTERNS' \
  '' \
  '## Categoria 1 — Test' \
  '' \
  '### Tarefa 1 — Exemplo um' \
  '- [ ] [b1] spec alpha' \
  '- [ ] [b2] spec beta' \
  > "$FIX"

# Passo do command: computa o sha atual via dod_bullets_sha.
SHA_NOW="$(dod_bullets_sha "$FIX" | awk -F'\t' '$1=="tarefa-1"{print $2}')"
[ -n "$SHA_NOW" ] && _pass || _fail "Parte B: dod_bullets_sha não derivou sha p/ tarefa-1"

# Passo do command: 1 log_event use por spec materializada, carregando --sha
# atual e --prefix test-spec. (2 materializações de tarefa-1 → 2 eventos use.)
log_event use tarefa-1 --sha "$SHA_NOW" --prefix test-spec
log_event use tarefa-1 --sha "$SHA_NOW" --prefix test-spec

# Isolamento de prefix: escreve em test-spec-usage.*, NÃO em dod-usage.*.
[ -n "$(find "$USAGE_LOG_HOME/telemetry" -name 'test-spec-usage.*.jsonl' 2>/dev/null)" ] && _pass \
  || _fail "Parte B: emit --prefix test-spec escreve em test-spec-usage.*.jsonl"
[ -z "$(find "$USAGE_LOG_HOME/telemetry" -name 'dod-usage.*.jsonl' 2>/dev/null)" ] && _pass \
  || _fail "Parte B: --prefix test-spec NÃO escreve em dod-usage.*"

# Fold (US-02) deriva os contadores: usos=2, desde_rev=2 (ambos no sha atual).
ROW="$(usage_fold --prefix test-spec --dod-file "$FIX" | awk -F'\t' '$1=="tarefa-1"')"
assert_eq "$(printf '%s' "$ROW" | cut -f2)" "2" "Parte B emitir via usage-log.sh → fold deriva usos=2"
assert_eq "$(printf '%s' "$ROW" | cut -f3)" "2" "Parte B eventos no sha atual → desde_rev=2"

# Revisão dos bullets: o sha muda → eventos use antigos param de casar →
# desde_rev re-deriva pra 0; usos (histórico) permanece 2.
printf '%s\n' \
  '# Fixture TEST-PATTERNS' \
  '' \
  '## Categoria 1 — Test' \
  '' \
  '### Tarefa 1 — Exemplo um' \
  '- [ ] [b1] spec alpha REVISADO' \
  '- [ ] [b2] spec beta' \
  > "$FIX"
SHA_NEW="$(dod_bullets_sha "$FIX" | awk -F'\t' '$1=="tarefa-1"{print $2}')"
[ "$SHA_NEW" != "$SHA_NOW" ] && _pass || _fail "Parte B: revisar bullets deveria mudar o sha"
ROW2="$(usage_fold --prefix test-spec --dod-file "$FIX" | awk -F'\t' '$1=="tarefa-1"')"
assert_eq "$(printf '%s' "$ROW2" | cut -f2)" "2" "Parte B: usos (histórico) intacto após revisão"
assert_eq "$(printf '%s' "$ROW2" | cut -f3)" "0" "Parte B: sha antigo não casa → desde_rev zera"

# ─── Summary ────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
