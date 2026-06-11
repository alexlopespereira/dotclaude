#!/usr/bin/env bash
set -u

# test_domain_docs_skill_protocol.sh — regressão de PROTOCOLO da skill-biblioteca
# domain-docs (US-01).
#
# Por que existe: o review de US-01 (progress.txt 2026-06-10T19:45:16) bloqueou
# porque o commit movia os formatos, escrevia o contrato inteiro e trocava os
# antigos por ponteiros, mas NENHUM teste travava a estrutura — "uma regressão
# que remova frontmatter/Gotchas, quebre links ou reintroduza duplicação passa
# sem teste". Este arquivo é essa regressão dedicada.
#
# A mudança é de DOCUMENTAÇÃO (texto de skill), então cada AC vira um assert de
# presença/ausência sobre os arquivos. Capture-proof: além dos asserts de
# conteúdo, AC6/AC7 contam quantos artefatos/links foram efetivamente varridos e
# falham se a varredura vier vazia (um caminho que não rodou não pode passar
# vacuamente).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/skills/domain-docs"
SKILL="$LIB/SKILL.md"
CTX="$LIB/CONTEXT-FORMAT.md"
ADR="$LIB/ADR-FORMAT.md"
PTR_CTX="$REPO_ROOT/skills/grill-with-docs/CONTEXT-FORMAT.md"
PTR_ADR="$REPO_ROOT/skills/grill-with-docs/ADR-FORMAT.md"

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

# ─── Pré-condições: os 5 arquivos existem ────────────────────────────────────
for f in "$SKILL" "$CTX" "$ADR" "$PTR_CTX" "$PTR_ADR"; do
  [[ -f "$f" ]] || { echo "FAIL: $f inexistente" >&2; exit 1; }
done

# ─── AC1 — frontmatter (name + description com 'o que faz'/'quando usar') + Gotchas ──
# Frontmatter: primeira linha é '---' e há um fechamento.
assert_eq "$(head -1 "$SKILL")" "---" "AC1 SKILL.md abre com frontmatter '---'"
assert_eq "$(grep -c '^---$' "$SKILL")" "2" "AC1 frontmatter tem abertura e fechamento '---'"
assert_present "$SKILL" "name: domain-docs"  "AC1 frontmatter declara name: domain-docs"
assert_present "$SKILL" "description:"        "AC1 frontmatter tem description"
assert_present "$SKILL" "O que faz"           "AC1 description tem 'o que faz'"
assert_present "$SKILL" "Quando usar"         "AC1 description tem 'quando usar'"
assert_present "$SKILL" "## Gotchas"          "AC1 SKILL.md tem seção Gotchas"

# ─── AC2 — TODAS as regras documentadas ──────────────────────────────────────
# Criação lazy + anúncio de 1 linha.
assert_present "$SKILL" "Criação lazy"        "AC2 regra: criação lazy"
assert_present "$SKILL" "anuncie em 1 linha"  "AC2 regra: anúncio de 1 linha"
# Gate triplo (as três condições).
assert_present "$SKILL" "Gate triplo de ADR"        "AC2 regra: gate triplo de ADR"
assert_present "$SKILL" "Hard to reverse"           "AC2 gate triplo: hard-to-reverse"
assert_present "$SKILL" "Surprising without context" "AC2 gate triplo: surprising"
assert_present "$SKILL" "real trade-off"            "AC2 gate triplo: trade-off"
# Modo inline (grills) vs modo batch + seção '## ADRs propostos'.
assert_present "$SKILL" "Modo inline"   "AC2 regra: modo inline (grills)"
assert_present "$SKILL" "Modo batch"    "AC2 regra: modo batch (plano persistido)"
assert_present "$SKILL" "## ADRs propostos" "AC2 modo batch: seção '## ADRs propostos'"
# Gates de materialização por fluxo (os 3 gates).
assert_present "$SKILL" "Gates de materialização" "AC2 regra: gates de materialização por fluxo"
assert_present "$SKILL" '`/plan`'        "AC2 gate: /plan (aceite do usuário)"
assert_present "$SKILL" "aceite do usuário" "AC2 gate /plan: aceite do usuário"
assert_present "$SKILL" "APROVADO"       "AC2 gate /full-planning-cycle: veredito APROVADO"
assert_present "$SKILL" "início da fase de execução" "AC2 gate /full-cycle*: início da execução"
# Fix BLOCK iter2: fixar os NOMES dos fluxos no contrato de gates — regressão que
# remova um nome de fluxo da tabela não pode passar só porque sobrou "APROVADO".
assert_present "$SKILL" '`/full-planning-cycle`' "AC2 gate: /full-planning-cycle nomeado no contrato"
assert_present "$SKILL" '`/full-cycle` e `/full-cycle-simple`' "AC2 gate: /full-cycle e /full-cycle-simple nomeados no contrato"
# Transbordo HST.
assert_present "$SKILL" "Transbordo HST" "AC2 regra: transbordo HST"
# Marcador de quitação.
assert_present "$SKILL" "<!-- adr-materialized -->" "AC2 marcador de quitação adr-materialized"

# ─── AC3 — termo OBSERVADO vs CUNHADO ────────────────────────────────────────
assert_present "$SKILL" "Termo OBSERVADO"       "AC3 distingue termo OBSERVADO"
assert_present "$SKILL" "CUNHADO pela solução"  "AC3 distingue termo CUNHADO pela solução"
# OBSERVADO escreve ao persistir o plano; CUNHADO viaja com os ADRs até a aprovação.
assert_present "$SKILL" "ao persistir o plano"  "AC3 OBSERVADO escreve ao persistir o plano"
assert_present "$SKILL" "materializa no" "AC3 CUNHADO materializa só na aprovação"

# ─── AC4 — conflito add/add em docs/adr/NNNN-* ───────────────────────────────
assert_present "$SKILL" "add/add"            "AC4 regra de conflito add/add"
assert_present "$SKILL" "renumere"           "AC4 add/add: renumerar pro próximo livre"
assert_present "$SKILL" "slug identifica"    "AC4 add/add: slug identifica a decisão"

# ─── AC5 — mecanismo de consumo (Read por path; flag só bloqueia disparo) ─────
assert_present "$SKILL" '`Read`'                       "AC5 consumo via Read"
assert_present "$SKILL" "~/.claude/skills/domain-docs/" "AC5 caminho fixo da biblioteca"
assert_present "$SKILL" "disable-model-invocation"      "AC5 cita a flag de não-invocação"
assert_present "$SKILL" "impede o disparo espontâneo"   "AC5 flag só impede disparo espontâneo"

# ─── AC6 — formatos movidos (byte-idêntico) + ponteiros de 1 linha (sem dup) ──
# Canônicos têm o corpo real (sentinelas do formato original).
assert_present "$CTX" "_Avoid_"      "AC6 CONTEXT-FORMAT canônico tem corpo (_Avoid_)"
assert_present "$CTX" "CONTEXT-MAP.md" "AC6 CONTEXT-FORMAT canônico tem single vs multi-context"
assert_present "$ADR" "## Template"  "AC6 ADR-FORMAT canônico tem o template"
assert_present "$ADR" "Hard to reverse" "AC6 ADR-FORMAT canônico tem o gate triplo"
# Byte-idêntico ao original (via git: conteúdo movido == conteúdo pré-move em grill-with-docs).
# Fix BLOCK iter2: `rev-parse HEAD` passa em clone shallow, mas o history pré-ponteiro
# não é alcançável (fetch-depth=1 no CI) → rev vazio → falso DIFERE. Detectar shallow
# explicitamente: sem rev alcançável EM repo shallow, o check degrada com aviso (os
# invariantes estruturais acima/abaixo seguem cobrindo); rev inalcançável em clone
# COMPLETO continua sendo falha real.
if git -C "$REPO_ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  identical=0
  revs_found=0
  for pair in "CONTEXT-FORMAT" "ADR-FORMAT"; do
    src="skills/grill-with-docs/$pair.md"
    # Versão pré-ponteiro = primeiro rev no history do path antigo com corpo (>1 linha).
    rev=""
    for h in $(git -C "$REPO_ROOT" log --format=%H -- "$src" 2>/dev/null); do
      if [ "$(git -C "$REPO_ROOT" show "$h:$src" 2>/dev/null | grep -c '')" -gt 1 ]; then rev="$h"; break; fi
    done
    if [ -n "$rev" ]; then
      revs_found=$((revs_found+1))
      # Pipe direto pro diff (command substitution comeria o newline final → falso DIFERE).
      if git -C "$REPO_ROOT" show "$rev:$src" 2>/dev/null | diff -q - "$LIB/$pair.md" >/dev/null 2>&1; then
        identical=$((identical+1))
      fi
    fi
  done
  if [ "$revs_found" -eq 0 ] && [ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    echo "  AVISO: clone shallow — history pré-ponteiro inacessível; byte-idêntico pulado (invariantes estruturais cobrem)"
    _pass
  else
    assert_eq "$identical" "2" "AC6 ambos os formatos byte-idênticos ao original pré-ponteiro (via git)"
  fi
else
  _pass  # repo sem history acessível — invariantes de conteúdo abaixo cobrem.
fi
# Ponteiros: exatamente 1 linha de conteúdo, apontam pro canônico, SEM corpo duplicado.
assert_eq "$(grep -c '' "$PTR_CTX")" "1" "AC6 ponteiro CONTEXT-FORMAT tem 1 linha"
assert_eq "$(grep -c '' "$PTR_ADR")" "1" "AC6 ponteiro ADR-FORMAT tem 1 linha"
assert_present "$PTR_CTX" "../domain-docs/CONTEXT-FORMAT.md" "AC6 ponteiro CONTEXT aponta pro canônico"
assert_present "$PTR_ADR" "../domain-docs/ADR-FORMAT.md"     "AC6 ponteiro ADR aponta pro canônico"
assert_absent  "$PTR_CTX" "_Avoid_"     "AC6 ponteiro CONTEXT não duplica o corpo"
assert_absent  "$PTR_ADR" "## Template" "AC6 ponteiro ADR não duplica o corpo"

# ─── AC7 — todo link markdown a CONTEXT-FORMAT|ADR-FORMAT resolve ─────────────
# Varre skills/ e commands/, extrai os alvos de `](...)` nas linhas que citam os
# formatos, resolve relativo ao dir do arquivo e exige que o alvo exista.
links_checked=0
while IFS= read -r line; do
  file="${line%%:*}"
  rest="${line#*:}"
  # extrai cada alvo entre ']( e )'
  targets="$(printf '%s\n' "$rest" | grep -oE '\]\([^)]*(CONTEXT-FORMAT|ADR-FORMAT)[^)]*\)' | sed -E 's/^\]\(//; s/\)$//')"
  [ -n "$targets" ] || continue
  dir="$(cd "$(dirname "$REPO_ROOT/$file")" && pwd)"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    t="${t%%#*}"  # descarta âncora #...
    links_checked=$((links_checked+1))
    if [ ! -f "$dir/$t" ]; then
      _fail "AC7 link quebrado em $file → $t (alvo inexistente)"
    fi
  done <<< "$targets"
done < <(cd "$REPO_ROOT" && grep -rnE '\]\([^)]*(CONTEXT-FORMAT|ADR-FORMAT)' skills/ commands/ 2>/dev/null)
# Capture-proof: a varredura precisa ter achado links de verdade (>=4: 2 ponteiros
# + 2 refs em grill-with-docs/SKILL.md). 0 = scan vazio mascarando regressão.
if [ "$links_checked" -ge 4 ]; then _pass
else _fail "AC7 varredura achou só $links_checked links markdown (esperado >=4) — scan vazio?"; fi

# ─── Summary ─────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
