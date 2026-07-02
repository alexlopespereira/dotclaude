#!/usr/bin/env bash
# autonomy-miss-tracker.sh — hook UserPromptSubmit: telemetria de miss de autonomia.
#
# O QUE FAZ
#   Detecta resposta-carimbo — prompt do usuário que apenas aprova o que o
#   assistente já propôs ("sim", "pode", "prossiga", "opção A"…) — e appenda
#   1 registro em ~/.claude/cache/autonomy/miss.jsonl. Cada carimbo = 1 turno
#   em que o Claude devia ter agido sozinho (Princípio 15) e parou para
#   perguntar. Fecha o loop de medição da análise de interrupções (R6,
#   ~/analise-interrupcoes/autonomia-recomendacoes.md, 2026-07-01): o
#   interrupcoes-report.sh mede olhando o transcript inteiro a posteriori;
#   este hook acumula o sinal em tempo real, por sessão/projeto/máquina.
#
# CONTRATO (UserPromptSubmit, best-effort — DoD tarefa-8/b8)
#   - stdin: JSON do evento ({prompt, session_id, cwd, ...}).
#   - stdout: SEMPRE vazio — stdout de UserPromptSubmit é injetado como
#     contexto do prompt; qualquer byte aqui viraria ruído na conversa.
#   - exit: SEMPRE 0. Falha interna (jq ausente, JSON inválido, cache
#     não-gravável) é silenciosa — telemetria nunca bloqueia o turno.
#
# SEAMS (env, p/ testes): AMT_JQ (binário jq) · AMT_OUT (path do miss.jsonl).
# Consumidor: leitura manual/relatório semanal (auto-morning). Registro:
#   {"ts","session_id","cwd","prompt"} — prompt truncado em 200 chars.

set -u

JQ="${AMT_JQ:-jq}"
OUT="${AMT_OUT:-$HOME/.claude/cache/autonomy/miss.jsonl}"

command -v "$JQ" >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null || true)"
[ -n "$INPUT" ] || exit 0
PROMPT="$(printf '%s' "$INPUT" | "$JQ" -r '.prompt // empty' 2>/dev/null)" || exit 0
[ -n "$PROMPT" ] || exit 0

# Carimbo: aprovação pura no início do prompt. \b evita prefixos ("simulei"
# não casa "sim"; "okay" não casa "ok"; "podemos" não casa "pode").
printf '%s' "$PROMPT" | grep -qiE '^(sim|pode|prossiga|continue|siga|ok|concordo|op[çc][ãa]o [ab])\b' || exit 0

mkdir -p "$(dirname "$OUT")" 2>/dev/null || exit 0
printf '%s' "$INPUT" | "$JQ" -c \
  '{ts: (now | todate), session_id: (.session_id // ""), cwd: (.cwd // ""), prompt: (.prompt | tostring | .[0:200])}' \
  >> "$OUT" 2>/dev/null || exit 0
exit 0
