---
description: Provisiona 5 checkouts paralelos do mesmo repo (workflow Boris Cherny — trunk-based, sem branches por feature)
allowed-tools: Bash(bash *), Bash(chmod *), Bash(test *), Bash(ls *), Read
argument-hint: <repo-url-ou-path> [--slots=N] [--no-install] [--copy-env]
---

Provisiona N checkouts paralelos (default: **5**) em `~/Projects/checkouts/<repo>-{1..N}`. Modelo de trabalho: **trunk-based** — todos os slots ficam em `main`, você commita direto em `main` e sincroniza entre slots via `git pull`. **Não criamos branches por feature.**

## Passos

1. **Validar entrada:**
   ```bash
   SCRIPT="$HOME/Projects/dotclaude/bin/checkout-init.sh"
   test -x "$SCRIPT" || chmod +x "$SCRIPT"
   ```

   Se `$ARGUMENTS` estiver vazio, **PARE** e peça `<repo-url-ou-path>`.

2. **Executar:**
   ```bash
   bash "$SCRIPT" $ARGUMENTS
   ```

   O script faz: clones independentes (com `--reference-if-able` se a fonte for local), install de deps detectando o package manager, e grava metadata em `~/Projects/checkouts/.<repo>.pool`.

3. **Reportar** o que o script imprimiu e sugira:
   - `/checkout-launch <repo>` — abrir as 5 abas
   - `/checkout-sync-all <repo>` — futura sincronização

## Guardrails

- **NUNCA** sobrescreva slots existentes — o script aborta automaticamente.
- **NUNCA** copie `.env` sem `--copy-env` explícito.
- O script já cobre todos os checks; este markdown é só wrapper.
