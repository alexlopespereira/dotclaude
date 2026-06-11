#!/usr/bin/env bash
set -u

# test_us06_context_migration.sh — regressão da migração dogfood do CONTEXT.md
# do dotclaude pro formato canônico (US-06).
#
# Por que existe: US-06 reformata o CONTEXT.md do repo (glossário canônico) e move
# os 4 blocos '### Decisão:' pra referência ao ADR 0001 (nenhum vira ADR novo, pois
# todos já estavam registrados no 0001). A mudança é de documentação, então cada AC
# vira assert de presença/ausência sobre CONTEXT.md e docs/adr/. Capture-proof:
# AC4 e AC5 contam quantos fatos/links foram varridos e falham se a varredura vier
# vazia (um caminho que não rodou não pode passar vacuamente).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CTX="$REPO_ROOT/CONTEXT.md"
ADR_DIR="$REPO_ROOT/docs/adr"
ADR1="$ADR_DIR/0001-adopt-graphify-sunset-llm-wiki.md"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq() { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_present() {
  if grep -qF -- "$2" "$1"; then _pass
  else _fail "$3 :: '$2' AUSENTE de $(basename "$1")"; fi
}
assert_absent() {
  if grep -qF -- "$2" "$1"; then
    _fail "$3 :: '$2' PRESENTE em $(basename "$1") (não deveria)"
  else _pass; fi
}
# assert_anywhere <fixed-string> <label> — presente em CONTEXT.md OU em qualquer ADR.
assert_anywhere() {
  if grep -qrF -- "$1" "$CTX" "$ADR_DIR" 2>/dev/null; then _pass
  else _fail "$2 :: fato '$1' AUSENTE de CONTEXT.md e de docs/adr/ (informação perdida)"; fi
}

# ─── Pré-condições ───────────────────────────────────────────────────────────
for f in "$CTX" "$ADR1"; do
  [[ -f "$f" ]] || { echo "FAIL: $f inexistente" >&2; exit 1; }
done

# ─── AC1 — suposição validada: nenhum bloco vira ADR novo; referenciam o 0001 ──
# Os 4 blocos '### Decisão:' saíram do CONTEXT.md.
assert_absent "$CTX" "### Decisão:" "AC1 CONTEXT.md sem nenhum bloco '### Decisão:'"
assert_eq "$(grep -c '^### Decisão' "$CTX")" "0" "AC1 zero headings de Decisão no CONTEXT.md"
# Nenhum ADR novo 0004+ foi criado por esta story (a suposição do plano era refutada).
new_adrs=0
for f in "$ADR_DIR"/*.md; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in
    000[4-9]-*|0[1-9][0-9][0-9]-*) new_adrs=$((new_adrs+1)) ;;
  esac
done
assert_eq "$new_adrs" "0" "AC1 nenhum ADR 0004+ criado (4 decisões já estavam no 0001)"
# A errata de migração mapeia explicitamente os 4 blocos pras Decisions do 0001.
assert_present "$ADR1" "migração dogfood do CONTEXT.md" "AC1 ADR 0001 tem a errata de migração"
for d in "Decision 3" "Decision 4" "Decision 5" "Decision 6"; do
  assert_present "$ADR1" "$d" "AC1 errata mapeia bloco → $d"
done

# ─── AC2 — formato canônico (skills/domain-docs/CONTEXT-FORMAT.md) ────────────
assert_present "$CTX" "_Avoid_"          "AC2 CONTEXT.md usa _Avoid_"
assert_present "$CTX" "## Relationships" "AC2 CONTEXT.md tem seção Relationships"
assert_present "$CTX" "**Graphify**:"    "AC2 termo em formato canônico '**Termo**:'"
assert_present "$CTX" "**llm-wiki**:"    "AC2 termo llm-wiki em formato canônico"
# Pelo menos 4 termos canônicos (linhas '**Termo**:').
nterms="$(grep -cE '^\*\*[^*]+\*\*:' "$CTX")"
[ "$nterms" -ge 4 ] && _pass || _fail "AC2 esperado >=4 termos canônicos, achei $nterms"
# Sem heading antigo '### Termo' (formato pré-migração).
assert_absent "$CTX" "### Graphify"   "AC2 sem heading antigo '### Graphify'"
# Sem termo de programação genérico (proibido pelo formato).
for generic in "**Timeout**" "**Retry**" "**Error**" "**Cache**"; do
  assert_absent "$CTX" "$generic" "AC2 sem termo genérico de programação $generic"
done

# ─── AC3 — destino rastreável dos blocos removidos (referência ao ADR 0001) ───
assert_present "$CTX" "0001-adopt-graphify-sunset-llm-wiki" "AC3 CONTEXT.md referencia o ADR 0001"
assert_present "$CTX" "Decision 3" "AC3 CONTEXT.md cita a Decision 3 (versionamento)"
assert_present "$CTX" "Decision 4" "AC3 CONTEXT.md cita a Decision 4 (merge)"

# ─── AC4 — nenhuma informação perdida (fato em CONTEXT.md OU num ADR) ─────────
ac4_facts=(
  "graphifyy"
  "safishamsi/graphify"
  "manifest.json"
  "cost.json"
  "merge=theirs"
  "graphify hook install"
  "graphify claude install"
  "graphify update ."
  "/graphify-init"
  "uv tool install graphifyy"
  "post-commit"
  "GRAPH_REPORT.md"
  "graph.json"
  "graph.html"
  ".git/hooks/"
  "2026-05-07"
)
facts_checked=0
for fact in "${ac4_facts[@]}"; do
  assert_anywhere "$fact" "AC4"
  facts_checked=$((facts_checked+1))
done
# Capture-proof: a lista precisa ter sido percorrida de verdade.
[ "$facts_checked" -ge 16 ] && _pass || _fail "AC4 varredura de fatos vazia ($facts_checked)"

# ─── AC5 — links markdown do CONTEXT.md (e ADRs novos) resolvem ──────────────
links_checked=0
while IFS= read -r line; do
  file="${line%%:*}"
  rest="${line#*:}"
  targets="$(printf '%s\n' "$rest" | grep -oE '\]\([^)]+\)' | sed -E 's/^\]\(//; s/\)$//')"
  [ -n "$targets" ] || continue
  dir="$(cd "$(dirname "$REPO_ROOT/$file")" && pwd)"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in http://*|https://*|"#"*) continue;; esac  # externos/âncoras: fora do escopo
    t="${t%%#*}"
    links_checked=$((links_checked+1))
    [ -f "$dir/$t" ] || _fail "AC5 link quebrado em $file → $t (alvo inexistente)"
  done <<< "$targets"
done < <(cd "$REPO_ROOT" && grep -nE '\]\([^)]+\)' CONTEXT.md)
# Capture-proof: CONTEXT.md tem >=1 link relativo (pro ADR 0001).
[ "$links_checked" -ge 1 ] && _pass || _fail "AC5 varredura achou $links_checked links relativos (esperado >=1)"

# ─── Summary ─────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
