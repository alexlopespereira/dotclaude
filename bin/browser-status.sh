#!/usr/bin/env bash
# browser-status.sh — Listagem read-only dos cookies do perfil Chrome dedicado.
#
# Uso: bash browser-status.sh
#
# Operação 100% read-only via URI sqlite3 'mode=ro&immutable=1' — não disputa
# o lock com o MCP (não cria journal/-wal/-shm) nem modifica o DB. Se o MCP
# estiver rodando, o snapshot é coerente mas não captura escritas dos
# últimos segundos (cookies criados imediatamente antes do snapshot podem
# não aparecer).

set -euo pipefail

PROFILE_DIR="$HOME/.claude/chrome-profile"
COOKIES_DB="$PROFILE_DIR/Default/Cookies"
LOCK_PID_FILE="$PROFILE_DIR/.lock/pid"

# Perfil ainda não inicializado: Default/Cookies só existe após a primeira
# subida do MCP Playwright apontando pro --user-data-dir.
if [ ! -f "$COOKIES_DB" ]; then
  echo "Perfil ainda não inicializado: '$COOKIES_DB' não existe."
  echo "O Chrome dedicado é criado na primeira vez que o MCP Playwright sobe."
  exit 0
fi

# Detectar MCP rodando via ~/.claude/chrome-profile/.lock/pid + kill -0.
# Snapshot immutable é coerente mas não vê writes em flight.
if [ -f "$LOCK_PID_FILE" ]; then
  pid=$(cat "$LOCK_PID_FILE" 2>/dev/null || echo "")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "AVISO: MCP rodando: PID $pid — snapshot immutable; cookies criados nos últimos segundos podem não aparecer." >&2
    echo "" >&2
  fi
fi

# Fórmula epoch Chromium → Unix:
#   (ts - 11644473600000000) / 1000000
#   - 11644473600 = segundos entre 1601-01-01 e 1970-01-01
#   - ts é em microssegundos desde 1601-01-01 (Windows FILETIME-like)
sqlite3 "file:${COOKIES_DB}?mode=ro&immutable=1" <<'SQL'
.mode column
.headers on
SELECT
  host_key AS DOMAIN,
  COUNT(*) AS COUNT,
  datetime((MAX(last_access_utc) - 11644473600000000) / 1000000, 'unixepoch', 'localtime') AS LAST_ACCESS,
  CASE
    WHEN MIN(expires_utc) = 0 THEN 'session'
    ELSE date((MIN(expires_utc) - 11644473600000000) / 1000000, 'unixepoch', 'localtime')
  END AS EXPIRES
FROM cookies
GROUP BY host_key
ORDER BY COUNT DESC, DOMAIN ASC;
SQL
