#!/usr/bin/env bash
# auto-morning.sh — Wrapper executado pelo LaunchAgent ao login do macOS.
# Edite os argumentos abaixo para customizar o que abrir automaticamente.
#
# Logs em ~/.claude/cache/auto-morning.log

set -uo pipefail

# Seams de teste (env) — defaults = comportamento de produção.
#   AM_LOG           path do log (default ~/.claude/cache/auto-morning.log)
#   AM_VM_MORNING    wrapper que abre as sessões VM (default vm-morning.sh)
#   AM_REFLECT_RETRO drenador de retros vencidas (default bin/reflect-retro-due.sh)
#   AM_BACKLOG_DISPATCH dispatcher de backlog entre repos (default bin/backlog-dispatch.sh)
#   AM_INTERRUPCOES  gerador do relatório de interrupções (default bin/interrupcoes-report.sh)
#   AM_AUTONOMY_CACHE dir do stamp/output do relatório semanal (default ~/.claude/cache/autonomy)
#   AM_SKIP_WAIT     1 = pula a espera por iTerm/Dock (testes não dependem da UI)
LOG="${AM_LOG:-$HOME/.claude/cache/auto-morning.log}"
mkdir -p "$(dirname "$LOG")"

{
  echo "═══ $(date -u +%Y-%m-%dT%H:%M:%SZ) — auto-morning iniciando ═══"

  # PATH explícito (LaunchAgent não herda do shell)
  export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  # Aguarda iTerm e Dock estarem prontos (até 30s)
  if [ "${AM_SKIP_WAIT:-0}" != "1" ]; then
    for _ in $(seq 1 30); do
      if pgrep -x Dock >/dev/null && [ -d /Applications/iTerm.app ]; then
        break
      fi
      sleep 1
    done
  fi

  # ============== CUSTOMIZE AQUI ==============
  # O trabalho (storefront/etl-crm/wikiapp) migrou pras VMs UTM. Em vez de
  # abrir abas em checkouts locais (morning.sh), abrimos sessões SSH+Claude nas
  # VMs via vm-morning.sh. Edite a lista de abas no topo desse script.
  VM_MORNING="${AM_VM_MORNING:-$HOME/Projects/dotclaude/vm-morning.sh}"
  REFLECT_RETRO="${AM_REFLECT_RETRO:-$HOME/Projects/dotclaude/bin/reflect-retro-due.sh}"
  BACKLOG_DISPATCH="${AM_BACKLOG_DISPATCH:-$HOME/Projects/dotclaude/bin/backlog-dispatch.sh}"
  # =============================================

  if [ ! -x "$VM_MORNING" ]; then
    echo "ERRO: vm-morning.sh não encontrado/executável em $VM_MORNING." >&2
    exit 1
  fi

  echo "→ executando: $VM_MORNING"
  bash "$VM_MORNING"

  # Drena retrospectivas /reflect vencidas (headless), non-blocking: uma falha
  # aqui NÃO derruba o auto-morning. O PATH explícito acima (inclui ~/.local/bin)
  # já alcança o `claude` que o script resolve internamente.
  if [ -x "$REFLECT_RETRO" ]; then
    echo "→ drenando retros vencidas: $REFLECT_RETRO --max 2"
    bash "$REFLECT_RETRO" --max 2 || true
  else
    echo "→ reflect-retro-due.sh ausente/não-executável em $REFLECT_RETRO — pulado."
  fi

  # Drena a fila de backlog entre repos (headless, non-blocking): despacha até 2
  # ciclos /full-cycle-simple em slots livres do pool. PARA no PR aberto sem
  # auto-merge (nada integra sem humano). Uma falha aqui NÃO derruba o
  # auto-morning (|| true).
  if [ -x "$BACKLOG_DISPATCH" ]; then
    echo "→ drenando backlog: $BACKLOG_DISPATCH --max 2"
    bash "$BACKLOG_DISPATCH" --max 2 || true
  else
    echo "→ backlog-dispatch.sh ausente/não-executável em $BACKLOG_DISPATCH — pulado."
  fi

  # Relatório semanal de interrupções (R6 da análise de autonomia, 2026-07-01):
  # taxa de perguntas auto-aprováveis por máquina, meta <10/dia nas VMs. Roda no
  # máximo 1×/semana (stamp por mtime); falha NÃO grava o stamp (re-tenta na
  # manhã seguinte) e NÃO derruba o auto-morning.
  INTERRUPCOES="${AM_INTERRUPCOES:-$HOME/Projects/dotclaude/bin/interrupcoes-report.sh}"
  AUTONOMY_CACHE="${AM_AUTONOMY_CACHE:-$HOME/.claude/cache/autonomy}"
  IR_STAMP="$AUTONOMY_CACHE/last-weekly-report"
  IR_OUT="$AUTONOMY_CACHE/interrupcoes-7d.md"
  if [ -x "$INTERRUPCOES" ]; then
    if [ ! -f "$IR_STAMP" ] || [ -n "$(find "$IR_STAMP" -mtime +6 2>/dev/null)" ]; then
      echo "→ relatório semanal de autonomia (meta <10 interrupções/dia nas VMs)"
      mkdir -p "$AUTONOMY_CACHE"
      if bash "$INTERRUPCOES" --since 7 \
           --remote vm1=dev@192.0.2.11 --remote vm2=dev@192.0.2.12 \
           --format md --out "$IR_OUT"; then
        touch "$IR_STAMP"
        grep -m1 '^Total:' "$IR_OUT" || true
      else
        echo "→ relatório de interrupções falhou — stamp não gravado, re-tenta amanhã."
      fi
    else
      echo "→ relatório semanal de autonomia: stamp fresco (<7d) — pulado."
    fi
  else
    echo "→ interrupcoes-report.sh ausente/não-executável em $INTERRUPCOES — pulado."
  fi

  echo "═══ concluído ═══"
} >> "$LOG" 2>&1
