#!/usr/bin/env bash
# handoff-resume.sh — SessionStart hook que re-injeta um handoff pendente
# como additionalContext na nova sessão (pós-/clear ou nova sessão).
#
# Dual-source: este script existe em /Users/dev/Projects/dotclaude/hooks/
# (versionado) e em ~/.claude/hooks/ (runtime) — ambas as cópias devem ter
# conteúdo idêntico (`diff` retorna empty). Acoplado a /handoff-continue.
#
# Contrato: lê $CWD/.claude/handoff-pending (uma linha = path absoluto do
# handoff doc), emite via JSON construído com jq, move o ponteiro para
# .consumed.<unix-ts> para evitar re-injeção.

set -euo pipefail

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)
CWD="${CWD:-$PWD}"

PTR="$CWD/.claude/handoff-pending"

# Short-circuit: sem ponteiro, hook é no-op (<5ms).
test -f "$PTR" || exit 0

HANDOFF=$(cat "$PTR")
TS=$(date -u +%s)

# Ponteiro órfão (handoff doc foi removido): consome silencioso e sai.
# Usamos `mv` para .consumed.orphan.<ts> em vez de `rm` para manter AC12
# (script depende apenas de bash, test, cat, jq, mv, wc, date).
if ! test -f "$HANDOFF"; then
  mv "$PTR" "$PTR.consumed.orphan.$TS"
  exit 0
fi

# Cap 10KB: warn em stderr mas NÃO aborta (usuário decide).
SIZE=$(wc -c < "$HANDOFF")
if [ "$SIZE" -gt 10240 ]; then
  printf 'handoff-resume.sh: warning: handoff doc %s tem %s bytes (> 10240) — contexto grande pode poluir a sessão\n' "$HANDOFF" "$SIZE" >&2
fi

CTX=$(cat "$HANDOFF")

# JSON via jq (NUNCA string templating — handoff em Markdown contém aspas,
# backticks e newlines que quebrariam templating manual).
jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'

# Move ponteiro para .consumed.<ts> — previne re-injeção em /clear subsequentes
# dentro do mesmo cwd. Garbage collect manual quando necessário.
mv "$PTR" "$PTR.consumed.$TS"

exit 0
