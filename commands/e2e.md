---
description: Gera ou roda testes E2E Playwright para uma rota ou fluxo
argument-hint: <rota ou descrição do fluxo>
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(npx playwright*), Bash(npm run dev*)
model: claude-sonnet-4-5
---

# E2E para: $ARGUMENTS

## Preflight
!`git status --short`
!`ls tests/e2e 2>/dev/null | head -20`
!`cat playwright.config.ts 2>/dev/null | head -40`

## Steps
1. Descubra specs existentes cobrindo $ARGUMENTS em tests/e2e/**.
2. Planeje: happy path + 2 error cases + 1 edge case como checklist.
3. Escreva tests/e2e/<slug>.spec.ts usando data-testid ou role selectors.
   Use test.describe por fluxo, test.step por ação, web-first assertions.
4. Rode: `npx playwright test tests/e2e/<slug>.spec.ts --reporter=line`
5. Repair loop (max 3): em falha, leia trace + screenshot de
   test-results/. Se seletor errado, use playwright mcp browser_snapshot
   para corrigir. Re-rode. Nunca --update-snapshots sem permissão.
6. Reporte tabela PASS/FAIL + arquivos tocados.

## Restrições
- Não inicie dev server — assuma localhost:3000 ativo.
- Não commite. Eu reviso primeiro.
