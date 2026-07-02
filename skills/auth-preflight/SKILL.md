---
name: auth-preflight
description: Preflight consolidado de credenciais no início de tarefa longa — proba TODAS as auths que a tarefa vai precisar (gh, gcloud, sf, codex, gemini) e faz UM único pedido consolidado de logins/renovações, em vez de 3 interrupções espalhadas mid-task. Use ao iniciar tarefa multi-passo que toca ≥2 serviços autenticados, antes de loop longo (Ralph, backlog-dispatch), ou quando o usuário menciona "preflight de auth", "checa as credenciais", "consolida os logins".
---

# auth-preflight

Operacional do **R5** do programa de autonomia (`~/analise-interrupcoes/autonomia-recomendacoes.md`):
as interrupções de auth eram legítimas mas **espalhadas** — 3 pedidos em momentos diferentes da
mesma tarefa. O preflight move todas para **um único pedido consolidado no início**, quando o
custo de contexto é mínimo.

## Quando disparar

1. **Início de tarefa longa** que vai tocar ≥2 serviços autenticados (deploy SF + GitHub PR +
   probe Gemini, ETL + gcloud, etc.). Infira do plano/pedido quais tools a tarefa precisa.
2. **Antes de loop autônomo** (Ralph, `backlog-dispatch`) — o Ralph já tem preflight próprio do
   Codex (`ralph-adversarial.sh`, US-04); este cobre o resto do catálogo.
3. **Candidato a SessionStart nas VMs** — leve (cache TTL 1h) e silencioso quando tudo OK.

Não dispare em tarefa curta de serviço único: a falha 401/403 mid-task já é coberta pelo gatilho
reativo da `browser-secrets`.

## Como

```bash
# modo requerido — a tarefa precisa destas (ausente = MISSING, exit 1):
bin/auth-preflight.sh --tools gh,sf,gemini

# modo auto — proba o que está instalado, pula o resto (SKIP):
bin/auth-preflight.sh
```

- **Só resultado OK é cacheado** (TTL 1h; `--refresh` fura) — renovação recém-feita aparece no
  run seguinte sem esperar TTL.
- Probes com teto (`--timeout`, default 15s); a key do Gemini vem de `GEMINI_API_KEY` ou do
  `./.env` e **nunca entra em argv** (header via `curl -K -`).
- Exit 0 = tudo OK/SKIP; exit 1 = há DEAD/MISSING; a última linha agrega as pendências.

## O pedido consolidado (integração com R4)

Com pendências, a ordem de resolução é:

1. **Renovação autônoma primeiro** — o que a `browser-secrets` renova sozinha (free/low-risk,
   profile autenticado quente), renove **sem perguntar** e reporte mascarado. Só o resto vira
   pedido ao usuário.
2. **O que sobrar vira UM turno só**: `AskUserQuestion` em batch (até 4 itens, máx. 1 turno de
   perguntas por fase — P15/R4), ou um único pedido de login consolidado ("faça login em X e Y e
   me avise") — nunca 1 pedido por credencial, espalhado pela tarefa. É **um único pedido
   consolidado** por tarefa.
3. **Códigos de verificação por email**: se o login dispara código para caixa alcançável, leia
   você mesmo — seção "Códigos de verificação" da `browser-actions`.

## Quota (aviso proativo, não reativo)

Estouro de quota (GitHub Actions, Gemini) é interrupção reativa que podia ser manutenção
silenciosa. No preflight de tarefa que consome quota mensurável, cheque o saldo junto com a auth
(`gh api /rate_limit`, billing de Actions, contadores do projeto Gemini) e **avise antes** de
iniciar consumo pesado. Para consumo recorrente, um monitor via `CronCreate` com threshold é o
mecanismo certo (P10). `[SUPOSIÇÃO]` monitores recorrentes ficam por projeto, não globais —
criados sob demanda quando um projeto estoura quota pela 2ª vez.

## Delegações

- **Renovar/provisionar credencial** → `browser-secrets` (tiered: free/low-risk age sozinha;
  Zona 3/custo/destrutivo confirma 1×).
- **Login assistido no browser + códigos de verificação** → `browser-actions`.
- **Preflight do Codex no Ralph** → já existe em `ralph-adversarial.sh` (probe `codex login
  status` com perl-alarm); este script usa o mesmo probe/idioma para o catálogo geral.

## Referência rápida

- Script: `bin/auth-preflight.sh` (`--tools`, `--refresh`, `--ttl`, `--timeout`, `--json`).
- Cache: `~/.claude/cache/auth-preflight/status.tsv` (só OK, com epoch).
- Testes: `bin/tests/test_auth_preflight.sh`.
