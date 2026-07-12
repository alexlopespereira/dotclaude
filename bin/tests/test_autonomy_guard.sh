#!/usr/bin/env bash
set -u

# test_autonomy_guard.sh — testes para hooks/autonomy-guard.sh (hook Stop, US-01+US-02).
#
# O hook é o backstop determinístico do P15: detecta turno-pergunta auto-aprovável
# no fim do turno. Parsing conforme a Revisão Adversária do plano autonomy-guard
# (Falhas #1/#3/#5): iteração REVERSA do transcript JSONL acumulando linhas
# assistant (não-sidechain) até o último prompt REAL do usuário; texto = APENAS
# blocks type=="text" (thinking excluído); SEM tail fixo. Classificador: allowlist
# primeiro (AskUserQuestion/ExitPlanMode/credencial/custo/irreversível), depois
# padrões hot derivados do interrupcoes-report.sh (PT+EN). Em advisory: só audita
# (stdout VAZIO, exit 0). Fail-open total (SEMPRE exit 0).
#
# US-02 — modo block: block efetivo SÓ com modo=='block' E marcador de VM
# presente (seam AUTONOMY_GUARD_VM_MARKER); saída {"decision":"block","reason"}
# exit 0; orçamento AUTONOMY_GUARD_MAX_BLOCKS (default 2) por session_id é o
# anti-loop PRIMÁRIO (stop_hook_active é best-effort); host nunca bloqueia;
# allowlist SEMPRE vence block.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO/hooks/autonomy-guard.sh"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_eq() { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected '$2' got '$1'"; }
assert_contains() { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: '$1' não contém '$2'" ;; esac; }

[ -f "$HOOK" ] || { echo "FAIL: $HOOK inexistente (TDD red)" >&2; exit 1; }

TMP="$(mktemp -d -t autonomy-guard.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/audit"

# ── Builders de fixture (1 linha JSONL por chamada, append em $T) ────────────
T=""
new_t()   { T="$TMP/t-$1.jsonl"; : > "$T"; }
u()       { printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"%s"}]}}\n' "$1" >> "$T"; }
toolres() { printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu1","content":"ok"}]}}\n' >> "$T"; }
at()      { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$1" >> "$T"; }
atool()   { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"%s","input":{}}]}}\n' "$1" >> "$T"; }
athink()  { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"%s"},{"type":"text","text":"%s"}]}}\n' "$1" "$2" >> "$T"; }
aside()   { printf '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$1" >> "$T"; }

# ── Runner: OUT/RC/ERR/AUDIT globais; EXTRA_ENV injeta seams (sem espaços) ───
# Isolamento do mode-file: TODA invocação carrega AUTONOMY_GUARD_MODE_FILE
# apontando pra path inexistente do $TMP — o default do hook
# (~/.claude/cache/autonomy/mode) NUNCA é lido, senão um host/VM com 'block'
# gravado quebra os casos advisory (baseline VM1: 1b/1e/1f/2b/2d/4c). Como
# duplicata posterior vence no env(1), um MODE_FILE explícito em EXTRA_ENV
# (caso 19) sobrescreve o default sem tratamento especial.
EXTRA_ENV=""
run_hook() { # <case> [payload — default: session sess-<case> + transcript $T]
  local c="$1" payload="${2:-}"
  AUDIT="$TMP/audit/$c.jsonl"; ERR="$TMP/audit/$c.stderr"
  [ -n "$payload" ] || payload="{\"session_id\":\"sess-$c\",\"transcript_path\":\"$T\",\"stop_hook_active\":false}"
  # EXTRA_ENV é lista de VAR=valor sem espaços — expansão sem aspas proposital
  # shellcheck disable=SC2086
  # AUTONOMY_GUARD_MODE= (vazia, falsy em resolve_mode) neutraliza herança do
  # shell chamador — a env var tem precedência sobre o MODE_FILE, então sem
  # isso um host com AUTONOMY_GUARD_MODE=block exportado quebra os casos
  # advisory (review holístico #1, reproduzido). Duplicata em EXTRA_ENV vence.
  OUT="$(printf '%s' "$payload" | env AUTONOMY_GUARD_AUDIT="$AUDIT" AUTONOMY_GUARD_MODE_FILE="$TMP/nonexistent-mode" AUTONOMY_GUARD_MODE= $EXTRA_ENV bash "$HOOK" 2>"$ERR")"
  RC=$?
}
audit_lines() { [ -f "$AUDIT" ] && wc -l < "$AUDIT" | tr -d ' ' || echo 0; }
afield() { jq -r "$1" "$AUDIT" 2>/dev/null; }

# ─── 0. Estrutura: shebang, executável, sem cliente de rede (specs 1/9) ──────
assert_eq "$(head -1 "$HOOK")" "#!/usr/bin/env bash" "0a shebang bash"
[ -x "$HOOK" ] && _pass || _fail "0b hook executável (chmod +x)"
NET="$(grep -cE '\b(curl|wget|xh|httpie)\b|git (fetch|pull)' "$HOOK" || true)"
assert_eq "$NET" "0" "0c zero clientes de rede no fonte (b9 por ausência)"

# ─── 1. Hot: "Quer que eu…?" → audit advisory, stdout vazio (AC5/AC8) ────────
new_t hot1; u "aplica o patch do parser"; at "Quer que eu aplique o patch agora?"
run_hook hot1
assert_eq "$RC" "0" "1a hot exit 0"
assert_eq "$OUT" "" "1b advisory: stdout VAZIO (AC8)"
assert_eq "$(cat "$ERR")" "" "1c sem stderr"
assert_eq "$(audit_lines)" "1" "1d exatamente 1 linha de audit"
assert_eq "$(afield '.decision')" "advisory" "1e decision advisory"
assert_eq "$(afield '.mode')" "advisory" "1f mode default advisory"
assert_eq "$(afield '.session_id')" "sess-hot1" "1g session_id do payload"
assert_eq "$(afield '.allowlist_reason')" "null" "1h allowlist_reason null em hot"
assert_contains "$(afield '.match')" "quer que eu" "1i match do padrão"

# ─── 2. Hot: "Posso prosseguir…?" (AC5) ──────────────────────────────────────
new_t hot2; u "implementa o parser"; at "Posso prosseguir com a implementação do parser?"
run_hook hot2
assert_eq "$(audit_lines)" "1" "2a 1 linha de audit"
assert_eq "$(afield '.decision')" "advisory" "2b decision advisory"
assert_contains "$(afield '.match')" "posso" "2c match posso-prosseguir"
assert_eq "$OUT" "" "2d stdout vazio"

# ─── 3. Hot: "Confirma que sigo?" (AC5) ──────────────────────────────────────
new_t hot3; u "segue o plano"; at "Confirma que sigo com o plano B?"
run_hook hot3
assert_eq "$(audit_lines)" "1" "3a 1 linha de audit"
assert_contains "$(afield '.match')" "confirma" "3b match confirma"

# ─── 4. Hot: menu (A)/(B) + recomendado (AC5) ────────────────────────────────
new_t hot4; u "decide a rota"
at "Duas rotas: **(A)** migrar agora (recomendado) ou **(B)** aguardar a janela."
run_hook hot4
assert_eq "$(audit_lines)" "1" "4a 1 linha de audit"
assert_eq "$(afield '.match')" "menu-ab-recomendado" "4b match menu-ab-recomendado"
assert_eq "$(afield '.decision')" "advisory" "4c decision advisory"

# ─── 5. Cold: texto declarativo → ZERO audit (AC5) ───────────────────────────
new_t cold; u "roda a suíte"; at "Rodei a suíte completa: 42 verdes, 0 falhas. Commit criado."
run_hook cold
assert_eq "$RC" "0" "5a cold exit 0"
assert_eq "$OUT" "" "5b cold stdout vazio"
assert_eq "$(audit_lines)" "0" "5c cold: zero audit"

# ─── 6. Turno MULTI-LINHA: hot só na 1ª linha do turno (AC2 / Falha #1) ──────
new_t multi; u "corrige o bug do parser"
at "Quer que eu aplique a correção no parser?"
atool "Bash"; toolres
at "Análise concluída; o traceback aponta pro tokenizer."
run_hook multi
assert_eq "$(audit_lines)" "1" "6a turno multi-linha acumulado → hot detectado"
assert_contains "$(afield '.match')" "quer que eu" "6b match veio da 1ª linha do turno"

# ─── 7. Thinking com padrão hot NÃO conta (AC3 / Falha #3) ───────────────────
new_t think; u "roda os testes"
athink "Quer que eu pergunte antes? Devo confirmar com o usuário?" "Suíte executada: 42 testes, tudo verde."
run_hook think
assert_eq "$RC" "0" "7a exit 0"
assert_eq "$(audit_lines)" "0" "7b thinking excluído: zero audit"

# ─── 8. Sem tail fixo: hot atrás de >200 tool_results (AC4 / Falha #5) ───────
new_t long; u "processa o lote"
at "Posso continuar com o lote inteiro de arquivos?"
i=0; while [ "$i" -lt 210 ]; do atool "Read"; toolres; i=$((i+1)); done
at "Processei o primeiro arquivo do lote."
run_hook long
assert_eq "$(audit_lines)" "1" "8a turno com 420+ linhas parseado inteiro (sem tail)"
assert_contains "$(afield '.match')" "posso" "8b hot achado no início do turno"

# ─── 9. isSidechain ignorado (AC4) ───────────────────────────────────────────
new_t side; u "gera o relatório"
at "Relatório gerado e salvo em disco no formato pedido."
aside "Quer que eu envie o relatório por e-mail?"
run_hook side
assert_eq "$(audit_lines)" "0" "9a sidechain hot ignorado: zero audit"

# ─── 10. Acumulação para no último prompt REAL (turno anterior não vaza) ─────
new_t boundary; u "primeira tarefa"
at "Quer que eu siga pela rota A?"
u "sim, segue pela A"
at "Rota A aplicada; resultado gravado no diretório de saída."
run_hook boundary
assert_eq "$(audit_lines)" "0" "10a hot do turno ANTERIOR não classifica o atual"

# ─── 11. Allowlist: AskUserQuestion vence texto hot (AC6) ────────────────────
new_t ask; u "planeja a migração"
at "Quer que eu siga pela opção mais simples?"; atool "AskUserQuestion"
run_hook ask
assert_eq "$(audit_lines)" "1" "11a allowlist audita 1 linha"
assert_eq "$(afield '.allowlist_reason')" "ask-user-question" "11b reason ask-user-question"
assert_eq "$(afield '.decision')" "null" "11c decision null em allowlist"
assert_eq "$OUT" "" "11d stdout vazio"

# ─── 12. Allowlist: ExitPlanMode (AC6) ───────────────────────────────────────
new_t plan; u "planeja"; at "Posso prosseguir com o plano descrito acima?"; atool "ExitPlanMode"
run_hook plan
assert_eq "$(afield '.allowlist_reason')" "exit-plan-mode" "12a reason exit-plan-mode"
assert_eq "$(afield '.decision')" "null" "12b decision null"

# ─── 13. Allowlist: credencial/login/2FA/código (AC6) ────────────────────────
new_t cred; u "faz o deploy"
at "Preciso do código de verificação do 2FA para completar o login. Pode colar aqui?"
run_hook cred
assert_eq "$(afield '.allowlist_reason')" "credential-request" "13a reason credential-request"
assert_eq "$(afield '.decision')" "null" "13b decision null"

# ─── 14. Allowlist: custo/cota (AC6) ─────────────────────────────────────────
new_t cost; u "provisiona a API"
at "Devo habilitar o tier pago? Isso aumenta o custo mensal e consome cota extra."
run_hook cost
assert_eq "$(afield '.allowlist_reason')" "cost-quota" "14a reason cost-quota"
assert_eq "$(afield '.decision')" "null" "14b decision null"

# ─── 15. Allowlist: irreversível em produção (branch AC9) ────────────────────
new_t irrev; u "limpa a base"
at "Confirma o drop da tabela de clientes? A operação é irreversível em produção."
run_hook irrev
assert_eq "$(afield '.allowlist_reason')" "irreversible-production" "15a reason irreversible-production"
assert_eq "$(afield '.decision')" "null" "15b decision null"

# ─── 16. Fail-open: payload malformado / transcript ausente (AC7) ────────────
run_hook f1 "isto não é json"
assert_eq "$RC" "0" "16a payload malformado → exit 0"
assert_eq "$OUT" "" "16b stdout vazio"
assert_eq "$(cat "$ERR")" "" "16c sem stderr fatal"
run_hook f2 '{"session_id":"s"}'
assert_eq "$RC" "0" "16d sem transcript_path → exit 0"
run_hook f3 "{\"session_id\":\"s\",\"transcript_path\":\"$TMP/nao-existe.jsonl\"}"
assert_eq "$RC" "0" "16e transcript inexistente → exit 0"
assert_eq "$(cat "$ERR")" "" "16f sem stderr fatal"

# ─── 17. Fail-open: python3 ausente via seam (AC7) ───────────────────────────
new_t pyseam; u "tarefa"; at "Quer que eu siga com a tarefa?"
EXTRA_ENV="AUTONOMY_GUARD_PY=$TMP/sem-python"
run_hook pyseam
EXTRA_ENV=""
assert_eq "$RC" "0" "17a python ausente → exit 0"
assert_eq "$OUT" "" "17b stdout vazio"
assert_eq "$(audit_lines)" "0" "17c zero audit sem python"

# ─── 18. stop_hook_active=true → no-op (AC7) ─────────────────────────────────
new_t shk; u "tarefa"; at "Quer que eu siga com a tarefa?"
run_hook shk "{\"session_id\":\"sess-shk\",\"transcript_path\":\"$T\",\"stop_hook_active\":true}"
assert_eq "$RC" "0" "18a stop_hook_active → exit 0"
assert_eq "$OUT" "" "18b stdout vazio"
assert_eq "$(audit_lines)" "0" "18c no-op: zero audit"

# ═══ US-02: modo block — gating VM + reason P15 + orçamento anti-loop ════════
VM_MARKER="$TMP/vm-marker"; touch "$VM_MARKER"
NO_MARKER="$TMP/marker-inexistente"

# ─── 19. Resolução de modo: env > arquivo > default (AC5) ────────────────────
# (default advisory já provado no teste 1f — 3ª fixture da resolução)
printf 'block\n' > "$TMP/modefile"
new_t mfile; u "mergeia"; at "Quer que eu siga com o merge?"
EXTRA_ENV="AUTONOMY_GUARD_MODE_FILE=$TMP/modefile AUTONOMY_GUARD_VM_MARKER=$VM_MARKER"
run_hook mfile
EXTRA_ENV=""
assert_eq "$(afield '.mode')" "block" "19a arquivo de modo vence default"
assert_eq "$(printf '%s' "$OUT" | jq -r '.decision' 2>/dev/null)" "block" "19b modo via arquivo é EFETIVO (emite block)"
new_t menv; u "mergeia"; at "Quer que eu siga com o merge?"
EXTRA_ENV="AUTONOMY_GUARD_MODE=advisory AUTONOMY_GUARD_MODE_FILE=$TMP/modefile AUTONOMY_GUARD_VM_MARKER=$VM_MARKER"
run_hook menv
EXTRA_ENV=""
assert_eq "$(afield '.mode')" "advisory" "19c env vence arquivo de modo"
assert_eq "$OUT" "" "19d env advisory vence arquivo block → sem decision"

# ─── 20. Block: hot + modo block + marcador VM → decision block (AC2) ────────
new_t blk; u "mergeia o PR"; at "Quer que eu siga com o merge?"
EXTRA_ENV="AUTONOMY_GUARD_MODE=block AUTONOMY_GUARD_VM_MARKER=$VM_MARKER"
run_hook blk
EXTRA_ENV=""
assert_eq "$RC" "0" "20a block exit 0"
assert_eq "$(cat "$ERR")" "" "20b sem stderr"
assert_eq "$(printf '%s' "$OUT" | jq -r '.decision' 2>/dev/null)" "block" "20c stdout JSON com decision==block"
REASON="$(printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null)"
assert_contains "$REASON" "P15" "20d reason cita P15"
assert_contains "$REASON" "recomenda" "20e reason instrui executar a recomendação"
assert_contains "$REASON" "[SUPOSIÇÃO]" "20f reason instrui registrar [SUPOSIÇÃO]"
assert_contains "$REASON" "(a)" "20g reason cita os gates (a)-(e)"
assert_eq "$(afield '.decision')" "block" "20h audit registra decision block"
assert_eq "$(afield '.mode')" "block" "20i audit registra mode block"

# ─── 21. Host sem marcador + modo block → advisory + host-never-blocks (AC3) ─
new_t hostblk; u "mergeia"; at "Quer que eu siga com o merge?"
EXTRA_ENV="AUTONOMY_GUARD_MODE=block AUTONOMY_GUARD_VM_MARKER=$NO_MARKER"
run_hook hostblk
EXTRA_ENV=""
assert_eq "$RC" "0" "21a exit 0"
assert_eq "$OUT" "" "21b host: NENHUM decision no stdout"
assert_eq "$(audit_lines)" "1" "21c 1 linha de audit"
assert_eq "$(afield '.event')" "host-never-blocks" "21d evento host-never-blocks"
assert_eq "$(afield '.decision')" "advisory" "21e degrada a advisory"

# ─── 22. Orçamento anti-loop: MAX_BLOCKS=2 → 3ª invocação degrada (AC4) ──────
new_t budget; u "empacota"; at "Posso prosseguir com o commit e o push?"
EXTRA_ENV="AUTONOMY_GUARD_MODE=block AUTONOMY_GUARD_VM_MARKER=$VM_MARKER AUTONOMY_GUARD_MAX_BLOCKS=2"
run_hook budget
assert_eq "$(printf '%s' "$OUT" | jq -r '.decision' 2>/dev/null)" "block" "22a 1ª invocação bloqueia"
run_hook budget
assert_eq "$(printf '%s' "$OUT" | jq -r '.decision' 2>/dev/null)" "block" "22b 2ª invocação bloqueia"
run_hook budget
assert_eq "$OUT" "" "22c 3ª invocação NÃO emite decision (orçamento esgotado)"
assert_eq "$(audit_lines)" "3" "22d 3 linhas de audit na sessão"
assert_eq "$(sed -n '3p' "$AUDIT" | jq -r '.event')" "BLOCK_BUDGET_EXHAUSTED" "22e 3ª audita BLOCK_BUDGET_EXHAUSTED"
assert_eq "$(sed -n '3p' "$AUDIT" | jq -r '.decision')" "advisory" "22f 3ª degrada a advisory"
run_hook budget "{\"session_id\":\"sess-budget-outra\",\"transcript_path\":\"$T\",\"stop_hook_active\":false}"
EXTRA_ENV=""
assert_eq "$(printf '%s' "$OUT" | jq -r '.decision' 2>/dev/null)" "block" "22g session_id diferente reseta o orçamento"

# ─── 23. Allowlist vence block: credencial + modo block + marcador (AC6) ─────
new_t credblk; u "faz o deploy"
at "Preciso do código de verificação do 2FA para completar o login. Pode colar aqui?"
EXTRA_ENV="AUTONOMY_GUARD_MODE=block AUTONOMY_GUARD_VM_MARKER=$VM_MARKER"
run_hook credblk
EXTRA_ENV=""
assert_eq "$OUT" "" "23a allowlist vence block: sem decision no stdout"
assert_eq "$(afield '.allowlist_reason')" "credential-request" "23b reason credential-request"
assert_eq "$(afield '.decision')" "null" "23c decision null"

# ═══ US-03: registro idempotente no sync.sh install + docs de rollout ════════
# Idiom de test_session_start_sync.sh: sandbox SYNC_CLAUDE_HOME + repo git temp
# com cópia do sync.sh real; SYNC_LOCAL_BIN aponta o symlink claude-yolo pro
# sandbox (sem tocar ~/.local/bin real).

SYNC_SRC="$REPO/sync.sh"
README="$REPO/README.md"

# Conta entradas Stop cujo command termina em hooks/autonomy-guard.sh.
ag_hook_count() {
  python3 - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(-1); sys.exit(0)
n = sum(1 for g in d.get("hooks", {}).get("Stop", [])
        for h in g.get("hooks", [])
        if str(h.get("command", "")).endswith("hooks/autonomy-guard.sh"))
print(n)
PY
}

mksyncrepo() {  # repo git temp mínimo: sync.sh real + hook real (com +x)
  local repo="$1"
  mkdir -p "$repo/hooks"
  cp "$SYNC_SRC" "$repo/sync.sh"; chmod +x "$repo/sync.sh"
  cp "$HOOK" "$repo/hooks/autonomy-guard.sh"; chmod +x "$repo/hooks/autonomy-guard.sh"
  git -C "$repo" init -q
  git -C "$repo" symbolic-ref HEAD refs/heads/main
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name  test
  git -C "$repo" config commit.gpgsign false
  git -C "$repo" add -A
  git -C "$repo" commit -q -m init
}

# ─── 24. AC1: install registra 1 entrada Stop (matcher vazio, timeout 5000) ──
SR="$TMP/sync/repo"; SH="$TMP/sync/home"; SB="$TMP/sync/bin"
mksyncrepo "$SR"; mkdir -p "$SH"
SYNC_CLAUDE_HOME="$SH" SYNC_LOCAL_BIN="$SB" bash "$SR/sync.sh" install >/dev/null 2>&1
[ -f "$SH/settings.json" ] && _pass || _fail "24a install criou settings.json"
assert_eq "$(ag_hook_count "$SH/settings.json")" "1" "24b 1 entrada Stop p/ autonomy-guard.sh"
if python3 - "$SH/settings.json" "$SH" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); home = sys.argv[2]
found = False
for g in d.get("hooks", {}).get("Stop", []):
    for h in g.get("hooks", []):
        c = str(h.get("command", ""))
        if c.endswith("hooks/autonomy-guard.sh"):
            assert g.get("matcher", "") == "", "matcher vazio"
            assert h.get("type") == "command", "type command"
            assert h.get("timeout") == 5000, "timeout 5000"
            assert c.startswith(home), "command usa CLAUDE_DIR expandido no install"
            found = True
sys.exit(0 if found else 1)
PY
then _pass; else _fail "24c entry Stop: matcher vazio + timeout 5000 + CLAUDE_DIR expandido"; fi

# ─── 25. AC1: 2º install não duplica (idempotência) ──────────────────────────
SYNC_CLAUDE_HOME="$SH" SYNC_LOCAL_BIN="$SB" bash "$SR/sync.sh" install >/dev/null 2>&1
assert_eq "$(ag_hook_count "$SH/settings.json")" "1" "25a contagem continua 1 no 2º install"

# ─── 26. AC2: hook propagado a ~/.claude/hooks/ com chmod +x preservado ──────
[ -f "$SH/hooks/autonomy-guard.sh" ] && _pass || _fail "26a hook propagado pelo install"
[ -x "$SH/hooks/autonomy-guard.sh" ] && _pass || _fail "26b chmod +x preservado"

# ─── 27. AC3: README documenta rollout advisory→block + path do audit ────────
grep -qF 'cache/autonomy/audit.jsonl' "$README" && _pass || _fail "27a README cita o path do audit"
grep -qF 'echo block > ~/.claude/cache/autonomy/mode' "$README" && _pass || _fail "27b README cita a promoção p/ block na VM"
grep -qF 'autonomy-guard.sh' "$README" && _pass || _fail "27c README cita o hook autonomy-guard.sh"

# ─── 28. Padrões "ok pra"/"ok para" + exclusões documentadas (finding V6) ────
new_t okpra; u "mergeia o fix"; at "Testes verdes. Está ok pra eu mergear o PR agora?"
run_hook okpra
assert_eq "$(audit_lines)" "1" "28a 'ok pra' é hot (fonte calibrada)"
assert_contains "$(afield '.match')" "ok pra" "28b match ok-pra"
new_t okpara; u "sobe o serviço"; at "Tudo pronto. Ok para subir o serviço?"
run_hook okpara
assert_eq "$(audit_lines)" "1" "28c 'ok para' é hot"
grep -qiE 'exclus[õo]es deliberadas' "$HOOK" && _pass || _fail "28d fonte documenta exclusões deliberadas vs interrupcoes-report.sh"

# ─── 29. Housekeeping: rotação do audit + GC de counters (finding V4) ────────
# Rotação: audit acima de AUTONOMY_GUARD_AUDIT_MAX_BYTES → vira .1, novo começa limpo
new_t rot; u "aplica o patch"; at "Quer que eu aplique o patch?"
AUDIT_PRE="$TMP/audit/rot.jsonl"
printf '%0.s{"pad":"x"}\n' {1..40} > "$AUDIT_PRE"   # ~440 bytes de audit antigo
EXTRA_ENV="AUTONOMY_GUARD_AUDIT_MAX_BYTES=200"
run_hook rot
EXTRA_ENV=""
[ -f "$TMP/audit/rot.jsonl.1" ] && _pass || _fail "29a audit rotacionado para .1 acima do teto"
assert_eq "$(audit_lines)" "1" "29b audit novo começa com só a linha corrente"
# GC: counter de sessão antiga (>30d) removido; marcador .last-gc criado
new_t gc; u "aplica o patch"; at "Quer que eu aplique o patch?"
OLD_CNT="$TMP/audit/block-budget-sess-old.count"; NEW_CNT="$TMP/audit/block-budget-sess-new.count"
echo 1 > "$OLD_CNT"; touch -t 202601010000 "$OLD_CNT"
echo 1 > "$NEW_CNT"
rm -f "$TMP/audit/.last-gc"   # caso 29-rotação já disparou o GC diário; reset p/ testar
run_hook gc
[ ! -f "$OLD_CNT" ] && _pass || _fail "29c counter >30d removido pelo GC"
[ -f "$NEW_CNT" ] && _pass || _fail "29d counter recente preservado"
[ -f "$TMP/audit/.last-gc" ] && _pass || _fail "29e marcador .last-gc criado (GC diário, 1 stat/turno)"

# ═══ US-01 (autonomy-4-melhorias): allowlist cost/credential exige ask_shape ═
# ask_shape = texto stripado termina em '?' OU padrão hot casa. Só as categorias
# 'cost-quota' e 'credential-request' são condicionadas; 'irreversible-production'
# e ALLOWLIST_TOOLS ficam intactas. Fixture 14 (hot 'devo' + custo) é a prova de
# que gate legítimo segue allowlisted (AC4 — já coberta acima).

# ─── 30. Declarativa com vocabulário de custo/cota, sem '?' e sem hot → cold ─
# (caso real dos 3 falsos 'cost-quota' do audit de 2026-07-02)
new_t askcost; u "implementa o detector de quota"
at "Implementei o detector: a leitura da cota vem do arquivo e o custo por chamada é zero. Suíte verde, commit criado."
run_hook askcost
assert_eq "$RC" "0" "30a exit 0"
assert_eq "$OUT" "" "30b stdout vazio"
assert_eq "$(audit_lines)" "0" "30c declarativa de custo/cota → cold, ZERO audit"

# ─── 31. Declarativa com vocabulário de credencial, sem forma interrogativa ──
new_t askcred; u "configura a credencial"
at "Gravei a chave no .env e a autenticação está configurada; o login do serviço já usa o token salvo."
run_hook askcred
assert_eq "$RC" "0" "31a exit 0"
assert_eq "$(audit_lines)" "0" "31b declarativa de credencial → cold, ZERO audit"

# ─── 32. Custo SEM padrão hot mas terminando em '?' → allowlist mantida ──────
new_t asksuffix; u "avalia o tier"
at 'O tier pago custa US$ 20 por mês e dobra a cota. Habilito já?'
run_hook asksuffix
assert_eq "$(audit_lines)" "1" "32a ask_shape via sufixo '?' → allowlist audita"
assert_eq "$(afield '.allowlist_reason')" "cost-quota" "32b reason cost-quota mantida"
assert_eq "$(afield '.decision')" "null" "32c decision null"

# ─── 33. Hot sem '?' + palavra-tema de custo → allowlist (limitação deliberada)
new_t askhot; u "habilita o tier"
at "Quer que eu habilite o tier pago no projeto. Isso muda o custo mensal."
run_hook askhot
assert_eq "$(audit_lines)" "1" "33a ask_shape via padrão hot (sem '?') → allowlist audita"
assert_eq "$(afield '.allowlist_reason')" "cost-quota" "33b reason cost-quota (hot com tema incidental segue imune)"
grep -qi 'ask_shape' "$HOOK" && _pass || _fail "33c fonte documenta o gating ask_shape"

# ─── 34. Declarativa 'irreversível' sem ask_shape → categoria NÃO gated ──────
new_t askirrev; u "aplica a migração"
at "Apliquei a migração de schema; o drop da coluna antiga é irreversível em produção e está documentado no runbook."
run_hook askirrev
assert_eq "$(audit_lines)" "1" "34a irreversible-production não condicionada a ask_shape"
assert_eq "$(afield '.allowlist_reason')" "irreversible-production" "34b reason irreversible-production mantida"
assert_eq "$(afield '.decision')" "null" "34c decision null"

# ─── Summary ─────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo "─── Resultado: $PASS/$TOTAL pass ──────────────────"
if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "$FAILED"
  exit 1
fi
exit 0
