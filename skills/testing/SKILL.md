---
name: testing
description: Princípios e procedimentos de teste para agentic coding. Cobre TDD red-green-refactor, qualidade de asserções, Playwright token-efficient (CLI > MCP), e Definition of Done. Use quando implementar features, corrigir bugs, escrever testes, ou antes de qualquer commit.
---

# Skill: Testing para Agentic Coding

## Princípio central

Um teste deve FALHAR quando a feature que testa está quebrada. Se um teste
não pode falhar por um defeito real, ele não tem valor — delete-o.

## TDD Loop (obrigatório)

1. RED: escreva o teste primeiro. Rode. Confirme que FALHA pelo motivo
   certo (comportamento ausente, não erro de sintaxe).
2. GREEN: escreva o código MÍNIMO para passar. Nada extra.
3. REFACTOR: limpe com testes verdes.

Regras inegociáveis:
- Nunca escreva implementação antes do teste.
- Nunca modifique um teste falhando para fazê-lo passar — corrija o código.
- Nunca use .skip, .only, xit, #[ignore], t.Skip() para esconder falhas.
- Bug fix DEVE conter teste de regressão que falhava antes do fix.

## Qualidade de asserções

- Asserções fortes: `toEqual(expected)` > `toBeTruthy()`.
- Sem literais mágicos: parametrize ou nomeie constantes.
- Valores esperados pré-computados — nunca use a saída do próprio SUT
  como oráculo.
- Cubra: happy path + edge case + erro + boundary.
- Prefira integração sobre mocking pesado. Não mocke o que você possui.
- Um comportamento lógico por teste. Nome descreve comportamento.
- Não teste o que o type checker já pega.

## Playwright — CLI primeiro, MCP por último

PREFIRA `npx playwright test --reporter=line --max-failures=3` sobre MCP.
Justificativa (README Microsoft): CLI evita carregar schemas de ferramentas
e accessibility trees no contexto do modelo.

Para exploração por agente, prefira `@playwright/cli` que salva snapshots
no disco e retorna paths em vez de injetar YAML no contexto.

### Comandos rápidos

```bash
# Apenas testes que falharam no último run
npx playwright test --last-failed --reporter=line

# Apenas testes alterados vs main
npx playwright test --only-changed=main --reporter=line

# Para na terceira falha
npx playwright test --max-failures=3 --reporter=line

# Filtrar por nome
npx playwright test --grep "checkout" --reporter=line

# Resumo compacto
npx playwright test --reporter=line 2>&1 | tail -50
```

### Quando usar MCP (apenas estes casos)
- Diff visual contra mockups em ./design/*.png
- Explorar UI desconhecida (≤10 steps)
- Diga "use playwright mcp" explicitamente na mensagem

### Nunca
- Commitar test-results/, playwright-report/, .playwright-mcp/
- Rodar `npx playwright install` sem perguntar
- Usar --debug, --ui, --headed (a menos que o humano peça)

## Locators resilientes

Use: `getByRole`, `getByTestId`, `getByText`, `filter({ hasText: ... })`
Evite: `page.locator('#app > div:nth-child(2) > button')` — quebra em
qualquer refactor.

## storageState para login

Nunca logar via UI em cada teste. Use projeto `setup` que salva
`playwright/.auth/user.json`, demais consomem via config.

## Organização de testes

- Unit: ao lado do source (`*.test.ts`)
- Integration: `tests/integration/`
- E2E: `tests/e2e/` com tags `@smoke`/`@full`

## Definition of Done

- [ ] Comportamento novo tem teste que FALHAVA antes da mudança.
- [ ] Suite completa verde localmente E no CI.
- [ ] Lint + typecheck + format passam com zero warnings.
- [ ] Nenhum novo .skip/.only/@ignore.
- [ ] Snapshot updates revisados linha a linha com justificativa.
- [ ] Verificação manual documentada (comando, URL ou screenshot).
- [ ] Bug fix referencia issue ID no teste de regressão.

## Anti-padrões a bloquear

- Happy-path only (sem edge cases).
- Over-mocking (mockar repo/cache/logger quebra refactors).
- Weak assertions que passam com resultado vazio.
- Flakiness por shared state (depender de time.Now()).
- Snapshot rubber-stamping (--update-snapshots sem revisão).
- Agent cheating: git blame mostra teste alterado no mesmo commit
  da feature, sem mudança na asserção esperada.
- "Take screenshot and describe" — custa screenshot inline + output.
  Substitua por `page.locator(...).textContent()`.

## Property-based testing (para lógica crítica)

Use fast-check (JS/TS), hypothesis (Python), proptest (Rust), jqwik (Java),
gopter (Go). Captura edge cases que LLMs introduzem silenciosamente.

## Mutation testing (periódico)

Stryker (JS/TS), mutmut (Python), cargo-mutants (Rust), PITest (Java).
Valida que os testes detectam bugs reais, não apenas cobrem linhas.
Rode semanalmente ou pré-release, não a cada commit.

## Templates de projeto

Esta skill vem com templates prontos em `~/.claude/skills/testing/templates/`
para copiar ao bootstrapar testing em um novo projeto:

- `playwright.config.ts` — config agent-aware (reporter line, maxFailures,
  traces on-first-retry, screenshot on-failure).
- `mcp.json` — entrada Playwright MCP token-efficient (headless, isolated,
  image-responses omit, snapshot incremental).
- `settings.hooks.json` — hook PreToolUse que bloqueia commit/push quando
  testes Playwright falham. **Inclui guarda**: só roda se
  `playwright.config.*` existe no projeto. Faça merge no
  `.claude/settings.json` ou `~/.claude/settings.json` do usuário.
- `gitignore.testing` — padrões Playwright (test-results/, .pw/, etc.)
  para apender ao `.gitignore` do projeto.
