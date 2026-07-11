#!/usr/bin/env bash
# test_context_threshold_escalation.sh — hook context-threshold-notify v2 (US-01).
#
# Cobre AC1-AC13 do PRD context-budget-gate:
#   AC1  Stop escalonado por nível (250K nada / 300K notifica+flag 285000 /
#        320K mesmo nível não re-notifica / 340K sobe nível → flag 335000).
#   AC2  flag legada (total cru '300000') lida como nível 0 — 320K não re-notifica.
#   AC3  [R5] payload SEM hook_event_name (ou casing divergente) → ramo Stop legado
#        (default defensivo, notificação dispara); par capture-proof com UPS que NÃO notifica.
#   AC4  [R2] guarda de /compact — usage pré-compact ignorada; simétrico sem compact injeta.
#   AC5  [R6] seek-from-end retorna a ÚLTIMA usage correta num transcript grande (multi-chunk).
#   AC6  UPS 320K → JSON advisory (handoff-continue, imperativo, sem header "não são
#        instruções do usuário"); 360K → crítico ("AGORA"); 250K → stdout vazio.
#   AC7  [R4] carimbo <session>.emitted escrito em UPS>=threshold, ausente em UPS<threshold.
#   AC8  best-effort exit 0 sem output: payload malformado / transcript ausente / osascript ausente.
#   AC9  [R1] register_context_threshold_hook via `sync.sh install`: Stop E UPS, timeout 5000,
#        command via $CLAUDE_DIR (sem /Users hardcoded); 2ª chamada idempotente — provado por jq.
#   AC10 [R3] cabeçalho documenta "interativo-only / sem humano para /clear" + caso headless não quebra.
#   AC11 [S1] thresholds são constantes nomeadas no topo; sem literal mágico repetido no corpo.
#   AC13 branches introduzidos exercitados (level_of, guarda compact, seek-from-end,
#        branch por evento c/ default, ramos Stop/UPS, carimbo).
#   (AC12 = regressão da suíte inteira, coberto por run-all.sh; test_notify_gc.sh intocado.)
#
# Estratégia: HOME fake p/ FLAG_DIR; osascript stubado via PATH com captura;
# transcripts JSONL de fixture; sync.sh install em sandbox (SYNC_CLAUDE_HOME).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CTX="$REPO_ROOT/hooks/context-threshold-notify.py"
SYNC_SRC="$REPO_ROOT/sync.sh"
PY=/usr/bin/python3

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_rc()      { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_eq()      { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_exists()  { [ -e "$1" ] && _pass || _fail "$2 :: $1 deveria existir"; }
assert_missing() { [ ! -e "$1" ] && _pass || _fail "$2 :: $1 NÃO deveria existir"; }
assert_contains(){ case "$2" in *"$1"*) _pass ;; *) _fail "$3 :: '$2' não contém '$1'" ;; esac; }
assert_absent()  { case "$2" in *"$1"*) _fail "$3 :: '$2' NÃO deveria conter '$1'" ;; *) _pass ;; esac; }

TMP="$(mktemp -d -t ctx-thr.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# osascript stub que registra cada chamada em $OSA_CAPTURE (contagem = # notificações).
BINDIR="$TMP/bin"; mkdir -p "$BINDIR"
cat > "$BINDIR/osascript" <<'STUB'
#!/bin/bash
echo "call" >> "$OSA_CAPTURE"
exit 0
STUB
chmod +x "$BINDIR/osascript"
export PATH="$BINDIR:$PATH"
export OSA_CAPTURE="$TMP/osa.log"
: > "$OSA_CAPTURE"
osa_count() { [ -f "$OSA_CAPTURE" ] && wc -l < "$OSA_CAPTURE" | tr -d ' ' || echo 0; }

FLAGSUB() { echo "$1/.claude/cache/context-notify"; }

# transcript de 1 usage assistant com N tokens de input.
mk_usage() { # $1=file $2=tokens
  printf '{"type":"assistant","message":{"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n' "$2" > "$1"
}

# Roda o hook. $1=home $2=payload_json
run_ctx() { HOME="$1" $PY "$CTX"; }

FLAGDIR_OF() { echo "$1/.claude/cache/context-notify"; }

# ══════════════════════════════════════════════════════════════════════════════
# AC1 — Stop escalonado por nível
# ══════════════════════════════════════════════════════════════════════════════
H1="$TMP/h1"; mkdir -p "$H1"; FD1="$(FLAGDIR_OF "$H1")"
TR="$TMP/tr.jsonl"

# 250K sem flag → sem notificação, exit 0, flag não escrita
mk_usage "$TR" 250000
before=$(osa_count)
echo "{\"session_id\":\"s\",\"transcript_path\":\"$TR\"}" | run_ctx "$H1"; rc=$?
assert_rc "$rc" "0" "AC1a 250K exit 0"
assert_eq "$(osa_count)" "$before" "AC1b 250K não notifica"
assert_missing "$FD1/s.flag" "AC1c 250K não grava flag"

# 300K sem flag → notifica, flag = forma-valor 285000
mk_usage "$TR" 300000
before=$(osa_count)
echo "{\"session_id\":\"s\",\"transcript_path\":\"$TR\"}" | run_ctx "$H1"; rc=$?
assert_rc "$rc" "0" "AC1d 300K exit 0"
assert_eq "$(osa_count)" "$((before+1))" "AC1e 300K notifica"
assert_exists "$FD1/s.flag" "AC1f 300K grava flag"
assert_eq "$(cat "$FD1/s.flag")" "285000" "AC1g flag = forma-valor nível 0 (285000)"

# 320K com flag nível 0 → NÃO re-notifica, flag inalterada
mk_usage "$TR" 320000
before=$(osa_count)
echo "{\"session_id\":\"s\",\"transcript_path\":\"$TR\"}" | run_ctx "$H1"; rc=$?
assert_rc "$rc" "0" "AC1h 320K exit 0"
assert_eq "$(osa_count)" "$before" "AC1i 320K mesmo nível não re-notifica"
assert_eq "$(cat "$FD1/s.flag")" "285000" "AC1j flag inalterada"

# 340K com flag nível 0 → re-notifica, flag sobe p/ nível 1 (335000)
mk_usage "$TR" 340000
before=$(osa_count)
echo "{\"session_id\":\"s\",\"transcript_path\":\"$TR\"}" | run_ctx "$H1"; rc=$?
assert_rc "$rc" "0" "AC1k 340K exit 0"
assert_eq "$(osa_count)" "$((before+1))" "AC1l 340K sobe nível → re-notifica"
assert_eq "$(cat "$FD1/s.flag")" "335000" "AC1m flag = forma-valor nível 1 (335000)"

# ══════════════════════════════════════════════════════════════════════════════
# AC2 — flag legada (valor total cru) lida como nível 0, sem migração
# ══════════════════════════════════════════════════════════════════════════════
H2="$TMP/h2"; FD2="$(FLAGDIR_OF "$H2")"; mkdir -p "$FD2"
printf '300000' > "$FD2/s.flag"   # formato legado v1: total cru
mk_usage "$TR" 320000
before=$(osa_count)
echo "{\"session_id\":\"s\",\"transcript_path\":\"$TR\"}" | run_ctx "$H2"; rc=$?
assert_rc "$rc" "0" "AC2a flag legada não crasha (exit 0)"
assert_eq "$(osa_count)" "$before" "AC2b legado nível 0 → 320K não re-notifica"

# ══════════════════════════════════════════════════════════════════════════════
# AC3 — [R5] default defensivo por evento (par capture-proof)
# ══════════════════════════════════════════════════════════════════════════════
H3="$TMP/h3"; mkdir -p "$H3"
mk_usage "$TR" 300000
# (a) SEM hook_event_name → ramo Stop → notifica
before=$(osa_count)
echo "{\"session_id\":\"a\",\"transcript_path\":\"$TR\"}" | run_ctx "$H3"
assert_eq "$(osa_count)" "$((before+1))" "AC3a evento ausente → Stop notifica"
# (b) casing divergente "userpromptsubmit" → NÃO casa UPS → default Stop → notifica
before=$(osa_count)
echo "{\"session_id\":\"b\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"userpromptsubmit\"}" | run_ctx "$H3"
assert_eq "$(osa_count)" "$((before+1))" "AC3b casing divergente → default Stop notifica"
# (c) capture-proof: UPS canônico NÃO chama osascript (prova que o roteamento distingue)
before=$(osa_count)
echo "{\"session_id\":\"c\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"UserPromptSubmit\"}" | run_ctx "$H3" >/dev/null
assert_eq "$(osa_count)" "$before" "AC3c UPS canônico não notifica (par capture-proof)"

# ══════════════════════════════════════════════════════════════════════════════
# AC4 — [R2] guarda de /compact
# ══════════════════════════════════════════════════════════════════════════════
H4="$TMP/h4"; mkdir -p "$H4"
# compact: usage 360K → isCompactSummary → usage 30K ; total = 30K < threshold → Stop não notifica
TRC="$TMP/trc.jsonl"
{
  printf '{"type":"assistant","message":{"usage":{"input_tokens":360000}}}\n'
  printf '{"isCompactSummary":true,"type":"system"}\n'
  printf '{"type":"assistant","message":{"usage":{"input_tokens":30000}}}\n'
} > "$TRC"
before=$(osa_count)
echo "{\"session_id\":\"c1\",\"transcript_path\":\"$TRC\"}" | run_ctx "$H4"
assert_eq "$(osa_count)" "$before" "AC4a pós-compact 30K < threshold → não notifica"
# boundary sem usage posterior: usage 360K → compact_boundary (variante type) → total 0
TRB="$TMP/trb.jsonl"
{
  printf '{"type":"assistant","message":{"usage":{"input_tokens":360000}}}\n'
  printf '{"type":"compact_boundary"}\n'
} > "$TRB"
before=$(osa_count)
echo "{\"session_id\":\"c2\",\"transcript_path\":\"$TRB\"}" | run_ctx "$H4"
assert_eq "$(osa_count)" "$before" "AC4b boundary antes de qualquer usage → total 0 → não notifica"
# simétrico SEM compact a 360K → notifica (injeta no Stop)
mk_usage "$TR" 360000
before=$(osa_count)
echo "{\"session_id\":\"c3\",\"transcript_path\":\"$TR\"}" | run_ctx "$H4"
assert_eq "$(osa_count)" "$((before+1))" "AC4c 360K sem compact → notifica"

# ══════════════════════════════════════════════════════════════════════════════
# AC5 — [R6] seek-from-end retorna a última usage num transcript grande (multi-chunk)
# ══════════════════════════════════════════════════════════════════════════════
H5="$TMP/h5"; mkdir -p "$H5"
BIG="$TMP/big.jsonl"
{
  printf '{"type":"assistant","message":{"usage":{"input_tokens":999999}}}\n'   # decoy: usage ANTERIOR
  printf '{"type":"assistant","message":{"usage":{"input_tokens":300000}}}\n'   # a ÚLTIMA usage relevante
  # milhares de linhas não-usage DEPOIS (>64KB → força multi-chunk no leitor reverso)
  for i in $(seq 1 2500); do
    printf '{"type":"user","message":{"role":"user","content":"linha de preenchimento numero %s aqui"}}\n' "$i"
  done
} > "$BIG"
# 300K ∈ [285K,356K) → UPS advisory (prova o VALOR: se pegasse a decoy 999999 seria crítico)
out=$(echo "{\"session_id\":\"big\",\"transcript_path\":\"$BIG\",\"hook_event_name\":\"UserPromptSubmit\"}" | run_ctx "$H5")
ctxval=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "advisory" "$ctxval" "AC5a seek-from-end pegou a última usage (300K → advisory, não a decoy 999999)"
assert_contains "handoff-continue" "$ctxval" "AC5b injeção advisory instrui /handoff-continue"

# ══════════════════════════════════════════════════════════════════════════════
# AC6 — UserPromptSubmit dois tiers
# ══════════════════════════════════════════════════════════════════════════════
H6="$TMP/h6"; mkdir -p "$H6"
# 320K → advisory
mk_usage "$TR" 320000
out=$(echo "{\"session_id\":\"u\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"UserPromptSubmit\"}" | run_ctx "$H6"); rc=$?
assert_rc "$rc" "0" "AC6a UPS 320K exit 0"
echo "$out" | jq -e . >/dev/null 2>&1 && _pass || _fail "AC6b UPS 320K stdout é JSON único parseável por jq"
assert_eq "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "UserPromptSubmit" "AC6c hookEventName correto"
ctx6=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "handoff-continue" "$ctx6" "AC6d advisory contém handoff-continue"
assert_contains "advisory" "$ctx6" "AC6e tier advisory"
assert_absent "não são instruções do usuário" "$ctx6" "AC6f sem header de referência (imperativo)"
# 360K → crítico ("AGORA")
mk_usage "$TR" 360000
out=$(echo "{\"session_id\":\"u\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"UserPromptSubmit\"}" | run_ctx "$H6")
ctx6c=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
assert_contains "AGORA" "$ctx6c" "AC6g crítico contém AGORA"
assert_contains "handoff-continue" "$ctx6c" "AC6h crítico também instrui /handoff-continue"
# 250K → stdout vazio, exit 0
mk_usage "$TR" 250000
out=$(echo "{\"session_id\":\"u\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"UserPromptSubmit\"}" | run_ctx "$H6"); rc=$?
assert_rc "$rc" "0" "AC6i UPS 250K exit 0"
assert_eq "$out" "" "AC6j UPS 250K stdout vazio"

# ══════════════════════════════════════════════════════════════════════════════
# AC7 — [R4] carimbo de compliance <session>.emitted
# ══════════════════════════════════════════════════════════════════════════════
H7="$TMP/h7"; mkdir -p "$H7"; FD7="$(FLAGDIR_OF "$H7")"
# >= threshold → carimbo escrito
mk_usage "$TR" 320000
echo "{\"session_id\":\"emit\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"UserPromptSubmit\"}" | run_ctx "$H7" >/dev/null
assert_exists "$FD7/emit.emitted" "AC7a UPS>=threshold grava carimbo .emitted"
# < threshold → carimbo NÃO escrito (par positivo/negativo)
mk_usage "$TR" 250000
echo "{\"session_id\":\"noemit\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"UserPromptSubmit\"}" | run_ctx "$H7" >/dev/null
assert_missing "$FD7/noemit.emitted" "AC7b UPS<threshold NÃO grava carimbo"

# ══════════════════════════════════════════════════════════════════════════════
# AC8 — best-effort: exit 0 sem output
# ══════════════════════════════════════════════════════════════════════════════
H8="$TMP/h8"; mkdir -p "$H8"
# payload malformado
out=$(printf 'not-json{{{' | run_ctx "$H8"); rc=$?
assert_rc "$rc" "0" "AC8a payload malformado exit 0"; assert_eq "$out" "" "AC8b malformado sem output"
# transcript ausente
out=$(echo "{\"session_id\":\"x\",\"transcript_path\":\"$TMP/nao-existe.jsonl\"}" | run_ctx "$H8"); rc=$?
assert_rc "$rc" "0" "AC8c transcript inexistente exit 0"; assert_eq "$out" "" "AC8d sem output"
# osascript REALMENTE ausente do PATH: dir vazio como único PATH → subprocess.run
# levanta FileNotFoundError → guarda `except Exception` (não-bloqueante) → exit 0.
# PATH="/usr/bin:/bin" NÃO servia: /usr/bin/osascript existe no macOS, o guard nunca
# era exercitado e uma regressão removendo-o passava invisível (mutation-blind).
EMPTY_PATH="$TMP/empty-path"; mkdir -p "$EMPTY_PATH"; FD8="$(FLAGDIR_OF "$H8")"
mk_usage "$TR" 320000
out=$(PATH="$EMPTY_PATH" HOME="$H8" $PY "$CTX" <<< "{\"session_id\":\"noosa\",\"transcript_path\":\"$TR\"}"); rc=$?
assert_rc "$rc" "0" "AC8e osascript ausente (dir vazio) exit 0 — guarda except exercitada"
assert_eq "$out" "" "AC8f sem output"
# Prova que o caminho quente foi alcançado: nível 0 passou, flag gravada, e só então
# osascript falhou → o guard está no fluxo, não curto-circuitado antes da notificação.
assert_exists "$FD8/noosa.flag" "AC8g alcançou a notificação (flag gravada) antes de osascript falhar"

# ══════════════════════════════════════════════════════════════════════════════
# AC9 — [R1] register_context_threshold_hook via sync.sh install (jq)
# ══════════════════════════════════════════════════════════════════════════════
REG_REPO="$TMP/reg/repo"; REG_HOME="$TMP/reg/home"
mkdir -p "$REG_REPO/hooks" "$REG_HOME"
cp "$SYNC_SRC" "$REG_REPO/sync.sh"; chmod +x "$REG_REPO/sync.sh"
cp "$CTX" "$REG_REPO/hooks/context-threshold-notify.py"
printf 'x\n' > "$REG_REPO/WORKFLOW.md"
git -C "$REG_REPO" init -q
git -C "$REG_REPO" symbolic-ref HEAD refs/heads/main
git -C "$REG_REPO" config user.email t@example.com
git -C "$REG_REPO" config user.name test
git -C "$REG_REPO" config commit.gpgsign false
git -C "$REG_REPO" add -A && git -C "$REG_REPO" commit -q -m init

SYNC_CLAUDE_HOME="$REG_HOME" SYNC_LOCAL_BIN="$TMP/reg/bin" bash "$REG_REPO/sync.sh" install >/dev/null 2>&1
SET="$REG_HOME/settings.json"
assert_exists "$SET" "AC9a install criou settings.json"

# jq: conta entries context-threshold sob Stop e UPS, valida timeout + command $CLAUDE_DIR
cnt_stop=$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | endswith("hooks/context-threshold-notify.py"))] | length' "$SET")
cnt_ups=$(jq '[.hooks.UserPromptSubmit[]?.hooks[]? | select(.command | endswith("hooks/context-threshold-notify.py"))] | length' "$SET")
assert_eq "$cnt_stop" "1" "AC9b registrado 1× em Stop"
assert_eq "$cnt_ups" "1" "AC9c registrado 1× em UserPromptSubmit"
# timeout 5000 nos dois eventos
to_ok=$(jq '[.hooks.Stop[]?.hooks[]?, .hooks.UserPromptSubmit[]?.hooks[]? | select(.command | endswith("hooks/context-threshold-notify.py")) | select(.timeout==5000)] | length' "$SET")
assert_eq "$to_ok" "2" "AC9d timeout 5000 em ambos os eventos"
# command usa $CLAUDE_DIR (sandbox) e não /Users hardcoded
hard=$(jq -r '[.hooks.Stop[]?.hooks[]?, .hooks.UserPromptSubmit[]?.hooks[]? | select(.command | endswith("hooks/context-threshold-notify.py")) | .command | select(contains("/Users/dev"))] | length' "$SET")
assert_eq "$hard" "0" "AC9e command sem /Users/dev hardcoded"
startsok=$(jq -r --arg h "$REG_HOME" '[.hooks.Stop[]?.hooks[]?, .hooks.UserPromptSubmit[]?.hooks[]? | select(.command | endswith("hooks/context-threshold-notify.py")) | .command | select(startswith($h))] | length' "$SET")
assert_eq "$startsok" "2" "AC9f command via \$CLAUDE_DIR do sandbox"

# idempotência: 2ª chamada não duplica
SYNC_CLAUDE_HOME="$REG_HOME" SYNC_LOCAL_BIN="$TMP/reg/bin" bash "$REG_REPO/sync.sh" install >/dev/null 2>&1
cnt_stop2=$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | endswith("hooks/context-threshold-notify.py"))] | length' "$SET")
cnt_ups2=$(jq '[.hooks.UserPromptSubmit[]?.hooks[]? | select(.command | endswith("hooks/context-threshold-notify.py"))] | length' "$SET")
assert_eq "$cnt_stop2" "1" "AC9g idempotente em Stop (2º install não duplica)"
assert_eq "$cnt_ups2" "1" "AC9h idempotente em UserPromptSubmit"

# ══════════════════════════════════════════════════════════════════════════════
# AC10 — [R3] limitação interativo-only documentada no fonte + caso headless não quebra
# ══════════════════════════════════════════════════════════════════════════════
grep -q "interativo-only" "$CTX" && _pass || _fail "AC10a cabeçalho documenta 'interativo-only'"
grep -q "sem humano para /clear" "$CTX" && _pass || _fail "AC10b cabeçalho documenta 'sem humano para /clear'"
# caso headless: UPS alto ainda emite JSON e exit 0 (injeção inócua mas não quebra)
H10="$TMP/h10"; mkdir -p "$H10"; mk_usage "$TR" 360000
out=$(echo "{\"session_id\":\"hl\",\"transcript_path\":\"$TR\",\"hook_event_name\":\"UserPromptSubmit\"}" | run_ctx "$H10"); rc=$?
assert_rc "$rc" "0" "AC10c caso headless não quebra (exit 0)"
echo "$out" | jq -e . >/dev/null 2>&1 && _pass || _fail "AC10d headless ainda emite JSON válido"

# ══════════════════════════════════════════════════════════════════════════════
# AC11 — [S1] thresholds como constantes nomeadas no topo; sem literal mágico repetido
# ══════════════════════════════════════════════════════════════════════════════
grep -q '^THRESHOLD_ADVISORY = 285_000' "$CTX" && _pass || _fail "AC11a THRESHOLD_ADVISORY definido no topo"
grep -q '^THRESHOLD_CRITICAL = 356_000' "$CTX" && _pass || _fail "AC11b THRESHOLD_CRITICAL definido no topo"
grep -q '^LEVEL_STEP = 50_000' "$CTX" && _pass || _fail "AC11c LEVEL_STEP definido no topo"
# nenhum literal mágico dos thresholds aparece "solto" (sem underscore) no corpo
assert_eq "$(grep -c '285000' "$CTX")" "0" "AC11d sem literal 285000 solto no corpo"
assert_eq "$(grep -c '356000' "$CTX")" "0" "AC11e sem literal 356000 solto no corpo"
assert_eq "$(grep -c '50000' "$CTX")" "0" "AC11f sem literal 50000 solto no corpo"

echo "test_context_threshold_escalation.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && { echo "FALHAS:$FAILED" >&2; exit 1; }
exit 0
