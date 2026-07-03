# Fases 7–8 — Branch efêmera + PR + watch de CI + merge + sync

> Reference compartilhado do `/full-cycle` e `/full-cycle-simple`. Leia APENAS
> ao iniciar a Fase 7.

## Fase 7 — Branch efêmera + Push + PR

Execute `/commit-push-pr "<mensagem em conventional commits>"` no cwd atual.
Esse comando:

- Cria branch efêmera derivada da mensagem (ex: `feat/add-dark-mode`).
- Pusha a branch para `origin`.
- Abre PR via `gh` para `main` (mantém branch protection).
- Auto-merge ON por default — PR mergeia sozinho quando CI passa.
- Reseta `main` local para `origin/main`.

Se `git push` falhar por hook do servidor ou política de proteção, reporte ao
usuário e **PARE** — não tente bypass.

## Fase 8 — Watch de CI em background → merge + sync na notificação

Em vez de bloquear a sessão com polling foreground do CI, dispare
`bin/pr-watch.sh` via Bash `run_in_background: true`. A sessão fica **livre**
durante o watch — o harness re-invoca a sessão quando a task termina (CI
concluído). **Sem polling foreground, sem `ScheduleWakeup`.**

```bash
# run_in_background: true — NÃO bloqueia a sessão; re-invoca na conclusão do CI.
bash $HOME/Projects/dotclaude/bin/pr-watch.sh
```

O helper resolve o PR por `.git/CPP_LAST_PR` (gravado pelo `/commit-push-pr` da
Fase 7) em vez da branch atual — o snippet inline antigo resolvia pela branch e
perdia a corrida quando o auto-merge mergeava/deletava a branch antes do watch
começar (caso real do PR #86). Ele também checa o state ANTES de watchar: PR já
`MERGED` → exit 0 direto (saída feliz, sem watch); `CLOSED` → exit 1; `OPEN` →
`gh pr checks --watch` com teto de 1800s (override: flag `--timeout=<s>`, que
vence a env `PRWATCH_TIMEOUT`). Contrato completo de exit codes no header de
`bin/pr-watch.sh`.

**Princípio 10 (scheduling).** `gh pr checks --watch` em background é o ramo
*evento-conhecido-em-process* da árvore de decisão — não escalar para
`ScheduleWakeup` polling nem loop foreground.

Quando a **notificação de conclusão** chegar, interprete o **exit code** (nem
todo ≠0 é CI vermelho):

- **exit 0 (CI verde / já mergeado / sem checks):**
  1. Se o PR ainda não mergeou (auto-merge não pegou — ex.: repo sem
     `allow_auto_merge`), mergeie via `/force-merge`.
  2. Detecte o pool:
     `REPO=$(basename "$(cd "$(git rev-parse --show-toplevel)" && pwd)" | sed 's/-[0-9]*$//')`.
  3. Rode `/checkout-sync-all <REPO>` para atualizar `main` em todos os slots +
     remover branches locais já mergeadas.
- **exit 142 (timeout do teto):** CI **ainda rodando** — NÃO é vermelho.
  Re-arme o watch (`bin/pr-watch.sh` de novo, em background) ou inspecione
  `gh pr checks` manualmente; se o auto-merge pegar nesse meio-tempo, o próximo
  pr-watch responde MERGED→0.
- **exit 3 (state irresolúvel):** erro transiente do `gh` (rede/5xx) — re-tente
  o watch; não é veredicto do CI nem erro de invocação.
- **exit 2 (invocação inválida):** corrija a chamada — não é veredicto do gate.
- **CI vermelho** (demais exit≠0, tipicamente 1): **PARE** e escale — não
  mergeie com CI falhando.
