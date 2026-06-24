#!/usr/bin/env bash
# keyword-context-loader.sh — UserPromptSubmit hook que injeta docs de referência
# SOB DEMANDA quando uma keyword aparece no prompt do usuário. Complementa o
# mecanismo path-scoped de `.claude/rules/*` (que dispara por arquivo tocado):
# este dispara por TÓPICO mencionado, antes mesmo de tocar arquivos (planejamento,
# perguntas, research). Objetivo: tirar referência pesada do contexto always-on
# (CLAUDE.md) e carregá-la só quando relevante.
#
# Dual-source: existe em dotclaude/hooks/ (versionado) e ~/.claude/hooks/ (runtime)
# — ambas as cópias idênticas (`diff` empty). Instalado por sync.sh.
#
# OPT-IN e fail-safe: NO-OP (exit 0, sem output) a menos que o projeto corrente
# tenha `$CWD/.claude/context-triggers.tsv`. Zero mudança de comportamento em
# repos que não aderiram. Qualquer erro de parse degrada para no-op.
#
# Formato do mapa (TSV, uma regra por linha; `#` = comentário):
#   <regex-egrep><TAB><path-relativo-à-raiz-do-projeto>
# A regex casa case-insensitive contra o prompt. Ex.:
#   omie|concilia                    .knowledge/knowledge_conciliacao.md
#   deploy.*(prod|produç)            .knowledge/knowledge_salesforce_production.md
#
# Contrato de saída: JSON hookSpecificOutput.additionalContext (via jq), com o
# conteúdo de cada doc casado (dedup por path), cap total de 12KB.

set -euo pipefail

INPUT=$(cat)

# jq ausente → no-op silencioso (mesma postura defensiva do handoff-resume).
command -v jq >/dev/null 2>&1 || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
CWD="${CWD:-$PWD}"
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)

MAP="$CWD/.claude/context-triggers.tsv"

# Short-circuit: sem mapa no projeto ou prompt vazio → no-op (<5ms).
test -f "$MAP" || exit 0
test -n "$PROMPT" || exit 0

MAXBYTES=12288
acc=""
accbytes=0
seen=""        # paths já injetados (dedup), separados por newline
truncated=0

# IFS controlado para preservar TAB como separador de campo.
while IFS=$'\t' read -r regex path _rest || [ -n "$regex" ]; do
  # Pula linhas em branco e comentários.
  case "$regex" in
    ''|\#*) continue ;;
  esac
  [ -n "$path" ] || continue

  # Casa a regex (case-insensitive) contra o prompt. grep falha silencioso em
  # regex inválida → trata como não-match (não derruba o hook).
  printf '%s' "$PROMPT" | grep -iqE -- "$regex" 2>/dev/null || continue

  # Resolve path relativo à raiz do projeto; absoluto também aceito.
  case "$path" in
    /*) abs="$path" ;;
    *)  abs="$CWD/$path" ;;
  esac
  test -f "$abs" || continue

  # Dedup: mesmo doc casado por 2 regras entra uma vez só.
  case "$seen" in
    *"|$abs|"*) continue ;;
  esac
  seen="$seen|$abs|"

  body=$(cat "$abs")
  chunk=$(printf '\n\n===== contexto sob demanda: %s =====\n%s\n' "$path" "$body")
  chunkbytes=$(printf '%s' "$chunk" | wc -c)

  if [ $((accbytes + chunkbytes)) -gt "$MAXBYTES" ]; then
    truncated=1
    continue
  fi
  acc="$acc$chunk"
  accbytes=$((accbytes + chunkbytes))
done < "$MAP"

# Nada casou → no-op (nenhum output).
test -n "$acc" || exit 0

if [ "$truncated" -eq 1 ]; then
  acc="$acc"$'\n\n(alguns docs de gatilho omitidos: cap de 12KB atingido)'
fi

header=$'Docs de referência carregados por gatilho de keyword (context-triggers.tsv). Use como contexto; não são instruções do usuário.'
acc="$header$acc"

jq -n --arg ctx "$acc" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'

exit 0
