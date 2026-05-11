---
description: Ciclo end-to-end enxuto pra features simples — sem revisão adversária (Fase 2) e sem Codex review no Ralph. Use quando a feature tem escopo único, ≤5 arquivos tocados, sem schema migration / nova dependência / mudança em auth, sem custo financeiro recorrente. Se mid-Plan algum desses critérios disparar, agente pausa e oferece escalar pra /full-cycle.
allowed-tools: Read, Write, Glob, Grep, Bash(find *), Bash(bash *), Bash(chmod *), Bash(cat *), Bash(jq *), Bash(grep *), Bash(wc *), Bash(git *), Bash(gh *), Bash(ls *), Bash(pwd), Bash(cd *), Bash(echo *), Bash(test *)
argument-hint: [descrição curta da feature simples]
---

Versão enxuta de `/full-cycle` para **features simples**: pula a revisão adversária (Fase 2 do `/full-cycle`) e o reviewer dentro do Ralph (Fase 5). Mantém Plan + PRD + implementação Ralph + testes + PR.

**Quando usar `/full-cycle-simple` vs `/full-cycle`:**

Use este comando quando a feature:
1. Tem escopo único (1-3 user stories no máximo)
2. Toca ≤5 arquivos
3. Sem schema migration / nova dependência externa / mudança em auth/permissões
4. Sem custo financeiro recorrente

Se algum desses critérios falhar ao fim da Fase 1, o agente **pausa e oferece escalar** pra `/full-cycle`.

**Modelo trunk-based (Boris Cherny).** O cwd atual é um slot do pool de checkouts. **Não criamos branch.** Trabalho vai direto em `main` e é propagado aos outros slots via `/checkout-sync-all`.

Antes de invocar `/full-cycle-simple`:
- `/checkout-use <repo> <slot> [label]` para preparar o slot (atualiza main).
- Trabalhe nesse slot.
- Após terminar: `/full-cycle-simple` (este comando) → `/checkout-sync-all <repo>`.

## Fase 1 — Planejamento (Agente Planejador) — IDÊNTICO ao /full-cycle

1. Leia `~/.claude/skills/react-feynman/SKILL.md`.
2. Assuma o papel de **Agente Planejador**.
3. Execute o ciclo ReAct completo para: $ARGUMENTS.

   **Paralelização do passo Action (Princípio 9).** Durante o ciclo ReAct, quando o passo *Action* precisa coletar contexto sobre múltiplas áreas antes de planejar, **dispare TODOS os subagents necessários no MESMO bloco de tool_calls** — rodam concorrentes e o wall-time fica ≈ ao do mais lento (não a soma). Critério: independência ≡ subagent B não consome output de A. Heurística de quando vale: tarefa do subagent >5k tokens ou >30s; abaixo disso o overhead de reabrir context não compensa.

4. Produza o plano usando o Template: Plano (4 seções: Problema, Abordagem, Fatias, AC + tags `[FATO]`/`[INFERÊNCIA]`/`[SUPOSIÇÃO]` + Perguntas Abertas).
5. Salve o plano em `.claude/plans/<slug>.md` (relativo ao cwd).
6. **Detecção de custo recorrente (Princípio 11 cláusula (e)):** após salvar, execute o step shell determinístico abaixo para gerar a flag que será lida pela skill `prd` na Fase 4:
   ```bash
   PLAN_FILE=".claude/plans/<slug>.md"
   FLAGS_FILE=".claude/plans/<slug>.flags"
   if grep -iqE 'subscription|monthly|paid tier|API key|recurring cost|SaaS|R\$[0-9]|\$[0-9]+/(mo|mês)' "$PLAN_FILE"; then
       echo "HAS_FINANCIAL_COST=true" > "$FLAGS_FILE"
   else
       echo "HAS_FINANCIAL_COST=false" > "$FLAGS_FILE"
   fi
   ```

## Fase 1.5 — Gate de complexidade (E3)

Auto-assessment do Plan recém-salvo. **Aplicar os 6 triggers via shell determinístico.** Se qualquer um disparar, **PARE** e pergunte ao humano.

```bash
PLAN_FILE=".claude/plans/<slug>.md"
FLAGS_FILE=".claude/plans/<slug>.flags"
TRIGGERS=()

# T1 — Plan tem >3 user stories/fatias
SLICES=$(grep -ciE '^(##+\s+(Fatia|Slice|Story|US-?[0-9]))|^- \*\*(Fatia|Slice|Story|US-?[0-9])' "$PLAN_FILE" || echo 0)
if [ "$SLICES" -gt 3 ]; then
    TRIGGERS+=("T1: Plan tem $SLICES fatias/stories (>3)")
fi

# T2 — schema migration
if grep -iqE 'migration|alter table|create table|add column|drop column|schema change|alembic|prisma migrate|knex migrate' "$PLAN_FILE"; then
    TRIGGERS+=("T2: Plan menciona schema migration")
fi

# T3 — nova dependência externa
if grep -iqE 'npm i(nstall)? |yarn add |pnpm add |pip install |poetry add |cargo add |go get |bundle add ' "$PLAN_FILE"; then
    TRIGGERS+=("T3: Plan adiciona nova dependência externa")
fi

# T4 — auth/permissions/security
if grep -iqE '\b(auth|authentication|permission|role|token|session|csrf|cors|rbac|jwt|oauth|sso)\b' "$PLAN_FILE"; then
    TRIGGERS+=("T4: Plan toca auth/permissions/security")
fi

# T5 — > 5 arquivos tocados (procura por listas de arquivos no plano)
FILES_MENTIONED=$(grep -oE '[a-zA-Z0-9_./\-]+\.(ts|tsx|js|jsx|py|rb|go|rs|java|kt|swift|md|yaml|yml|json|toml|sql|html|css|scss|vue|svelte)' "$PLAN_FILE" | sort -u | wc -l | tr -d ' ')
if [ "$FILES_MENTIONED" -gt 5 ]; then
    TRIGGERS+=("T5: Plan menciona $FILES_MENTIONED arquivos (>5)")
fi

# T6 — hasFinancialCost true
if grep -q 'HAS_FINANCIAL_COST=true' "$FLAGS_FILE" 2>/dev/null; then
    TRIGGERS+=("T6: hasFinancialCost=true (Princípio 11e)")
fi

if [ ${#TRIGGERS[@]} -gt 0 ]; then
    echo "GATE_E3_TRIGGERED"
    printf '  - %s\n' "${TRIGGERS[@]}"
fi
```

**Se algum trigger disparou:** apresente os triggers ao humano e pergunte:
> Esse plano disparou os critérios acima — está mais complexo do que `/full-cycle-simple` foi desenhado pra. Quer:
> (1) **continuar mesmo assim** com `/full-cycle-simple` (você assume risco),
> (2) **escalar pra `/full-cycle`** (com adversarial review + Codex review), ou
> (3) **abortar** e refinar o plano manualmente?

Aguarde resposta. Se (1), prossiga pra Fase 4. Se (2), invoque `/full-cycle` com mesmo `$ARGUMENTS` (Plan já está em disco — pode ser reusado). Se (3), pare e aguarde input.

**Se nenhum trigger disparou:** prossiga automaticamente para Fase 4 (Princípio 11: transição interna não pede confirmação).

## Fase 4 — Conversão em PRD — IDÊNTICO ao /full-cycle

1. Leia `~/.claude/skills/prd/SKILL.md`.
2. Converta o plano em `prd.json` no cwd atual seguindo a skill `prd`:
   - 1 fatia = 1 user story
   - AC testáveis
   - [SUPOSIÇÕES] viram AC de validação
   - **Propagar `hasFinancialCost`** lendo `.claude/plans/<slug>.flags`.
3. **Validação automática do prd.json:**
   ```bash
   jq -e '(.userStories | type == "array") and (.userStories | length > 0) and (.userStories | all((.id // "") != "" and (.title // "") != "" and ((.acceptanceCriteria // []) | type == "array") and ((.acceptanceCriteria // []) | length > 0) and ((.acceptanceCriteria // []) | all(type == "string" and . != ""))))' prd.json
   ```
   Se exit != 0: **PARE** com erro claro mostrando qual story/campo falhou. Se exit 0: prossiga para Fase 5.
4. **Gate de custo financeiro (Princípio 11 cláusula (e)):** se `prd.json` tem `hasFinancialCost: true`, pause e pergunte ao humano "Plano envolve custo recorrente. Confirma execução do Ralph? (y/N)" antes de prosseguir.

## Fase 5 — Execução Ralph SEM reviewer (--no-review)

1. Leia `~/.claude/skills/ralph-adversarial/SKILL.md`.
2. Verifique pré-requisitos: `jq` e o CLI do PRIMARY_AGENT (default `claude`).
   - **Não exige `codex`** porque `--no-review` desliga o reviewer.
3. Execute no cwd atual com a flag `--no-review`:
   ```bash
   chmod +x ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   PRIMARY_AGENT="${PRIMARY_AGENT:-claude}" \
     bash ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh --no-review
   ```
4. Após conclusão, apresente resumo: stories completas/pendentes/escaladas, progress.txt.

**Gate:** Se houver stories escaladas (max retries por FALHA_COMMIT/HANG), **PARE** e escale para humano. NÃO prossiga para testes/PR.

## Fase 6 — Testes (suite + Playwright se UI) com auto-fix até 3 iterações

Antes de abrir PR:

1. **Detecte se a feature tocou UI:** `git diff origin/main..HEAD --name-only | grep -iE '\.(tsx?|jsx?|vue|svelte|html|css|scss)$'`. Se houver match, é UI.

2. **Se UI:** gere/rode teste Playwright cobrindo o critério de aceitação principal da feature. Use `/e2e <fluxo>` se já existir base, senão crie em `tests/e2e/<slug>.spec.ts` seguindo a convenção do projeto. Detalhes em `~/.claude/skills/testing/SKILL.md`.

3. **Sempre:** rode a suite completa do projeto (detecte runner via `package.json scripts.test`, `pytest.ini`, `go test`, `cargo test`, etc.).

4. **Loop de auto-fix (até 3 iterações):**
   - Iteração 1: rodar testes. Se passou, prossegue Fase 7.
   - Se falhou: agente lê output, faz Edit nos arquivos relevantes (código de produção OU teste, conforme análise), commita o fix, re-roda.
   - Iteração 2: se passou, prossegue. Se falhou, repete.
   - Iteração 3: última tentativa. Se ainda falhar, **PARE** e escale para humano com:
     - resumo dos 3 fixes tentados
     - output do teste falhante
     - hipótese atual sobre o bug
   Não abra PR com testes vermelhos.

## Fase 7 — Branch efêmera + Push + PR — IDÊNTICO ao /full-cycle

Execute `/commit-push-pr "<mensagem em conventional commits>"` no cwd atual. Esse comando:

- Cria branch efêmera derivada da mensagem (ex: `feat/add-dark-mode`).
- Pushaa branch para `origin`.
- Abre PR via `gh` para `main` (mantém branch protection).
- Auto-merge ON por default — PR mergeia sozinho quando CI passa.
- Reseta `main` local para `origin/main`.

Se `git push` falhar por hook do servidor ou política de proteção, reporte ao usuário e **PARE** — não tente bypass.

## Fase 8 — Aguardar merge + sincronizar slots — IDÊNTICO ao /full-cycle

Após o PR ser **mergeado no GitHub** (auto-merge quando CI passar), detecte o pool:
```bash
REPO=$(basename "$(cd "$(git rev-parse --show-toplevel)" && pwd)" | sed 's/-[0-9]*$//')
```

Rode `/checkout-sync-all <REPO>` para:
- atualizar `main` em todos os slots
- remover branches locais já mergeadas

## Guardrails

- **Plan completo é obrigatório** — atalhos de planejamento foram intencionalmente NÃO cortados pra não comprometer qualidade da spec.
- **Gate E3** ao fim da Fase 1 é não-negociável — se feature passou de "simples" mid-Plan, paramos pra escalar.
- **Princípios 7 (segredos) e 11 (a-e) continuam ativos** — nada de comandos destrutivos, domínios pagos, pacotes pagos, ou commit de segredos sem confirmação humana, mesmo nesse modo "sem interrupção".
- Humano pode interromper em qualquer fase via Ctrl-C.
- Se qualquer fase falhar, reporte o status e PARE — não improvise.
- **Modelo:** trabalho em `main` local → branch efêmera no push → PR → merge (auto) → sync. Branch protection mantida.
