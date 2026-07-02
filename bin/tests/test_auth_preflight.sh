#!/usr/bin/env bash
# bin/tests/test_auth_preflight.sh — Cobre R5 do programa de autonomia
# (~/analise-interrupcoes/autonomia-recomendacoes.md): preflight consolidado
# de auth no início de tarefa longa.
#
#   Parte A — bin/auth-preflight.sh: probe table-driven (gh, gcloud, sf,
#   codex, gemini) com timeout perl-alarm (idioma do Ralph), cache TTL só de
#   resultado OK, modos auto (--tools ausente → tool não instalada = SKIP) e
#   requerido (--tools LIST → ausente = MISSING, exit 1), saída tab-separated
#   + pedido consolidado único, --json parseável.
#
#   Parte B (regressão de documentação) — skills/auth-preflight/SKILL.md
#   existe e ancora o contrato (script, pedido único consolidado, delegações);
#   browser-actions/SKILL.md ganhou o self-service de códigos de verificação
#   (2FA/email) — ler o código sozinho quando a caixa é alcançável.
#
# Estratégia (padrão test_ralph_preflight_auth.sh): stubs de gh/gcloud/sf/
# codex/curl num dir temporário + PATH restrito ($STUBS:/usr/bin:/bin) —
# hermético mesmo com as CLIs reais instaladas; zero rede (curl é stub).
# perl/awk/date/jq são reais (/usr/bin).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APF="$REPO_ROOT/bin/auth-preflight.sh"
SKILL_APF="$REPO_ROOT/skills/auth-preflight/SKILL.md"
SKILL_BA="$REPO_ROOT/skills/browser-actions/SKILL.md"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_rc()       { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_contains() { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' not found";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' found but should NOT be";; *) _pass;; esac; }
assert_present()  {
  if grep -qF -- "$2" "$1" 2>/dev/null; then _pass
  else _fail "$3 :: '$2' AUSENTE de ${1##*/}"; fi
}

# ─── Setup: stubs + PATH restrito ────────────────────────────────────────────
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
WORK="$TMP/work"; mkdir -p "$WORK"   # cwd sem .env (caso auto-skip do gemini)
P="$STUBS:/usr/bin:/bin"

# write_stub <name> <rc> [sleep_s] — stub que sai com rc; com sleep_s vira
# `exec sleep N` (o exec faz o SIGALRM do perl matar o próprio sleep,
# destravando o $() — idioma de test_ralph_preflight_auth.sh).
write_stub() {
  { echo '#!/bin/bash'
    if [ -n "${3:-}" ]; then echo "exec sleep $3"; else echo "exit $2"; fi
  } > "$STUBS/$1"
  chmod +x "$STUBS/$1"
}
all_ok() { for t in gh gcloud sf codex curl; do write_stub "$t" 0; done; }

run_apf() {  # run_apf <cache-dir> [args...] — stdout+stderr em $OUT, rc em $RC
  local cd="$1"; shift
  OUT=$(cd "$WORK" && env PATH="$P" GEMINI_API_KEY="${GEM_KEY-stub-key}" \
        bash "$APF" --cache-dir "$cd" "$@" 2>&1); RC=$?
}

[ -f "$APF" ] || { echo "FAIL: $APF inexistente" >&2; echo "test_auth_preflight: PASS=0 FAIL=1"; exit 1; }

# ─── AC1: flag desconhecida → usage, rc=2 ────────────────────────────────────
all_ok
run_apf "$TMP/c1" --nope
assert_rc "$RC" 2 "AC1 flag desconhecida → rc=2"
assert_contains "$OUT" "Uso:" "AC1 imprime usage"

# ─── AC2: tudo OK → rc=0, sem pedido consolidado ─────────────────────────────
all_ok
run_apf "$TMP/c2"
assert_rc "$RC" 0 "AC2 tudo OK → rc=0"
assert_contains "$OUT" "gh	OK" "AC2 linha 'gh<TAB>OK'"
assert_contains "$OUT" "gemini	OK" "AC2 gemini probado via curl stub"
assert_not_contains "$OUT" "pedido consolidado" "AC2 sem pendência → sem pedido consolidado"

# ─── AC3: 1 morta → rc=1, hint de renovação + pedido consolidado único ───────
all_ok; write_stub gcloud 1
run_apf "$TMP/c3"
assert_rc "$RC" 1 "AC3 gcloud morto → rc=1"
assert_contains "$OUT" "gcloud	DEAD" "AC3 linha 'gcloud<TAB>DEAD'"
assert_contains "$OUT" "gcloud auth login" "AC3 hint de renovação do gcloud"
assert_contains "$OUT" "pedido consolidado" "AC3 pendências agregadas num pedido consolidado"

# ─── AC4: modo auto — tool não instalada = SKIP, não derruba rc ──────────────
all_ok; rm "$STUBS/sf"
run_apf "$TMP/c4"
assert_rc "$RC" 0 "AC4 sf ausente em modo auto → rc=0"
assert_contains "$OUT" "sf	SKIP" "AC4 linha 'sf<TAB>SKIP'"

# ─── AC5: modo requerido — --tools com tool ausente = MISSING, rc=1 ──────────
run_apf "$TMP/c5" --tools sf
assert_rc "$RC" 1 "AC5 --tools sf com sf ausente → rc=1"
assert_contains "$OUT" "sf	MISSING" "AC5 linha 'sf<TAB>MISSING'"

# ─── AC6: gemini — sem key = SKIP no auto, MISSING no requerido; .env vale ───
all_ok
GEM_KEY="" run_apf "$TMP/c6"
assert_contains "$OUT" "gemini	SKIP" "AC6 sem GEMINI_API_KEY em modo auto → SKIP"
assert_rc "$RC" 0 "AC6 SKIP não derruba rc"
GEM_KEY="" run_apf "$TMP/c6" --tools gemini
assert_rc "$RC" 1 "AC6 --tools gemini sem key → rc=1"
assert_contains "$OUT" "gemini	MISSING" "AC6 linha 'gemini<TAB>MISSING'"
assert_contains "$OUT" "GEMINI_API_KEY" "AC6 MISSING nomeia a env var"
echo 'GEMINI_API_KEY=from-dotenv' > "$WORK/.env"
GEM_KEY="" run_apf "$TMP/c6b" --tools gemini
assert_rc "$RC" 0 "AC6 key vinda do ./.env → probe roda e passa"
rm "$WORK/.env"

# ─── AC7: cache — OK é cacheado (TTL), DEAD nunca; --refresh fura o cache ────
all_ok
run_apf "$TMP/c7"                       # popula cache com tudo OK
write_stub gh 1                          # gh morre depois do cache
run_apf "$TMP/c7"
assert_rc "$RC" 0 "AC7 cache fresco → não re-proba, rc=0"
assert_contains "$OUT" "cache" "AC7 resultado cacheado é marcado como cache"
run_apf "$TMP/c7" --refresh
assert_rc "$RC" 1 "AC7 --refresh fura o cache → gh DEAD, rc=1"
assert_contains "$OUT" "gh	DEAD" "AC7 gh DEAD após refresh"
write_stub gh 0                          # gh renovado
run_apf "$TMP/c7"
assert_contains "$OUT" "gh	OK" "AC7 DEAD não foi cacheado → re-probe vê renovação"
assert_rc "$RC" 0 "AC7 pós-renovação → rc=0"

# ─── AC8: timeout perl-alarm — probe pendurado vira DEAD ─────────────────────
all_ok; write_stub gh 0 3
run_apf "$TMP/c8" --timeout 1 --tools gh
assert_rc "$RC" 1 "AC8 probe > timeout → rc=1"
assert_contains "$OUT" "gh	DEAD" "AC8 timeout classifica como DEAD"
assert_contains "$OUT" "timeout" "AC8 motivo 'timeout' na linha"

# ─── AC9: --json parseável ───────────────────────────────────────────────────
all_ok
run_apf "$TMP/c9" --json
assert_rc "$RC" 0 "AC9 --json com tudo OK → rc=0"
N_OK=$(printf '%s' "$OUT" | /usr/bin/jq -r '[.tools[] | select(.status=="OK")] | length' 2>/dev/null)
[ "${N_OK:-0}" -ge 4 ] && _pass || _fail "AC9 JSON parseável com ≥4 tools OK (got '${N_OK:-parse-error}')"

# ─── Parte B: âncoras de documentação (skill + 2FA self-service) ─────────────
[ -f "$SKILL_APF" ] && _pass || _fail "B1 skills/auth-preflight/SKILL.md existe"
assert_present "$SKILL_APF" "bin/auth-preflight.sh" "B1 skill referencia o script"
assert_present "$SKILL_APF" "um único pedido consolidado" "B1 skill ancora o pedido único consolidado"
assert_present "$SKILL_APF" "browser-secrets" "B1 skill delega renovação a browser-secrets"
assert_present "$SKILL_APF" "quota" "B1 skill cobre aviso proativo de quota"
assert_present "$SKILL_BA" "ler o código sozinho" "B2 browser-actions: self-service de código de verificação"
assert_present "$SKILL_BA" "Códigos de verificação" "B2 browser-actions: seção de códigos de verificação"

# ─── Sumário ─────────────────────────────────────────────────────────────────
echo "test_auth_preflight: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Falhas:$FAILED" >&2
  exit 1
fi
exit 0
