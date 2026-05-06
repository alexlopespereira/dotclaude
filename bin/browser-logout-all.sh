#!/usr/bin/env bash
# browser-logout-all.sh — Limpa cookies HTTP do perfil Chrome dedicado.
#
# Uso:
#   bash browser-logout-all.sh             # preview (read-only)
#   bash browser-logout-all.sh --confirm   # executa DELETE + VACUUM
#
# Operação destrutiva exige MCP encerrado (lock liberado). Cookies-only:
# Local Storage, IndexedDB e cache não são afetados.

set -euo pipefail

PROFILE_DIR="$HOME/.claude/chrome-profile"
COOKIES_DB="$PROFILE_DIR/Default/Cookies"
LOCK_PID_FILE="$PROFILE_DIR/.lock/pid"

WARNING_MSG="Apenas cookies HTTP foram listados/removidos. Local Storage, IndexedDB, e cache do browser NÃO são afetados. Para limpeza total, encerre o MCP e remova ~/.claude/chrome-profile/."

# Único argumento aceito: --confirm. Qualquer outra coisa é erro.
CONFIRM=0
case "${1:-}" in
  "")          CONFIRM=0 ;;
  "--confirm") CONFIRM=1 ;;
  *)
    echo "ERRO: argumento desconhecido '$1'. Único arg aceito: --confirm." >&2
    exit 2
    ;;
esac
if [ "${2:-}" != "" ]; then
  echo "ERRO: argumento extra '$2'. Único arg aceito: --confirm." >&2
  exit 2
fi

# Perfil ainda não inicializado = no-op gracioso.
if [ ! -f "$COOKIES_DB" ]; then
  echo "Perfil ainda não inicializado: '$COOKIES_DB' não existe."
  echo "Nada a fazer."
  echo ""
  echo "$WARNING_MSG"
  exit 0
fi

# Snapshot count: URI 'mode=ro&immutable=1' ignora o WAL e não disputa lock —
# usado APENAS no preview (MCP pode estar rodando). Pode subestimar o total
# quando há cookies em WAL não-checkpointed (ex: MCP escreveu há segundos).
count_cookies_snapshot() {
  sqlite3 "file:${COOKIES_DB}?mode=ro&immutable=1" "SELECT COUNT(*) FROM cookies;" 2>/dev/null || echo "?"
}

# Live count: 'mode=ro' SEM immutable respeita o WAL committed e reflete o
# estado real. Use APENAS após o lock check passar — leitura concorrente
# enquanto o MCP escreve cria shm/wal pode disputar lock.
count_cookies_live() {
  sqlite3 "file:${COOKIES_DB}?mode=ro" "SELECT COUNT(*) FROM cookies;" 2>/dev/null || echo "?"
}

# Avalia o lock e popula LOCK_STATUS (vazio = livre, "PID=N" = vivo).
LOCK_STATUS=""
if [ -f "$LOCK_PID_FILE" ]; then
  lock_pid=$(cat "$LOCK_PID_FILE" 2>/dev/null || echo "")
  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
    LOCK_STATUS="$lock_pid"
  fi
fi

if [ "$CONFIRM" -ne 1 ]; then
  # Preview: snapshot count (não disputa lock; pode subestimar se há WAL).
  current_count=$(count_cookies_snapshot)
  echo "Preview — /browser-logout-all (sem --confirm)"
  echo ""
  echo "  Cookies atualmente: $current_count (snapshot — pode subestimar se MCP escreveu há segundos)"
  echo "  Banco:              $COOKIES_DB"
  echo ""
  if [ -n "$LOCK_STATUS" ]; then
    echo "  ⚠ MCP rodando: PID $LOCK_STATUS — operação destrutiva exige MCP encerrado."
  else
    echo "  Lock liberado."
  fi
  echo ""
  echo "Para executar a limpeza, re-rode com:"
  echo "  bash $0 --confirm"
  echo ""
  echo "$WARNING_MSG"
  exit 0
fi

# CONFIRM=1 daqui pra baixo: operação destrutiva.

# Aborta se MCP vivo (concorrência destrutiva quebra o DB).
if [ -n "$LOCK_STATUS" ]; then
  echo "ERRO: MCP rodando (PID $LOCK_STATUS). Encerre a sessão Claude Code que está usando o browser e tente de novo." >&2
  echo "" >&2
  echo "$WARNING_MSG" >&2
  exit 1
fi

# Lock liberado: count via mode=ro (não immutable) reflete WAL committed.
# Sem este reorder, immutable=1 podia retornar 0 com cookies pendentes em
# WAL e o early-exit "cookies já vazio" pularia o checkpoint+DELETE+VACUUM,
# deixando dados em WAL que reapareceriam na próxima subida do MCP.
current_count=$(count_cookies_live)

# Cookies vazio = no-op gracioso.
if [ "$current_count" = "0" ]; then
  echo "Cookies já vazio (count=0). Nada a fazer."
  echo ""
  echo "$WARNING_MSG"
  exit 0
fi

# Sequência destrutiva em batch (1 invocação sqlite3):
#   1. wal_checkpoint(TRUNCATE) — drena WAL pendente pro DB principal
#      e zera o arquivo -wal antes de deletar.
#   2. DELETE FROM cookies — remove todas as linhas.
#   3. VACUUM — DELETE só marca páginas como livres, não shrinka o arquivo;
#      VACUUM rebuilda o DB recuperando o espaço em disco (relevante quando
#      o perfil acumulou MBs de cookies).
# stdout do sqlite3 é descartado (PRAGMA wal_checkpoint retorna 3 colunas
# busy/log/checkpointed que não interessam ao usuário); stderr passa pra
# preservar erros, e `set -e` aborta se sqlite3 retornar exit != 0.
sqlite3 "$COOKIES_DB" >/dev/null <<'SQL'
PRAGMA wal_checkpoint(TRUNCATE);
DELETE FROM cookies;
VACUUM;
SQL

new_count=$(count_cookies_live)

echo "Limpeza concluída."
echo "  Antes:  $current_count"
echo "  Depois: $new_count"
echo ""
echo "$WARNING_MSG"
