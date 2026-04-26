---
description: Atualiza TODOS os slots do pool com origin/main (workflow Boris — sincroniza após push num slot)
allowed-tools: Bash(bash *), Bash(test *), Bash(chmod *), Read
argument-hint: <repo> [--force]
---

Roda `git fetch + pull --ff-only origin main` em todos os slots do pool `<repo>`. Pula slots dirty (a menos que `--force`).

## Quando usar

Sempre que você commitou+pushou de um slot e quer que os outros vejam o trabalho antes de começar nova tarefa.

## Passos

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/checkout-sync-all.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
bash "$SCRIPT" $ARGUMENTS
```

Reporte o resumo (atualizados | pulados | falhas).

## Guardrails

- **NUNCA** descarta mudanças sem `--force` explícito.
- Slots em outra branch (não default) pulam ou recebem checkout — script lida.
