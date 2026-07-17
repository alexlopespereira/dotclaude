#!/usr/bin/env bash
set -u
# bin/tests/test_ralph_review_evidence.sh — cobre extract_review_evidence() de
# skills/ralph-adversarial/parse-verdict.sh.
#
# Origem: sessão gcontacts-sf-sync (2026-07-16). O Codex frequentemente emite
# REQUEST_CHANGES como PROSA — bullets "arquivo:linha — descrição" (o formato
# que a própria rubrica pede), SEM array `findings` JSON. A extração antiga só
# lia (1) `.findings[].evidence` via jq e (2) fallback grep `"evidence":` sobre
# o JSON isolado. Prosa não casava em nenhum → evidence VAZIA em progress.txt →
# o worker da próxima iteração recebia "evidência vazia", não via o finding e
# quase deixou passar um bug de data-loss (US-03 OtherPhone). extract_review_
# evidence adiciona um 3º fallback que captura os findings em prosa SEM raspar o
# `cat progress.txt` poluído (linhas de evento pipe-delimited) que o reviewer
# imprime no início — preservando a isolação do fix 2026-05-25.
#
# Cobertura:
#   1. JSON estruturado com findings[].evidence  → extrai a evidence real.
#   2. JSON path NÃO regride a isolação: ignora evidence VELHA cross-story do
#      header progress.txt.
#   3. PROSA "arquivo:linha — desc" sem findings JSON → extrai os findings.
#   4. PROSA: NÃO capta as linhas de evento do progress.txt poluído (bleed).
#   5. Filtro do exemplo didático da rubrica (user_id concatenado em SQL).
#   6. Sem finding nenhum → saída vazia.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_SH="$(cd "$SCRIPT_DIR/../.." && pwd)/skills/ralph-adversarial/parse-verdict.sh"

[ -f "$PARSE_SH" ] || { echo "FAIL: parse-verdict.sh não encontrado em $PARSE_SH"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq não instalado"; exit 1; }
# shellcheck source=/dev/null
source "$PARSE_SH"
command -v extract_review_evidence >/dev/null 2>&1 \
    || { echo "FAIL: extract_review_evidence não definido em parse-verdict.sh"; exit 1; }

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }

# ── 1+2) Transcript com findings JSON (+ header progress.txt poluído) ────────
read -r -d '' T_JSON <<'EOF' || true
exec sed -n '1,240p' progress.txt
2026-05-20 | REVIEW_REQUEST_CHANGES | US-01 | VELHO finding cross-story a
2026-05-20 | REVIEW_REQUEST_CHANGES | US-02 | VELHO finding cross-story b
codex
Vou revisar o HEAD.
{
  "ac_trace": [{"ac_id":"US-03.AC2","code":"match.py:228","test":"t.py:1","verdict":"partial"}],
  "findings": [{"dim":"AC_COMPLIANCE","priority":1,"file":"match.py","line":228,"evidence":"REAL_JSON: build_phone_update zera OtherPhone no ramo mobile vazio","fix":"emitir só campos alterados"}],
  "verdict": "REQUEST_CHANGES"
}
## Verdict: REQUEST_CHANGES
EOF

EV_JSON="$(printf '%s' "$T_JSON" | extract_review_evidence)"
case "$EV_JSON" in *"REAL_JSON: build_phone_update"*) _pass ;; *) _fail "1) evidence do finding JSON real ausente (got: $EV_JSON)";; esac
case "$EV_JSON" in *VELHO*) _fail "2) evidence NÃO deve conter finding VELHO cross-story (got: $EV_JSON)" ;; *) _pass ;; esac

# ── 3+4) Transcript com findings em PROSA (sem array findings JSON) ──────────
read -r -d '' T_PROSE <<'EOF' || true
exec sed -n '1,240p' progress.txt
2026-05-20 | REVIEW_REQUEST_CHANGES | US-01 | VELHO finding cross-story x
[B] Codex — Revisando código...
codex
src/gcsync/match.py:228 — build_phone_update escreve OtherPhone em qualquer cascata; ramo mobile vazio zera dado existente.

tests/test_match.py:199 — teste negativo AC6 passa trivialmente num payload vazio.

## Verdict: REQUEST_CHANGES
tokens used
81.996
src/gcsync/match.py:228 — build_phone_update escreve OtherPhone em qualquer cascata; ramo mobile vazio zera dado existente.

## Verdict: REQUEST_CHANGES
EOF

EV_PROSE="$(printf '%s' "$T_PROSE" | extract_review_evidence)"
case "$EV_PROSE" in *"match.py:228"*) _pass ;; *) _fail "3) finding em prosa (match.py:228) deveria ser extraído (got: $EV_PROSE)";; esac
case "$EV_PROSE" in *"test_match.py:199"*) _pass ;; *) _fail "3b) segundo finding em prosa (test_match.py:199) ausente (got: $EV_PROSE)";; esac
case "$EV_PROSE" in *VELHO*) _fail "4) prosa NÃO deve captar linha de evento poluída do progress.txt (got: $EV_PROSE)" ;; *) _pass ;; esac
# dedup: o finding repetido não deve aparecer 2×
N_DUP=$(printf '%s\n' "$EV_PROSE" | grep -c 'match.py:228' || true)
[ "$N_DUP" -le 1 ] && _pass || _fail "4b) finding repetido deveria ser deduplicado (got ${N_DUP}×)"

# ── 5) filtro do exemplo didático da rubrica ────────────────────────────────
read -r -d '' T_RUBRIC <<'EOF' || true
codex
auth.py:12 — user_id concatenado em SQL sem parâmetro (exemplo da rubrica)
## Verdict: REQUEST_CHANGES
EOF
EV_RUBRIC="$(printf '%s' "$T_RUBRIC" | extract_review_evidence)"
[ -z "$EV_RUBRIC" ] && _pass || _fail "5) exemplo didático da rubrica deveria ser filtrado (got: $EV_RUBRIC)"

# ── 6) sem finding → vazio ──────────────────────────────────────────────────
EV_NONE="$(printf 'só prosa sem findings\n## Verdict: MERGE' | extract_review_evidence)"
[ -z "$EV_NONE" ] && _pass || _fail "6) transcript sem finding → saída vazia (got: $EV_NONE)"

# ── Summary ─────────────────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
echo "test_ralph_review_evidence: $PASS/$TOTAL pass"
if [ "$FAIL" -gt 0 ]; then printf '%s\n' "$FAILED"; exit 1; fi
exit 0
