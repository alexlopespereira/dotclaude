---
description: Atalho para /checkout-sync-all — auto-detecta o pool a partir do cwd
allowed-tools: Bash(bash *), Bash(test *), Bash(chmod *), Read
argument-hint: [--force] [--no-prune] [<repo>]
---

Sincroniza todos os slots do pool atual com `origin/main`. Se você está em `~/Projects/checkouts/<repo>-N/...`, o pool é inferido automaticamente.

Equivalente a `/checkout-sync-all <repo>` mas sem precisar lembrar o nome.

## Passos

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/sync.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
bash "$SCRIPT" $ARGUMENTS
```

Reporte o resumo (atualizados | pulados | falhas | branches removidas).
