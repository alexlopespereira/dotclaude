# Exemplo — report no chat + linha de audit

Cenário: usuário pediu "cria uma API key da OpenAI nesse projeto". Trigger = intent de setup.
Profile quente. Free/low-risk → proativo.

## Report no chat (sempre mascarado)

```
✅ Provisionei a API key da OpenAI.

- tool:          OpenAI
- tipo:          API key (secret)
- escopo:        default (project key, least-privilege)
- destino:       ./.env  (OPENAI_API_KEY) — .gitignore já cobre .env
- verificação:   live probe → GET https://api.openai.com/v1/models → 200 OK
- trigger:       intent de setup ("cria uma API key da OpenAI")
- valor:         sk-...AbCd   (mascarado — segredo cru nunca ecoado)
- revogar em:    https://platform.openai.com/api-keys
- ação sua:      nenhuma
```

## Linha append-only em `~/.claude/cache/browser-secrets/audit.jsonl`

Uma linha JSON por provisionamento. **Nunca** o segredo cru — só o `tail` mascarado.

```json
{"timestamp":"2026-06-08T14:32:10Z","tool":"OpenAI","dominio":"platform.openai.com","tipo":"api_key","tail":"sk-...AbCd","destino":"./.env:OPENAI_API_KEY","verificacao":"live_probe:200"}
```

Campos: `timestamp`, `tool`, `dominio`, `tipo`, `tail` (mascarado), `destino`, `verificacao`
(`live_probe:<status>` ou `format_assert:<ok|fail>`).
