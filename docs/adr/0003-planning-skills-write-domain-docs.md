# Skills de planejamento escrevem docs de domínio via biblioteca `domain-docs`

Todas as skills de planejamento (plan/HST, full-planning-cycle, full-cycle, full-cycle-simple, grill-me, auto-grill-me) geram/atualizam `CONTEXT.md` e `docs/adr/` nos formatos canônicos, centralizados na skill-biblioteca `skills/domain-docs/` (formatos movidos de `grill-with-docs`, que vira casca fina junto com `grill-me`). Timing híbrido por maturidade: grills interativos escrevem inline; planejamento não-interativo escreve CONTEXT.md ao persistir o plano (apenas termos observados no domínio — termos cunhados pela solução esperam aprovação) e ADRs só após aprovação, transportados na seção `## ADRs propostos` do plano.

## Considered Options

- Duplicar as regras em cada skill — rejeitado: 6 cópias divergem (deriva garantida).
- ADR com `status: proposed` direto em `docs/adr/` — rejeitado: polui o repo versionado com propostas que o adversarial review pode derrubar.

## Consequences

Gate de materialização é prompt-driven com backstop determinístico: warning best-effort no Stop hook quando plano com `## ADRs propostos` não tem mudança correspondente em `docs/adr/` (mesma lição da telemetria DoD — instrução de prompt sem hook não dispara). Origem: plano `.claude/plans/2026-06-10T16-02-14Z-domain-docs-em-planejamento.md`.
