#!/usr/bin/env bash
# test_notify_gc.sh — auto-GC diário nos caches notify (US-02 quick wins).
#
# Cobre:
#   AC3 — stop-notify: sem marcador, GC apaga arquivo >30d, preserva recentes,
#         cria .last-gc; com marcador fresco, NÃO varre de novo (arquivo velho
#         plantado depois sobrevive e o marcador não é re-tocado).
#   AC4 — context-threshold-notify.py: mesma semântica, via HOME fake.
#   AC6 — .last-gc nunca se auto-apaga: marcador >30d dispara GC, velhos somem,
#         marcador é re-tocado (continua existindo).
#   AC5 — comportamento principal preservado: debounce do stop-notify segue
#         funcionando (2ª chamada <30s sai cedo) e py retorna 0 sem transcript.
#
# Estratégia: HOME fake; osascript stubado via PATH; mtimes via touch -t.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STOP="$REPO_ROOT/hooks/stop-notify.sh"
CTX="$REPO_ROOT/hooks/context-threshold-notify.py"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_rc()      { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_exists()  { [ -e "$1" ] && _pass || _fail "$2 :: $1 deveria existir"; }
assert_missing() { [ ! -e "$1" ] && _pass || _fail "$2 :: $1 NÃO deveria existir"; }
assert_eq()      { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }

TMP="$(mktemp -d -t notify-gc.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# osascript stub (PATH) — stop-notify dispara notificação real sem isso.
BINDIR="$TMP/bin"; mkdir -p "$BINDIR"
printf '#!/bin/bash\nexit 0\n' > "$BINDIR/osascript"; chmod +x "$BINDIR/osascript"
export PATH="$BINDIR:$PATH"

# Dual de data compartilhado (testlib) — evita 3ª cópia divergente do idiom
# (review holístico #7). UTC vs local desloca ≤3h; thresholds são em dias.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/testlib.sh"
old_ts() { _days_ago_iso "$1" %Y%m%d%H%M; } # formato do touch -t (CCYYMMDDhhmm)

mtime_epoch() { # mtime epoch (número) — GNU `stat -f` suja o stdout, por isso -c primeiro
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# ── AC3: stop-notify GC ───────────────────────────────────────────────────────
H="$TMP/home-stop"; CACHE="$H/.claude/cache/stop-notify"; mkdir -p "$CACHE"
touch -t "$(old_ts 40)" "$CACHE/velho-40d"
touch -t "$(old_ts 20)" "$CACHE/medio-20d"
touch "$CACHE/novo-hoje"

printf '{"session_id":"s1"}' | HOME="$H" bash "$STOP"; rc=$?
assert_rc "$rc" "0" "AC3a stop-notify exit 0"
assert_missing "$CACHE/velho-40d"  "AC3b arquivo >30d removido"
assert_exists  "$CACHE/medio-20d"  "AC3c arquivo 20d preservado"
assert_exists  "$CACHE/novo-hoje"  "AC3d arquivo de hoje preservado"
assert_exists  "$CACHE/.last-gc"   "AC3e marcador criado"

# marcador fresco → NÃO varre de novo: planta velho, re-roda, velho sobrevive
MARK_BEFORE=$(mtime_epoch "$CACHE/.last-gc")
touch -t "$(old_ts 40)" "$CACHE/velho-plantado"
printf '{"session_id":"s2"}' | HOME="$H" bash "$STOP"; rc=$?
assert_rc "$rc" "0" "AC3f 2ª chamada exit 0"
assert_exists "$CACHE/velho-plantado" "AC3g marcador fresco: sem re-varredura"
assert_eq "$(mtime_epoch "$CACHE/.last-gc")" "$MARK_BEFORE" "AC3h marcador não re-tocado no mesmo dia"

# AC5: debounce preservado — 2ª chamada com mesmo session_id <30s sai cedo (exit 0)
printf '{"session_id":"s1"}' | HOME="$H" bash "$STOP"; assert_rc "$?" "0" "AC5a debounce segue exit 0"

# ── AC6: marcador velho dispara GC e não se auto-apaga ────────────────────────
H2="$TMP/home-stop2"; CACHE2="$H2/.claude/cache/stop-notify"; mkdir -p "$CACHE2"
touch -t "$(old_ts 40)" "$CACHE2/velho-40d"
touch -t "$(old_ts 40)" "$CACHE2/.last-gc"
printf '{"session_id":"s3"}' | HOME="$H2" bash "$STOP"; rc=$?
assert_rc "$rc" "0" "AC6a exit 0"
assert_missing "$CACHE2/velho-40d" "AC6b marcador velho disparou GC (velho removido)"
assert_exists  "$CACHE2/.last-gc"  "AC6c .last-gc não se auto-apaga"

# ── AC4: context-threshold-notify.py GC ──────────────────────────────────────
H3="$TMP/home-ctx"; FLAGS="$H3/.claude/cache/context-notify"; mkdir -p "$FLAGS"
touch -t "$(old_ts 40)" "$FLAGS/velho-40d.flag"
touch "$FLAGS/novo.flag"
# payload sem transcript_path → retorna cedo, mas o GC roda mesmo assim
printf '{"session_id":"x"}' | HOME="$H3" /usr/bin/python3 "$CTX"; rc=$?
assert_rc "$rc" "0" "AC4a py exit 0 sem transcript"
assert_missing "$FLAGS/velho-40d.flag" "AC4b flag >30d removida"
assert_exists  "$FLAGS/novo.flag"      "AC4c flag recente preservada"
assert_exists  "$FLAGS/.last-gc"       "AC4d marcador criado"

# marcador fresco → sem re-varredura
touch -t "$(old_ts 40)" "$FLAGS/velho-plantado.flag"
printf '{"session_id":"x"}' | HOME="$H3" /usr/bin/python3 "$CTX"; rc=$?
assert_rc "$rc" "0" "AC4e 2ª chamada exit 0"
assert_exists "$FLAGS/velho-plantado.flag" "AC4f marcador fresco: sem re-varredura"

echo "test_notify_gc.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && { echo "FALHAS:$FAILED" >&2; exit 1; }
exit 0
