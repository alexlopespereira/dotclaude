---
description: Lista cookies do perfil Chrome dedicado (~/.claude/chrome-profile) em modo read-only
allowed-tools: Bash(bash *), Bash(test *), Bash(chmod *), Read
argument-hint:
---

Imprime tabela agregada por host_key — DOMAIN, COUNT, LAST_ACCESS, EXPIRES — abrindo o SQLite em modo `mode=ro&immutable=1`. Não disputa lock com o MCP nem modifica o banco.

## Passos

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/browser-status.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
bash "$SCRIPT"
```

Reporte a tabela exatamente como o script imprimir. Se o perfil ainda não foi inicializado (Default/Cookies inexistente), o script imprime mensagem amigável e termina com exit 0. Se o MCP estiver rodando, o script imprime aviso explícito mencionando o PID — o snapshot é coerente mas pode não capturar cookies criados nos últimos segundos.
