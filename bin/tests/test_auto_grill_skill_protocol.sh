#!/usr/bin/env bash
set -u

# test_auto_grill_skill_protocol.sh — testes para o protocolo §Contadores de uso
# de skills/auto-grill-me/SKILL.md (US-05).
#
# Cobre os 3 acceptance criteria da story "Protocolo da skill auto-grill-me emite
# evento" — a mudança é de PROTOCOLO (texto da skill), então a regressão é
# verificada em duas camadas:
#
#   Parte A (regressão de documentação) — a §Contadores de uso do SKILL.md:
#     AC1 — instrui emitir N eventos `use` via bin/lib/usage-log.sh no Stop
#           criterion e afirma que NÃO edita contador inline no DOD.md; a antiga
#           instrução de edição-in-place (deltas numa passagem por DOD.md) sumiu.
#     AC2 — a instrução de lock `mkdir <lockdir>` está AUSENTE do arquivo inteiro
#           (aparecia na §Incremento e no Gotcha #3 da versão inline).
#     AC3 — a §Contadores afirma que o evento `use` carrega o sha atual dos
#           bullets do DoD e que o sha vem de dod_bullets_sha; a emissão usa --sha.
#
#   Parte B (integração / anti-phantom) — o comando que o SKILL documenta é real
#     e produz a semântica documentada: emitir `log_event use <id> --sha
#     $(dod_bullets_sha)` faz o fold (US-02) derivar usos/desde_rev; mudar os
#     bullets muda o sha → eventos antigos param de casar → desde_rev re-deriva.
#     (Não-tautológico: prova que o sha carregado no evento É o que dirige a
#     derivação content-based de "desde rev" — AC1 emite, AC3 carrega o sha.)
#
# Por que este teste existe: o commit 01d4583 atribuiu a cobertura de US-05 a
# test_usage_log.sh (que cobre US-01, o writer) — review pediu regressão dedicada
# das mudanças de protocolo. Este arquivo é essa regressão.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL="$REPO_ROOT/skills/auto-grill-me/SKILL.md"
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

[[ -f "$SKILL" ]]    || { echo "FAIL: $SKILL inexistente" >&2; exit 1; }
[[ -f "$LIB_FOLD" ]] || { echo "FAIL: $LIB_FOLD inexistente" >&2; exit 1; }

TMP="$(mktemp -d -t agm-protocol.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ─── Extrai a §Contadores de uso (do heading "## Contadores de uso" até o ───────
# próximo heading top-level "## " exclusivo). `^## ` casa exatamente 2 hashes +
# espaço → os subheadings "### …" da seção NÃO encerram a extração.
SECTION="$TMP/contadores.md"
awk '/^## Contadores de uso/{f=1;print;next} /^## /{if(f)exit} f{print}' "$SKILL" > "$SECTION"
[ -s "$SECTION" ] && _pass || _fail "pré-condição: §Contadores de uso não encontrada em SKILL.md"

# ─── AC1 — emite N eventos `use` via usage-log.sh no Stop criterion; sem inline ─
assert_present "$SECTION" 'bin/lib/usage-log.sh' "AC1 §Contadores referencia o writer bin/lib/usage-log.sh"
assert_present "$SECTION" 'log_event use'        "AC1 §Contadores instrui emitir evento use (log_event use)"
assert_present "$SECTION" 'Stop criterion'       "AC1 emissão acontece no Stop criterion"
assert_present "$SECTION" 'não edita contador inline' "AC1 afirma explicitamente que NÃO edita contador inline"
# Negativo: a instrução inline antiga (editar DOD.md em batch) sumiu do arquivo.
assert_absent "$SKILL" 'aplica todos os deltas' "AC1 regressão: edição-in-place em batch removida"
assert_absent "$SKILL" 'Map<dod_id'             "AC1 regressão: acumulador de deltas inline removido"

# ─── AC2 — instrução de lock `mkdir <lockdir>` removida (arquivo inteiro) ───────
assert_absent "$SKILL" 'mkdir <lockdir>' "AC2 lock 'mkdir <lockdir>' removido do SKILL.md"

# ─── AC3 — o evento `use` carrega o sha atual dos bullets do DoD aplicado ───────
assert_present "$SECTION" 'carrega o sha atual dos bullets' "AC3 evento use carrega o sha atual dos bullets"
assert_present "$SECTION" 'dod_bullets_sha'                 "AC3 sha vem de dod_bullets_sha (content-based)"
assert_present "$SECTION" '--sha'                           "AC3 a emissão passa --sha <sha-atual>"

# ─── Parte B — o protocolo documentado executa e deriva o esperado ──────────────
# Sandbox isolado: USAGE_LOG_HOME não polui ~/.claude. Sourcing de usage-fold.sh
# traz dod_bullets_sha + log_event (sourceia usage-log.sh) + usage_fold.
export USAGE_LOG_HOME="$TMP/home"
# shellcheck source=bin/lib/usage-fold.sh
source "$LIB_FOLD"

# Fixture DOD.md controlado (sha determinístico, desacoplado do DOD.md real).
FIX="$TMP/DOD.md"
printf '%s\n' \
  '# Fixture DOD' \
  '' \
  '## Categoria 1 — Test' \
  '' \
  '### Tarefa 1 — Exemplo um' \
  '- [ ] [b1] alpha' \
  '- [ ] [b2] beta' \
  > "$FIX"

# Passo 1 do SKILL: computa o sha atual dos bullets via dod_bullets_sha.
SHA_NOW="$(dod_bullets_sha "$FIX" | awk -F'\t' '$1=="tarefa-1"{print $2}')"
[ -n "$SHA_NOW" ] && _pass || _fail "Parte B: dod_bullets_sha não derivou sha p/ tarefa-1"

# Passo 2 do SKILL: 1 chamada log_event use por inserção, carregando --sha atual.
# (2 inserções de tarefa-1 no plano → 2 eventos use.)
log_event use tarefa-1 --sha "$SHA_NOW" --prefix dod
log_event use tarefa-1 --sha "$SHA_NOW" --prefix dod

# Fold (US-02) deriva os contadores: usos=2, desde_rev=2 (ambos no sha atual).
ROW="$(usage_fold --prefix dod --dod-file "$FIX" | awk -F'\t' '$1=="tarefa-1"')"
assert_eq "$(printf '%s' "$ROW" | cut -f2)" "2" "Parte B/AC1 emitir via usage-log.sh → fold deriva usos=2"
assert_eq "$(printf '%s' "$ROW" | cut -f3)" "2" "Parte B/AC3 eventos no sha atual → desde_rev=2"

# Revisão dos bullets: o sha muda → os eventos use antigos (sha antigo) deixam de
# casar → desde_rev re-deriva pra 0; usos (histórico) permanece 2. Prova que é o
# sha CARREGADO no evento que dirige a derivação content-based de "desde rev".
printf '%s\n' \
  '# Fixture DOD' \
  '' \
  '## Categoria 1 — Test' \
  '' \
  '### Tarefa 1 — Exemplo um' \
  '- [ ] [b1] alpha REVISADO' \
  '- [ ] [b2] beta' \
  > "$FIX"
SHA_NEW="$(dod_bullets_sha "$FIX" | awk -F'\t' '$1=="tarefa-1"{print $2}')"
[ "$SHA_NEW" != "$SHA_NOW" ] && _pass || _fail "Parte B: revisar bullets deveria mudar o sha"
ROW2="$(usage_fold --prefix dod --dod-file "$FIX" | awk -F'\t' '$1=="tarefa-1"')"
assert_eq "$(printf '%s' "$ROW2" | cut -f2)" "2" "Parte B: usos (histórico) intacto após revisão"
assert_eq "$(printf '%s' "$ROW2" | cut -f3)" "0" "Parte B/AC3: sha antigo não casa → desde_rev zera"

# ─── Summary ────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
