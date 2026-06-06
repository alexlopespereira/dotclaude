#!/usr/bin/env bash
# spec: US-02-verify-before-handoff-guard
# Regressão do hook PostToolUse hooks/verify-before-handoff-guard.sh (US-02).
# Cada bloco mapeia 1:1 com um AC. AC10.a é [CAT3-MANUAL] (claude --debug em
# sessão real) e fica fora deste teste por design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$SCRIPT_DIR/.."
REPO_DIR="$(cd "$SKILL_DIR/../.." && pwd)"
HOOK="$REPO_DIR/hooks/verify-before-handoff-guard.sh"
REG_JSON="$SKILL_DIR/references/settings-registration.json"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq ausente (necessário p/ AC4/AC6)" >&2; exit 1; }

FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }

WORK="$(mktemp -d -t vbh-guard.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# run_hook <audit_path> <promote_n> <json_payload> → stdout do hook; captura rc em RC.
RC=0
run_hook() {
  local audit="$1" n="$2" payload="$3" out
  out="$(printf '%s' "$payload" | VERIFY_HANDOFF_AUDIT="$audit" VERIFY_HANDOFF_PROMOTE_N="$n" bash "$HOOK" 2>/dev/null)"
  RC=$?
  printf '%s' "$out"
}

# ── AC1: shebang explícito + executável ──────────────────────────────────────
head -1 "$HOOK" | grep -qE '^#!' || fail "AC1: shebang ausente no hook"
[[ -x "$HOOK" ]] || fail "AC1: hook não é executável (chmod +x)"
# AC1 (fail-open / review F1): python3 AUSENTE → no-op exit 0, nunca 127.
# SHIM = PATH curado com coreutils (inclui `cat`, usado p/ montar o heredoc PYCODE)
# MAS sem python3; bash invocado por path absoluto (senão a própria invocação não
# acharia bash no SHIM). Nuke total do PATH NÃO serve: quebraria o `cat` antes do
# guard. Sem o guard `command -v python3 || exit 0`, o `exec python3` daria 127.
fo_shim="$WORK/nopy"; mkdir -p "$fo_shim"
for _b in cat env grep sed awk head; do _p="$(command -v "$_b" 2>/dev/null)"; [[ -n "$_p" ]] && ln -sf "$_p" "$fo_shim/$_b"; done
fo_bash="$(command -v bash)"
fo_out="$(printf '%s' '{"tool_name":"mcp__gmail__send_message","tool_input":{}}' \
  | PATH="$fo_shim" VERIFY_HANDOFF_AUDIT="$WORK/fo.jsonl" "$fo_bash" "$HOOK" 2>/dev/null)"; fo_rc=$?
[[ "$fo_rc" -eq 0 ]] || fail "AC1(fail-open): python3 ausente deveria exit 0, veio $fo_rc"
[[ -z "$fo_out" ]] || fail "AC1(fail-open): python3 ausente deveria no-op (sem output)"

# ── AC2: lê stdin (JSON PostToolUse) e respeita contrato de exit codes ────────
# payload hot MCP → output não-vazio, rc 0.
a2="$WORK/a2.jsonl"
out="$(run_hook "$a2" 2 '{"tool_name":"mcp__gmail__create_draft","tool_input":{"subject":"x"}}')"
[[ "$RC" -eq 0 ]] || fail "AC2: rc esperado 0 em hot, veio $RC"
[[ -n "$out" ]] || fail "AC2: output vazio em payload hot (deveria injetar reminder)"
# JSON inválido na stdin → fail-open, rc 0, sem output.
out="$(printf 'not-json' | VERIFY_HANDOFF_AUDIT="$WORK/a2b.jsonl" bash "$HOOK" 2>/dev/null)"; rc=$?
[[ "$rc" -eq 0 ]] || fail "AC2: rc esperado 0 em JSON inválido (fail-open), veio $rc"
[[ -z "$out" ]] || fail "AC2: output esperado vazio em JSON inválido"

# ── AC3: classificador com 4 fixtures (cada uma com assert) ───────────────────
# (a) Bash 'curl -X POST https://api.externa' → hot
out="$(run_hook "$WORK/a3a.jsonl" 2 '{"tool_name":"Bash","tool_input":{"command":"curl -X POST https://api.externa/x"}}')"
[[ -n "$out" ]] || fail "AC3(a): curl -X POST externo deveria ser hot (output vazio)"
# (b) Bash 'git status' → cold
# Precondição: RC=0 ANTES de assertar output vazio — senão um crash (exit≠0,
# stdout vazio) passaria falsamente sem ter exercido o classificador.
out="$(run_hook "$WORK/a3b.jsonl" 2 '{"tool_name":"Bash","tool_input":{"command":"git status"}}')"
[[ "$RC" -eq 0 ]] || fail "AC3(b): hook crashou (rc=$RC) — cold não exercitado"
[[ -z "$out" ]] || fail "AC3(b): 'git status' deveria ser cold (output não-vazio: $out)"
[[ ! -s "$WORK/a3b.jsonl" ]] || fail "AC3(b): cold não deveria anexar ao audit.jsonl"
# (c) tool MCP '...__create_draft' → hot
out="$(run_hook "$WORK/a3c.jsonl" 2 '{"tool_name":"mcp__claude_ai_Gmail__create_draft","tool_input":{}}')"
[[ -n "$out" ]] || fail "AC3(c): tool MCP __create_draft deveria ser hot (output vazio)"
# (d) 'Read' → cold
out="$(run_hook "$WORK/a3d.jsonl" 2 '{"tool_name":"Read","tool_input":{"file_path":"/x"}}')"
[[ "$RC" -eq 0 ]] || fail "AC3(d): hook crashou (rc=$RC) — cold não exercitado"
[[ -z "$out" ]] || fail "AC3(d): 'Read' deveria ser cold (output não-vazio: $out)"
# bônus: POST contra localhost → cold (não-externo)
out="$(run_hook "$WORK/a3e.jsonl" 2 '{"tool_name":"Bash","tool_input":{"command":"curl -X POST http://localhost:3000/x"}}')"
[[ "$RC" -eq 0 ]] || fail "AC3(bonus): hook crashou (rc=$RC) — cold não exercitado"
[[ -z "$out" ]] || fail "AC3(bonus): POST localhost deveria ser cold"

# ── AC4: append em audit.jsonl = 1 linha JSON válida c/ ts,tool,signature,tier,decision ──
a4="$WORK/a4.jsonl"
run_hook "$a4" 2 '{"tool_name":"mcp__gmail__send_message","tool_input":{}}' >/dev/null
[[ -s "$a4" ]] || fail "AC4: audit.jsonl não foi criado/append em hot"
lines="$(wc -l < "$a4" | tr -d ' ')"
[[ "$lines" == "1" ]] || fail "AC4: esperava 1 linha no audit, veio $lines"
jq -e . "$a4" >/dev/null 2>&1 || fail "AC4: linha do audit não é JSON válido (jq)"
for field in ts tool signature tier decision; do
  v="$(jq -r --arg f "$field" '.[$f] // empty' "$a4")"
  [[ -n "$v" ]] || fail "AC4: campo '$field' ausente/vazio na linha do audit"
done
[[ "$(jq -r '.tool' "$a4")" == "mcp__gmail__send_message" ]] || fail "AC4: campo tool incorreto"
[[ "$(jq -r '.signature' "$a4")" == "mcp__gmail__send_message" ]] || fail "AC4: signature MCP deveria ser o nome da tool"

# ── AC5: promoção soft→hard quando count >= N (N=2 default, configurável) ─────
a5="$WORK/a5.jsonl"
# pré-popula 1 visão prévia da MESMA assinatura (tier soft) → próxima vira a 2ª.
printf '%s\n' '{"ts":"2026-06-06T00:00:00Z","tool":"mcp__gmail__create_draft","signature":"mcp__gmail__create_draft","tier":"soft","decision":"hot"}' > "$a5"
out="$(run_hook "$a5" 2 '{"tool_name":"mcp__gmail__create_draft","tool_input":{}}')"
echo "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 \
  || fail "AC5: 2ª visão (count>=2) deveria promover p/ hard (decision:block). Output: $out"
[[ "$(tail -1 "$a5" | jq -r '.tier')" == "hard" ]] || fail "AC5: linha anexada deveria ter tier=hard"
# N configurável: com N=3, a 2ª visão ainda é soft.
a5b="$WORK/a5b.jsonl"
printf '%s\n' '{"ts":"2026-06-06T00:00:00Z","tool":"mcp__gmail__create_draft","signature":"mcp__gmail__create_draft","tier":"soft","decision":"hot"}' > "$a5b"
out="$(run_hook "$a5b" 3 '{"tool_name":"mcp__gmail__create_draft","tool_input":{}}')"
echo "$out" | jq -e '.hookSpecificOutput.additionalContext != null and .decision == null' >/dev/null 2>&1 \
  || fail "AC5: com N=3 a 2ª visão deveria continuar soft (additionalContext, sem block). Output: $out"

# ── AC6 + AC8: registro canônico — PostToolUse, matcher específico, timeout 5000, path ~/.claude/hooks ──
[[ -f "$REG_JSON" ]] || fail "AC6/AC8: snippet de registro ausente em $REG_JSON"
jq -e . "$REG_JSON" >/dev/null 2>&1 || fail "AC6/AC8: settings-registration.json não é JSON válido"
matcher="$(jq -r '.matcher // empty' "$REG_JSON")"
[[ -n "$matcher" ]] || fail "AC6: matcher vazio/ausente (proibido — DoD T8-b6)"
echo "$matcher" | grep -q 'Bash' || fail "AC6: matcher deveria cobrir Bash"
[[ "$(jq -r '.hooks[0].timeout' "$REG_JSON")" == "5000" ]] || fail "AC6: timeout deveria ser 5000ms (DoD T8-b4)"
cmd="$(jq -r '.hooks[0].command' "$REG_JSON")"
echo "$cmd" | grep -qE '\.claude/hooks/verify-before-handoff-guard\.sh$' \
  || fail "AC8: command deveria apontar p/ ~/.claude/hooks/verify-before-handoff-guard.sh (destino do sync). Veio: $cmd"

# ── AC7: provar o MECANISMO de injeção (Finding #3) ──────────────────────────
# soft entrega via hookSpecificOutput.additionalContext; hard via decision:block (block leve).
out="$(run_hook "$WORK/a7s.jsonl" 2 '{"tool_name":"mcp__gmail__create_draft","tool_input":{}}')"
echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | length > 0)' >/dev/null 2>&1 \
  || fail "AC7: soft deveria injetar via hookSpecificOutput.additionalContext. Output: $out"
a7h="$WORK/a7h.jsonl"
printf '%s\n' '{"signature":"mcp__gmail__create_draft"}' > "$a7h"
out="$(run_hook "$a7h" 2 '{"tool_name":"mcp__gmail__create_draft","tool_input":{}}')"
echo "$out" | jq -e '.decision == "block" and (.reason | length > 0)' >/dev/null 2>&1 \
  || fail "AC7: hard deveria usar decision:block + reason (block leve). Output: $out"
# o hook documenta o mecanismo no header (campo do JSON de saída).
grep -q 'additionalContext' "$HOOK" || fail "AC7: header do hook deveria documentar o campo additionalContext"
grep -qi 'block leve' "$HOOK" || fail "AC7: header do hook deveria documentar o tier hard como block leve"

# ── AC9: header do hook documenta registro machine-local + manual nas VMs ─────
grep -qi 'machine-local' "$HOOK" || fail "AC9: header deveria documentar registro machine-local"
grep -qi 'não viaja no sync\|nao viaja no sync\|à mão\|a mao\|manual' "$HOOK" \
  || fail "AC9: header deveria documentar registro manual (não via sync) nas VMs"

if (( FAIL )); then
  echo "test-hook-guard.sh: FAIL" >&2
  exit 1
fi
echo "test-hook-guard.sh: PASS"
