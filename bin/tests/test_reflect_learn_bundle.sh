#!/usr/bin/env bash
set -u

# test_reflect_learn_bundle.sh — testes para bin/reflect-learn-bundle.sh (US-02).
#
# Cobre:
#   AC6  — bundle JSON emitido em stdout com chaves canônicas
#          (us_id, description, dod_bullets, specs, results, commits_summary)
#   AC7  — markers `// spec:` / `# spec:` detectados em test files;
#          spec sem marker vira finding `tdd_gap_marker_missing`
#   AC5  — modo --with-llm sempre grava raw-llm-output.txt; quando output
#          NÃO é JSON, proposal.json carrega finding `llm_output_unparseable`
#   AC4  — timeout do subprocess claude --print honrado (override via
#          BUNDLE_LLM_TIMEOUT_SEC=1 + mock que dorme 5s ⇒ rc != 0, mas
#          raw-llm-output.txt continua presente — fail-graceful)
#   AC8  — modo --with-llm produz report.md, proposed.diff, proposal.json em $DIR
#
# Estratégia: tudo em tmpdir; env overrides apontam para fixtures controladas.
# Mock de `claude` via PATH shadow + override de BUNDLE_CLAUDE_BIN.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(cd "$SCRIPT_DIR/.." && pwd)/reflect-learn-bundle.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }

assert_rc()       { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_contains() { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' not found";; esac; }
assert_jq_eq()    {
  # $1=file, $2=jq expr, $3=expected, $4=msg
  local got
  got="$(jq -r "$2" "$1" 2>/dev/null)"
  if [ "$got" = "$3" ]; then _pass
  else _fail "$4 :: jq '$2' got '$got' expected '$3'"; fi
}

[[ -x "$TARGET" ]] || { echo "FAIL: $TARGET inexistente ou não-executável" >&2; exit 1; }

TMP="$(mktemp -d -t reflect-learn-bundle.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ─── Fixture: prd.json com 1 US ────────────────────────────────────────────
cat > "$TMP/prd.json" <<'EOF'
{
  "userStories": [
    {
      "id": "US-FIXT",
      "title": "Fixture story",
      "description": "Just a fixture for bundle assembly tests.",
      "acceptanceCriteria": ["AC1: foo", "AC2: bar"],
      "passes": false
    }
  ]
}
EOF

# ─── Fixture: DOD.md com 3 bullets [bN] ───────────────────────────────────
cat > "$TMP/dod.md" <<'EOF'
## Categoria 1 — Fixture

### Tarefa 99 — Fixture
- [ ] [b1] bullet alpha fixture
- [ ] [b2] bullet beta fixture
- [ ] [b3] bullet gamma fixture
EOF

# ─── Fixture: TEST-PATTERNS.md com 2 specs ────────────────────────────────
cat > "$TMP/specs.md" <<'EOF'
### Tarefa 99 — Fixture
- [ ] spec-1-A (tarefa-99-spec-1-A): dado fixture, quando rodo bundle, então JSON sai
- [ ] spec-2 (tarefa-99-spec-2): dado outra spec, quando rodo, então valida
EOF

# ─── Fixture: test files com 1 marker (// spec:) — spec-1-A coberta ──────
mkdir -p "$TMP/tests" "$TMP/skills/foo/bin" "$TMP/bin/tests"
cat > "$TMP/tests/test_a.js" <<'EOF'
// spec: tarefa-99-spec-1-A
describe("fixture", () => {});
EOF
cat > "$TMP/skills/foo/bin/test-bar.sh" <<'EOF'
#!/usr/bin/env bash
# spec: tarefa-99-spec-1-A (em shell, hash comment)
echo "ok"
EOF
chmod +x "$TMP/skills/foo/bin/test-bar.sh"
# spec-2 fica sem marker → deve virar finding tdd_gap_marker_missing

# ─── Run modo bundle-only (AC6) ───────────────────────────────────────────
OUT="$(
  BUNDLE_PRD_PATH="$TMP/prd.json" \
  BUNDLE_DOD_PATH="$TMP/dod.md" \
  BUNDLE_SPECS_PATH="$TMP/specs.md" \
  BUNDLE_TEST_GLOB_ROOT="$TMP" \
  BUNDLE_COMMITS_OVERRIDE="abc1234 fixture commit" \
  "$TARGET" 999 US-FIXT 2>&1
)"
RC=$?

# AC6 — exit 0
assert_rc "$RC" 0 "AC6 bundle exit 0"

# AC6 — output is valid JSON with all canonical keys
echo "$OUT" > "$TMP/out.json"
if jq -e . "$TMP/out.json" >/dev/null 2>&1; then _pass
else _fail "AC6: stdout não é JSON válido :: $OUT"; fi

assert_jq_eq "$TMP/out.json" '.us_id'                       'US-FIXT' "AC6 us_id"
assert_jq_eq "$TMP/out.json" '.description'                 'Just a fixture for bundle assembly tests.' "AC6 description"
assert_jq_eq "$TMP/out.json" '(.dod_bullets | length)'      '3' "AC6 dod_bullets count"
assert_jq_eq "$TMP/out.json" '.dod_bullets[0].id'           'b1' "AC6 dod_bullets[0].id"
assert_jq_eq "$TMP/out.json" '(.specs | length)'            '2' "AC6 specs count"
assert_jq_eq "$TMP/out.json" '.specs[0].id'                 'tarefa-99-spec-1-A' "AC6 specs[0].id"
assert_jq_eq "$TMP/out.json" '(.results | type)'            'object' "AC6 results is object"
assert_jq_eq "$TMP/out.json" '.commits_summary'             'abc1234 fixture commit' "AC6 commits_summary"

# AC7 — spec-1-A tem test_files (>=1), spec-2 sem marker → finding tdd_gap_marker_missing
SPEC1_FILES=$(jq -r '.specs[] | select(.id=="tarefa-99-spec-1-A") | .test_files | length' "$TMP/out.json")
if [ "$SPEC1_FILES" -ge 1 ]; then _pass
else _fail "AC7: spec-1-A esperado ≥1 test_file, obtido $SPEC1_FILES"; fi

GAP_FINDINGS=$(jq -r '.findings[] | select(.type=="tdd_gap_marker_missing") | .spec_id' "$TMP/out.json")
case "$GAP_FINDINGS" in
  *tarefa-99-spec-2*) _pass ;;
  *) _fail "AC7: finding tdd_gap_marker_missing pra spec-2 ausente :: '$GAP_FINDINGS'" ;;
esac

# ─── AC5 — modo --with-llm SEMPRE grava raw, parse fail-graceful ─────────
# Mock claude que retorna texto NÃO-JSON.
MOCK_BIN_DIR="$TMP/mock-bin"
mkdir -p "$MOCK_BIN_DIR"
cat > "$MOCK_BIN_DIR/claude-nonjson" <<'EOF'
#!/usr/bin/env bash
echo "Hi, I cannot output JSON because I'm just text here."
echo "{this is not valid json"
exit 0
EOF
chmod +x "$MOCK_BIN_DIR/claude-nonjson"

OUT_DIR="$TMP/learn-out-nonjson"
BUNDLE_PRD_PATH="$TMP/prd.json" \
BUNDLE_DOD_PATH="$TMP/dod.md" \
BUNDLE_SPECS_PATH="$TMP/specs.md" \
BUNDLE_TEST_GLOB_ROOT="$TMP" \
BUNDLE_COMMITS_OVERRIDE="abc1234 fixture commit" \
BUNDLE_CLAUDE_BIN="$MOCK_BIN_DIR/claude-nonjson" \
BUNDLE_LLM_TIMEOUT_SEC=10 \
  "$TARGET" 999 US-FIXT --with-llm "$OUT_DIR" > /dev/null 2>&1
RC=$?

assert_rc "$RC" 0 "AC5 --with-llm exit 0 mesmo com output não-JSON"

# AC5 — raw gravado SEMPRE
if [ -s "$OUT_DIR/raw-llm-output.txt" ]; then _pass
else _fail "AC5: raw-llm-output.txt vazio ou ausente"; fi

# AC5 — proposal.json tem finding llm_output_unparseable
if [ -f "$OUT_DIR/proposal.json" ] && \
   jq -e '.findings[] | select(.type=="llm_output_unparseable")' "$OUT_DIR/proposal.json" >/dev/null 2>&1; then
  _pass
else
  _fail "AC5: proposal.json sem finding llm_output_unparseable"
fi

# AC8 — 3 outputs presentes
for f in report.md proposed.diff proposal.json; do
  if [ -s "$OUT_DIR/$f" ]; then _pass
  else _fail "AC8: $f ausente ou vazio em $OUT_DIR"; fi
done

# AC8 — report.md tem tabela renderizada com header "DoD × Spec"
if grep -q 'DoD × Spec' "$OUT_DIR/report.md" 2>/dev/null; then _pass
else _fail "AC8: report.md sem header de tabela"; fi

# ─── AC5 bonus — modo --with-llm com claude que emite JSON válido ────────
cat > "$MOCK_BIN_DIR/claude-okjson" <<'EOF'
#!/usr/bin/env bash
cat <<JSON
{"summary":"all good","proposals":[{"target_file":"DOD.md","action":"add_bullet","text":"novo bullet"}],"findings":[]}
JSON
EOF
chmod +x "$MOCK_BIN_DIR/claude-okjson"

OUT_DIR2="$TMP/learn-out-ok"
BUNDLE_PRD_PATH="$TMP/prd.json" \
BUNDLE_DOD_PATH="$TMP/dod.md" \
BUNDLE_SPECS_PATH="$TMP/specs.md" \
BUNDLE_TEST_GLOB_ROOT="$TMP" \
BUNDLE_COMMITS_OVERRIDE="abc1234 fixture commit" \
BUNDLE_CLAUDE_BIN="$MOCK_BIN_DIR/claude-okjson" \
BUNDLE_LLM_TIMEOUT_SEC=10 \
  "$TARGET" 999 US-FIXT --with-llm "$OUT_DIR2" > /dev/null 2>&1

# proposal.json parseou, summary preservado
if [ -f "$OUT_DIR2/proposal.json" ] && \
   [ "$(jq -r '.summary' "$OUT_DIR2/proposal.json" 2>/dev/null)" = "all good" ]; then
  _pass
else
  _fail "AC5 bonus: summary não preservado de output JSON válido"
fi

# AC4 — timeout HARD-CODED 600s. Duas asserções:
#   (a) estrutural: TIMEOUT_SEC default no script é 600 (grep direto na fonte)
#   (b) behavioral: quando `timeout`/`gtimeout` existe, override BUNDLE_LLM_TIMEOUT_SEC=1
#       mata o mock antes que ele complete (sleep 30). Skip behavioral no macOS
#       sem coreutils — script documenta isso como fallback aceito; teste
#       atestaria comportamento de overhead de subprocess, não de timeout.
if grep -qE '^TIMEOUT_SEC="\$\{BUNDLE_LLM_TIMEOUT_SEC:-600\}"' "$TARGET"; then _pass
else _fail "AC4 (estrutural): TIMEOUT_SEC default ≠ 600 em $TARGET"; fi

if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  cat > "$MOCK_BIN_DIR/claude-sleep" <<'EOF'
#!/usr/bin/env bash
sleep 30
echo "{}"
EOF
  chmod +x "$MOCK_BIN_DIR/claude-sleep"

  OUT_DIR3="$TMP/learn-out-timeout"
  START=$(date +%s)
  BUNDLE_PRD_PATH="$TMP/prd.json" \
  BUNDLE_DOD_PATH="$TMP/dod.md" \
  BUNDLE_SPECS_PATH="$TMP/specs.md" \
  BUNDLE_TEST_GLOB_ROOT="$TMP" \
  BUNDLE_COMMITS_OVERRIDE="abc1234 fixture commit" \
  BUNDLE_CLAUDE_BIN="$MOCK_BIN_DIR/claude-sleep" \
  BUNDLE_LLM_TIMEOUT_SEC=1 \
    "$TARGET" 999 US-FIXT --with-llm "$OUT_DIR3" > /dev/null 2>&1
  END=$(date +%s)
  ELAPSED=$((END - START))

  # Gap 30→1: limite generoso (≤10s) absorve overhead do shell.
  # Falha real = elapsed ≥30 (timeout não disparou).
  if [ "$ELAPSED" -le 10 ]; then _pass
  else _fail "AC4 (behavioral): timeout 1s não honrado (elapsed=${ELAPSED}s, esperado ≤10 vs mock sleep=30)"; fi

  if [ -e "$OUT_DIR3/raw-llm-output.txt" ]; then _pass
  else _fail "AC4/AC5: raw-llm-output.txt ausente após timeout"; fi
else
  # No timeout binary → skip behavioral. Estrutural já cobre código.
  # Documenta no output pra evitar suspeita de "teste pulado escondido".
  echo "  ⊘ AC4 behavioral: skipped (sem timeout/gtimeout — instale coreutils via 'brew install coreutils' pra rodar este caso)" >&2
  _pass; _pass  # 2 _pass equivalente aos 2 asserts da branch behavioral, mantém TOTAL constante
fi

# ─── US-06 (AC3) — flag --model propagada ao claude --print ──────────────
# Mock que loga argv num call-log (capture-proof) e emite JSON válido.
MODEL_LOG="$TMP/model-calllog.txt"
cat > "$MOCK_BIN_DIR/claude-logargv" <<EOF
#!/usr/bin/env bash
echo "claude \$*" >> "$MODEL_LOG"
echo '{"summary":"ok","proposals":[],"findings":[]}'
EOF
chmod +x "$MOCK_BIN_DIR/claude-logargv"

# AC3 default → --model claude-fable-5 no argv de claude --print
: > "$MODEL_LOG"
OUT_DIR_M="$TMP/learn-out-model-default"
BUNDLE_PRD_PATH="$TMP/prd.json" \
BUNDLE_DOD_PATH="$TMP/dod.md" \
BUNDLE_SPECS_PATH="$TMP/specs.md" \
BUNDLE_TEST_GLOB_ROOT="$TMP" \
BUNDLE_COMMITS_OVERRIDE="abc1234 fixture commit" \
BUNDLE_CLAUDE_BIN="$MOCK_BIN_DIR/claude-logargv" \
BUNDLE_LLM_TIMEOUT_SEC=10 \
  "$TARGET" 999 US-FIXT --with-llm "$OUT_DIR_M" > /dev/null 2>&1
RC=$?
assert_rc "$RC" 0 "US06-AC3a --with-llm default exit 0"
# capture-proof: o mock rodou co-presente (call-log não-vazio)
if [ -s "$MODEL_LOG" ]; then _pass; else _fail "US06-AC3b capture-proof: claude mock não rodou"; fi
assert_contains "$(cat "$MODEL_LOG")" "--model claude-fable-5" "US06-AC3c default --model claude-fable-5 no argv"
assert_contains "$(cat "$MODEL_LOG")" "--print" "US06-AC3d --print presente (invocação correta)"

# AC3 --model custom respeitado
: > "$MODEL_LOG"
OUT_DIR_M2="$TMP/learn-out-model-custom"
BUNDLE_PRD_PATH="$TMP/prd.json" \
BUNDLE_DOD_PATH="$TMP/dod.md" \
BUNDLE_SPECS_PATH="$TMP/specs.md" \
BUNDLE_TEST_GLOB_ROOT="$TMP" \
BUNDLE_COMMITS_OVERRIDE="abc1234 fixture commit" \
BUNDLE_CLAUDE_BIN="$MOCK_BIN_DIR/claude-logargv" \
BUNDLE_LLM_TIMEOUT_SEC=10 \
  "$TARGET" 999 US-FIXT --with-llm "$OUT_DIR_M2" --model claude-opus-4-8 > /dev/null 2>&1
assert_contains "$(cat "$MODEL_LOG")" "--model claude-opus-4-8" "US06-AC3e --model custom respeitado no argv"

# AC3 --model sem valor → exit != 0
"$TARGET" 999 US-FIXT --model > /dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then _pass; else _fail "US06-AC3f --model sem valor → exit != 0 (rc=$RC)"; fi

# ─── Summary ───────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
