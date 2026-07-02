---
description: Ciclo end-to-end — planejamento + revisão adversária + PRD + Ralph + PR/merge
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(find *), Bash(bash *), Bash(chmod *), Bash(cat *), Bash(jq *), Bash(git *), Bash(gh *), Bash(ls *), Bash(pwd), Bash(cd *), Bash(echo *), Bash(test *)
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
7. **Docs de domínio (modo batch):** ao salvar o plano, escreva os **termos OBSERVADOS** no `CONTEXT.md` (criação lazy + anúncio de 1 linha) e inclua a seção `## ADRs propostos` com o texto integral de cada ADR que passa no gate triplo. Regras na biblioteca `domain-docs` (`~/.claude/skills/domain-docs/SKILL.md`) — não duplique o formato. Os ADRs materializam no início da fase de execução (Fase 4).

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

0. **Materialização de ADRs (gate `/full-cycle` — início da fase de execução, pós-gate de aprovação da Fase 3):** antes de converter o plano em PRD, materialize a seção `## ADRs propostos` do plano em `docs/adr/` (e os termos cunhados pela solução no `CONTEXT.md`), resolvendo a numeração na hora, e emita o marcador `<!-- adr-materialized -->` na seção do plano. Regras na biblioteca `domain-docs` (`~/.claude/skills/domain-docs/SKILL.md`) — não reproduza o formato aqui. Plano sem seção `## ADRs propostos` → nada a materializar, siga.
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

## Fase 4.5 — Auto-invoke `/test-spec` (TDD bake-in)

Antes da Fase 5 Ralph, gere test specs táticos derivados das DoDs referenciadas no plano. O Ralph implementer lê o plano com a seção `## Test Specs` populada — TDD vira parte do contexto fresco de cada iteração, não disciplina manual.

1. **Resolva o plano alvo:**
   ```bash
   PLAN_PATH=$(jq -r '.sourcePlan // empty' prd.json)
   test -n "$PLAN_PATH" && test -f "$PLAN_PATH" || {
     echo "AVISO: prd.json não declara sourcePlan ou plano não existe — pulando /test-spec." >&2
     # NÃO aborta o pipeline — Fase 4.5 é best-effort (specs são aid, não gate)
   }
   ```

2. **Execute `/test-spec <plan-path>`** (modo plan path da skill `testing` — anexa seção `## Test Specs` no plano com specs para cada `tarefa-N`/`cat-N-base` referenciado como artefato).

3. **Comportamento non-blocking.** Se `/test-spec` falhar (DOD.md ausente, TEST-PATTERNS.md ainda não criado em repo virgem, regex parser quebrado), registre o aviso mas **NÃO interrompa o pipeline** — specs são input de qualidade, não pré-requisito hard. Erro vira finding na Fase 9 reflect.

4. **Após sucesso**, anuncie quantos blocos de spec foram anexados (`grep -c '^### Specs para' "$PLAN_PATH"`) — visibilidade no log do `/full-cycle`.

5. **Propague para Fase 5:** o Ralph lê `$PLAN_PATH` no contexto fresco de cada iteração via `sourcePlan` do prd.json. Specs anexas viajam automaticamente — nenhuma instrumentação extra no Ralph.

**Skip condition:** se o plano já tem seção `## Test Specs` populada (idempotência — re-rodar `/full-cycle` sobre o mesmo plano não duplica), pular sem regenerar. Use `--regenerate` em `/test-spec` se quiser forçar refresh.

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

## Fase 5.5 — Code review nativo (holístico pós-Ralph) ∥ suíte de testes (Fase 6)

Após Ralph completar (Fase 5 verde), execute `/code-review high` para captar simplificações/reuse que o reviewer Codex iteração-por-iteração não vê. Complementa (não substitui) o adversarial do Ralph: o Codex revisa cada commit isoladamente; `/code-review` olha o diff agregado.

**Paralelização Fase 5.5 ∥ Fase 6 (Princípio 9 + `run_in_background`).** A suíte de testes (Fase 6) e o `/code-review high` são independentes — nenhum consome o output do outro — então rodam **concorrentes**. **Antes** de invocar `/code-review high`, dispare a suíte de testes do projeto em background via Bash `run_in_background: true`. Anote o SHA em que o review foi disparado (`REVIEW_BASE_SHA=$(git rev-parse HEAD)`) — a Fase 6 usa esse SHA na regra de re-review. O `/code-review high` roda em foreground na sessão enquanto a suíte progride em background. O **join explícito** (aguardar AMBOS verdes) acontece na Fase 6, antes da Fase 7: o PR **só abre** com code-review sem P0 **e** suíte verde.

```bash
# 1. Marque o SHA coberto pelo review (consumido pela regra de re-review da Fase 6)
REVIEW_BASE_SHA=$(git rev-parse HEAD)
echo "REVIEW_BASE_SHA=$REVIEW_BASE_SHA" >> progress.txt

# 2. Dispare a suíte em background (run_in_background: true) — NÃO bloqueia a sessão.
#    Detecte o runner do projeto (package.json scripts.test, pytest, go test, bin/tests/...).
#    A task re-invoca a sessão na conclusão; o veredicto é avaliado no join da Fase 6.
```

Em seguida, na mesma sessão, invoque `/code-review high` (foreground). Anote findings num bloco `## Code review findings` no `progress.txt` (cwd atual). Princípio 11 aplica — transição interna não pede confirmação humana.

**Gate:**
- **Findings P0 (crítico / segurança / correctness):** PARE — não prossiga para Fase 6. Sugira `/reflect --on-failure 5.5 --context-file <path-com-findings-P0>` antes de escalar pra humano.
- **Findings P1/P2 (simplificação / dead code / nits):** registre no `progress.txt` e prossiga para Fase 6. Humano decide no review do PR se aborda antes do merge.

**Escopo do `/code-review`.** O comando nativo (v2.1.146) analisa por default o diff do working tree / último commit. No modelo Boris (Fase 5 já commitou em `main` local), rode com `git diff origin/main..HEAD` em mente — se a primeira execução mostrar escopo errado, ajustar com argumento ou flag de range na próxima iteração do `/full-cycle`.

**Non-blocking se indisponível.** Se `/code-review` não existir (Claude Code < v2.1.146) ou falhar, registre o aviso e prossiga para Fase 6 — é layer adicional de qualidade, não gate hard.

## Fase 6 — Join: suíte de testes (disparada na Fase 5.5) + code-review

Esta fase é o **ponto de junção** (join) do paralelismo iniciado na Fase 5.5. O PR só abre com **ambos verdes**: suíte de testes **e** `/code-review high` (sem P0). Aguarde a task de testes em background concluir — o `run_in_background` re-invoca a sessão na conclusão; leia o `TaskOutput` e confirme o exit code.

Se a suíte falhar, **PARE** e escale — não abra PR com testes vermelhos.

**Antes de escalar para humano:** sugira `/reflect --on-failure 6 --from-stdin` (alimentado por output do test runner) para entender qual critério DoD teria capturado a falha de teste antes do CI.

**Re-review do parecer após auto-fix (gotcha do paralelismo Fase 5.5 ∥ 6).** O `/code-review high` analisou o diff em `REVIEW_BASE_SHA` (marcado na Fase 5.5). Se a suíte falhou e foram commitadas correções (loop de auto-fix) **depois** desse SHA, esses fix-commits **não foram revisados**. Antes de prosseguir para a Fase 7, escolha uma das duas opções:
   - **(a) Re-review do delta:** re-rode `/code-review high` restrito ao range dos fix-commits — `git diff $REVIEW_BASE_SHA..HEAD`. Use quando o delta tem lógica nova/não-trivial.
   - **(b) Registrar SHA coberto:** se o delta for trivial (ajuste de teste, typo, formatação), registre em `progress.txt` a linha `CODE_REVIEW_VALID_UNTIL=<REVIEW_BASE_SHA>` documentando até onde o parecer original é válido, mais o range não-revisado (`$REVIEW_BASE_SHA..HEAD`).

   Se nenhum fix-commit ocorreu após `REVIEW_BASE_SHA` (suíte passou de primeira), o parecer cobre todo o diff e nenhuma das duas é necessária.

## Fase 7 — Branch efêmera + Push + PR

Execute `/commit-push-pr "<mensagem em conventional commits>"` no cwd atual. Esse comando:

- Cria branch efêmera derivada da mensagem (ex: `feat/add-dark-mode`).
- Pushaa branch para `origin`.
- Abre PR via `gh` para `main` (mantém branch protection).
- Reseta `main` local para `origin/main`.

Se `git push` falhar por hook do servidor ou política de proteção, reporte ao usuário e **PARE** — não tente bypass.

## Fase 8 — Watch de CI em background → merge + sync na notificação

Em vez de bloquear a sessão com polling foreground do CI, dispare `bin/pr-watch.sh` via Bash `run_in_background: true`. A sessão fica **livre** durante o watch — o harness re-invoca a sessão quando a task termina (CI concluído). **Sem polling foreground, sem `ScheduleWakeup`.**

```bash
# run_in_background: true — NÃO bloqueia a sessão; re-invoca na conclusão do CI.
bash $HOME/Projects/dotclaude/bin/pr-watch.sh
```

O helper resolve o PR por `.git/CPP_LAST_PR` (gravado pelo `/commit-push-pr` da Fase 7) em vez da branch atual — o snippet inline antigo resolvia pela branch e perdia a corrida quando o auto-merge mergeava/deletava a branch antes do watch começar (caso real do PR #86). Ele também checa o state ANTES de watchar: PR já `MERGED` → exit 0 direto (saída feliz, sem watch); `CLOSED` → exit 1; `OPEN` → `gh pr checks --watch` com teto de 1800s (override: flag `--timeout=<s>`, que vence a env `PRWATCH_TIMEOUT`). Contrato completo de exit codes no header de `bin/pr-watch.sh`.

**Princípio 10 (scheduling).** `gh pr checks --watch` em background é o ramo *evento-conhecido-em-process* da árvore de decisão — não escalar para `ScheduleWakeup` polling nem loop foreground.

Quando a **notificação de conclusão** chegar, interprete o **exit code** (nem todo ≠0 é CI vermelho):
- **exit 0 (CI verde / já mergeado / sem checks):**
  1. Se o PR ainda não mergeou (auto-merge não pegou), mergeie via `/force-merge`.
  2. Detecte o pool: `REPO=$(basename "$(cd "$(git rev-parse --show-toplevel)" && pwd)" | sed 's/-[0-9]*$//')`.
  3. Rode `/checkout-sync-all <REPO>` para atualizar `main` em todos os slots + remover branches locais já mergeadas.
- **exit 142 (timeout do teto):** CI **ainda rodando** — NÃO é vermelho. Re-arme o watch (`bin/pr-watch.sh` de novo, em background) ou inspecione `gh pr checks` manualmente; se o auto-merge pegar nesse meio-tempo, o próximo pr-watch responde MERGED→0.
- **exit 3 (state irresolúvel):** erro transiente do `gh` (rede/5xx) — re-tente o watch; não é veredicto do CI nem erro de invocação.
- **exit 2 (invocação inválida):** corrija a chamada — não é veredicto do gate.
- **CI vermelho** (demais exit≠0, tipicamente 1): **PARE** e escale — não mergeie com CI falhando.

## Fase 9 — Reflexão sobre DoD (gate heurístico --learn vs --baseline)

Após o sync dos slots, dispare a reflexão sobre DoD como **subprocess headless** `claude -p "/reflect <PR> <modo>"` em **background** (não inline). O subprocess é um processo `claude` novo: usa o **modelo padrão configurado do Claude Code** (settings/`/model`), não herda o modelo volátil da sessão pai (pattern slash-command-via-claude-p já em produção em `bin/reflect-retro-due.sh`). Para pinar um modelo específico, acrescente `--model <id>`. O modo é decidido por gate heurístico inline (AC9 do US-02): `--learn` quando o ciclo correu **anômalo** (precisa LLM analisar a TDD-chain por US), `--baseline` quando correu **limpo** (compliance retroativa basta).

```bash
PR_NUMBER=$(gh pr list --state merged --limit 1 --base main --json number --jq .[0].number)

# Gate heurístico: NEED_LEARN se QUALQUER destes for verdadeiro
NEED_LEARN=false

# (a) prd.json tem alguma US escalada
if test -f prd.json && jq -e '.userStories[]? | select(.passes=="ESCALATED")' prd.json >/dev/null 2>&1; then
  NEED_LEARN=true
fi

# (b) progress.txt registrou ≥2 REVIEW_BLOCK ou REVIEW_REQUEST_CHANGES.
# Gotcha: `grep -c` exit 1 em zero matches imprime "0" no stdout — combinar
# com `|| echo 0` produz "0\n0" e quebra `[ -ge ]` ("integer expression
# expected"). Padrão correto: `VAR=$(...) || VAR=0` (fallback substitui,
# não concatena).
if test -f progress.txt; then
  REVIEW_COUNT=$(grep -cE 'REVIEW_BLOCK|REVIEW_REQUEST_CHANGES' progress.txt 2>/dev/null) || REVIEW_COUNT=0
  if [ "$REVIEW_COUNT" -ge 2 ]; then NEED_LEARN=true; fi
fi

# (c) auto-fix loop disparou (marcador AUTOFIX_TRIGGERED em progress.txt)
if test -f progress.txt && grep -q 'AUTOFIX_TRIGGERED' progress.txt 2>/dev/null; then
  NEED_LEARN=true
fi

REFLECT_MODE=$([ "$NEED_LEARN" = "true" ] && echo --learn || echo --baseline)

# Subprocess headless em background usando o modelo padrão do Claude Code
# (sem --model — processo novo lê o default configurado, não herda a sessão).
# `&` + `disown` garantem que a Fase 9 não bloqueia o término do pipeline; o
# redirect captura o output pra inspeção pós-merge sem poluir a sessão.
mkdir -p ~/.claude/cache/reflect
REFLECT_NESTED=1 REFLECT_LEARN_GATE=$([ "$NEED_LEARN" = "true" ] && echo 1 || echo 0) \
  claude -p "/reflect $PR_NUMBER $REFLECT_MODE" \
  >> ~/.claude/cache/reflect/fase9-fullcycle.log 2>&1 &
disown
```

**Comportamento non-blocking.** O subprocess roda em background (`&` + `disown`): a falha dele (PR não correlaciona com plano, `gh` offline, sessão `/auto-grill-me` ausente, modelo indisponível) **NÃO interrompe o pipeline** — reflexão é auditoria, não gate, e o exit code do background job nem é colhido. O pipeline já considerou Fase 8 (sync) como término efetivo da entrega; Fase 9 apenas anexa metadado de qualidade (output em `~/.claude/cache/reflect/fase9-fullcycle.log`).

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
