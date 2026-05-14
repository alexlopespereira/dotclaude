---
description: Inspeciona o audit log do supply-chain-guard (decisões últimos 7d, bypasses, cache stats) — saída legível pra humano
---

# /supply-chain-audit

Lê `~/.claude/cache/supply-chain/audit.jsonl` produzido pelo hook `supply-chain-guard.sh` (US-05) e gera um relatório curto com:

- Total de decisões nos últimos 7 dias
- Breakdown por `decision` (allow / block / bypass)
- Lista de **bypasses recentes** com timestamp, comando e `CLAUDE_SC_REASON`
- Proxy de cache hit-rate (contagem de arquivos em `registry-times/`)
- Top 5 motivos de bloqueio

Argumento opcional `<N>`: número de entradas mais recentes a inspecionar (default 50).

## O que executar

Roda este bloco bash e mostra a saída ao usuário (apenas reformatando se necessário):

```bash
LOG="${SC_AUDIT_LOG:-${SC_CACHE_DIR:-$HOME/.claude/cache/supply-chain}/audit.jsonl}"
CACHE_DIR="${SC_CACHE_DIR:-$HOME/.claude/cache/supply-chain}/registry-times"
N="${1:-50}"

echo "═══════════════════════════════════════════════════════════"
echo "  /supply-chain-audit — relatório"
echo "═══════════════════════════════════════════════════════════"
echo ""

if [ ! -f "$LOG" ]; then
  echo "Audit log ausente em $LOG"
  echo "  • Hook ainda não foi acionado por nenhum Bash tool call."
  echo "  • OU SC_AUDIT_LOG aponta pra outro caminho."
  echo ""
  echo "Skill: ~/.claude/skills/supply-chain-guard/SKILL.md"
  exit 0
fi

TOTAL=$(wc -l < "$LOG" | tr -d ' ')
echo "Total de decisões no log: $TOTAL"
echo "Log: $LOG"
echo ""

# Últimos 7 dias (epoch comparison via date)
SEVEN_AGO=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
RECENT=$(jq -c --arg cut "$SEVEN_AGO" 'select(.ts >= $cut)' "$LOG")
N_RECENT=$(printf '%s\n' "$RECENT" | grep -c . || echo 0)

echo "── Últimos 7 dias ($N_RECENT decisões) ──"
if [ "$N_RECENT" -gt 0 ]; then
  printf '%s\n' "$RECENT" | jq -r '.decision' | sort | uniq -c | sort -rn | awk '{printf "  %s: %s\n", $2, $1}'
else
  echo "  (nenhuma decisão nos últimos 7 dias)"
fi
echo ""

echo "── Últimas $N entradas (todas decisões) ──"
tail -n "$N" "$LOG" | jq -r '
  "[\(.ts)] \(.decision | ascii_upcase) | \(.command[0:80])\(if (.command | length) > 80 then "…" else "" end)" +
  (if .reason then " — \(.reason[0:60])\(if (.reason | length) > 60 then "…" else "" end)" else "" end)
'
echo ""

echo "── Bypasses recentes (auditar REASON) ──"
BYPASSES=$(jq -c 'select(.decision == "bypass")' "$LOG" | tail -20)
if [ -n "$BYPASSES" ]; then
  printf '%s\n' "$BYPASSES" | jq -r '
    "  \(.ts)\n    cmd: \(.command)\n    why: \(.reason // "(none)")"
  '
else
  echo "  (nenhum bypass registrado)"
fi
echo ""

echo "── Top 5 motivos de bloqueio ──"
BLOCKS=$(jq -c 'select(.decision == "block")' "$LOG")
if [ -n "$BLOCKS" ]; then
  printf '%s\n' "$BLOCKS" \
    | jq -r '.reason // ""' \
    | tr ';' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' \
    | sort | uniq -c | sort -rn | head -5 \
    | awk '{count=$1; $1=""; printf "  %4d × %s\n", count, $0}'
else
  echo "  (nenhum bloqueio)"
fi
echo ""

echo "── Cache stats (proxy hit-rate) ──"
if [ -d "$CACHE_DIR" ]; then
  N_NPM=$(find "$CACHE_DIR/npm" -name '*.iso' 2>/dev/null | wc -l | tr -d ' ')
  N_PYPI=$(find "$CACHE_DIR/pypi" -name '*.iso' 2>/dev/null | wc -l | tr -d ' ')
  echo "  npm timestamps cached:  $N_NPM"
  echo "  pypi timestamps cached: $N_PYPI"
  echo "  cache dir: $CACHE_DIR"
else
  echo "  (cache dir não existe — provavelmente nenhum cooldown lookup feito)"
fi
echo ""

echo "── Histórico de rotação ──"
LOG_DIR=$(dirname "$LOG")
LOG_BASE=$(basename "$LOG" .jsonl)
ROTATED=$(ls "$LOG_DIR"/"$LOG_BASE"-*.jsonl 2>/dev/null | wc -l | tr -d ' ')
echo "  Arquivos históricos: $ROTATED (max 5 mantidos)"
echo ""

echo "Para configurar bypass / desativar hook: ~/.claude/skills/supply-chain-guard/SKILL.md"
```

## Como usar a saída

- **Decisões "block" frequentes** com mesmo motivo: indica padrão. Investigar se a política está calibrada ou se há falso positivo.
- **Bypasses com REASON genérico** ("test", "bypass", "ok"): abuse. Refinar política ou bloquear o REASON-pattern.
- **Cache muito vazio**: hook está sendo bypassado por outro caminho, ou nada de install está rodando — verificar.
- **N_RECENT alto** comparado a histórico: pode indicar nova fase de trabalho (clonando muitos projetos) ou ataque tentando exfiltrar.

## Referências

- Hook: `~/.claude/hooks/supply-chain-guard.sh`
- Skill: `~/.claude/skills/supply-chain-guard/SKILL.md`
- ADR: `docs/adr/0002-supply-chain-cooldown-gate.md`
- Princípio 13: `~/.claude/CLAUDE.md`
