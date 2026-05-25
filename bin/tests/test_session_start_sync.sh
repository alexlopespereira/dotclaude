#!/usr/bin/env bash
set -u

# test_session_start_sync.sh — testes para o hook SessionStart híbrido
# (US-08 / M8 parte 2 / Adv #6).
#
# Cobre os acceptance criteria automatizáveis da story "Hook SessionStart híbrido (L2)":
#   AC1 — o hook roda `sync.sh install` SOMENTE se `git -C <dotclaude>` está limpo
#         E na branch main; caso contrário imprime aviso de drift e NÃO instala.
#         Casos: (A) limpo+main → instala; (B) tree sujo → avisa, não instala;
#         (C) branch != main → avisa, não instala; (D) repo/sync.sh ausente → no-op.
#   AC2 — o hook NÃO bloqueia a sessão (exit 0 em todos os caminhos) e roda em
#         <1s (medido) tanto no caminho install quanto no caminho aviso.
#   AC3 é [CAT3-MANUAL] — validação em sessão real, fora deste harness.
#
# Registro: o hook só dispara se estiver registrado sob hooks.SessionStart no
# settings.json. `sync.sh install` registra de forma idempotente (espelha o Stop
# hook de US-07) — sem isso o script existe mas nunca roda. Verificado aqui.
#
# Estratégia: sandbox em tmpdir. DOTCLAUDE_REPO aponta o repo alvo do hook para
# um repo git temp (cópia do sync.sh real + source mínimo). SYNC_CLAUDE_HOME
# aponta o ~/.claude do install para um sandbox vazio (= "fresh machine").

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SYNC_SRC="$REPO_ROOT/sync.sh"
HOOK="$REPO_ROOT/hooks/session-start-sync.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }

assert_eq()     { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_rc()     { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_file()   { [ -f "$1" ] && _pass || _fail "$2 :: arquivo ausente: $1"; }
assert_nofile() { [ ! -f "$1" ] && _pass || _fail "$2 :: arquivo NÃO deveria existir: $1"; }
assert_grep()   { printf '%s' "$1" | grep -q "$2" && _pass || _fail "$3 :: padrão '$2' ausente em: $1"; }

[[ -f "$SYNC_SRC" ]] || { echo "FAIL: $SYNC_SRC inexistente" >&2; exit 1; }
[[ -f "$HOOK" ]]     || { echo "FAIL: $HOOK inexistente (implemente o hook)" >&2; exit 1; }

TMP="$(mktemp -d -t ss-sync.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Aquece o python3 (file cache do interpretador) fora da janela cronometrada —
# evita que o cold-start do 1º python contamine a medição de <1s do AC2.
python3 -c 'pass' >/dev/null 2>&1 || true

now()     { python3 -c 'import time;print(time.time())'; }
assert_lt1() { python3 -c "import sys;sys.exit(0 if float('$1')<1.0 else 1)" \
                 && _pass || _fail "$2 :: tempo ${1}s >= 1.0s (AC2 viola <1s)"; }

# ── Monta um repo dotclaude temp: cópia do sync.sh real + source mínimo,
#    git init, branch main, 1 commit (→ working tree limpo em main). ──────────
mkrepo() {
  local repo="$1"
  mkdir -p "$repo/commands" "$repo/hooks"
  cp "$SYNC_SRC" "$repo/sync.sh"; chmod +x "$repo/sync.sh"
  cp "$HOOK" "$repo/hooks/session-start-sync.sh"
  printf 'NEW-CLAUDE\n'   > "$repo/CLAUDE.md"
  printf 'NEW-WORKFLOW\n' > "$repo/WORKFLOW.md"
  printf 'newcmd\n'       > "$repo/commands/newcmd.md"
  git -C "$repo" init -q
  git -C "$repo" symbolic-ref HEAD refs/heads/main   # branch main p/ qualquer versão de git
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name  test
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" add -A
  git -C "$repo" commit -q -m init
}

mkclaude() { mkdir -p "$1"; }   # ~/.claude "fresh machine" (vazio)

run_hook() {  # $1=repo $2=home ; stdin = payload SessionStart ; ecoa stderr
  echo '{"hook_event_name":"SessionStart","source":"startup"}' | \
    DOTCLAUDE_REPO="$1" SYNC_CLAUDE_HOME="$2" bash "$HOOK" 2>&1 >/dev/null
}

# ═══ AC1-A — limpo + main → instala (source propagado p/ ~/.claude) ══════════
REPOA="$TMP/a/repo"; HOMEA="$TMP/a/home"
mkrepo "$REPOA"; mkclaude "$HOMEA"
T0=$(now)
echo '{}' | DOTCLAUDE_REPO="$REPOA" SYNC_CLAUDE_HOME="$HOMEA" bash "$HOOK" >/dev/null 2>&1
RC=$?; T1=$(now)
assert_rc "$RC" 0 "AC1-A hook exit 0"
assert_file "$HOMEA/CLAUDE.md"                     "AC1-A install rodou (CLAUDE.md propagado)"
assert_file "$HOMEA/commands/newcmd.md"            "AC1-A install propagou commands/"
assert_file "$HOMEA/hooks/session-start-sync.sh"   "AC1-A install propagou o próprio hook"
assert_eq "$(cat "$HOMEA/CLAUDE.md")" "NEW-CLAUDE" "AC1-A conteúdo instalado correto"
ELAPSED_A=$(python3 -c "print(round(float('$T1')-float('$T0'),3))")
assert_lt1 "$ELAPSED_A" "AC2 caminho install <1s"

# ═══ AC1-B — tree sujo (em main) → NÃO instala, avisa ════════════════════════
REPOB="$TMP/b/repo"; HOMEB="$TMP/b/home"
mkrepo "$REPOB"; mkclaude "$HOMEB"
printf 'edit\n' > "$REPOB/uncommitted.txt"          # untracked → working tree sujo
ERRB="$(run_hook "$REPOB" "$HOMEB")"; RCB=$?
assert_rc "$RCB" 0 "AC1-B hook exit 0 (não bloqueia)"
assert_nofile "$HOMEB/CLAUDE.md"        "AC1-B install NÃO rodou (tree sujo)"
assert_nofile "$HOMEB/commands/newcmd.md" "AC1-B install NÃO propagou commands/ (tree sujo)"
assert_grep "$ERRB" "drift"             "AC1-B avisa drift no stderr"

# ═══ AC1-C — branch != main (limpo) → NÃO instala, avisa ═════════════════════
REPOC="$TMP/c/repo"; HOMEC="$TMP/c/home"
mkrepo "$REPOC"; mkclaude "$HOMEC"
git -C "$REPOC" checkout -q -b feat/algo               # branch de feature, tree limpo
T0C=$(now)
ERRC="$(run_hook "$REPOC" "$HOMEC")"; RCC=$?
T1C=$(now)
assert_rc "$RCC" 0 "AC1-C hook exit 0 (não bloqueia)"
assert_nofile "$HOMEC/CLAUDE.md"  "AC1-C install NÃO rodou (branch != main)"
assert_grep "$ERRC" "drift"       "AC1-C avisa drift no stderr"
assert_grep "$ERRC" "feat/algo"   "AC1-C aviso cita a branch atual"
ELAPSED_C=$(python3 -c "print(round(float('$T1C')-float('$T0C'),3))")
assert_lt1 "$ELAPSED_C" "AC2 caminho aviso <1s"

# ═══ AC1-D — repo/sync.sh ausente (máquina sem checkout dotclaude) → no-op ═══
HOMED="$TMP/d/home"; mkclaude "$HOMED"
echo '{}' | DOTCLAUDE_REPO="$TMP/d/does-not-exist" SYNC_CLAUDE_HOME="$HOMED" bash "$HOOK" >/dev/null 2>&1
assert_rc "$?" 0 "AC1-D hook exit 0 sem repo (no-op silencioso)"
assert_nofile "$HOMED/CLAUDE.md" "AC1-D nada instalado sem repo"

# ═══ Registro — install registra o SessionStart hook em settings.json ════════
# Helper: nº de entradas SessionStart apontando p/ session-start-sync.sh.
ss_hook_count() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(-1); sys.exit(0)
n = sum(1 for g in d.get("hooks", {}).get("SessionStart", [])
        for h in g.get("hooks", [])
        if str(h.get("command", "")).endswith("hooks/session-start-sync.sh"))
print(n)
PY
}

# Caso 1: sem settings.json prévio → install cria com a entrada SessionStart
REGR="$TMP/reg/repo"; REGH="$TMP/reg/home"
mkrepo "$REGR"; mkclaude "$REGH"
SYNC_CLAUDE_HOME="$REGH" bash "$REGR/sync.sh" install >/dev/null 2>&1
assert_file "$REGH/settings.json" "REG install criou settings.json"
assert_eq "$(ss_hook_count "$REGH/settings.json")" "1" \
  "REG settings.json contém entrada SessionStart p/ session-start-sync.sh"

# Caso 2: idempotência — 2º install não duplica
SYNC_CLAUDE_HOME="$REGH" bash "$REGR/sync.sh" install >/dev/null 2>&1
assert_eq "$(ss_hook_count "$REGH/settings.json")" "1" \
  "REG install idempotente (SessionStart não duplicado no 2º run)"

# Caso 3: preserva settings.json pré-existente (não clobbera outros hooks)
PREr="$TMP/pre/repo"; PREh="$TMP/pre/home"
mkrepo "$PREr"; mkclaude "$PREh"
printf '%s\n' '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"/x/pre-existing.sh"}]}]}}' \
  > "$PREh/settings.json"
SYNC_CLAUDE_HOME="$PREh" bash "$PREr/sync.sh" install >/dev/null 2>&1
if python3 - "$PREh/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [str(h.get("command", "")) for g in d.get("hooks", {}).get("SessionStart", [])
        for h in g.get("hooks", [])]
ok = any(c.endswith("/x/pre-existing.sh") for c in cmds) and \
     any(c.endswith("hooks/session-start-sync.sh") for c in cmds)
sys.exit(0 if ok else 1)
PY
then _pass; else _fail "REG install preservou hook pré-existente E adicionou o novo"; fi

# ═══ Summary ═════════════════════════════════════════════════════════════════
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
