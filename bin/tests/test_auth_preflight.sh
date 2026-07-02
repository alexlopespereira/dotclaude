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
  # --expiry-file sempre passado (hermético: o default real ~/.claude/... pode
  # existir na máquina); EXPIRY_FIXTURE injeta inventário por caso (US-02 R9).
  local cd="$1"; shift
  OUT=$(cd "$WORK" && env PATH="$P" GEMINI_API_KEY="${GEM_KEY-stub-key}" \
        bash "$APF" --cache-dir "$cd" \
        --expiry-file "${EXPIRY_FIXTURE:-$TMP/sem-inventario.jsonl}" "$@" 2>&1); RC=$?
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

# ═══ US-02 (r9-secrets-lifecycle): advisory de expiração no preflight ════════
# Inventário JSONL (seam --expiry-file) → modo texto imprime '⚠ expira:' após
# os probes; --json embute campo 'expiring'. NUNCA vira pendência (exit igual).
# Datas dinâmicas com a MESMA transformação serial do secrets-expiry.sh
# (localtime → timegm meia-noite → ±N*86400 → gmtime). A versão anterior usava
# localtime(time+N*86400), que NÃO é DST-imune — flake 2×/ano (code-review R9).
d_off() { perl -MTime::Local -e 'my @n = localtime;
  my @t = gmtime(timegm(0, 0, 0, $n[3], $n[4], $n[5] + 1900) + $ARGV[0] * 86400);
  printf "%04d-%02d-%02d", $t[5]+1900, $t[4]+1, $t[3]' -- "$1"; }
DUE_KEY="token-vencendo"
INV="$TMP/inventario.jsonl"
cat > "$INV" <<EOF
{"key_name":"$DUE_KEY","provider":"prov","expires_at":"$(d_off 3)"}
{"key_name":"token-longe","provider":"prov","expires_at":"$(d_off 30)"}
{"key_name":"token-never","provider":"prov","expires_at":"never"}
EOF

# AC3 positivo + AC4: entrada due → advisory com key_name e dias; rc segue 0
all_ok
EXPIRY_FIXTURE="$INV" run_apf "$TMP/e1"
assert_rc "$RC" 0 "US-02/AC4 advisory com todos os probes OK mantém rc=0"
assert_contains "$OUT" "⚠ expira: $DUE_KEY" "US-02/AC3 linha advisory com key_name"
printf '%s' "$OUT" | grep -qE "⚠ expira: $DUE_KEY em -?[0-9]+d" && _pass \
  || _fail "US-02/AC3 linha advisory traz os dias restantes (em Nd)"
assert_not_contains "$OUT" "token-longe" "US-02/AC3 fora da janela de 14d não vira advisory"
assert_not_contains "$OUT" "token-never" "US-02/AC3 'never' não vira advisory"
assert_not_contains "$OUT" "pedido consolidado" "US-02/AC4 advisory não gera pedido consolidado"

# AC3 negativo (par capture-proof): sem arquivo de inventário → nenhuma advisory
all_ok
run_apf "$TMP/e2"    # EXPIRY_FIXTURE default aponta pra arquivo inexistente
assert_rc "$RC" 0 "US-02/AC3 sem inventário → rc=0"
assert_not_contains "$OUT" "⚠" "US-02/AC3 sem inventário → nenhuma linha advisory"

# AC4 (complemento): advisory NÃO mascara pendência real nem muda o exit dela
all_ok; write_stub gcloud 1
EXPIRY_FIXTURE="$INV" run_apf "$TMP/e3"
assert_rc "$RC" 1 "US-02/AC4 pendência real continua rc=1 com advisory presente"
assert_contains "$OUT" "⚠ expira: $DUE_KEY" "US-02/AC4 advisory coexiste com pendência"

# AC5: --json com due → JSON único parseável com campo expiring; sem '⚠' cru
all_ok
EXPIRY_FIXTURE="$INV" run_apf "$TMP/e4" --json
assert_rc "$RC" 0 "US-02/AC5 --json com due e probes OK → rc=0"
EXP_KEY=$(printf '%s' "$OUT" | /usr/bin/jq -r '.expiring[0].key_name' 2>/dev/null)
[ "$EXP_KEY" = "$DUE_KEY" ] && _pass || _fail "US-02/AC5 .expiring[0].key_name (got '${EXP_KEY:-parse-error}')"
# campo canônico days_left — o MESMO nome que secrets-expiry.sh `due --json`
# emite (code-review R9: a cópia inline emitia `days`, divergente na origem)
EXP_DTYPE=$(printf '%s' "$OUT" | /usr/bin/jq -r '.expiring[0].days_left | type' 2>/dev/null)
[ "$EXP_DTYPE" = "number" ] && _pass || _fail "US-02/AC5 .expiring[0].days_left é número (got '${EXP_DTYPE:-parse-error}')"
N_EXP=$(printf '%s' "$OUT" | /usr/bin/jq -r '.expiring | length' 2>/dev/null)
[ "${N_EXP:-0}" = "1" ] && _pass || _fail "US-02/AC5 só a entrada due na janela (got '${N_EXP:-parse-error}')"
N_PEND=$(printf '%s' "$OUT" | /usr/bin/jq -r '.pending' 2>/dev/null)
[ "$N_PEND" = "0" ] && _pass || _fail "US-02/AC5 expiring NÃO conta em pending (got '${N_PEND:-parse-error}')"
assert_not_contains "$OUT" "⚠" "US-02/AC5 modo --json sem linha ⚠ crua no stdout"

# --json sem inventário → expiring:[] (JSON segue parseável)
run_apf "$TMP/e5" --json
N_EXP=$(printf '%s' "$OUT" | /usr/bin/jq -r '.expiring | length' 2>/dev/null)
[ "${N_EXP:-x}" = "0" ] && _pass || _fail "US-02/AC5 sem inventário → expiring vazio (got '${N_EXP:-parse-error}')"

# Branch: inventário existe mas nada due (só never) → sem advisory no texto
INV_SEMDUE="$TMP/inventario-sem-due.jsonl"
printf '{"key_name":"token-never","provider":"p","expires_at":"never"}\n' > "$INV_SEMDUE"
EXPIRY_FIXTURE="$INV_SEMDUE" run_apf "$TMP/e6"
assert_rc "$RC" 0 "US-02 inventário sem due → rc=0"
assert_not_contains "$OUT" "⚠" "US-02 inventário sem due → nenhuma advisory (branch vazio)"

# Branch: tombstone (fold last-wins) — key removida não gera advisory
INV_TOMB="$TMP/inventario-tomb.jsonl"
cat > "$INV_TOMB" <<EOF
{"key_name":"$DUE_KEY","provider":"prov","expires_at":"$(d_off 3)"}
{"key_name":"$DUE_KEY","deleted":true}
EOF
EXPIRY_FIXTURE="$INV_TOMB" run_apf "$TMP/e7"
assert_not_contains "$OUT" "⚠" "US-02 tombstone: key removida não vira advisory"

# Branch: entrada JÁ vencida → "vencida há Nd", nunca "expira em -Nd"
# (code-review R9: negativo renderizava mensagem sem sentido)
INV_VENC="$TMP/inventario-vencida.jsonl"
printf '{"key_name":"token-podre","provider":"prov","expires_at":"%s"}\n' "$(d_off -12)" > "$INV_VENC"
all_ok
EXPIRY_FIXTURE="$INV_VENC" run_apf "$TMP/e9"
assert_rc "$RC" 0 "US-02 vencida é advisory, não pendência (rc=0)"
assert_contains "$OUT" "⚠ vencida: token-podre há 12d" "US-02 vencida rende 'há Nd'"
assert_not_contains "$OUT" "em -" "US-02 nunca renderiza dias negativos ('em -Nd')"

# Branch: inventário corrompido → NUNCA silencioso (code-review R9): --json
# mantém parse com expiring:[] + expiring_error; texto avisa em stderr
INV_BAD="$TMP/inventario-bad.jsonl"
printf 'isto não é json\n' > "$INV_BAD"
EXPIRY_FIXTURE="$INV_BAD" run_apf "$TMP/e8" --json
assert_rc "$RC" 0 "US-02 inventário corrompido não muda o exit do preflight"
N_EXP=$(printf '%s' "$OUT" | /usr/bin/jq -r '.expiring | length' 2>/dev/null)
[ "${N_EXP:-x}" = "0" ] && _pass || _fail "US-02 corrompido → expiring vazio, JSON parseável (got '${N_EXP:-parse-error}')"
ERR_T=$(printf '%s' "$OUT" | /usr/bin/jq -r '.expiring_error | type' 2>/dev/null)
[ "$ERR_T" = "string" ] && _pass || _fail "US-02 corrompido --json → campo expiring_error presente (got '${ERR_T:-parse-error}')"
EXPIRY_FIXTURE="$INV_BAD" run_apf "$TMP/e8b"
assert_rc "$RC" 0 "US-02 corrompido modo texto → exit inalterado"
assert_contains "$OUT" "ilegível" "US-02 corrompido modo texto → aviso em stderr (não silencioso)"

# RF (review US-02, 2026-07-02): flag de valor SEM valor → usage rc=2, sem loop
# infinito. Bug: `EXPIRY_FILE="${2:-}"; shift 2` com $#=1 — o shift falha SEM
# consumir $1 e o `while [ $# -gt 0 ]` nunca termina. Alarm 5s prova a
# terminação: se o loop voltar, o SIGALRM mata o processo e rc vira 142 ≠ 2.
for f in --tools --cache-dir --ttl --timeout --expiry-file; do
  OUT=$(env PATH="$P" perl -e 'alarm shift; exec @ARGV' 5 bash "$APF" "$f" 2>&1); RC=$?
  assert_rc "$RC" 2 "US-02/RF $f sem valor → rc=2 (sem loop infinito)"
  assert_contains "$OUT" "Uso:" "US-02/RF $f sem valor imprime usage"
done

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
