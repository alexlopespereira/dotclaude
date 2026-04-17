# Workflow: Como Usar o Sistema Multi-Agente

## Comandos Disponíveis

| Comando | Uso |
|---------|-----|
| `/plan [problema]` | Produz plano técnico com ReAct + Feynman |
| `/adversarial-review [plano]` | Revisão adversária de um plano existente |
| `/full-cycle [problema]` | Planejamento + auto-revisão em sequência |
| `/adversarial-research [tema]` | Deep research com 3 provedores |
| `/pr` | Cria PR e faz merge automaticamente |
| `/export-report` | Exporta última resposta como Markdown |

## Fluxo de Planejamento

1. `/plan [problema]` → salva em `.claude/plans/`
2. `/adversarial-review .claude/plans/[arquivo].md` → parecer adversário
3. Iterar até aprovação (máx. 3 ciclos)
4. Implementar a Próxima Fatia

Ou use `/full-cycle [problema]` para executar as duas fases em sequência.

## Dicas

- Tarefas triviais NÃO ativam ReAct (o CLAUDE.md isenta explicitamente).
- Use `/compact` entre planejar e revisar para simular "olhos frescos".
- Planos sempre vão para `.claude/plans/` (arquivo, não conversa).
