---
description: Limpa todos os cookies HTTP do perfil Chrome dedicado (operação destrutiva, exige --confirm e MCP encerrado)
allowed-tools: Bash(bash *), Bash(test *), Bash(chmod *), Read
argument-hint: [--confirm]
---

Sem `--confirm`: imprime preview (status do lock + contagem de cookies) sem modificar nada. Com `--confirm` e lock liberado: executa `PRAGMA wal_checkpoint(TRUNCATE)` → `DELETE FROM cookies` → `VACUUM` numa única invocação sqlite3.

## Passos

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/browser-logout-all.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
bash "$SCRIPT" $ARGUMENTS
```

Reporte a saída do script (preview ou contagem antes/depois) e o aviso de escopo restrito.

## Guardrails

- **`--confirm` obrigatório** para qualquer escrita. Sem flag o script imprime só preview.
- **MCP encerrado obrigatório** — se `~/.claude/chrome-profile/.lock/pid` aponta pra um PID vivo, a operação destrutiva aborta com exit 1 instruindo o usuário a fechar a sessão Claude Code que está usando o browser. Operação concorrente em SQLite com WAL pode corromper o banco.
- **Escopo restrito a cookies HTTP** — Local Storage, IndexedDB e cache do browser **não** são afetados. Para limpeza total, encerre o MCP e rode `rm -rf ~/.claude/chrome-profile/`.
- **Argumento extra ou desconhecido aborta** com exit 2 — único arg aceito é `--confirm`.
