# Fase 4 — Conversão em PRD (+ Fase 4.5 test specs, só /full-cycle)

> Reference do `/full-cycle` e `/full-cycle-simple`. Leia APENAS ao iniciar a
> Fase 4.

## Fase 4 — Conversão em PRD

0. **Materialização de ADRs** (início da fase de execução, pós-gate de
   aprovação — Fase 3 no `/full-cycle`, Fase 1.5 no `/full-cycle-simple`):
   antes de converter o plano em PRD, materialize a seção `## ADRs propostos`
   do plano em `docs/adr/` (e os termos cunhados pela solução no `CONTEXT.md`),
   resolvendo a numeração na hora, e emita o marcador `<!-- adr-materialized -->`
   na seção do plano. Regras na biblioteca `domain-docs`
   (`~/.claude/skills/domain-docs/SKILL.md`) — não reproduza o formato aqui.
   Plano sem seção `## ADRs propostos` → nada a materializar, siga.
1. Leia `~/.claude/skills/prd/SKILL.md`.
2. Converta o plano em `prd.json` no cwd atual seguindo a skill `prd`:
   - 1 fatia = 1 user story
   - AC testáveis
   - [SUPOSIÇÕES] viram AC de validação
   - **Propagar `hasFinancialCost`** lendo `.claude/plans/<slug>.flags` (escrito
     pela Fase 1) ou heurística da seção "Custos recorrentes" — vide skill `prd`.
3. **Validação automática do prd.json (Princípio 11 substitui o gate humano):**
   ```bash
   jq -e '(.userStories | type == "array") and (.userStories | length > 0) and (.userStories | all((.id // "") != "" and (.title // "") != "" and ((.acceptanceCriteria // []) | type == "array") and ((.acceptanceCriteria // []) | length > 0) and ((.acceptanceCriteria // []) | all(type == "string" and . != ""))))' prd.json
   ```
   Se exit != 0: **PARE** com erro claro mostrando qual story/campo falhou. Se
   exit 0: prossiga.
4. **Gate de custo financeiro (Princípio 11 cláusula (e)):** se `prd.json` tem
   `hasFinancialCost: true`, pause e pergunte ao humano "Plano envolve custo
   recorrente. Confirma execução do Ralph? (y/N)" antes de prosseguir.

## Fase 4.5 — Test specs via subprocess headless (só /full-cycle)

Antes da Fase 5 Ralph, gere test specs táticos derivados das DoDs referenciadas
no plano. O Ralph implementer lê o plano com a seção `## Test Specs` populada —
TDD vira parte do contexto fresco de cada iteração, não disciplina manual.

**Invocação por subprocess `claude -p` (anti-inchaço de contexto):** o corpo do
`/test-spec` (~10 kB) não entra na janela da sessão-mãe — o subprocess roda numa
janela própria e descartável (mesmo pattern da Fase 9 reflect).

```bash
PLAN_PATH=$(jq -r '.sourcePlan // empty' prd.json)
if test -n "$PLAN_PATH" && test -f "$PLAN_PATH"; then
  # Skip de idempotência: seção já populada → não regenerar.
  if grep -q '^## Test Specs' "$PLAN_PATH"; then
    echo "test-spec: seção '## Test Specs' já populada — pulando (use --regenerate manualmente pra forçar)."
  else
    mkdir -p .claude/cache
    claude -p "/test-spec $PLAN_PATH" > .claude/cache/test-spec-fase45.log 2>&1
    echo "test-spec: $(grep -c '^### Specs para' "$PLAN_PATH" 2>/dev/null || echo 0) blocos de spec anexados (log: .claude/cache/test-spec-fase45.log)"
  fi
else
  echo "AVISO: prd.json não declara sourcePlan ou plano não existe — pulando /test-spec." >&2
fi
```

**Comportamento non-blocking.** Se o subprocess falhar (DOD.md ausente,
TEST-PATTERNS.md ainda não criado em repo virgem, parser quebrado), registre o
aviso mas **NÃO interrompa o pipeline** — specs são input de qualidade, não
pré-requisito hard. Erro vira finding na Fase 9 reflect.

**Propagação para a Fase 5:** o Ralph lê `$PLAN_PATH` no contexto fresco de
cada iteração via `sourcePlan` do prd.json. Specs anexas viajam automaticamente
— nenhuma instrumentação extra no Ralph.
