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
  printf 'NEW-CLAUDE\n'   > "$repo/CLAUDE.global.md"   # fonte global → ~/.claude/CLAUDE.md
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

# ═══ AC1 (US-02) B2 — dirt SÓ em telemetry/ (staged + untracked) → instala ════
# Gate telemetry-exempt: o Stop hook deixa telemetry/ suja, mas isso NÃO é drift
# de source → o hook deve rodar install mesmo assim.
REPOB2="$TMP/b2/repo"; HOMEB2="$TMP/b2/home"
mkrepo "$REPOB2"; mkclaude "$HOMEB2"
mkdir -p "$REPOB2/telemetry"
printf 'untracked\n' > "$REPOB2/telemetry/untrk.log"      # untracked telemetry dirt
printf 'staged\n'    > "$REPOB2/telemetry/staged.log"
git -C "$REPOB2" add "telemetry/staged.log"               # staged telemetry dirt
ERRB2="$(run_hook "$REPOB2" "$HOMEB2")"; RCB2=$?
assert_rc "$RCB2" 0 "B2 hook exit 0"
assert_file "$HOMEB2/CLAUDE.md"          "B2 install RODOU (dirt só em telemetry/ é isento)"
assert_file "$HOMEB2/commands/newcmd.md" "B2 install propagou commands/ (telemetry isento)"

# ═══ AC2 (US-02) B3 — dirt em telemetry/ E fora → NÃO instala; drift só fora ══
REPOB3="$TMP/b3/repo"; HOMEB3="$TMP/b3/home"
mkrepo "$REPOB3"; mkclaude "$HOMEB3"
mkdir -p "$REPOB3/telemetry"
printf 'tel\n' > "$REPOB3/telemetry/untrk.log"            # dirt em telemetry/ (isento)
printf 'src\n' > "$REPOB3/outside.txt"                    # dirt FORA (único contado)
ERRB3="$(run_hook "$REPOB3" "$HOMEB3")"; RCB3=$?
assert_rc "$RCB3" 0 "B3 hook exit 0"
assert_nofile "$HOMEB3/CLAUDE.md" "B3 install NÃO rodou (dirt fora de telemetry/)"
assert_grep "$ERRB3" "drift"      "B3 avisa drift no stderr"
assert_grep "$ERRB3" "1 item"     "B3 drift conta SÓ o dirt fora de telemetry/ (1 item)"

# ── Helper: monta um checkout com remote bare local (p/ testar auto-pull). ────
# Cria $base/bare.git (remote), $base/seed (origem dos commits) e $base/repo
# (o checkout dotclaude que o hook vê). repo fica 1 commit ATRÁS do bare.
mkrepo_remote() {
  local base="$1"
  local bare="$base/bare.git" seed="$base/seed" repo="$base/repo"
  git init -q --bare "$bare"
  # HEAD do bare → main ANTES do push: sem isso, em máquina sem
  # init.defaultBranch global (ex.: runner de CI) o HEAD default (master)
  # aponta pra ref inexistente após o push de main e o clone vem vazio
  # ("remote HEAD refers to nonexistent ref").
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  mkdir -p "$seed/commands" "$seed/hooks"
  cp "$SYNC_SRC" "$seed/sync.sh"; chmod +x "$seed/sync.sh"
  cp "$HOOK" "$seed/hooks/session-start-sync.sh"
  printf 'PRE-PULL\n'    > "$seed/CLAUDE.global.md"
  printf 'NEW-WORKFLOW\n' > "$seed/WORKFLOW.md"
  printf 'newcmd\n'      > "$seed/commands/newcmd.md"
  git -C "$seed" init -q
  git -C "$seed" symbolic-ref HEAD refs/heads/main
  git -C "$seed" config user.email t@example.com
  git -C "$seed" config user.name test
  git -C "$seed" config commit.gpgsign false
  git -C "$seed" add -A
  git -C "$seed" commit -q -m init
  git -C "$seed" remote add origin "$bare"
  git -C "$seed" push -q origin main
  git clone -q "$bare" "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name test
  git -C "$repo" config commit.gpgsign false
}
# Avança o bare 1 commit (CLAUDE.md → POST-PULL), deixando repo atrás.
advance_remote() {
  local seed="$1/seed"
  printf 'POST-PULL\n' > "$seed/CLAUDE.global.md"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m c2
  git -C "$seed" push -q origin main
}

# ═══ AC3 (US-02) — SEM opt-in → nenhum pull (HEAD do clone não avança) ════════
P3="$TMP/p3"; mkrepo_remote "$P3"; advance_remote "$P3"; mkclaude "$P3/home"
HEAD_B3=$(git -C "$P3/repo" rev-parse HEAD)
echo '{}' | DOTCLAUDE_REPO="$P3/repo" SYNC_CLAUDE_HOME="$P3/home" bash "$HOOK" >/dev/null 2>&1
RC=$?; HEAD_A3=$(git -C "$P3/repo" rev-parse HEAD)
assert_rc "$RC" 0 "AC3 hook exit 0 sem opt-in"
assert_eq "$HEAD_A3" "$HEAD_B3" "AC3 sem opt-in NÃO faz pull (HEAD inalterado)"
assert_file "$P3/home/CLAUDE.md" "AC3 install rodou (gate seguro), só sem pull"

# ═══ AC4 (US-02) — opt-in via ENV → pull --ff-only avança HEAD; install pós-pull
P4E="$TMP/p4e"; mkrepo_remote "$P4E"; advance_remote "$P4E"; mkclaude "$P4E/home"
HEAD_B4E=$(git -C "$P4E/repo" rev-parse HEAD)
echo '{}' | DOTCLAUDE_AUTO_PULL=1 DOTCLAUDE_REPO="$P4E/repo" SYNC_CLAUDE_HOME="$P4E/home" bash "$HOOK" >/dev/null 2>&1
RC=$?; HEAD_A4E=$(git -C "$P4E/repo" rev-parse HEAD)
assert_rc "$RC" 0 "AC4-env hook exit 0"
[ "$HEAD_A4E" != "$HEAD_B4E" ] && _pass || _fail "AC4-env pull avançou HEAD do clone"
assert_eq "$(cat "$P4E/home/CLAUDE.md")" "POST-PULL" "AC4-env install rodou com conteúdo PÓS-pull"

# ═══ AC4 (US-02) — opt-in via MARCADOR .vm-profile → idem ═════════════════════
P4M="$TMP/p4m"; mkrepo_remote "$P4M"; advance_remote "$P4M"; mkclaude "$P4M/home"
touch "$P4M/home/.vm-profile"                              # marcador na base ~/.claude
HEAD_B4M=$(git -C "$P4M/repo" rev-parse HEAD)
echo '{}' | DOTCLAUDE_REPO="$P4M/repo" SYNC_CLAUDE_HOME="$P4M/home" bash "$HOOK" >/dev/null 2>&1
RC=$?; HEAD_A4M=$(git -C "$P4M/repo" rev-parse HEAD)
assert_rc "$RC" 0 "AC4-marker hook exit 0"
[ "$HEAD_A4M" != "$HEAD_B4M" ] && _pass || _fail "AC4-marker pull avançou HEAD do clone"
assert_eq "$(cat "$P4M/home/CLAUDE.md")" "POST-PULL" "AC4-marker install rodou com conteúdo PÓS-pull"

# ═══ AC5 (US-02) — pull FALHA (non-ff) → aviso stderr, exit 0, install local ══
P5="$TMP/p5"; mkrepo_remote "$P5"; advance_remote "$P5"; mkclaude "$P5/home"
printf 'LOCAL\n' > "$P5/repo/localfile.txt"               # commit local divergente
git -C "$P5/repo" add -A; git -C "$P5/repo" commit -q -m localdivergent
HEAD_B5=$(git -C "$P5/repo" rev-parse HEAD)
ERR5="$(echo '{}' | DOTCLAUDE_AUTO_PULL=1 DOTCLAUDE_REPO="$P5/repo" SYNC_CLAUDE_HOME="$P5/home" bash "$HOOK" 2>&1 >/dev/null)"
RC=$?; HEAD_A5=$(git -C "$P5/repo" rev-parse HEAD)
assert_rc "$RC" 0 "AC5 pull falho NÃO aborta o hook (exit 0)"
assert_eq "$HEAD_A5" "$HEAD_B5" "AC5 pull non-ff falhou (HEAD inalterado)"
assert_grep "$ERR5" "pull" "AC5 aviso de pull no stderr"
assert_eq "$(cat "$P5/home/CLAUDE.md")" "PRE-PULL" "AC5 install prosseguiu do estado LOCAL"

# ═══ AC6/AC7 (US-02) — _register_hook matcher+timeout → PostToolUse c/ CLAUDE_DIR
# Conta hooks PostToolUse cujo command termina no sufixo do guard.
pt_verify_count() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(-1); sys.exit(0)
n = sum(1 for g in d.get("hooks", {}).get("PostToolUse", [])
        for h in g.get("hooks", [])
        if str(h.get("command", "")).endswith("hooks/verify-before-handoff-guard.sh"))
print(n)
PY
}

# AC6/AC7 caso 1: settings fresco → cria entry {type,command,timeout} sob matcher
# exato 'Bash|mcp__.*', command usando CLAUDE_DIR do sandbox (sem /Users/).
VR="$TMP/vh/repo"; VH="$TMP/vh/home"
mkrepo "$VR"; mkclaude "$VH"
SYNC_CLAUDE_HOME="$VH" bash "$VR/sync.sh" install >/dev/null 2>&1
assert_eq "$(pt_verify_count "$VH/settings.json")" "1" \
  "AC6 install registra verify-before-handoff sob PostToolUse"
if python3 - "$VH/settings.json" "$VH" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); home = sys.argv[2]
found = False
for g in d.get("hooks", {}).get("PostToolUse", []):
    for h in g.get("hooks", []):
        c = str(h.get("command", ""))
        if c.endswith("hooks/verify-before-handoff-guard.sh"):
            assert g.get("matcher") == "Bash|mcp__.*", "matcher exato"
            assert h.get("type") == "command", "type command"
            assert h.get("timeout") == 5000, "timeout 5000"
            assert "/Users/" not in c, "sem /Users hardcoded"
            assert c.startswith(home), "usa CLAUDE_DIR do sandbox"
            found = True
sys.exit(0 if found else 1)
PY
then _pass; else _fail "AC7 entry PostToolUse: matcher 'Bash|mcp__.*' + timeout 5000 + CLAUDE_DIR sandbox"; fi

# Idempotência: 2º install não duplica
SYNC_CLAUDE_HOME="$VH" bash "$VR/sync.sh" install >/dev/null 2>&1
assert_eq "$(pt_verify_count "$VH/settings.json")" "1" \
  "AC6 install idempotente (PostToolUse não duplicado no 2º run)"

# AC6 caso 2: registro pré-existente de MESMO sufixo (path absoluto diferente) →
# no-op sem duplicata.
VR2="$TMP/vh2/repo"; VH2="$TMP/vh2/home"
mkrepo "$VR2"; mkclaude "$VH2"
printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"Bash|mcp__.*","hooks":[{"type":"command","command":"/other/path/hooks/verify-before-handoff-guard.sh","timeout":5000}]}]}}' \
  > "$VH2/settings.json"
SYNC_CLAUDE_HOME="$VH2" bash "$VR2/sync.sh" install >/dev/null 2>&1
assert_eq "$(pt_verify_count "$VH2/settings.json")" "1" \
  "AC6 pré-existente mesmo sufixo (path diferente) é no-op sem duplicata"

# ═══ UPGRADE — ~/.claude com versão HISTÓRICA → install pós-pull NÃO bloqueia ═
# Regressão real (pós-#49): o gate do install bloqueava QUALQUER update de
# arquivo existente — após git pull, ~/.claude (stale) difere do HEAD novo e o
# elo pull→install das VMs ficava morto. Stale = hash bate com versão histórica
# do repo → upgrade seguro; só edit local real (hash fora do histórico) bloqueia.
REPOU="$TMP/u/repo"; HOMEU="$TMP/u/home"
mkrepo "$REPOU"; mkclaude "$HOMEU"
SYNC_CLAUDE_HOME="$HOMEU" bash "$REPOU/sync.sh" install >/dev/null 2>&1
printf 'newcmd-v2\n' > "$REPOU/commands/newcmd.md"
printf 'CLAUDE-v2\n' > "$REPOU/CLAUDE.global.md"
git -C "$REPOU" add -A
git -C "$REPOU" commit -q -m v2
out=$(SYNC_CLAUDE_HOME="$HOMEU" bash "$REPOU/sync.sh" install 2>&1); rcu=$?
assert_rc "$rcu" 0 "UPG-a install pós-pull com cópia stale NÃO bloqueia"
assert_eq "$(cat "$HOMEU/commands/newcmd.md")" "newcmd-v2" "UPG-b DIRS atualizado p/ v2"
assert_eq "$(cat "$HOMEU/CLAUDE.md")" "CLAUDE-v2" "UPG-c FILES atualizado p/ v2"

# ═══ EDIT LOCAL — conteúdo fora do histórico do repo → install BLOQUEIA ═══════
printf 'edit local meu\n' > "$HOMEU/commands/newcmd.md"
out=$(SYNC_CLAUDE_HOME="$HOMEU" bash "$REPOU/sync.sh" install 2>&1); rce=$?
assert_rc "$rce" 2 "EDT-a edit local real continua bloqueando install"
assert_grep "$out" "edit local" "EDT-b mensagem distingue edit local de stale"
assert_eq "$(cat "$HOMEU/commands/newcmd.md")" "edit local meu" "EDT-c edit local preservado (não clobberado)"

# ═══ Summary ═════════════════════════════════════════════════════════════════
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
