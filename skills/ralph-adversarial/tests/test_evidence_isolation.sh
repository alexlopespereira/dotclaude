#!/usr/bin/env bash
set -u
# test_evidence_isolation.sh — F1 do plano ralph-evidence-pollution-fix.
#
# Garante que extract_verdict_json isola o ÚLTIMO objeto JSON com .verdict no
# transcript do reviewer, ignorando o `cat progress.txt` poluído que o Codex
# imprime no início (pipe-delimited, com substrings "evidence": que NÃO são
# objetos JSON). Assim a evidence extraída é só a do finding REAL desta story,
# nunca a velha/cross-story que poluía progress.txt.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../parse-verdict.sh
source "$SCRIPT_DIR/../parse-verdict.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }

command -v extract_verdict_json >/dev/null 2>&1 || { echo "FAIL: extract_verdict_json não definido em parse-verdict.sh" >&2; exit 1; }

# ── Fixture: transcript realista do Codex ───────────────────────────────────
# (a) echo poluído de progress.txt (pipe-delimited; substrings "evidence" mas
#     NÃO objetos JSON com .verdict); (b) prosa; (c) bloco JSON real no fim.
#     O finding real tem um `}` DENTRO da string de evidence — prova que o
#     parser respeita contexto de string (brace-counting ingênuo quebraria aqui).
read -r -d '' TRANSCRIPT <<'EOF' || true
exec sed -n '1,240p' progress.txt
2026-05-20 | REVIEW_REQUEST_CHANGES | US-01 | "evidence": "VELHO finding tdd-chain dod-add-bullet-ids"
2026-05-20 | REVIEW_REQUEST_CHANGES | US-02 | "evidence": "VELHO finding TMP_NEXT cleanup leak"
codex
Vou revisar o HEAD em modo somente leitura.
{
  "ac_trace": [{"ac_id":"US-01.AC1","code":"x.sh:58","test":"t.sh:54","verdict":"pass"}],
  "findings": [{"dim":"RELIABILITY","priority":1,"file":"usage-log.sh","line":66,"evidence":"REAL: log_event use --sha sem valor entra em loop (shift 2 nao consome) }","fix":"guard [ $# -ge 2 ]"}],
  "verdict": "REQUEST_CHANGES"
}
## Verdict: REQUEST_CHANGES
EOF

VJSON="$(printf '%s' "$TRANSCRIPT" | extract_verdict_json)"

# 1) bloco isolado é JSON válido com .verdict
if printf '%s' "$VJSON" | jq -e '.verdict' >/dev/null 2>&1; then _pass
else _fail "bloco isolado deveria parsear com .verdict (got: $VJSON)"; fi

# 2) verdict correto
V="$(printf '%s' "$VJSON" | jq -r '.verdict' 2>/dev/null)"
[ "$V" = "REQUEST_CHANGES" ] && _pass || _fail "verdict do bloco == REQUEST_CHANGES (got: $V)"

# 3) evidence extraída INCLUI o finding real (com } na string)
EV="$(printf '%s' "$VJSON" | jq -r '.findings[]?.evidence // empty' 2>/dev/null)"
case "$EV" in *"REAL: log_event"*) _pass ;; *) _fail "evidence deveria incluir o finding real (got: $EV)";; esac

# 4) evidence NÃO inclui finding velho (poluição cross-story) — o coração do fix
case "$EV" in *VELHO*) _fail "evidence NÃO deve incluir finding velho (poluição de progress.txt)" ;; *) _pass ;; esac

# 5) transcript sem bloco JSON → extract_verdict_json vazio (não raspa lixo)
NOJSON="$(printf 'so prosa\n2026 | REVIEW | US-09 | "evidence": "lixo"\n## Verdict: MERGE' | extract_verdict_json)"
[ -z "$NOJSON" ] && _pass || _fail "sem objeto JSON com .verdict → deve retornar vazio (got: $NOJSON)"

# 6) múltiplos blocos → pega o ÚLTIMO com .verdict (Codex às vezes duplica)
MULTI="$(printf '{"verdict":"BLOCK","findings":[{"evidence":"primeiro"}]}\nprosa\n{"verdict":"MERGE","findings":[{"evidence":"ultimo"}]}' | extract_verdict_json | jq -r '.findings[0].evidence')"
[ "$MULTI" = "ultimo" ] && _pass || _fail "deve isolar o ÚLTIMO bloco com .verdict (got: $MULTI)"

# ── Summary ─────────────────────────────────────────────────────────────────
TOTAL=$((PASS+FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then printf '%s\n' "$FAILED"; exit 1; fi
exit 0
