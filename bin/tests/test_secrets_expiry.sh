#!/usr/bin/env bash
# bin/tests/test_secrets_expiry.sh — US-01 do ciclo R9 (ciclo de vida de
# secrets): inventário de METADADOS de expiração de credenciais em
# bin/secrets-expiry.sh (append-only + fold last-wins; nunca armazena valores).
#
# Mapa AC → bloco de asserts (contrato de cobertura do plano
# .claude/plans/2026-07-02T12-53-27Z-r9-secrets-lifecycle.md):
#   AC1 parsing/usage sem efeito colateral        → bloco AC1
#   AC2 validação --expires-at/--tier + campos    → bloco AC2
#   AC3 fold last-wins + tombstone + append-only  → bloco AC3
#   AC4 due --days (4 fixtures, exit 1/0)         → bloco AC4
#   AC5 datas via perl (fonte sem flags GNU/BSD)  → bloco AC5
#   AC6 due --json parseável por jq               → bloco AC6
#   AC7 capture-proof: valor-sentinela nunca gravado → bloco AC7
#   AC8 cobertura: tool bash indisponível (progress.txt) → cobertura provada
#       por exaustão de branches nos blocos acima; sem pragma 'no cover'.
#   RF1/RF2 (review 2026-07-02): falha de escrita e inventário corrompido
#       nunca retornam rc=0 → blocos RF1/RF2 (rc=3 dedicado).
#
# Hermético: inventário sempre via --file em mktemp; $HOME nunca é tocado.
# Datas de fixture calculadas com a MESMA aritmética serial do script
# (localtime → timegm à meia-noite) para nunca divergir do due.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SX="$REPO_ROOT/bin/secrets-expiry.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_rc()       { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_contains() { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' not found";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' found but should NOT be";; *) _pass;; esac; }
assert_lines()    { n=$(wc -l < "$1" | tr -d ' '); [ "$n" = "$2" ] && _pass || _fail "$3 :: expected $2 lines got $n"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

run_sx() {  # stdout em $OUT, stderr em $ERR, rc em $RC
  OUT=$(bash "$SX" "$@" 2>"$TMP/stderr.txt"); RC=$?; ERR=$(cat "$TMP/stderr.txt")
}

# d_off <N> — data local de hoje+N dias, pela MESMA transformação serial do
# script (localtime → timegm meia-noite → ±N*86400 → gmtime): imune a DST.
d_off() {
  perl -MTime::Local -e '
    my @n = localtime;
    my @t = gmtime(timegm(0, 0, 0, $n[3], $n[4], $n[5] + 1900) + $ARGV[0] * 86400);
    printf "%04d-%02d-%02d", $t[5] + 1900, $t[4] + 1, $t[3]' -- "$1"
}

[ -f "$SX" ] || { echo "FAIL: $SX inexistente" >&2; echo "test_secrets_expiry: PASS=0 FAIL=1"; exit 1; }

# ─── AC1: parsing/usage → stderr + rc=2, sem efeito colateral ────────────────
I1="$TMP/ac1/expiry.jsonl"

run_sx
assert_rc "$RC" 2 "AC1 sem args → rc=2"
assert_contains "$ERR" "Uso:" "AC1 sem args imprime usage em stderr"

run_sx frobnicate
assert_rc "$RC" 2 "AC1 subcomando desconhecido → rc=2"
assert_contains "$ERR" "Uso:" "AC1 subcomando desconhecido imprime usage"

run_sx --help
assert_rc "$RC" 0 "AC1 --help → rc=0"
assert_contains "$OUT" "Uso:" "AC1 --help imprime usage em stdout"

run_sx list --nope --file "$I1"
assert_rc "$RC" 2 "AC1 flag desconhecida em list → rc=2"

run_sx add --file "$I1" --days 3 --key k
assert_rc "$RC" 2 "AC1 flag de outro subcomando (--days em add) → rc=2"

run_sx add --file "$I1" --provider p
assert_rc "$RC" 2 "AC1 add sem --key → rc=2"
assert_contains "$ERR" "--key" "AC1 add sem --key nomeia a flag"

run_sx remove --file "$I1"
assert_rc "$RC" 2 "AC1 remove sem --key → rc=2"

run_sx add --file "$I1" --key
assert_rc "$RC" 2 "AC1 flag com valor faltando → rc=2"
assert_contains "$ERR" "faltando valor" "AC1 valor faltando nomeado no erro"

[ ! -e "$I1" ] && _pass || _fail "AC1 nenhum erro de parsing criou o arquivo de inventário"

# ─── AC2: validação de --expires-at e --tier; campos do JSONL ────────────────
I2="$TMP/ac2/expiry.jsonl"   # subdir inexistente: prova o mkdir -p do add

run_sx add --file "$I2" --key gh-pat --provider github --expires-at 2026-13-01
assert_rc "$RC" 2 "AC2 mês 13 → rc=2"
run_sx add --file "$I2" --key gh-pat --provider github --expires-at 2026-02-30
assert_rc "$RC" 2 "AC2 30 de fevereiro (regex ok, calendário não) → rc=2"
run_sx add --file "$I2" --key gh-pat --provider github --expires-at amanha
assert_rc "$RC" 2 "AC2 --expires-at não-ISO → rc=2"
run_sx add --file "$I2" --key gh-pat --provider github --tier gold
assert_rc "$RC" 2 "AC2 --tier fora do vocabulário → rc=2"
run_sx add --file "$I2" --key so-key
assert_rc "$RC" 2 "AC2 add sem --provider → rc=2"
assert_contains "$ERR" "--provider" "AC2 add sem --provider nomeia a flag"
[ ! -e "$I2" ] && _pass || _fail "AC2 valores inválidos → sem append (arquivo não criado)"

run_sx add --file "$I2" --key gh-pat --provider github --expires-at 2026-09-01 \
  --renewal-method browser-secrets --tier paid --consumers vm1,laptop
assert_rc "$RC" 0 "AC2 add válido → rc=0"
[ -f "$I2" ] && _pass || _fail "AC2 add válido criou o inventário (mkdir -p)"
assert_lines "$I2" 1 "AC2 add válido appendou exatamente 1 linha"
tail -1 "$I2" | jq -e '.key_name == "gh-pat" and .provider == "github"
  and .expires_at == "2026-09-01" and .renewal_method == "browser-secrets"
  and .tier == "paid" and .consumers == ["vm1","laptop"]' >/dev/null \
  && _pass || _fail "AC2 linha JSONL com os 6 campos de metadados corretos"

run_sx add --file "$I2" --key min-key --provider p2
assert_rc "$RC" 0 "AC2 add só com obrigatórios → rc=0"
tail -1 "$I2" | jq -e '.expires_at == "never" and .tier == "" and .consumers == []' \
  >/dev/null && _pass || _fail "AC2 defaults: expires_at=never, tier vazio, consumers=[]"

run_sx add --file "$I2" --key t-fl --provider p --tier free-low
assert_rc "$RC" 0 "AC2 --tier free-low aceito"
run_sx add --file "$I2" --key t-z3 --provider p --tier zona3 --expires-at never
assert_rc "$RC" 0 "AC2 --tier zona3 + --expires-at never explícito aceitos"

# ─── AC3: fold last-wins, tombstone, append-only ─────────────────────────────
I3="$TMP/ac3.jsonl"

run_sx add --file "$I3" --key keyA --provider p-one
run_sx add --file "$I3" --key keyA --provider p-two --expires-at 2027-01-01
assert_lines "$I3" 2 "AC3 2 adds da mesma key = 2 linhas (append, não rewrite)"

run_sx list --file "$I3"
assert_rc "$RC" 0 "AC3 list → rc=0"
[ "$(printf '%s\n' "$OUT" | grep -c '^keyA	')" = "1" ] && _pass \
  || _fail "AC3 fold last-wins: list mostra exatamente 1 linha para keyA"
assert_contains "$OUT" "p-two" "AC3 list mostra dados do 2º add"
assert_contains "$OUT" "2027-01-01" "AC3 list mostra expires_at do 2º add"
assert_not_contains "$OUT" "p-one" "AC3 list NÃO mostra dados do 1º add"

run_sx add --file "$I3" --key keyB --provider p-b
run_sx remove --file "$I3" --key keyA
assert_rc "$RC" 0 "AC3 remove → rc=0"
assert_lines "$I3" 4 "AC3 remove appenda tombstone (4 linhas, nada apagado)"
head -1 "$I3" | grep -q "p-one" && _pass \
  || _fail "AC3 append-only: 1ª linha (p-one) preservada após upsert+remove"

run_sx list --file "$I3"
assert_not_contains "$OUT" "keyA" "AC3 tombstone omite keyA do list"
assert_contains "$OUT" "keyB" "AC3 keyB sobrevive ao tombstone de keyA"

run_sx list --file "$TMP/ghost.jsonl"
assert_rc "$RC" 0 "AC3 list sem inventário → rc=0"
[ -z "$OUT" ] && _pass || _fail "AC3 list sem inventário → stdout vazio"

# ─── AC4: due --days 14 com 4 fixtures; exit 1 com due, 0 sem ────────────────
I4="$TMP/ac4.jsonl"
VENCIDA=$(d_off -1); VENCENDO=$(d_off 7); FORA=$(d_off 30)

run_sx add --file "$I4" --key vencida-key --provider pv --expires-at "$VENCIDA"
run_sx add --file "$I4" --key vencendo-key --provider pv --expires-at "$VENCENDO"
run_sx add --file "$I4" --key fora-key --provider pv --expires-at "$FORA"
run_sx add --file "$I4" --key never-key --provider pv --expires-at never
# entradas hostis (só via edição manual — add valida): datas inaproveitáveis
# devem ser puladas sem crash, não derrubar o due
printf '%s\n' '{"key_name":"corrompida","provider":"x","expires_at":"2026-02-30"}' >> "$I4"
printf '%s\n' '{"key_name":"sem-data","provider":"x"}' >> "$I4"

run_sx due --file "$I4" --days 14
assert_rc "$RC" 1 "AC4 há due → rc=1"
assert_contains "$OUT" "vencida-key" "AC4 vencida (ontem) listada"
assert_contains "$OUT" "vencendo-key" "AC4 vencendo (hoje+7d) listada"
assert_not_contains "$OUT" "fora-key" "AC4 fora da janela (hoje+30d) omitida"
assert_not_contains "$OUT" "never-key" "AC4 never omitida"
assert_not_contains "$OUT" "corrompida" "AC4 data inválida manual pulada"
assert_not_contains "$OUT" "sem-data" "AC4 entrada sem expires_at = never (omitida)"
assert_contains "$OUT" "-1d" "AC4 dias restantes computados (vencida = -1d)"
assert_contains "$OUT" "7d" "AC4 dias restantes computados (vencendo = 7d)"

run_sx due --file "$I4"
assert_rc "$RC" 1 "AC4 default --days 14 → mesmo resultado (rc=1)"
assert_contains "$OUT" "vencendo-key" "AC4 default inclui hoje+7d"

run_sx due --file "$I4" --days 5
assert_rc "$RC" 1 "AC4 --days 5 → rc=1 (só a vencida)"
assert_contains "$OUT" "vencida-key" "AC4 --days 5 mantém a vencida"
assert_not_contains "$OUT" "vencendo-key" "AC4 --days 5 exclui hoje+7d"

run_sx due --file "$I4" --days abc
assert_rc "$RC" 2 "AC4 --days não-inteiro → rc=2"

I4B="$TMP/ac4b.jsonl"
run_sx add --file "$I4B" --key fora-key --provider pv --expires-at "$FORA"
run_sx add --file "$I4B" --key never-key --provider pv
run_sx due --file "$I4B" --days 14
assert_rc "$RC" 0 "AC4 sem due → rc=0"
[ -z "$OUT" ] && _pass || _fail "AC4 sem due → stdout vazio"

run_sx due --file "$TMP/ghost2.jsonl"
assert_rc "$RC" 0 "AC4 due sem inventário → rc=0"

# ─── AC5: aritmética de datas via perl, sem flags de plataforma do date ──────
grep -Eq 'date[[:space:]]+-d|date[[:space:]]+-j' "$SX" \
  && _fail "AC5 fonte contém chamada de date com flag de plataforma" || _pass
grep -q 'Time::Local' "$SX" && _pass \
  || _fail "AC5 fonte não usa perl Time::Local"

# ─── AC6: due --json parseável por jq; nenhuma linha não-JSON ────────────────
run_sx due --file "$I4" --days 14 --json
assert_rc "$RC" 1 "AC6 --json preserva exit 1 com due"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "1" ] && _pass \
  || _fail "AC6 stdout do --json é 1 linha única (nenhuma linha não-JSON)"
printf '%s' "$OUT" | jq -e 'type == "array" and length == 2' >/dev/null \
  && _pass || _fail "AC6 JSON é array com exatamente as 2 entradas due"
printf '%s' "$OUT" | jq -e '(map(.key_name) | sort) == ["vencendo-key","vencida-key"]' \
  >/dev/null && _pass || _fail "AC6 array contém vencida-key e vencendo-key"
printf '%s' "$OUT" | jq -e 'all(.[]; has("days_left"))' >/dev/null \
  && _pass || _fail "AC6 entradas due carregam days_left"

run_sx due --file "$I4B" --days 14 --json
assert_rc "$RC" 0 "AC6 --json sem due → rc=0"
printf '%s' "$OUT" | jq -e 'type == "array" and length == 0' >/dev/null \
  && _pass || _fail "AC6 sem due → array vazio parseável"

# ─── AC7: capture-proof — valor de secret nunca aceito nem gravado ───────────
SENTINEL="tok-sentinela-nao-persistir-9f8e7d"
LINES_BEFORE=$(wc -l < "$I3" | tr -d ' ')

run_sx add --file "$I3" --key sneaky --provider p --value "$SENTINEL"
assert_rc "$RC" 2 "AC7 add não aceita --value → rc=2"
run_sx add --file "$I3" --key sneaky --provider p --secret "$SENTINEL"
assert_rc "$RC" 2 "AC7 add não aceita --secret → rc=2"
run_sx remove --file "$I3" --key keyB --value "$SENTINEL"
assert_rc "$RC" 2 "AC7 remove não aceita --value → rc=2"

assert_lines "$I3" "$LINES_BEFORE" "AC7 tentativas rejeitadas não appendaram nada"
grep -q "$SENTINEL" "$I3" && _fail "AC7 sentinela vazou para o inventário" || _pass
grep -q "keyB" "$I3" && _pass \
  || _fail "AC7 par positivo: metadados (keyB) seguem presentes no arquivo"
run_sx list --file "$I3"
assert_contains "$OUT" "keyB" "AC7 par positivo: keyB segue listada (remove não executou)"

# ─── RF1 (review 2026-07-02): falha de escrita → rc=3, nunca 0 ───────────────
# Finding: append_line falhava a redirection e add/remove caíam no exit 0.
DIR_AS_FILE="$TMP/dir-as-file"; mkdir -p "$DIR_AS_FILE"

run_sx add --file "$DIR_AS_FILE" --key k --provider p
assert_rc "$RC" 3 "RF1 add com --file apontando pra diretório → rc=3 (não 0)"
assert_contains "$ERR" "falha ao gravar" "RF1 falha de escrita do add reportada em stderr"

run_sx remove --file "$DIR_AS_FILE" --key k
assert_rc "$RC" 3 "RF1 remove com --file apontando pra diretório → rc=3"

touch "$TMP/plain-file"
run_sx add --file "$TMP/plain-file/sub/expiry.jsonl" --key k --provider p
assert_rc "$RC" 3 "RF1 mkdir -p impossível (componente do path é arquivo) → rc=3"
[ ! -e "$TMP/plain-file/sub" ] && _pass \
  || _fail "RF1 mkdir falho não deixou resíduo de diretório"

# ─── RF2 (review 2026-07-02): inventário corrompido → rc=3, nunca [] rc=0 ────
# Finding: fold | perl mascarava falha de parse do jq — due --json emitia []
# exit 0 com entrada due presente antes da linha malformada.
IC="$TMP/corrupt.jsonl"
run_sx add --file "$IC" --key corrupt-due --provider p --expires-at "$VENCIDA"
printf '%s\n' '{linha quebrada' >> "$IC"

run_sx due --file "$IC" --days 14 --json
assert_rc "$RC" 3 "RF2 due --json com JSONL malformado → rc=3 (não 0)"
[ -z "$OUT" ] && _pass \
  || _fail "RF2 due --json corrompido não emite JSON falso no stdout"
assert_contains "$ERR" "corrompido" "RF2 due --json nomeia corrupção em stderr"

run_sx due --file "$IC" --days 14
assert_rc "$RC" 3 "RF2 due texto com JSONL malformado → rc=3"

run_sx list --file "$IC"
assert_rc "$RC" 3 "RF2 list com JSONL malformado → rc=3"
assert_contains "$ERR" "corrompido" "RF2 list nomeia corrupção em stderr"

# ─── AC-merge (code-review R9): add é MERGE-upsert, não clobber ──────────────
# Finding confirmado: renovação via secret-capture chamava add só com
# --key/--provider/--renewal-method e o fold last-wins de registro inteiro
# apagava expires_at/tier/consumers — a key sumia dos avisos (a mesma classe
# do incidente VM1). Campo omitido herda do registro folded; explícito vence.
IM="$TMP/merge/expiry.jsonl"
D20=$(d_off 20)
run_sx add --file "$IM" --key K1 --provider gh --expires-at "$D20" --tier paid --consumers vm1,vm2
assert_rc "$RC" 0 "AC-merge seed: add completo ok"
run_sx add --file "$IM" --key K1 --provider gh --renewal-method secret-capture
assert_rc "$RC" 0 "AC-merge: add parcial ok"
run_sx list --file "$IM"
assert_contains "$OUT" "$D20" "AC-merge: expires_at herdado (não vira never)"
assert_contains "$OUT" "paid" "AC-merge: tier herdado"
assert_contains "$OUT" "vm1,vm2" "AC-merge: consumers herdados"
assert_contains "$OUT" "secret-capture" "AC-merge: renewal_method atualizado"
run_sx add --file "$IM" --key K1 --provider gh --expires-at never
assert_rc "$RC" 0 "AC-merge: override explícito aceito"
run_sx list --file "$IM"
assert_contains "$OUT" "never" "AC-merge: override explícito de expires_at vence"
assert_contains "$OUT" "paid" "AC-merge: tier segue herdado após override de outra flag"
run_sx due --file "$IM" --days 30
assert_rc "$RC" 0 "AC-merge: never não é due"
# key nova (sem registro prévio) segue funcionando com defaults
run_sx add --file "$IM" --key K2 --provider gl
assert_rc "$RC" 0 "AC-merge: key nova sem prévio ok"
run_sx list --file "$IM"
assert_contains "$OUT" "K2" "AC-merge: key nova listada"

# ─── Sumário ─────────────────────────────────────────────────────────────────
echo "test_secrets_expiry: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Falhas:$FAILED" >&2
  exit 1
fi
exit 0
