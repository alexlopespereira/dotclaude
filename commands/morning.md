---
description: Rotina de manhã — sync de todos os slots + abre abas do terminal
allowed-tools: Bash(bash *), Bash(test *), Bash(chmod *), Bash(ls *), Read
argument-hint: <repo> [--names=A,B,C,D] [--claude] [--skip-permissions|--yolo] [--no-sync]
---

Rotina diária de início de trabalho. Encadeia:

1. **Reflexões pendentes** — lê `~/.claude/cache/reflect/reminders.jsonl` (baselines do `/reflect`) e exibe `N baselines aguardando retro (mais antiga: D+X)` quando há entradas, lembrando de rodar `/reflect <pr> --retro` em PRs ≥ D+7.
2. `/checkout-sync-all <repo>` — puxa `origin/main` em todos os slots, remove branches mergeadas.
3. `/checkout-launch <repo>` — abre 1 janela com N abas, opcionalmente com `claude --name` por slot.

Use `--no-sync` para pular o sync (ex: já fez de manhã, está só reabrindo).

## Passos

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/morning.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
bash "$SCRIPT" $ARGUMENTS
```

## Exemplos

```
/morning storefront
/morning storefront --claude --names=feature-a,tests,bugfix,spike
/morning storefront --yolo --names=feature-a,tests,bugfix,spike   # claude --dangerously-skip-permissions em cada aba
/morning storefront --no-sync   # já sincronizou, só abre as abas
```
