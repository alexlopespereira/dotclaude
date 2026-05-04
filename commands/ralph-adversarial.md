---
description: Executa o loop Ralph Adversarial — Claude implementa stories do prd.json, Codex revisa cada commit usando a rubrica V2
allowed-tools: Read, Write, Bash(bash *), Bash(chmod *), Bash(cat *), Bash(jq *), Bash(git *)
argument-hint: [--parallel | --parallel=N] [max_iterations, default 10]
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

> **Nota US-05:** `run_parallel` ainda delega ao `run_serial`; o dispatch real para os workers chega em US-06 (F6). O modo paralelo já valida o pool e exibe orquestrador/workers, mas as stories rodam serialmente até essa fase.
