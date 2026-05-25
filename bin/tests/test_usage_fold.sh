#!/usr/bin/env bash
set -u

# test_usage_fold.sh — testes para bin/lib/usage-fold.sh (US-02).
#
# Cobre os 5 acceptance criteria da story "Fold content-based (deriva contadores)":
#   AC1 — lê TODOS os telemetry/<prefix>-usage.*.jsonl e emite TSV
#         `dod_id\tusos\tdesde_rev\tlast_seen` (headerless, 4 campos/linha).
#         + isolamento por prefix (dod NÃO lê test-spec e vice-versa).
#   AC2 — usos = #eventos use + Σ(baseline.count) para o dod_id.
#   AC3 — desde_rev = #eventos use cujo sha == sha atual dos bullets (hash computado
#         na hora). baseline NÃO conta para desde_rev (só para usos); revision nunca
#         conta. sha atual == hash canônico (cross-check independente contra
#         sha256sum dos bullets — não tautológico).
#   AC4 — determinismo cross-host: 2 logs de machine-ids distintos, ts fora de
#         ordem → output idêntico independente de ordem de arquivo/evento/máquina.
#   AC5 — last_seen = max(ts) entre todos os eventos do dod_id.
#
# Estratégia: tudo em tmpdir; USAGE_LOG_HOME aponta p/ sandbox; DOD.md é um fixture
# controlado (--dod-file) p/ shas determinísticos; logs JSONL escritos à mão p/
# controle total de ts/machine/sha. 1 teste de integração usa o writer real (US-01).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$(cd "$SCRIPT_DIR/.." && pwd)/lib/usage-fold.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq()    { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_ne()    { [ "$1" != "$2" ] && _pass || _fail "$3 :: expected NOT '$2' but got it"; }
assert_match() { case "$1" in $2) _pass ;; *) _fail "$3 :: '$1' não casa com '$2'";; esac; }

[[ -f "$TARGET" ]] || { echo "FAIL: $TARGET inexistente" >&2; exit 1; }

# sha256 de stdin (mesma escolha de ferramenta que o impl).
h256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  else shasum -a 256 | cut -d' ' -f1; fi
}

# Emite 1 linha JSONL schema v1.  mkev <kind> <dod_id> <sha> <ts> <machine> [count]
mkev() {
  local kind="$1" id="$2" sha="$3" ts="$4" mach="$5" count="${6:-}"
  if [ "$kind" = baseline ]; then
    printf '{"v":1,"ts":"%s","machine":"%s","dod_id":"%s","kind":"baseline","count":%s,"sha":"%s"}\n' \
      "$ts" "$mach" "$id" "$count" "$sha"
  else
    printf '{"v":1,"ts":"%s","machine":"%s","dod_id":"%s","kind":"%s","sha":"%s"}\n' \
      "$ts" "$mach" "$id" "$kind" "$sha"
  fi
}

TMP="$(mktemp -d -t usage-fold.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ─── Fixture DOD.md (bytes controlados; blank lines onde indicado) ───────────
FIX="$TMP/DOD.md"
printf '%s\n' \
  '# Fixture DOD' \
  '' \
  '## Categoria 1 — Test' \
  '' \
  '### DoD-base — Categoria 1 (usos: 0 · desde rev: 0)' \
  '- [ ] [b1] foo base' \
  '- [ ] [b2] bar base' \
  '' \
  '### Tarefa 1 — Exemplo um (usos: 0 · desde rev: 0)' \
  '- [ ] [b1] alpha' \
  '' \
  '### Tarefa 2 — Exemplo dois (usos: 0 · desde rev: 0)' \
  '- [ ] [b1] beta' \
  '- [ ] [b2] gamma' \
  > "$FIX"

# Funções do impl no shell atual (dual-mode guard impede execução ao sourcear).
# shellcheck source=bin/lib/usage-fold.sh
source "$TARGET"

SHAMAP="$(dod_bullets_sha "$FIX")"
SHA_C1="$(printf '%s\n' "$SHAMAP" | awk -F'\t' '$1=="cat-1-base"{print $2}')"
SHA_T1="$(printf '%s\n' "$SHAMAP" | awk -F'\t' '$1=="tarefa-1"{print $2}')"
SHA_T2="$(printf '%s\n' "$SHAMAP" | awk -F'\t' '$1=="tarefa-2"{print $2}')"
STALE="stalesha000"

# ─── AC3 (sub) — sha atual == hash canônico dos bullets (cross-check) ────────
# tarefa-1: 1 bullet + blank line antes do próximo heading (capturado pela awk).
EXP_T1="$(printf '%s\n' '- [ ] [b1] alpha' '' | h256)"
assert_eq "$SHA_T1" "$EXP_T1" "AC3 sha tarefa-1 == sha256 canônico (bullet + blank)"
# tarefa-2: 2 bullets, sem blank trailing (EOF).
EXP_T2="$(printf '%s\n' '- [ ] [b1] beta' '- [ ] [b2] gamma' | h256)"
assert_eq "$SHA_T2" "$EXP_T2" "AC3 sha tarefa-2 == sha256 canônico (2 bullets, EOF)"
assert_ne "$SHA_T1" "$STALE" "AC3 sha real != sha stale (sanidade)"
assert_ne "$SHA_T1" "$SHA_T2" "AC3 DoDs distintos → shas distintos"

# ─── Logs: 2 máquinas, ts fora de ordem, eventos por dod_id ──────────────────
HOME_A="$TMP/A"; mkdir -p "$HOME_A/telemetry"
{
  mkev use      tarefa-1   "$SHA_T1" 2026-01-01T00:00:00Z m1
  mkev use      tarefa-1   "$STALE"  2026-02-02T00:00:00Z m1
  mkev baseline tarefa-2   "$SHA_T2" 2026-01-05T00:00:00Z m1 7
  mkev use      cat-1-base "$SHA_C1" 2026-05-05T00:00:00Z m1
  mkev use      tarefa-99  anysha1   2026-01-09T00:00:00Z m1
  mkev baseline tarefa-99  anysha3   2026-01-08T00:00:00Z m1 3
} > "$HOME_A/telemetry/dod-usage.m1.jsonl"
{
  mkev use      tarefa-1   "$SHA_T1" 2026-03-03T00:00:00Z m2
  mkev use      tarefa-2   "$SHA_T2" 2026-04-04T00:00:00Z m2
  mkev baseline cat-1-base "$STALE"  2026-01-02T00:00:00Z m2 5
  mkev use      tarefa-99  anysha2   2026-02-09T00:00:00Z m2
} > "$HOME_A/telemetry/dod-usage.m2.jsonl"

OUT1="$(USAGE_LOG_HOME="$HOME_A" usage_fold --dod-file "$FIX")"

# Esperado (ordenado por dod_id):
#   cat-1-base: usos=5(baseline@stale)+1(use@cur)=6 ; desde_rev=1(use@cur)          (AC2 floor; AC3 baseline não conta)
#   tarefa-1  : usos=3(use) ; desde_rev=2(use@cur, 1 use@stale excluído)            (AC2 use, AC3)
#   tarefa-2  : usos=7(baseline)+1(use)=8 ; desde_rev=1(use@cur; baseline NÃO conta) (AC3 use-only — finding P0)
#   tarefa-99 : usos=2(use)+3(baseline)=5 ; desde_rev=0 (órfão, sha_atual=null) ; last_seen=max
EXPECTED="$(printf 'cat-1-base\t6\t1\t2026-05-05T00:00:00Z\ntarefa-1\t3\t2\t2026-03-03T00:00:00Z\ntarefa-2\t8\t1\t2026-04-04T00:00:00Z\ntarefa-99\t5\t0\t2026-02-09T00:00:00Z')"
assert_eq "$OUT1" "$EXPECTED" "AC1+AC2+AC3+AC5 fold completo bate exato"

# AC1 — toda linha tem exatamente 4 campos TSV.
BADROWS="$(printf '%s\n' "$OUT1" | awk -F'\t' 'NF!=4{c++} END{print c+0}')"
assert_eq "$BADROWS" "0" "AC1 toda linha do TSV tem 4 campos"

# AC5 — last_seen é o max(ts) (cat-1-base: 05-05 é o maior dos seus 2 eventos).
LS_C1="$(printf '%s\n' "$OUT1" | awk -F'\t' '$1=="cat-1-base"{print $4}')"
assert_eq "$LS_C1" "2026-05-05T00:00:00Z" "AC5 last_seen = max(ts) do dod_id"

# ─── AC4 — determinismo: redistribui os MESMOS eventos em 2 outros arquivos,
#           ordem de linha revertida e máquina trocada → output idêntico. ─────
HOME_B="$TMP/B"; mkdir -p "$HOME_B/telemetry"
revlines() { awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' "$1"; }
revlines "$HOME_A/telemetry/dod-usage.m2.jsonl" > "$HOME_B/telemetry/dod-usage.m3.jsonl"
revlines "$HOME_A/telemetry/dod-usage.m1.jsonl" > "$HOME_B/telemetry/dod-usage.m4.jsonl"
OUT2="$(USAGE_LOG_HOME="$HOME_B" usage_fold --dod-file "$FIX")"
assert_eq "$OUT2" "$OUT1" "AC4 output idêntico sob permutação de arquivo/evento/máquina"

# ─── AC1 — isolamento por prefix ─────────────────────────────────────────────
HOME_PX="$TMP/PX"; mkdir -p "$HOME_PX/telemetry"
mkev use tarefa-1 "$SHA_T1" 2026-01-01T00:00:00Z mx > "$HOME_PX/telemetry/dod-usage.mx.jsonl"
mkev use tarefa-1 "$SHA_T1" 2026-01-01T00:00:00Z mx > "$HOME_PX/telemetry/test-spec-usage.mx.jsonl"
OUT_DOD="$(USAGE_LOG_HOME="$HOME_PX" usage_fold --prefix dod --dod-file "$FIX")"
OUT_SPEC="$(USAGE_LOG_HOME="$HOME_PX" usage_fold --prefix test-spec --dod-file "$FIX")"
assert_eq "$(printf '%s' "$OUT_DOD"  | cut -f2)" "1" "AC1 prefix dod lê só dod-usage.* (usos=1, não 2)"
assert_eq "$(printf '%s' "$OUT_SPEC" | cut -f2)" "1" "AC1 prefix test-spec lê só test-spec-usage.*"

# ─── AC3 regressão (finding P0, review-US-02-iter4) — baseline@sha-atual NÃO
#     conta para desde_rev. Único baseline{count:7,sha:atual}, zero eventos use →
#     usos=7 (baseline = piso de usos), desde_rev=0 (só kind=use conta). ─────────
HOME_BL="$TMP/BL"; mkdir -p "$HOME_BL/telemetry"
mkev baseline tarefa-1 "$SHA_T1" 2026-01-01T00:00:00Z mb 7 > "$HOME_BL/telemetry/dod-usage.mb.jsonl"
OUT_BL="$(USAGE_LOG_HOME="$HOME_BL" usage_fold --dod-file "$FIX")"
assert_eq "$(printf '%s' "$OUT_BL" | cut -f2)" "7" "AC3 baseline@cur: usos=7 (piso de usos)"
assert_eq "$(printf '%s' "$OUT_BL" | cut -f3)" "0" "AC3 baseline@cur NÃO conta p/ desde_rev (regressão finding P0)"

# ─── Empty — sem logs → TSV vazio, exit 0 ────────────────────────────────────
HOME_E="$TMP/E"; mkdir -p "$HOME_E"
OUT_E="$(USAGE_LOG_HOME="$HOME_E" usage_fold --dod-file "$FIX")"; RC_E=$?
assert_eq "$OUT_E" "" "fold sem logs → TSV vazio"
assert_eq "$RC_E" "0" "fold sem logs → exit 0"

# ─── Integração com o writer real (US-01 ↔ US-02) ────────────────────────────
HOME_C="$TMP/C"; mkdir -p "$HOME_C"
USAGE_LOG_HOME="$HOME_C" log_event use tarefa-1 --sha "$SHA_T1"
USAGE_LOG_HOME="$HOME_C" log_event use tarefa-1 --sha "$SHA_T1"
OUT_INT="$(USAGE_LOG_HOME="$HOME_C" usage_fold --dod-file "$FIX")"
assert_eq "$(printf '%s' "$OUT_INT" | cut -f1)" "tarefa-1" "integração: dod_id derivado do writer"
assert_eq "$(printf '%s' "$OUT_INT" | cut -f2)" "2"        "integração: usos=2 (2 use via log_event)"
assert_eq "$(printf '%s' "$OUT_INT" | cut -f3)" "2"        "integração: desde_rev=2 (sha == sha atual)"
assert_match "$(printf '%s' "$OUT_INT" | cut -f4)" "????-??-??T??:??:??Z" "integração: last_seen ISO-8601 UTC"

# ─── Summary ─────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
