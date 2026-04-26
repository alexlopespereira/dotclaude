---
description: Rotina de manhã — sync de todos os slots + abre abas do terminal
allowed-tools: Bash(bash *), Bash(test *), Bash(chmod *), Bash(ls *), Read
argument-hint: <repo> [--names=A,B,C,D] [--claude] [--skip-permissions|--yolo] [--no-sync]
---

Rotina diária de início de trabalho. Encadeia:

1. `/checkout-sync-all <repo>` — puxa `origin/main` em todos os slots, remove branches mergeadas.
2. `/checkout-launch <repo>` — abre 1 janela com N abas, opcionalmente com `claude --name` por slot.

Use `--no-sync` para pular o sync (ex: já fez de manhã, está só reabrindo).

## Passos

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/morning.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
bash "$SCRIPT" $ARGUMENTS
```

## Exemplos

```
/morning horizons
/morning horizons --claude --names=feature-a,tests,bugfix,spike
/morning horizons --yolo --names=feature-a,tests,bugfix,spike   # claude --dangerously-skip-permissions em cada aba
/morning horizons --no-sync   # já sincronizou, só abre as abas
```
