---
description: Prepara um slot para trabalho — atualiza main, NÃO cria branch (modelo trunk-based Boris)
allowed-tools: Bash(bash *), Bash(chmod *), Bash(test *), Read
argument-hint: <repo> <slot> [label]
---

Prepara o slot `<slot>` do pool `<repo>` para uma sessão de trabalho. **Não cria branch** — todo trabalho acontece direto em `main`. Apenas:

1. Verifica que slot está limpo e em `main`.
2. Atualiza `main` via `git pull --ff-only origin main`.
3. Grava um label opcional (descrição do que vai fazer ali) em `.claude/.slot-info`.

## Parâmetros

- `<repo>` — nome do pool (ex: `horizons`).
- `<slot>` — número do slot (1..N).
- `[label]` — descrição opcional ("feature-a", "tests", "bugfix"). Vai para o `.slot-info` e aparece em `/checkout-status`.

## Passos

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/checkout-use.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
bash "$SCRIPT" $ARGUMENTS
```

Reporte exatamente o que o script imprimir.

## Guardrails

- **NUNCA** crie branch — o script trabalha só em `main` por design.
- Se o slot estiver dirty ou em outra branch, o script aborta com instrução clara — repasse ao usuário.
