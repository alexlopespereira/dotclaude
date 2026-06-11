#!/usr/bin/env bash
set -u

# test_us03_command_docs.sh — regressão de PROTOCOLO dos 4 commands planejadores
# (US-03): parágrafo '## Docs de domínio' / delegação à biblioteca domain-docs +
# gate de materialização de ADR correto por fluxo.
#
# Por que existe: o review de US-01 (progress.txt 2026-06-10T19:45:16) bloqueou
# porque a mudança de documentação não tinha teste travando a estrutura — "uma
# regressão que remova ... ou reintroduza duplicação passa sem teste". Espelha
# test_domain_docs_skill_protocol.sh para os commands.
#
# A mudança é de DOCUMENTAÇÃO (texto de slash command), então cada AC vira assert
# de presença/ausência. Capture-proof: AC4/AC5 contam quantos arquivos foram
# efetivamente varridos e falham se a contagem vier vazia (caminho que não rodou
# não pode passar vacuamente).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLAN="$REPO_ROOT/commands/plan.md"
FPC="$REPO_ROOT/commands/full-planning-cycle.md"
FC="$REPO_ROOT/commands/full-cycle.md"
FCS="$REPO_ROOT/commands/full-cycle-simple.md"
LIB_PATH="~/.claude/skills/domain-docs/SKILL.md"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq() { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
# assert_present <file> <fixed-string> <label> — grep -F casa → pass.
assert_present() {
  if grep -qF -- "$2" "$1"; then _pass
  else _fail "$3 :: '$2' AUSENTE de $(basename "$1")"; fi
}
# assert_absent <file> <fixed-string> <label> — grep -F NÃO casa → pass.
assert_absent() {
  if grep -qF -- "$2" "$1"; then
    _fail "$3 :: '$2' PRESENTE em $(basename "$1") (não deveria)"
  else _pass; fi
}

# ─── Pré-condições: os 4 commands existem ────────────────────────────────────
for f in "$PLAN" "$FPC" "$FC" "$FCS"; do
  [[ -f "$f" ]] || { echo "FAIL: $f inexistente" >&2; exit 1; }
done

# ─── AC1 — plan.md: escreve termos OBSERVADOS, seção '## ADRs propostos',
#            materializa na aprovação ANTES de tudo + marcador ────────────────
assert_present "$PLAN" "## Docs de domínio"          "AC1 plan.md tem seção '## Docs de domínio'"
assert_present "$PLAN" "termos OBSERVADOS"           "AC1 plan.md escreve termos OBSERVADOS no CONTEXT.md"
assert_present "$PLAN" "criação lazy"                "AC1 plan.md criação lazy"
assert_present "$PLAN" "## ADRs propostos"           "AC1 plan.md seção '## ADRs propostos'"
assert_present "$PLAN" "texto INTEGRAL"              "AC1 plan.md ADRs propostos com texto integral"
assert_present "$PLAN" "ANTES de qualquer outra ação" "AC1 plan.md materializa ANTES de qualquer outra ação"
assert_present "$PLAN" "<!-- adr-materialized -->"   "AC1 plan.md emite marcador de quitação"

# ─── AC2 — full-planning-cycle.md: Fase 0 delega inline; Fase 3 materializa em
#            APROVADO (ressalvas incorporadas primeiro) ──────────────────────
assert_present "$FPC" "modo inline"                  "AC2 fpc Fase 0 delega modo inline à biblioteca"
assert_present "$FPC" "domain-docs"                  "AC2 fpc referencia a biblioteca domain-docs"
# Orphan da instrução inline antiga removida (Fase 0 agora delega).
assert_absent  "$FPC" "atualize-o inline conforme termos forem resolvidos" "AC2 fpc removeu instrução inline antiga"
assert_present "$FPC" "Materialize os ADRs propostos" "AC2 fpc Fase 3 materializa ADRs propostos"
assert_present "$FPC" "APROVADO COM RESSALVAS"       "AC2 fpc trata APROVADO COM RESSALVAS"
assert_present "$FPC" "incorpore as ressalvas no texto do ADR primeiro" "AC2 fpc ressalvas incorporadas primeiro"
assert_present "$FPC" "<!-- adr-materialized -->"    "AC2 fpc emite marcador de quitação"

# ─── AC3 — full-cycle*.md materializam no início da execução + marcador ──────
for f in "$FC" "$FCS"; do
  bn="$(basename "$f")"
  assert_present "$f" "início da fase de execução" "AC3 $bn materializa no início da fase de execução"
  assert_present "$f" "pós-gate de aprovação"      "AC3 $bn materializa pós-gate de aprovação"
  assert_present "$f" "## ADRs propostos"          "AC3 $bn materializa a seção '## ADRs propostos'"
  assert_present "$f" "<!-- adr-materialized -->"  "AC3 $bn emite marcador de quitação"
done

# ─── AC4 — os 4 referenciam a biblioteca por caminho; nenhum duplica formato ──
# Capture-proof: conta quantos dos 4 citam o caminho fixo (precisa ser 4).
lib_refs=0
for f in "$PLAN" "$FPC" "$FC" "$FCS"; do
  if grep -qF -- "$LIB_PATH" "$f"; then lib_refs=$((lib_refs+1)); fi
  # Regra de formato canônica NÃO duplicada: o texto integral do gate triplo
  # ("Surprising without context") só vive na biblioteca.
  assert_absent "$f" "Surprising without context" "AC4 $(basename "$f") não duplica regra de formato (gate triplo integral)"
done
assert_eq "$lib_refs" "4" "AC4 os 4 commands referenciam ~/.claude/skills/domain-docs/SKILL.md"

# ─── AC5 — toda menção a CONTEXT.md é consistente com a biblioteca ───────────
# Capture-proof: para cada arquivo que cita CONTEXT.md, exige co-presença de
# 'domain-docs' (sem instrução órfã do comportamento antigo read-only); conta os
# arquivos varridos e falha se vier 0.
ctx_files=0
for f in "$PLAN" "$FPC" "$FC" "$FCS"; do
  if grep -qF -- "CONTEXT.md" "$f"; then
    ctx_files=$((ctx_files+1))
    assert_present "$f" "domain-docs" "AC5 $(basename "$f") CONTEXT.md co-ocorre com a biblioteca domain-docs"
  fi
done
if [ "$ctx_files" -ge 4 ]; then _pass
else _fail "AC5 varredura achou só $ctx_files arquivos citando CONTEXT.md (esperado >=4) — scan vazio?"; fi
# Orphan read-only específico do plan.md antigo removido.
assert_absent "$PLAN" "(criado por \`grill-with-docs\`), leia esses artefatos" "AC5 plan.md removeu orphan read-only antigo"

# ─── AC1/AC2/AC3 executável — allowed-tools com ferramenta de escrita ────────
# O comportamento obrigatório (escrever termos no CONTEXT.md, materializar
# docs/adr, emitir marcador no plano) é INEXECUTÁVEL se o frontmatter não
# permite Write/Edit. Origem: REVIEW_BLOCK US-03 2026-06-10T20:19:55 — plan.md
# tinha a seção '## Docs de domínio' mas allowed-tools só Read/Glob/Grep/Bash/Agent.
# Fix code-review Fase 5.5: exigir AMBOS — Write (ADR novo) E Edit (marcador
# <!-- adr-materialized --> apendado em plano existente; CONTEXT.md existente).
# Write-only força rewrite integral do arquivo (propenso a corrupção em plano
# grande); plan.md ganhou os dois no fix do REVIEW_BLOCK — irmãos consistentes.
for f in "$PLAN" "$FPC" "$FC" "$FCS"; do
  bn="$(basename "$f")"
  if grep -iE '^allowed-tools:.*\bWrite\b' "$f" >/dev/null \
     && grep -iE '^allowed-tools:.*\bEdit\b' "$f" >/dev/null; then _pass
  else _fail "$bn allowed-tools sem Write E Edit — comportamento de docs inexecutável/inseguro"; fi
done

# ─── Summary ─────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
