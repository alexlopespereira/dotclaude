---
description: Ciclo end-to-end — planejamento + revisão adversária + PRD + Ralph + PR/merge
allowed-tools: Read, Write, Glob, Grep, Bash(find *), Bash(bash *), Bash(chmod *), Bash(cat *), Bash(jq *), Bash(git *), Bash(gh *), Bash(ls *), Bash(pwd), Bash(cd *), Bash(echo *), Bash(test *)
argument-hint: [descrição do problema ou feature]
---

Executa o ciclo completo de entrega no cwd atual: planejamento → revisão adversária → PRD → Ralph → commit + push em main.

**Modelo trunk-based (Boris Cherny).** O cwd atual é um slot do pool de checkouts. **Não criamos branch.** Trabalho vai direto em `main` e é propagado aos outros slots via `/checkout-sync-all`.

Antes de invocar `/full-cycle`:
- `/checkout-use <repo> <slot> [label]` para preparar o slot (atualiza main).
- Trabalhe nesse slot.
- Após terminar: `/full-cycle` (este comando) → `/checkout-sync-all <repo>`.

Para apenas planejar (sem executar/merge), use `/full-planning-cycle`.

## Fase 1 — Planejamento (Agente Planejador)

1. Leia `~/.claude/skills/react-feynman/SKILL.md`.
2. Assuma o papel de **Agente Planejador**.
3. Execute o ciclo ReAct completo para: $ARGUMENTS.

   **Paralelização do passo Action (Princípio 9).** Durante o ciclo ReAct, quando o passo *Action* precisa coletar contexto sobre múltiplas áreas antes de planejar, **dispare TODOS os subagents necessários no MESMO bloco de tool_calls** — rodam concorrentes e o wall-time fica ≈ ao do mais lento (não a soma). Critério: independência ≡ subagent B não consome output de A. Heurística de quando vale: tarefa do subagent >5k tokens ou >30s; abaixo disso o overhead de reabrir context não compensa.

   - ✅ `Agent(Explore: módulo afetado pela feature)` + `Agent(Explore: testes/fixtures relacionados)` + `Agent(Explore: features análogas já implementadas)` — três investigações independentes, mesmo turn.
   - ✅ `Agent(Plan: arquitetura A)` + `Agent(Plan: arquitetura B)` quando você quer pesar duas opções — pareceres independentes, mesmo turn.
   - ❌ `Agent(Explore: módulo X)` → ler resultado → `Agent(Plan: baseado em X)` — segundo precisa do output do primeiro. Sequencial.
4. Produza o plano usando o Template: Plano.
5. Salve o plano em `.claude/plans/<slug>.md` (relativo ao cwd).
6. **Detecção de custo recorrente (Princípio 11 cláusula (e)):** após salvar, execute o step shell determinístico abaixo para gerar a flag que será lida pela skill `prd` na Fase 4. **Heurística aplicada por shell, NÃO pelo agente** — evita circularidade ("agente decide se o que ele mesmo escreveu contém palavras-chave"):
   ```bash
   PLAN_FILE=".claude/plans/<slug>.md"
   FLAGS_FILE=".claude/plans/<slug>.flags"
   if grep -iqE 'subscription|monthly|paid tier|API key|recurring cost|SaaS|R\$[0-9]|\$[0-9]+/(mo|mês)' "$PLAN_FILE"; then
       echo "HAS_FINANCIAL_COST=true" > "$FLAGS_FILE"
   else
       echo "HAS_FINANCIAL_COST=false" > "$FLAGS_FILE"
   fi
   ```

## Fase 2 — Revisão Adversária (Agente Revisor)

1. Troque para o papel de **Agente Revisor Adversário**.
2. Releia o plano com olhos frescos.
3. Para cada decisão, tente refutar. Aplique Teste Feynman.

   **Paralelização de refutações (Princípio 9).** O Revisor normalmente ataca o plano por várias frentes ortogonais — checar se uma SUPOSIÇÃO bate com o código real, procurar anti-patterns similares no histórico, stress-testar contra edge cases conhecidos, validar dependências externas. Dispare **todos os subagents adversários no MESMO turn** quando as investigações forem independentes — cada um devolve um finding que o Revisor consolida no parecer. Mesma regra de independência da Fase 1.

   - ✅ `Agent(Explore: a SUPOSIÇÃO "API X é idempotente" bate com a implementação?)` + `Agent(Explore: histórico de bugs no módulo Y)` + `Agent(Explore: cobertura de teste do caso Z)` — três refutações ortogonais, mesmo turn.
   - ❌ Esperar resposta de uma para decidir a próxima — anula o ganho.
4. Produza o parecer usando o Template: Revisão Adversária.
5. Adicione o parecer ao mesmo arquivo do plano, sob `---` separador.

## Fase 3 — Gate de Aprovação

**Se REPROVADO:**
- Destaque os 3 pontos mais críticos.
- **PARE AQUI** — escale para o humano. NÃO prossiga para PRD/Ralph/PR.
- **Antes de escalar para humano:** sugira `/reflect --on-failure 3 --context-file <path-do-parecer>` para entender qual critério DoD teria evitado a reprovação.

**Se APROVADO COM RESSALVAS:**
- Liste as ressalvas bloqueantes (severidade Crítica/Alta) — recomendar correção durante implementação como ACs adicionais.
- Prossiga automaticamente para Fase 4 (Princípio 11: transição interna não pede confirmação). Humano interrompe via Ctrl-C se quiser revisar antes.

**Se APROVADO:** prossiga para Fase 4.

## Fase 4 — Conversão em PRD

1. Leia `~/.claude/skills/prd/SKILL.md`.
2. Converta o plano em `prd.json` no cwd atual seguindo a skill `prd`:
   - 1 fatia = 1 user story
   - AC testáveis
   - [SUPOSIÇÕES] viram AC de validação
   - **Propagar `hasFinancialCost`** lendo `.claude/plans/<slug>.flags` (escrito pela Fase 1) ou heurística da seção "Custos recorrentes" — vide skill `prd`.
3. **Validação automática do prd.json (Princípio 11 substitui o gate humano):**
   ```bash
   jq -e '(.userStories | type == "array") and (.userStories | length > 0) and (.userStories | all((.id // "") != "" and (.title // "") != "" and ((.acceptanceCriteria // []) | type == "array") and ((.acceptanceCriteria // []) | length > 0) and ((.acceptanceCriteria // []) | all(type == "string" and . != ""))))' prd.json
   ```
   Se exit != 0: **PARE** com erro claro mostrando qual story/campo falhou. Se exit 0: prossiga para Fase 5.
4. **Gate de custo financeiro (Princípio 11 cláusula (e)):** se `prd.json` tem `hasFinancialCost: true`, pause e pergunte ao humano "Plano envolve custo recorrente. Confirma execução do Ralph? (y/N)" antes de prosseguir.

## Fase 5 — Execução Ralph Adversarial

1. Leia `~/.claude/skills/ralph-adversarial/SKILL.md`.
2. Verifique pré-requisitos: `jq`, `CODE_REVIEW.md`, e os CLIs necessários conforme os papéis:
   - Default: `claude` implementa, `codex` revisa → ambos precisam existir.
   - Se `PRIMARY_AGENT` / `REVIEWER_AGENT` estiverem definidos no ambiente, valide apenas os CLIs escolhidos.
3. Execute no cwd atual, **propagando as env vars de papéis** se estiverem definidas:
   ```bash
   chmod +x ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   PRIMARY_AGENT="${PRIMARY_AGENT:-claude}" REVIEWER_AGENT="${REVIEWER_AGENT:-codex}" \
     bash ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   ```
   Para inverter os papéis, o usuário lança o Claude Code com as vars no shell:
   `PRIMARY_AGENT=codex REVIEWER_AGENT=claude claude` — depois invoca `/full-cycle`.
4. Após conclusão, apresente resumo: stories completas/pendentes/escaladas, findings P0/P1, progress.txt.

**Gate:** Se houver stories escaladas ou findings P0 não resolvidos, **PARE** e escale para humano. NÃO prossiga para PR.

**Antes de escalar para humano:** sugira `/reflect --on-failure 5 --context-file <path-com-findings-P0>` para entender qual critério DoD teria capturado os findings P0 antes do Ralph escalar.

## Fase 6 — Testes finais

Antes de abrir PR, rode a suíte de testes do projeto no cwd atual:
```bash
# Detecte o runner (package.json, pytest, go test...) e execute
```

Se falhar, **PARE** e escale — não abra PR com testes vermelhos.

**Antes de escalar para humano:** sugira `/reflect --on-failure 6 --from-stdin` (alimentado por output do test runner) para entender qual critério DoD teria capturado a falha de teste antes do CI.

## Fase 7 — Branch efêmera + Push + PR

Execute `/commit-push-pr "<mensagem em conventional commits>"` no cwd atual. Esse comando:

- Cria branch efêmera derivada da mensagem (ex: `feat/add-dark-mode`).
- Pushaa branch para `origin`.
- Abre PR via `gh` para `main` (mantém branch protection).
- Reseta `main` local para `origin/main`.

Se `git push` falhar por hook do servidor ou política de proteção, reporte ao usuário e **PARE** — não tente bypass.

## Fase 8 — Aguardar merge + sincronizar slots

Após o PR ser **mergeado no GitHub** (review humano normalmente), detecte o pool:
```bash
REPO=$(basename "$(cd "$(git rev-parse --show-toplevel)" && pwd)" | sed 's/-[0-9]*$//')
```

Rode `/checkout-sync-all <REPO>` para:
- atualizar `main` em todos os slots
- remover branches locais já mergeadas

## Fase 9 — Reflexão sobre DoD (auto-baseline)

Após o sync dos slots, invoque automaticamente `/reflect --baseline` para classificar a adequação do Definition of Done aplicado a esta PR. Gera relatório baseline em `.claude/reflections/<ts>-<slug>-baseline.md` e agenda follow-up retro D+7 via `~/.claude/cache/reflect/reminders.jsonl`.

```bash
PR_NUMBER=$(gh pr list --state merged --limit 1 --base main --json number --jq .[0].number) && /reflect $PR_NUMBER --baseline
```

**Comportamento non-blocking.** Se `/reflect` falhar (ex.: PR não correlaciona com plano, `gh` offline, sessão `/auto-grill-me` ausente), registre o aviso mas **NÃO interrompa o pipeline** — reflexão é auditoria, não gate. O pipeline já considerou Fase 8 (sync) como término efetivo da entrega; Fase 9 apenas anexa metadado de qualidade.

### Verificação (humano pós-merge — Cat 3 explícito)

**Classificação:** AC8 e AC9 da US-02 são **Cat 3 (humano-validated post-merge)** por limite físico do Ralph adversarial — slash command recursivo dentro do worker é inviável. A automação Cat 1/2 esbarraria em loop infinito (`/full-cycle` invocando `/reflect` invocando `/full-cycle`...). Este bloco lista o checklist manual que substitui a evidência empírica esperada pelo Codex.

**Convenção mais ampla:** este caso particular se encaixa no padrão geral `[CAT3-MANUAL]` — qualquer AC prefixado com `[CAT3-MANUAL]` em qualquer PRD é filtrado pelo Ralph antes do prompt ser enviado a Claude/Codex, e a validação fica a cargo de um checklist humano pós-merge como o abaixo. Sintaxe formal e exemplos em `skills/prd/SKILL.md`.

**Checklist (rode UMA vez após merge do próximo PR via `/full-cycle`):**

- [ ] **AC8 — Baseline gravado.** Inspecione `.claude/reflections/<ts>-<slug>-baseline.md` no cwd (ou `~/.claude/cache/reflect/<repo>/<ts>-<slug>-baseline.md` em fallback). Verifique que contém: cabeçalho `Plan match: <marker|slug-exact|fuzzy|none>`, `Session correlated: <true|false>`, seção `CI checks` listando pelo menos 1 check (ou `ci_checks: nenhum`), e seção `Aviso retrospectiva` com data D+7 ≈ correta.
- [ ] **AC8b — Reminder agendado.** `tail -1 ~/.claude/cache/reflect/reminders.jsonl` deve mostrar entrada JSON com `pr` da PR mergeada, `repo` correto e `retro_due_at` no formato ISO-8601 ≈ D+7.
- [ ] **AC9 — Sugestão `/reflect --on-failure N` em Fases 3/5/6.** Trigger UMA parada deliberada (escolha um cenário):
  - Fase 3: introduza erro deliberado no plano que dispare REPROVADO no adversarial-review.
  - Fase 5: simule finding P0 no Codex review da primeira iteração Ralph.
  - Fase 6: deixe um teste falhar 3× (loop auto-fix esgotado).
- [ ] **AC9b — Output contém markdown explícito.** Confirme que `/full-cycle` imprime `**Antes de escalar para humano:** sugira /reflect --on-failure <N> ...` no momento da parada — não apenas no arquivo, mas no output da sessão.

Após preencher os 4 checks, atualize `prd.json` (ou a próxima `/reflect --retro` automática) marcando US-02 como `passes: true`.

## Guardrails

- Nenhum código de produção é escrito antes do veredicto APROVADO.
- Humano pode interromper em qualquer fase.
- Se qualquer fase falhar, reporte o status e PARE — não improvise.
- **Modelo:** trabalho em `main` local → branch efêmera no push → PR → merge → sync. Branch protection mantida.
