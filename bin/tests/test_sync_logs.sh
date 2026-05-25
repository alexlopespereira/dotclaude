#!/usr/bin/env bash
set -u

# test_sync_logs.sh — testes para o split source/log do sync.sh + backup
# automatizado de telemetria (US-07 / M8 parte 1).
#
# Cobre os 4 acceptance criteria da story "sync.sh split source/log + backup automatizado":
#   AC1 — `sync.sh install` NÃO toca telemetry/ (telemetry/ fora dos DIRS de
#         install). Estrutural (telemetry ausente de DIRS) + comportamental
#         (install não cria/modifica ~/.claude/telemetry/).
#   AC2 — novo `sync.sh sync-logs` copia ~/.claude/telemetry/<prefix>-usage.<mid>.jsonl
#         (APENAS o arquivo desta máquina; ambos os prefixes dod e test-spec) →
#         repo/telemetry/. NÃO copia logs de outras máquinas nem arquivos não-telemetria.
#   AC3 — gatilho automático: hooks/sync-telemetry-log.sh (Stop hook) roda
#         sync-logs e stageia telemetry/ no repo dotclaude. Best-effort: exit 0
#         mesmo sem repo. Telemetria chega ao git sem ação manual.
#   AC4 — regressão do bug original: estado dirty em telemetry/ NÃO bloqueia
#         install (telemetry/ fora de escopo → install nunca aborta por ele).
#
# Estratégia: sandbox em tmpdir. SYNC_CLAUDE_HOME aponta o ~/.claude do sync.sh
# para o sandbox; o repo é uma cópia temp do sync.sh (REPO_DIR = dirname do script).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SYNC="$REPO_ROOT/sync.sh"
HOOK="$REPO_ROOT/hooks/sync-telemetry-log.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }

assert_eq()     { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_rc()     { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_file()   { [ -f "$1" ] && _pass || _fail "$2 :: arquivo ausente: $1"; }
assert_nofile() { [ ! -f "$1" ] && _pass || _fail "$2 :: arquivo NÃO deveria existir: $1"; }

[[ -f "$SYNC" ]] || { echo "FAIL: $SYNC inexistente" >&2; exit 1; }

TMP="$(mktemp -d -t sync-logs.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

MID="11111111-2222-3333-4444-555555555555"
OTHER="99999999-8888-7777-6666-000000000000"

# ── Monta um "repo" temp: cópia do sync.sh (REPO_DIR=dirname do script) ──────
mkrepo() {
  local repo="$1"
  mkdir -p "$repo"
  cp "$SYNC" "$repo/sync.sh"
  chmod +x "$repo/sync.sh"
}

# ── Monta um sandbox ~/.claude com telemetria desta máquina + de outra ──────
mkclaude() {
  local home="$1"
  mkdir -p "$home/telemetry"
  printf '%s\n' "$MID" > "$home/.machine-id"
  printf '{"v":1,"dod_id":"a","kind":"use"}\n' > "$home/telemetry/dod-usage.$MID.jsonl"
  printf '{"v":1,"dod_id":"b","kind":"use"}\n' > "$home/telemetry/test-spec-usage.$MID.jsonl"
  # log de OUTRA máquina — sync-logs NÃO deve copiar
  printf '{"v":1,"dod_id":"c","kind":"use"}\n' > "$home/telemetry/dod-usage.$OTHER.jsonl"
  # arquivo não-telemetria (failed events do Claude Code) — NÃO deve copiar
  printf '{"unrelated":true}\n' > "$home/telemetry/1p_failed_events.$MID.json"
}

# ═══ AC1 (estrutural) — telemetry NÃO está em DIRS ═══════════════════════════
if grep -nE '^\s*DIRS=\(' "$SYNC" >/dev/null; then
  DIRS_BLOCK="$(awk '/^[[:space:]]*DIRS=\(/{f=1} f{print} /\)/{if(f)exit}' "$SYNC")"
  if printf '%s' "$DIRS_BLOCK" | grep -qE '"telemetry"'; then
    _fail "AC1 estrutural: telemetry NÃO deveria estar em DIRS (vira source-impuro)"
  else _pass; fi
else _fail "AC1 estrutural: bloco DIRS=( não encontrado em sync.sh"; fi

# ═══ AC2 — sync-logs copia só o log desta máquina (dod + test-spec) ══════════
REPO2="$TMP/ac2/repo"; HOME2="$TMP/ac2/home"
mkrepo "$REPO2"; mkclaude "$HOME2"
SYNC_CLAUDE_HOME="$HOME2" bash "$REPO2/sync.sh" sync-logs >/dev/null 2>&1
assert_rc "$?" 0 "AC2 sync-logs exit 0"
assert_file   "$REPO2/telemetry/dod-usage.$MID.jsonl"       "AC2 copiou dod-usage desta máquina"
assert_file   "$REPO2/telemetry/test-spec-usage.$MID.jsonl" "AC2 copiou test-spec-usage desta máquina"
assert_nofile "$REPO2/telemetry/dod-usage.$OTHER.jsonl"     "AC2 NÃO copiou log de outra máquina"
assert_nofile "$REPO2/telemetry/1p_failed_events.$MID.json" "AC2 NÃO copiou arquivo não-telemetria"
# conteúdo preservado byte-a-byte
if cmp -s "$HOME2/telemetry/dod-usage.$MID.jsonl" "$REPO2/telemetry/dod-usage.$MID.jsonl"; then _pass
else _fail "AC2 conteúdo do log copiado difere do original"; fi

# ═══ AC3 — hook Stop sync-telemetry-log.sh: copia + stageia, best-effort ═════
assert_file "$HOOK" "AC3 hook sync-telemetry-log.sh existe"
[ -x "$HOOK" ] && _pass || _fail "AC3 hook não é executável"

if [ -f "$HOOK" ]; then
  REPO3="$TMP/ac3/repo"; HOME3="$TMP/ac3/home"
  mkrepo "$REPO3"; mkclaude "$HOME3"
  git -C "$REPO3" init -q
  # alimenta o hook com payload JSON no stdin (formato Stop) e seams
  echo '{"session_id":"test","hook_event_name":"Stop"}' | \
    DOTCLAUDE_REPO="$REPO3" SYNC_CLAUDE_HOME="$HOME3" bash "$HOOK" >/dev/null 2>&1
  assert_rc "$?" 0 "AC3 hook exit 0 (best-effort)"
  assert_file "$REPO3/telemetry/dod-usage.$MID.jsonl" "AC3 hook disparou a cópia do log → repo"
  # staged: aparece no index do repo
  STAGED="$(git -C "$REPO3" diff --cached --name-only 2>/dev/null)"
  if printf '%s\n' "$STAGED" | grep -qx "telemetry/dod-usage.$MID.jsonl"; then _pass
  else _fail "AC3 log não foi staged (git add) :: index='$STAGED'"; fi

  # best-effort: repo inexistente → exit 0, não quebra a sessão
  echo '{}' | DOTCLAUDE_REPO="$TMP/ac3/does-not-exist" SYNC_CLAUDE_HOME="$HOME3" bash "$HOOK" >/dev/null 2>&1
  assert_rc "$?" 0 "AC3 hook exit 0 mesmo sem repo (não bloqueia sessão)"
fi

# ═══ AC3 (registro) — install registra o Stop hook em settings.json ══════════
# O gatilho só é "automático" se a entrada Stop existe de fato no settings.json.
# Registrar via install (não edit manual de host) torna o gatilho reproduzível em
# qualquer máquina — sem isso o script existe mas nunca dispara (Adv #1).
# Helper: nº de entradas Stop apontando p/ sync-telemetry-log.sh (-1 = JSON ilegível).
stop_hook_count() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(-1); sys.exit(0)
n = sum(1 for g in d.get("hooks", {}).get("Stop", [])
        for h in g.get("hooks", [])
        if str(h.get("command", "")).endswith("hooks/sync-telemetry-log.sh"))
print(n)
PY
}

# Caso 1: sem settings.json prévio → install cria com a entrada Stop
REPO3b="$TMP/ac3b/repo"; HOME3b="$TMP/ac3b/home"
mkrepo "$REPO3b"; mkclaude "$HOME3b"
mkdir -p "$REPO3b/hooks"; cp "$HOOK" "$REPO3b/hooks/sync-telemetry-log.sh"
SYNC_CLAUDE_HOME="$HOME3b" bash "$REPO3b/sync.sh" install >/dev/null 2>&1
assert_rc "$?" 0 "AC3 install exit 0"
assert_file "$HOME3b/settings.json" "AC3 install criou settings.json"
assert_eq "$(stop_hook_count "$HOME3b/settings.json")" "1" \
  "AC3 settings.json contém a entrada Stop p/ sync-telemetry-log.sh após install"

# Caso 2: idempotência — 2º install não duplica a entrada
SYNC_CLAUDE_HOME="$HOME3b" bash "$REPO3b/sync.sh" install >/dev/null 2>&1
assert_eq "$(stop_hook_count "$HOME3b/settings.json")" "1" \
  "AC3 install idempotente (entrada Stop não duplicada no 2º run)"

# Caso 3: preserva settings.json pré-existente (não clobbera outros hooks)
REPO3c="$TMP/ac3c/repo"; HOME3c="$TMP/ac3c/home"
mkrepo "$REPO3c"; mkclaude "$HOME3c"
mkdir -p "$REPO3c/hooks"; cp "$HOOK" "$REPO3c/hooks/sync-telemetry-log.sh"
printf '%s\n' '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/pre-existing.sh"}]}]}}' \
  > "$HOME3c/settings.json"
SYNC_CLAUDE_HOME="$HOME3c" bash "$REPO3c/sync.sh" install >/dev/null 2>&1
if python3 - "$HOME3c/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [str(h.get("command", "")) for g in d.get("hooks", {}).get("Stop", [])
        for h in g.get("hooks", [])]
ok = any(c.endswith("/x/pre-existing.sh") for c in cmds) and \
     any(c.endswith("hooks/sync-telemetry-log.sh") for c in cmds)
sys.exit(0 if ok else 1)
PY
then _pass; else _fail "AC3 install preservou hook pré-existente E adicionou o novo"; fi

# ═══ AC4 — telemetry dirty NÃO bloqueia install ═════════════════════════════
REPO4="$TMP/ac4/repo"; HOME4="$TMP/ac4/home"
mkrepo "$REPO4"; mkclaude "$HOME4"
# Source idêntico nos DIRS/FILES (sem divergência → install não deveria bloquear)
printf '# claude\n' > "$REPO4/CLAUDE.md"
printf '# claude\n' > "$HOME4/CLAUDE.md"
mkdir -p "$REPO4/commands" "$HOME4/commands"
printf 'x\n' > "$REPO4/commands/foo.md"
printf 'x\n' > "$HOME4/commands/foo.md"
# telemetry DIVERGENTE entre repo e ~/.claude (o "estado dirty" do bug original)
mkdir -p "$REPO4/telemetry"
printf 'REPO-VERSION\n'   > "$REPO4/telemetry/dod-usage.$MID.jsonl"
printf 'CLAUDE-VERSION\n' > "$HOME4/telemetry/dod-usage.$MID.jsonl"

SYNC_CLAUDE_HOME="$HOME4" bash "$REPO4/sync.sh" install >/dev/null 2>&1
INSTALL_RC=$?
assert_rc "$INSTALL_RC" 0 "AC4 install NÃO bloqueia com telemetry dirty (exit 0)"
# install não tocou ~/.claude/telemetry (fora de escopo → conteúdo preservado)
assert_eq "$(cat "$HOME4/telemetry/dod-usage.$MID.jsonl")" "CLAUDE-VERSION" \
  "AC4 install não sobrescreveu ~/.claude/telemetry/ (fora dos DIRS)"

# ═══ Summary ═════════════════════════════════════════════════════════════════
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
