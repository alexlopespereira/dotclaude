---
description: Executa o loop Ralph Adversarial — Claude implementa stories do prd.json, Codex revisa cada commit usando a rubrica V2
allowed-tools: Read, Write, Bash(bash *), Bash(chmod *), Bash(cat *), Bash(jq *), Bash(git *)
argument-hint: [--parallel | --parallel=N] [--allow-dirty] [max_iterations, default 10]
---

Executa o loop de implementação Ralph Adversarial.

1. Leia `~/.claude/skills/ralph-adversarial/SKILL.md`.

2. Verifique pré-requisitos:
   - `prd.json` existe na raiz do projeto atual?
   - `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md` existe?
   - `jq` disponível?
   - CLIs dos papéis escolhidos: default exige `claude` e `codex`; se `PRIMARY_AGENT`/`REVIEWER_AGENT` estiverem definidos, valide apenas os escolhidos.

3. Se `prd.json` NÃO existir:
   - Verifique se há plano aprovado em `.claude/plans/`
   - Se sim, ofereça: "Encontrei o plano [nome]. Deseja convertê-lo em prd.json?"
   - Se o usuário concordar, use a skill `prd` para converter.

4. Execute:
   ```bash
   chmod +x ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   bash ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh $ARGUMENTS
   ```

   Para alternar os papéis, exporte as env vars antes (defaults: `claude` implementa, `codex` revisa):
   ```bash
   PRIMARY_AGENT=codex REVIEWER_AGENT=claude \
     bash ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   ```

### Pré-flight de árvore limpa (US-02 — anti-stash)

No **início do `run_serial`**, antes de qualquer iteração ou mutação, o loop roda um pré-flight: se `git status --porcelain` lista qualquer arquivo sujo (tracked-modificado **ou** untracked) **fora da lista de framework files**, o loop **aborta com exit ≠ 0** sem tocar na árvore (nenhum commit/stash/checkout). Isso fecha o vetor do incidente real de 2026-06-10, em que um worker em HANG rodou `git stash push -u` global e varreu o WIP NÃO-commitado do usuário (`vm1.sh`/`vm2.sh`/`vm-paste.sh`).

**Lista de framework files** (sujeira legítima — o próprio Ralph cria/atualiza esses arquivos por design; repos que não os gitignoram, como o dotclaude, têm sujeira por design — ressalva R1 da revisão adversária):

- `prd.json`
- `progress.txt`, `progress-*.txt`, `progress-*.jsonl`
- `agents-delta-*.md`
- `.claude/` (diretório inteiro)
- `graphify-out/` (diretório inteiro)

A **mesma lista** é usada como pathspec de exclusão no `git stash` da rota HANG: quando um agente trava no meio de edits, o stash de salvamento usa `git stash push -u -- '.' :(exclude)<framework files>`, preservando o WIP do worker (`src/*`) mas **deixando os framework files intactos no working tree** (capture-proof: `git stash show` não lista `progress.txt`).

**`--allow-dirty`** pula o pré-flight (assume responsabilidade pela árvore suja). Use quando há, intencionalmente, WIP não-framework na árvore antes de iniciar o loop:

```bash
bash ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh --allow-dirty
```

> O pré-flight cobre **apenas o modo serial** (`run_serial`). O modo `--parallel` tem seu próprio pré-flight por slot (`preflight_slot`) no bootstrap.

5. Após conclusão, apresente resumo:
   - Stories completas vs pendentes vs escaladas
   - Findings P0/P1 encontrados pelo reviewer (Codex ou Claude, conforme `REVIEWER_AGENT`)
   - Conteúdo do progress.txt (aprendizados acumulados)

**Princípio 11 (consistência):** este comando é a Fase 5 do `/full-cycle` quando invocado lá; quando invocado direto, é o ponto de entrada do loop autônomo. Em ambos os casos, transições internas (verificações, execuções por iteração) não pedem confirmação humana — o gate humano é o veredito do reviewer (BLOCK/REQUEST_CHANGES). Humano interrompe via Ctrl-C a qualquer momento.

## Modo paralelo (Fase 2 — story-level parallelism)

Use `--parallel` (ou `--parallel=N`) **a partir de um slot de pool** criado por `/checkout-init`. O slot de invocação atua como orquestrador; os demais slots do pool atuam como workers. O bootstrap (US-05/F5) detecta o pool pelo `$PWD` (regex `^.*/checkouts/<repo>-<N>$`), valida o pré-flight (`core.logAllRefUpdates` ativo, git ≥ 2.9 em cada slot) e imprime `orquestrador=<repo>-<N>, workers=[<lista>]` antes de prosseguir.

Capacidade máxima de workers em paralelo (`compute_cap`):

| Pool size | Slots disponíveis (pool − orquestrador) | Cap default (`RALPH_PARALLEL_N=4`) |
|-----------|----------------------------------------|------------------------------------|
| 1         | 0                                      | aborta — `--parallel exige pool ≥ 2 slots` |
| 2         | 1                                      | 1                                  |
| 3         | 2                                      | 2                                  |
| 5         | 4                                      | 4 (cap atinge `RALPH_PARALLEL_N`)  |

Override via env: `RALPH_PARALLEL_N=2 ralph-adversarial --parallel`.

### Dispatch operacional

`run_parallel` roda um loop de ticks que, a cada iteração, faz na ordem: `poll_workers` (detecta workers concluídos/em HANG) → `poll_review` (drena a fila de review, um por vez) → `dispatch_workers_tick` (preenche slots livres até `compute_cap`). Workers concluídos entram na fila de review; a review é **serializada** (no máximo um review ativo por vez), e só depois os slots livres são re-preenchidos.

**Elegibilidade de despacho (`is_dispatchable`, `lib/dispatch.sh`):** uma story só é co-despachada quando:

- tem `passes: false`, **e**
- toda entrada de `dependsOn` tem `passes: true` (literal `true` — uma dependência `"ESCALATED"` **bloqueia** as dependentes até resolução humana), **e**
- (após US-04) seus `touchesFiles` **não intersectam** os das stories em voo (workers ativos + fila de review). A interseção é por prefixo literal até o primeiro metacaractere glob — conservadora: na dúvida serializa, nunca corrompe. Campo ausente em qualquer lado = sem restrição extra.

Stories sem `dependsOn`/`touchesFiles` herdam o comportamento independente (despacháveis assim que houver slot). O grafo `dependsOn` é checado contra ciclos (`detect_dependsOn_cycle`) — um ciclo aborta o modo paralelo. A geração desses campos é responsabilidade da skill `prd` (veja `skills/prd/SKILL.md`, seção "Campos de DAG paralelo").

Erro de estimativa de `touchesFiles` degrada, no pior caso, para conflito de merge na integração serial (`merge_and_push_story` → `REBASE_CONFLICT`), que já escala para humano — nunca para corrupção silenciosa.
