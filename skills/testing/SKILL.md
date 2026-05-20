---
name: testing
description: Princípios de teste para agentic coding — TDD red-green-refactor, asserções fortes, Playwright token-efficient (CLI > MCP), Definition of Done, lifecycle de test specs derivadas de DoDs (TEST-PATTERNS.md). Use ao implementar features, corrigir bugs, escrever testes, gerar tactical test spec, test spec por tarefa, TDD a partir de DoD, ou antes de qualquer commit.
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

> **Delimitação:** "Playwright CLI > MCP" aqui se refere ao **test runner** (`npx playwright test`).
> Controle de browser via Playwright MCP pra **agir em nome do usuário** é categoria distinta,
> governada pelo Princípio 12 + skill `browser-actions`.

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

## Lifecycle de Test Specs

Test specs Gherkin-lite vivem em `skills/testing/references/TEST-PATTERNS.md`
(mirror estrutural de `skills/auto-grill-me/references/DOD.md`). Cada heading
`### Tarefa N` / `### DoD-base — Categoria N` lá corresponde 1:1 ao heading
homônimo na DOD.md, com contador `(usos: X · desde rev: Y)` paralelo.
Geração via `/test-spec [tarefa-N | cat-N-base | <plan-path>]`.

### Política de granularidade (não-negociável)

- **1 spec = 1 asserção atômica.** Bullets de DoD com N asserções viram N
  specs com sufixo `-A/-B/-C` (`spec-3-A`, `spec-3-B`).
- **Bullets puramente declarativos (review humano)** — ex.: "executado em
  sessão real", "revisado por outra sessão" — recebem prefixo
  `[CAT3-MANUAL]` na descrição e **geram 0 specs automatizáveis**. Compatível
  com a sintaxe rígida da skill `prd` (Ralph filtra `[CAT3-MANUAL]` antes do
  prompt para não inflacionar prd.json com critérios não-binários).
- **Heading literal idêntico à DOD.md**: `### Tarefa N — <título> (usos: X · desde rev: Y)`
  ou `### DoD-base — Categoria N (usos: X · desde rev: Y)`. **Nunca** prefixe
  `Test specs para` — o regex parser do `bin/test-spec-reset-rev.sh` é literal
  `^### Tarefa` / `^### DoD-base`.
- **Ids referenciados em plano mas ausentes em DOD.md** (caso real iter US-01):
  Ramo-3 do `/test-spec` tolera com `[CAT3-MANUAL] (tarefa-N): ausente no
  DOD.md em HEAD` — não aborta. Lifecycle DOD↔plano descasa quando plano
  sugere ids novos antes de a DoD versionar.

### Scripts utilitários

- `bin/test-spec-reset-rev.sh <spec_id>` — zera `desde rev` do heading +
  atualiza `last_seen_iso` no snapshot.
- `bin/test-spec-reset-rev.sh --show [--sort=desde-rev|usos|id]` — tabela
  legível para revisão.
- `bin/test-spec-reset-rev.sh --gc` — remove entries órfãs do snapshot.
- `bin/test-spec-migrate-add-counters.sh` — one-shot idempotente para
  bootstrap: adiciona `(usos: 0 · desde rev: 0)` a 28 headings e cria
  `.test-spec-revision-state.json` (sha256 do bullet block + metadata).
  Ambos clones literais de `dod-*.sh` (apenas `TARGET_FILE`/`SNAPSHOT_FILE`
  diferem) — decisão deliberada (footnote #6 do plano).

### Snapshot

`references/.test-spec-revision-state.json` — schema idêntico ao
`.dod-revision-state.json`: chaves `dod_id` (`tarefa-N` / `cat-N-base`),
valores `{bullets_sha256, slug, title_current, last_seen_iso}`. Hash do
bullet block é a única fonte de verdade para "este bloco mudou desde a
última revisão" — reset detectado naturalmente via mismatch quando o usuário
roda `--show`/`<spec_id>`.

### Convenção `// spec:` em código de teste

Camada complementar ao mirror DOD.md ↔ TEST-PATTERNS.md: marker textual em
**código de teste** que aponta para a spec validada. Permite que
`/reflect --learn` cruze DoD → spec → teste e emita finding
`tdd_gap_marker_missing` quando um teste novo não declara qual spec valida.
Política de granularidade do spec id permanece em `references/TEST-PATTERNS.md`
(header daquele arquivo) — esta subseção adiciona apenas a camada de marker
no código.

**Sintaxe.** Comment de linha na sintaxe nativa da linguagem, payload
`spec: tarefa-X-spec-N[-A]` (ou `cat-N-base-spec-N`). O regex canônico em
`bin/reflect-learn-bundle.sh` é `(//|#)[[:space:]]*spec:[[:space:]]*tarefa-[0-9]+-spec-[0-9]+(-[A-Z])?`
— tolera whitespace entre o comment char e `spec:`. Suportado em ≥3
linguagens:

| Linguagem        | Comment   | Marker                          |
|------------------|-----------|---------------------------------|
| JavaScript/TypeScript | `//`  | `// spec: tarefa-1-spec-3-A`    |
| Python           | `#`       | `# spec: tarefa-1-spec-3-A`     |
| Shell (bash/zsh) | `#`       | `# spec: tarefa-1-spec-3-A`     |

Outras linguagens cuja sintaxe de comment de linha case com `//` ou `#`
(Go, Rust, C/C++/Java, Ruby, etc.) entram automaticamente — o marker é
**texto**, não construção de linguagem.

**Localização.** O marker fica na linha **imediatamente acima** do bloco
de teste que valida a spec — `describe`/`it`/`test` (JS/TS), `def test_<...>`
(Python), função `test_<...>` ou bloco de asserção (shell). Markers inline
no fim da linha do `it(...)` também são capturados pelo grep, mas a
convenção preferida é linha dedicada (mais fácil de auditar via `git diff`).

Quando o mesmo teste valida **múltiplas specs** (ex.: refactor que cobre
`spec-3-A` e `spec-3-B`), acumule múltiplos markers consecutivos — um por
linha, sem linha em branco entre eles:

```ts
// spec: tarefa-1-spec-3-A
// spec: tarefa-1-spec-3-B
it("rejeita allowed-tools wildcard", () => { /* ... */ });
```

**Enforcement.** A convenção é **SOFT** (best-effort, não bloqueante):

- `/reflect --learn` (via `bin/reflect-learn-bundle.sh`) grepa os paths
  canônicos `tests/`, `skills/*/bin/test-*.sh` e `bin/tests/test_*.sh`
  por markers e cruza com as specs da DoD aplicada na PR. Specs sem
  marker correspondente viram finding `tdd_gap_marker_missing` no
  `proposal.json`.
- **Não há hook PreToolUse bloqueante** nessa fatia — o finding é input
  para revisão humana, **não bloqueia merge**. Ausência de marker em
  teste legado nunca trava PR.
- Custo do soft enforcement: drift entre DoD declarada e teste efetivo
  fica visível no proposal, mas só corrige se o autor escolher. Trade-off
  deliberado: forçar marker via hook bloquearia bug-fixes urgentes onde
  o teste de regressão existe mas o autor esqueceu o marker.

**Exemplo concreto (multi-linguagem).** Spec alvo: `tarefa-1-spec-3-A`
em `references/TEST-PATTERNS.md`:

> "dado o corpo do command, quando faço `grep -E '\$ARGUMENTS|\$1|\$2'`,
> então há ≥1 match (se o command toma input do usuário)"

Marker no teste, três sabores:

```ts
// JS/TS — tests/commands.test.ts
// spec: tarefa-1-spec-3-A
it("commands com $ARGUMENTS em body", () => {
  const body = readFileSync("commands/foo.md", "utf-8");
  expect(body).toMatch(/\$ARGUMENTS|\$1|\$2/);
});
```

```python
# Python — tests/test_commands.py
# spec: tarefa-1-spec-3-A
def test_command_body_has_arguments_placeholder():
    body = Path("commands/foo.md").read_text()
    assert re.search(r"\$ARGUMENTS|\$1|\$2", body)
```

```bash
# Shell — skills/testing/bin/test-commands-have-arguments.sh
# spec: tarefa-1-spec-3-A
test_command_body_has_arguments() {
  grep -qE '\$ARGUMENTS|\$1|\$2' commands/foo.md \
    || { echo "FAIL: $0"; exit 1; }
}
test_command_body_has_arguments
```

O exemplo shell é o padrão do dotclaude — testes vivem em
`skills/*/bin/test-*.sh` e `bin/tests/test_*.sh`. Veja
`skills/auto-grill-me/bin/test-dod-add-bullet-ids.sh` para referência
canônica do estilo.

## Gotchas

- **Drift entre DOD.md e TEST-PATTERNS.md (mirror lag).** TEST-PATTERNS.md é
  mirror estrutural manual de DOD.md, não regenerado automaticamente: quando
  a DOD.md ganha um `### Tarefa N` novo, TEST-PATTERNS.md fica defasado até a
  próxima rodada de `/test-spec`. Mitigação: convenção de revisão — alterar
  DoD em PR separado e gerar specs no PR seguinte; nunca refatorar a fonte e
  o mirror no mesmo commit (impossível bisect).
- **Hash-sensitivity disparando reset constante em specs (tradeoff herdado).**
  `bullets_sha256` muda em qualquer edição do bullet block — incluindo
  rewording sem mudança semântica. Reset zera `desde rev`, então um typo-fix
  reseta o contador. Tradeoff aceito: false-positive em rewording é o preço
  de captura confiável de mudanças reais. Mitigação: agrupar rewording em
  commits dedicados e rodar `--show` antes/depois para baseline visual.
- **Concorrência multi-slot Boris via `mkdir <lockdir>`.** Os scripts usam
  `mkdir "$LOCK_DIR"` como exclusão mútua POSIX (`flock` clássico não existe
  no Darwin). Em workflow Boris com 5 slots paralelos no mesmo repo, dois
  slots rodando `/test-spec` simultaneamente em `tarefa-N` diferentes
  serializam pelo lockdir; o segundo retry após 50 tentativas (5s) com exit
  3. Mitigação: se o lock ficar travado por crash, rode `rmdir
  skills/testing/references/.test-spec-*.lock` manualmente.

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
