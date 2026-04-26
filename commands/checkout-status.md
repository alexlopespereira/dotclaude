---
description: Mostra estado dos slots — branch, dirty, ahead/behind, label, última atividade
allowed-tools: Bash(bash *), Bash(test *), Bash(chmod *), Read
argument-hint: [repo]
---

Lista o estado de todos os slots em `~/Projects/checkouts/`. Sem argumento mostra todos os pools; com `<repo>` filtra.

## Passos

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/checkout-status.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
bash "$SCRIPT" $ARGUMENTS
```

Reporte a tabela exatamente como o script imprimir.
