#!/usr/bin/env bash
set -euo pipefail

# bin/dod-add-bullet-ids.sh — adiciona prefixo [bN] aos bullets do DOD.md (US-01).
#
# Para cada bullet `- [ ] ...` dentro de um bloco `### Tarefa N` ou
# `### DoD-base — Categoria N`, prepende `[bN]` (N reseta a cada heading). O match
# de heading é por PREFIXO (sem o sufixo `(usos…)`, removido na migração US-03) —
# AC3 do US-04. A derivação de dod_id continua correta.
#
# US-04: o resync do snapshot `.dod-revision-state.json` foi REMOVIDO — o snapshot
# deixou de existir (US-03 AC6) e nenhum script escreve mais .json de estado (M7);
# os shas dos bullets agora vivem nos eventos `revision` do log append-only.
#
# Idempotente: re-execuções detectam `[b\d+]` no DOD.md e saem com exit 0.
#
# Uso:
#   dod-add-bullet-ids.sh              # aplica migration (default)
#   dod-add-bullet-ids.sh --dry-run    # mostra diff sem mutar
#   dod-add-bullet-ids.sh --help       # esta ajuda
#
# Exit codes:
#   0 — sucesso (migrado, já migrado, ou dry-run)
#   1 — uso inválido / estado inesperado do arquivo
#   3 — lock ocupado após retry

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
REFERENCES_DIR="$SKILL_DIR/references"
DOD_FILE="$REFERENCES_DIR/DOD.md"
LOCK_DIR="$REFERENCES_DIR/.dod-add-bullet-ids.lock"

TMP_DOD=""
LOCK_HELD=0

cleanup() {
  [[ -n "$TMP_DOD" && -e "$TMP_DOD" ]] && rm -f "$TMP_DOD"
  # Só remove o lock se ESTE processo o adquiriu (mesmo padrão dos dod-*.sh).
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

show_help() {
  cat <<'EOF'
dod-add-bullet-ids — adiciona prefixo [bN] aos bullets do DOD.md e
                     resincroniza bullets_sha256 no snapshot.

uso:
  dod-add-bullet-ids.sh              aplica migration (default)
  dod-add-bullet-ids.sh --dry-run    mostra diff sem mutar arquivos
  dod-add-bullet-ids.sh --help       esta ajuda

efeito:
  - DOD.md: cada bullet '- [ ]' dentro de '### Tarefa N' ou
    '### DoD-base — Categoria N' ganha prefixo [bN] (numeração reseta no
    próximo heading).
  - DoD-base Categoria 1 b4 ganha sufixo '(prefix `[US-XX]` aceito quando
    gerado pelo Ralph)' — aprendizado meta do PR #27.

idempotente: 2º run detecta o prefixo [bN] e sai com exit 0.
EOF
}

DRY_RUN=0
case "${1:-}" in
  ""        ) ;;
  --help|-h ) show_help; exit 0 ;;
  --dry-run ) DRY_RUN=1 ;;
  *         ) echo "uso desconhecido: $1" >&2; show_help >&2; exit 1 ;;
esac

# Lock via mkdir (atomic POSIX; macOS-compatible — fd-lock indisponível no Darwin)
attempts=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
  attempts=$((attempts + 1))
  if [[ $attempts -ge 50 ]]; then
    echo "erro: lock $LOCK_DIR ocupado após 5s; rodar de novo após o outro processo liberar" >&2
    exit 3
  fi
  sleep 0.1
done
LOCK_HELD=1

# Idempotência: bullets já têm prefixo [bN] → nada a fazer.
if grep -qE '^- \[ \] \[b[0-9]+\] ' "$DOD_FILE"; then
  echo "já migrado: prefixo [bN] presente em $DOD_FILE"
  exit 0
fi

# Awk-stateful: prepende [bN] aos bullets dentro de cada bloco Tarefa/DoD-base.
# Também aplica AC10 — string-match exato no bullet b4 da DoD-base Cat 1.
TMP_DOD="$(mktemp "$REFERENCES_DIR/.dod-add-bullet-ids.tmp.XXXXXX")"
AC10_OLD="- [ ] [b4] commitado em git com mensagem \`feat(claude): ...\`"
AC10_NEW="- [ ] [b4] commitado em git com mensagem \`feat(claude): ...\` (prefix \`[US-XX]\` aceito quando gerado pelo Ralph)"

awk -v ac10_old="$AC10_OLD" -v ac10_new="$AC10_NEW" '
  BEGIN {
    in_block = 0
    in_cat1_base = 0
    bn = 0
  }
  /^### Tarefa [0-9]+ — / {
    in_block = 1
    in_cat1_base = 0
    bn = 0
    print
    next
  }
  /^### DoD-base — Categoria [0-9]+/ {
    in_block = 1
    # AC3 (US-04): casa "Categoria 1" seguido de espaço (sufixo pré-strip) OU
    # fim-de-linha (heading source-puro pós-US-03). Antes exigia o espaço do
    # sufixo `(usos…)` → quebrava no DOD.md strippado. `1$|1[ ]` não casa "10"+.
    in_cat1_base = ($0 ~ /^### DoD-base — Categoria 1([ ]|$)/)
    bn = 0
    print
    next
  }
  /^### / || /^## / {
    in_block = 0
    in_cat1_base = 0
    bn = 0
    print
    next
  }
  {
    if (in_block && match($0, /^- \[ \] /)) {
      bn += 1
      rest = substr($0, RLENGTH + 1)
      new_line = sprintf("- [ ] [b%d] %s", bn, rest)
      if (in_cat1_base && new_line == ac10_old) {
        print ac10_new
      } else {
        print new_line
      }
      next
    }
    print
  }
' "$DOD_FILE" > "$TMP_DOD"

# Validação: contagem de markers no migrado deve casar com a contagem original
# de bullets (170 esperado). AC7 exige ≥100.
orig_bullets=$(grep -cE '^- \[ \] ' "$DOD_FILE" || true)
new_markers=$(grep -cE '^- \[ \] \[b[0-9]+\] ' "$TMP_DOD" || true)
if [[ "$new_markers" -ne "$orig_bullets" ]]; then
  echo "erro: $new_markers bullets marcados, esperado $orig_bullets (drift no awk)" >&2
  exit 1
fi
if [[ "$new_markers" -lt 100 ]]; then
  echo "erro: $new_markers bullets marcados; AC7 exige ≥100" >&2
  exit 1
fi

# AC10 sanity check: o sufixo deve estar presente em exatamente 1 linha.
# shellcheck disable=SC2016  # literal com backticks/brackets — aspas simples são intencionais
ac10_hits=$(grep -cF '(prefix `[US-XX]` aceito quando gerado pelo Ralph)' "$TMP_DOD" || true)
if [[ "$ac10_hits" -ne 1 ]]; then
  echo "erro: AC10 sufixo presente em $ac10_hits linhas (esperado 1)" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  diff -u "$DOD_FILE" "$TMP_DOD" || true
  echo "--- dry-run: nada gravado em disco ---"
  exit 0
fi

# Write atômico: mv dentro do mesmo filesystem.
mv "$TMP_DOD" "$DOD_FILE"
TMP_DOD=""

# US-04: sem resync de snapshot (.dod-revision-state.json removido em US-03; M7).
# A única regex que exigia o sufixo `(usos…)` vivia aqui — eliminá-la satisfaz o
# AC3 sem quebrar a derivação de dod_id (o match de heading do [bN] acima é por
# prefixo). Os shas dos bullets passam a viver nos eventos `revision` do log.
final_bn=$(grep -cE '^- \[ \] \[b[0-9]+\] ' "$DOD_FILE" || true)
echo "migrado: $final_bn bullets numerados (snapshot .json aposentado — US-03/US-04)"
