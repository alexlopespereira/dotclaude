#!/usr/bin/env bash
# test_interrupcoes_report.sh — testes para bin/interrupcoes-report.sh.
#
# Cobre o comportamento observável (read-only, host-only):
#   T1 — --help responde e documenta o que conta como interrupção; args inválidos
#        → rc=2 (usage no stderr).
#   T2 — detecção: turno terminando em pergunta seguido de prompt REAL vira 1
#        registro; turno seguido de tool_result/<ide_selection>/eco de slash
#        command NÃO conta; turno de conclusão (sem pergunta) NÃO conta.
#   T3 — sinais especiais: AskUserQuestion → kind ask_tool; ExitPlanMode → exit_plan.
#   T4 — isSidechain true é excluído.
#   T5 — --format json/tsv/md: json traz os registros; md agrupa por categoria
#        e marca caixas `[ ]`; --since 0 (sem janela) zera resultados de arquivos
#        antigos via mtime (seam mtime).
#   T6 — categorização: pergunta sobre deploy → externo/billable/deploy.
#
# Estratégia: PR_TRANSCRIPT_DIR aponta para um diretório temporário com .jsonl
# sintéticos controlados (seam de transcripts). Sem rede, sem ssh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IR="$REPO_ROOT/bin/interrupcoes-report.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
assert_grep()   { printf '%s' "$1" | grep -qE -- "$2" && _pass || _fail "$3 :: padrão '$2' ausente em: $(printf '%s' "$1" | head -c 400)"; }
assert_nogrep() { printf '%s' "$1" | grep -qE -- "$2" && _fail "$3 :: padrão '$2' NÃO deveria aparecer" || _pass; }
assert_rc()     { [ "$1" = "$2" ] && _pass || _fail "$3 :: esperado rc=$2 obteve rc=$1"; }
assert_count()  { local n; n=$(printf '%s\n' "$1" | grep -cE -- "$2"); [ "$n" = "$3" ] && _pass || _fail "$4 :: esperado $3 de '$2', obteve $n"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROJ="$WORK/-Users-dev-Projects-demo"
mkdir -p "$PROJ"

# Helper: linhas JSONL. Cada chamada acrescenta uma linha ao arquivo de sessão.
SES="$PROJ/sess.jsonl"
: > "$SES"
add() { printf '%s\n' "$1" >> "$SES"; }

# (a) assistant faz pergunta -> usuário responde de verdade  => CONTA (question)
add '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Terminei a parte 1. Quer que eu siga para a parte 2?"}]},"timestamp":"2099-01-01T10:00:00Z","cwd":"/Users/dev/Projects/demo"}'
add '{"type":"user","message":{"role":"user","content":"sim, segue"}}'

# (b) assistant faz pergunta -> próximo é tool_result  => NÃO conta
add '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Vou ler o arquivo. Posso prosseguir?"},{"type":"tool_use","name":"Read","input":{}}]},"timestamp":"2099-01-01T10:01:00Z"}'
add '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}'

# (c) assistant faz pergunta -> próximo é <ide_selection> (ruído)  => NÃO conta
add '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Pronto. Deseja que eu comece?"}]},"timestamp":"2099-01-01T10:02:00Z"}'
add '{"type":"user","message":{"role":"user","content":"<ide_selection>linha 1 a 5</ide_selection>"}}'

# (d) assistant conclui SEM pergunta -> usuário fala  => NÃO conta
add '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Feito. Tudo commitado e o build passou."}]},"timestamp":"2099-01-01T10:03:00Z"}'
add '{"type":"user","message":{"role":"user","content":"valeu"}}'

# (e) AskUserQuestion  => CONTA (ask_tool)
add '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"Qual banco de dados usar?"}]}}]},"timestamp":"2099-01-01T10:04:00Z"}'
add '{"type":"user","message":{"role":"user","content":"postgres"}}'

# (f) ExitPlanMode  => CONTA (exit_plan)
add '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Plano: passo 1, passo 2."},{"type":"tool_use","name":"ExitPlanMode","input":{}}]},"timestamp":"2099-01-01T10:05:00Z"}'
add '{"type":"user","message":{"role":"user","content":"aprovado"}}'

# (g) pergunta sobre deploy  => CONTA, categoria externo/billable/deploy
add '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"O código está pronto. Quer que eu rode o deploy no Cloud Run agora?"}]},"timestamp":"2099-01-01T10:06:00Z"}'
add '{"type":"user","message":{"role":"user","content":"pode"}}'

# (h) isSidechain (subagente) com pergunta  => NÃO conta
add '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"Subagente: quer que eu continue?"}]},"timestamp":"2099-01-01T10:07:00Z"}'
add '{"type":"user","isSidechain":true,"message":{"role":"user","content":"sim"}}'

export PR_TRANSCRIPT_DIR="$WORK"

# ── T1: help + args inválidos ────────────────────────────────────────────────
H=$(bash "$IR" --help 2>&1); assert_rc $? 0 "T1 help rc"
assert_grep "$H" "interrupç|interrupc" "T1 help menciona interrupções"
bash "$IR" --format xml >/dev/null 2>&1; assert_rc $? 2 "T1 formato inválido rc=2"
bash "$IR" --bogus >/dev/null 2>&1; assert_rc $? 2 "T1 flag desconhecida rc=2"

# ── T2/T3/T4: detecção via json ──────────────────────────────────────────────
J=$(bash "$IR" --since 9999 --format json 2>/dev/null)
# devem contar: (a) question, (e) ask_tool, (f) exit_plan, (g) question(deploy) = 4
assert_count "$J" '"kind"' 4 "T2 total de interrupções = 4"
assert_grep "$J" "Quer que eu siga para a parte 2" "T2a question conta"
assert_nogrep "$J" "Posso prosseguir" "T2b tool_result não conta"
assert_nogrep "$J" "Deseja que eu comece" "T2c ide_selection não conta"
assert_nogrep "$J" "Tudo commitado" "T2d conclusão sem pergunta não conta"
assert_grep "$J" '"ask_tool"' "T3 AskUserQuestion -> ask_tool"
assert_grep "$J" "Qual banco de dados" "T3 texto da AskUserQuestion"
assert_grep "$J" '"exit_plan"' "T3 ExitPlanMode -> exit_plan"
assert_nogrep "$J" "Subagente" "T4 isSidechain excluído"

# ── T5: formatos + janela mtime ──────────────────────────────────────────────
M=$(bash "$IR" --since 9999 --format md 2>/dev/null)
assert_grep "$M" "## externo/billable/deploy" "T5 md agrupa por categoria"
assert_grep "$M" '`\[ \]`' "T5 md tem caixas de rótulo"
assert_grep "$M" "Resumo por categoria" "T5 md tem resumo"
T=$(bash "$IR" --since 9999 --format tsv 2>/dev/null)
assert_grep "$T" "ROTULO" "T5 tsv tem coluna ROTULO"
# --since 0: arquivo tem mtime de agora, então 0 dias ainda inclui; usamos um
# arquivo antigo para validar o corte por mtime.
OLDPROJ="$WORK/-Users-dev-Projects-old"; mkdir -p "$OLDPROJ"
cp "$SES" "$OLDPROJ/old.jsonl"
touch -t 202001010000 "$OLDPROJ/old.jsonl"
J2=$(bash "$IR" --since 7 --format json 2>/dev/null)
assert_count "$J2" '"kind"' 4 "T5 mtime corta arquivo antigo (continua 4, não 8)"

# ── T6: categorização deploy ─────────────────────────────────────────────────
assert_grep "$J" "externo/billable/deploy" "T6 deploy categorizado"

# ── sumário ──────────────────────────────────────────────────────────────────
echo "── test_interrupcoes_report: $PASS passaram, $FAIL falharam ──"
if [ "$FAIL" -gt 0 ]; then printf '%s\n' "$FAILED"; exit 1; fi
exit 0
