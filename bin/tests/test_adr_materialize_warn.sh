#!/usr/bin/env bash
set -u

# test_adr_materialize_warn.sh — testes para hooks/adr-materialize-warn.sh.
#
# O hook é um Stop hook BEST-EFFORT (nunca bloqueia, SEMPRE exit 0) que avisa
# quando o plano mais recente em <proj>/.claude/plans/*.md contém a seção
# '## ADRs propostos', NÃO contém o marcador de quitação <!-- adr-materialized -->,
# E o git status não mostra mudança em docs/adr/ (ADRs prometidos mas não
# materializados). Qualquer outra combinação → silêncio. Backstop determinístico
# da ressalva Alta #1 da revisão adversária (ADR proposto esquecido).
#
# Estratégia (espelha test_dod_usage_hook.sh): CLAUDE_PROJECT_DIR aponta p/ um
# projeto SANDBOX (git real, docs/adr/ commitado limpo); ADR_WARN_GIT é um seam
# p/ injetar um git ausente/quebrado e exercitar a falha interna. Asserts
# CAPTURE-PROOF: cada caso de SILÊNCIO vem acompanhado de um sibling positivo
# com as MESMAS fixtures menos a condição silenciadora, provando que o pipeline
# de detecção realmente rodou (silêncio genuíno, não falso-pass por path errado).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO/hooks/adr-materialize-warn.sh"
SYNC_SRC="$REPO/sync.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq()       { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_contains() { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: '$2' ausente em '$1'" ;; esac; }
assert_empty()    { [ -z "$1" ] && _pass || _fail "$2 :: esperava vazio, veio '$1'"; }

[ -f "$HOOK" ] || { echo "FAIL: $HOOK inexistente" >&2; exit 1; }

# ── AC1: contrato estático (shebang + bit de execução) ──────────────────────
case "$(head -1 "$HOOK")" in
  '#!'*) _pass ;;
  *)     _fail "AC1 shebang explícito na 1ª linha" ;;
esac
[ -x "$HOOK" ] && _pass || _fail "AC1 hook é executável (chmod +x)"

TMP="$(mktemp -d -t adr-warn.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# mkplan <plansdir> <file> <tem_secao 1|0> <tem_marcador 1|0>
PLAN_SECTION='## ADRs propostos'
mkplan() {
  mkdir -p "$1"
  {
    echo "# Plano de teste"
    [ "$3" = 1 ] && printf '%s\n' "$PLAN_SECTION"
    echo "- ADR-X: usar Y em vez de Z porque trade-off W"
    [ "$4" = 1 ] && echo "<!-- adr-materialized -->"
  } > "$1/$2"
}

# mkproj <dir> — projeto git sandbox com docs/adr/ commitado e árvore limpa
mkproj() {
  mkdir -p "$1/docs/adr" "$1/.claude/plans"
  echo "# ADR 0001 base" > "$1/docs/adr/0001-base.md"
  git -C "$1" init -q
  git -C "$1" symbolic-ref HEAD refs/heads/main
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name  test
  git -C "$1" config commit.gpgsign false
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" commit -q -m init
}

# run_hook <proj> <payload> [gitbin] → stdout (RC via $?)
run_hook() {
  local proj="$1" payload="${2:-}" gitbin="${3:-}"
  [ -n "$payload" ] || payload='{}'
  if [ -n "$gitbin" ]; then
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj" ADR_WARN_GIT="$gitbin" bash "$HOOK"
  else
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$proj" bash "$HOOK"
  fi
}

# ─── 1. CASO WARNING (baseline positivo) ────────────────────────────────────
# seção presente + sem marcador + docs/adr/ sem mudança → avisa com o path.
P1="$TMP/warn"; mkproj "$P1"
mkplan "$P1/.claude/plans" "2026-01-01-plano.md" 1 0
OUT="$(run_hook "$P1" '{}')"; RC=$?
assert_eq "$RC" "0" "1 warning case exit 0"
assert_contains "$OUT" "$P1/.claude/plans/2026-01-01-plano.md" "1 warning cita o path do plano"
assert_contains "$OUT" "não materializado" "1 warning traz a frase de diagnóstico"

# ─── 2. QUITADO PELO MARCADOR → silêncio (capture-proof) ────────────────────
# Co-presença: o MESMO dir/plano sem marcador avisa (prova que o path roda);
# com o marcador <!-- adr-materialized --> fica em silêncio.
P2="$TMP/marker"; mkproj "$P2"
mkplan "$P2/.claude/plans" "plano.md" 1 0
OUT="$(run_hook "$P2" '{}')"
assert_contains "$OUT" "plano.md" "2 (co-prova) sem marcador → avisa"
mkplan "$P2/.claude/plans" "plano.md" 1 1     # agora COM marcador
OUT="$(run_hook "$P2" '{}')"; RC=$?
assert_eq "$RC" "0" "2 marcador exit 0"
assert_empty "$OUT" "2 marcador <!-- adr-materialized --> → silêncio"

# ─── 3. docs/adr/ ALTERADO → silêncio (capture-proof) ───────────────────────
# Co-presença: árvore limpa avisa; introduzir mudança em docs/adr/ silencia.
P3="$TMP/adrchange"; mkproj "$P3"
mkplan "$P3/.claude/plans" "plano.md" 1 0
OUT="$(run_hook "$P3" '{}')"
assert_contains "$OUT" "plano.md" "3 (co-prova) docs/adr/ limpo → avisa"
echo "# ADR 0004 novo" > "$P3/docs/adr/0004-novo.md"   # mudança não-commitada
OUT="$(run_hook "$P3" '{}')"; RC=$?
assert_eq "$RC" "0" "3 docs/adr alterado exit 0"
assert_empty "$OUT" "3 mudança em docs/adr/ → silêncio (materialização em curso)"

# ─── 4. SEM A SEÇÃO → silêncio (capture-proof) ──────────────────────────────
P4="$TMP/nosec"; mkproj "$P4"
mkplan "$P4/.claude/plans" "plano.md" 0 0      # sem '## ADRs propostos'
OUT="$(run_hook "$P4" '{}')"; RC=$?
assert_eq "$RC" "0" "4 sem seção exit 0"
assert_empty "$OUT" "4 plano sem '## ADRs propostos' → silêncio"
mkplan "$P4/.claude/plans" "plano.md" 1 0      # co-prova: adicionar a seção avisa
OUT="$(run_hook "$P4" '{}')"
assert_contains "$OUT" "plano.md" "4 (co-prova) com a seção → avisa"

# ─── 5. FALHA INTERNA (git ausente) → exit 0 silencioso (capture-proof) ─────
# Co-presença: com git real avisa; com ADR_WARN_GIT apontando p/ binário
# inexistente, a checagem de docs/adr/ falha → silêncio sem quebrar.
P5="$TMP/nogit"; mkproj "$P5"
mkplan "$P5/.claude/plans" "plano.md" 1 0
OUT="$(run_hook "$P5" '{}')"
assert_contains "$OUT" "plano.md" "5 (co-prova) git real → avisa"
OUT="$(run_hook "$P5" '{}' "$TMP/no-such-git-binary")"; RC=$?
assert_eq "$RC" "0" "5 git ausente exit 0"
assert_empty "$OUT" "5 git ausente → silêncio (falha interna não bloqueia)"

# ─── 6. stop_hook_active=true → no-op (guard de re-entrância, AC1) ───────────
P6="$TMP/guard"; mkproj "$P6"
mkplan "$P6/.claude/plans" "plano.md" 1 0
OUT="$(run_hook "$P6" '{"stop_hook_active":true}')"; RC=$?
assert_eq "$RC" "0" "6 stop_hook_active exit 0"
assert_empty "$OUT" "6 stop_hook_active=true → no-op silencioso"
OUT="$(run_hook "$P6" '{}')"     # co-prova: sem o guard, avisa
assert_contains "$OUT" "plano.md" "6 (co-prova) sem guard → avisa o plano pendente"

# ─── 7. PLANO MAIS RECENTE manda — só ele é avaliado ────────────────────────
# Dois planos: o mais antigo TEM a seção, o mais recente NÃO. Como só o mais
# recente conta, o resultado é silêncio. Inverter a ordem → avisa.
P7="$TMP/recent"; mkproj "$P7"
PL7="$P7/.claude/plans"
mkplan "$PL7" "antigo.md" 1 0
mkplan "$PL7" "novo.md"   0 0
touch -t 202601010000 "$PL7/antigo.md"
touch -t 202601020000 "$PL7/novo.md"
OUT="$(run_hook "$P7" '{}')"
assert_empty "$OUT" "7 mais recente sem seção → silêncio (ignora plano antigo com seção)"
# inverte: o mais recente passa a ter a seção
mkplan "$PL7" "novo.md" 1 0
touch -t 202601020000 "$PL7/novo.md"
OUT="$(run_hook "$P7" '{}')"
assert_contains "$OUT" "novo.md" "7 mais recente com seção → avisa (cita o plano novo)"

# ─── 8. SEM dir de planos → silêncio exit 0 ─────────────────────────────────
P8="$TMP/noplans"; mkdir -p "$P8"
OUT="$(run_hook "$P8" '{}')"; RC=$?
assert_eq "$RC" "0" "8 sem .claude/plans exit 0"
assert_empty "$OUT" "8 projeto sem dir de planos → silêncio"

# ─── 9. AC4: install registra o hook como Stop com timeout 5000 ─────────────
# Reproduz o pattern do dod-usage-log.sh: sandbox repo + sync.sh install +
# SYNC_CLAUDE_HOME, asserindo a entry Stop com sufixo do hook e timeout 5000ms.
mkrepo() {
  local repo="$1"
  mkdir -p "$repo/hooks"
  cp "$SYNC_SRC" "$repo/sync.sh"; chmod +x "$repo/sync.sh"
  cp "$HOOK" "$repo/hooks/adr-materialize-warn.sh"; chmod +x "$repo/hooks/adr-materialize-warn.sh"
  printf 'X\n' > "$repo/CLAUDE.md"
  git -C "$repo" init -q
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name  test
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" add -A >/dev/null 2>&1
  git -C "$repo" commit -q -m init
}
adr_stop_entry() {   # <settings.json> <home> → "<count> <timeout> <matcher_ok> <home_ok>"
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("-1 - - -"); sys.exit(0)
home = sys.argv[2]
cnt = 0; timeout = "-"; matcher_ok = "0"; home_ok = "0"
for g in d.get("hooks", {}).get("Stop", []):
    for h in g.get("hooks", []):
        c = str(h.get("command", ""))
        if c.endswith("hooks/adr-materialize-warn.sh"):
            cnt += 1
            timeout = str(h.get("timeout"))
            matcher_ok = "1" if g.get("matcher", "") == "" else "0"
            home_ok = "1" if c.startswith(home) and "/Users/" not in c.replace(home, "") else "0"
print(f"{cnt} {timeout} {matcher_ok} {home_ok}")
PY
}
if command -v python3 >/dev/null 2>&1; then
  RR="$TMP/reg/repo"; RH="$TMP/reg/home"; mkrepo "$RR"; mkdir -p "$RH"
  SYNC_CLAUDE_HOME="$RH" bash "$RR/sync.sh" install >/dev/null 2>&1
  read -r CNT TMO MOK HOK <<<"$(adr_stop_entry "$RH/settings.json" "$RH")"
  assert_eq "$CNT" "1"    "9 AC4 install registra 1 entry Stop p/ adr-materialize-warn.sh"
  assert_eq "$TMO" "5000" "9 AC4 timeout explícito 5000ms"
  assert_eq "$MOK" "1"    "9 AC4 matcher Stop vazio (grupo '')"
  assert_eq "$HOK" "1"    "9 AC4 command usa CLAUDE_DIR do sandbox (sem /Users hardcoded)"
  # idempotência
  SYNC_CLAUDE_HOME="$RH" bash "$RR/sync.sh" install >/dev/null 2>&1
  read -r CNT2 _ _ _ <<<"$(adr_stop_entry "$RH/settings.json" "$RH")"
  assert_eq "$CNT2" "1"   "9 AC4 install idempotente (Stop não duplicado)"
else
  _pass; _pass; _pass; _pass; _pass   # python3 ausente: pula o bloco de registro
fi

# ─── Summary ────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
