#!/usr/bin/env bash
# test_autonomy_miss_tracker.sh — testes para hooks/autonomy-miss-tracker.sh (R6).
#
# O hook UserPromptSubmit detecta resposta-carimbo (prompt que só aprova o que o
# assistente já propôs: "sim", "pode", "prossiga", "opção A"…) e appenda 1 miss
# de autonomia em miss.jsonl. Cada carimbo = 1 turno em que o Claude devia ter
# agido sozinho (Princípio 15). Origem: R6 da análise de 504 interrupções
# (2026-07-01), ~/analise-interrupcoes/autonomia-recomendacoes.md.
#
# Contratos cobertos:
#   T1 — table-driven (DoD tarefa-8/b12): carimbo × não-carimbo. Boundaries:
#        "simulei" não casa "sim"; "okay" não casa "ok".
#   T2 — registro escrito é JSON válido com ts/session_id/cwd/prompt (b13:
#        jq parse do tail) e append acumula (2 runs → 2 linhas).
#   T3 — best-effort (b8): stdin vazio/JSON inválido/jq ausente → exit 0, sem
#        escrita, sem crash.
#   T4 — stdout SEMPRE vazio (stdout de UserPromptSubmit vira contexto injetado).
#
# Seams: AMT_JQ (binário jq), AMT_OUT (path do miss.jsonl).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/autonomy-miss-tracker.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_rc() { [ "$1" = "$2" ] && _pass || _fail "$3 :: esperado rc=$2 obteve rc=$1"; }
assert_eq() { [ "$1" = "$2" ] && _pass || _fail "$3 :: esperado '$2' obteve '$1'"; }

[ -f "$HOOK" ] || { echo "FAIL: hook inexistente: $HOOK" >&2; exit 1; }
bash -n "$HOOK" || { echo "FAIL: bash -n sujo" >&2; exit 1; }

TMP="$(mktemp -d -t amt.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

payload() { # payload <prompt> — JSON de UserPromptSubmit
  python3 -c 'import json,sys; print(json.dumps({"session_id":"sess-1","cwd":"/tmp/proj","hook_event_name":"UserPromptSubmit","prompt":sys.argv[1]}))' "$1"
}

run_hook() { # run_hook <out-file> <prompt> → ecoa "rc stdout_len line_count"
  local out="$1" prompt="$2" rc stdout
  stdout="$(payload "$prompt" | AMT_OUT="$out" bash "$HOOK")"; rc=$?
  echo "$rc ${#stdout} $( [ -f "$out" ] && wc -l < "$out" || echo 0 )"
}

# ── T1: table-driven carimbo × não-carimbo ───────────────────────────────────
CARIMBOS=("sim" "Sim, segue" "pode" "prossiga" "continue" "siga" "OK" "ok pra mim" "concordo" "opção A" "Opcao B")
NAO_CARIMBOS=("como funciona o retry?" "simulei o teste e falhou" "okay vamos mudar a abordagem" "podemos discutir outra opção" "/commit-push-pr" "implementa a feature X")

i=0
for p in "${CARIMBOS[@]}"; do
  i=$((i+1)); OUT="$TMP/c$i.jsonl"
  read -r rc slen lines <<< "$(run_hook "$OUT" "$p")"
  assert_rc "$rc" 0 "T1 carimbo '$p' exit 0"
  assert_eq "$lines" 1 "T1 carimbo '$p' appenda 1 linha"
  assert_eq "$slen" 0 "T4 carimbo '$p' stdout vazio"
done
i=0
for p in "${NAO_CARIMBOS[@]}"; do
  i=$((i+1)); OUT="$TMP/n$i.jsonl"
  read -r rc slen lines <<< "$(run_hook "$OUT" "$p")"
  assert_rc "$rc" 0 "T1 não-carimbo '$p' exit 0"
  assert_eq "$lines" 0 "T1 não-carimbo '$p' NÃO appenda"
  assert_eq "$slen" 0 "T4 não-carimbo '$p' stdout vazio"
done

# ── T2: registro válido + append acumula ────────────────────────────────────
OUT2="$TMP/acc.jsonl"
payload "sim" | AMT_OUT="$OUT2" bash "$HOOK"
payload "opção A" | AMT_OUT="$OUT2" bash "$HOOK"
assert_eq "$(wc -l < "$OUT2" | tr -d ' ')" 2 "T2 append acumula (2 runs → 2 linhas)"
TAIL_OK="$(tail -1 "$OUT2" | jq -r 'select(.ts and .session_id=="sess-1" and .cwd=="/tmp/proj" and .prompt) | "ok"' 2>/dev/null)"
assert_eq "$TAIL_OK" "ok" "T2 tail é JSON válido com ts/session_id/cwd/prompt"

# ── T3: best-effort ──────────────────────────────────────────────────────────
OUT3="$TMP/be.jsonl"
printf '' | AMT_OUT="$OUT3" bash "$HOOK"; assert_rc $? 0 "T3 stdin vazio exit 0"
printf 'not-json{{{' | AMT_OUT="$OUT3" bash "$HOOK"; assert_rc $? 0 "T3 JSON inválido exit 0"
payload "sim" 2>/dev/null | AMT_JQ="/nonexistent/jq" AMT_OUT="$OUT3" bash "$HOOK" 2>/dev/null; assert_rc $? 0 "T3 jq ausente exit 0"
[ ! -s "$OUT3" ] && _pass || _fail "T3 nenhum caso best-effort escreve registro"

# ── sumário ──────────────────────────────────────────────────────────────────
echo "── test_autonomy_miss_tracker: $PASS passaram, $FAIL falharam ──"
if [ "$FAIL" -gt 0 ]; then printf '%s\n' "$FAILED"; exit 1; fi
exit 0
