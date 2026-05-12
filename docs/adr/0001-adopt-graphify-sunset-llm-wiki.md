# ADR 0001 — Adopt Graphify; sunset llm-wiki

## Status

Accepted — 2026-05-03

## Context

Antes desta decisão, o repo `dotclaude` mantinha em `bootstrap/llm-wiki/` um sistema próprio para gerar e manter "wikis de repositório" via LLM. O sistema:

- Mantinha `wiki/` markdown versionado por módulo top-level no repo-alvo.
- Atualizava automaticamente em PR merged via GitHub Action (`wiki-update.yml`) usando subscription Claude Code via OAuth token.
- Validava estrutura via `wiki-lint.py` (lint bloqueava merge se wiki saísse de sincronia).
- Era instalado em repos novos via `bootstrap/llm-wiki/install.sh`.

Em paralelo, surgiu o projeto open-source [Graphify](https://github.com/safishamsi/graphify) (PyPI: `graphifyy`), que produz **knowledge graph** local (não wiki) sobre o código do repo. Trade-offs comparativos:

| Aspecto | llm-wiki (próprio) | Graphify (externo) |
|---|---|---|
| Output | Markdown por módulo | `graph.json` + `graph.html` viewer + `GRAPH_REPORT.md` |
| Auto-update | GitHub Action em PR merged (LLM cost por PR) | Git hook post-commit/post-checkout local (AST-only, zero API cost) |
| Query/exploração | Apenas leitura de markdown | Knowledge graph queriable: `graphify query`, `graphify path`, MCP server |
| Custo de manutenção (do código do bootstrap) | Alto — script bash, workflow YAML, lint Python, AGENTS.md template | Zero — projeto upstream mantém |
| Lock-in | Próprio | Externo (mas open source MIT) |
| Provedor LLM | Claude Code OAuth via Action | Claude Code subagent via skill.md (subscription) — default zero-cost |
| Determinismo / staleness | Lint bloqueia merge se stale | Hook git rebuild automático após cada commit |

## Decision

1. **Adotar Graphify como sistema de knowledge graph para repos pessoais e de produto.**
2. **Descontinuar `bootstrap/llm-wiki/`** — diretório será deletado.
3. **Versionar `graphify-out/`** seguindo recomendação oficial do autor (README:183–197), com `.gitignore` excluindo apenas `manifest.json`, `cost.json` e `cache/`.
4. **Estratégia de merge:** `.gitattributes` com `graphify-out/graph.json merge=theirs` — em conflito durante `git pull`/`/sync`, preserva versão de `origin/main`. Após pull, regenerar localmente via `graphify .` para realinhar.
5. **Bootstrap pra repos novos:** criar slash command `/graphify-init` que executa os 6 passos canônicos (build inicial, `graphify claude install`, `graphify hook install`, `.gitignore`, `.gitattributes`, commit). Estender `/checkout-init` para rodar `graphify hook install` + `graphify claude install` em cada um dos 5 slots Boris automaticamente.
6. **Hook PreToolUse per-repo (não global):** seguir default de `graphify claude install` (grava em `.claude/settings.json` versionado no repo). Garante que colaboradores que clonem herdem o hook automaticamente; coexiste sem conflito com hook global de secret-scan.

## Consequences

### Positive
- Zero custo de LLM em rebuilds incrementais (hook AST-only, sem API call).
- Primeira build (`graphify .`) usa subscription Claude Code via subagent — zero custo de API.
- Onboarding: novo dev/slot dá `git pull` e já tem o grafo (artefato versionado).
- Eliminação de manutenção de código (~200 linhas Python+bash+YAML do llm-wiki).
- Slash commands `graphify query`, `graphify path` adicionam capacidades novas vs. wiki estática.

### Negative
- Dependência externa (PyPI `graphifyy`) — bug upstream pode bloquear workflow.
- `graph.json` versionado polui PR diff (JSON denso, ~MB em repos grandes).
- `merge=theirs` significa que `graph.json` no `main` reflete sempre o último PR merged — pode estar momentaneamente fora-de-sincronia com working tree local até `graphify .` rodar.
- `post-commit` hook é background-detached; commit que faz mudança grande de código produz `graph.json` regenerado em commit *seguinte*, não no atual (lag de 1 commit).
- Quando 2 slots Boris tocam código no mesmo intervalo, conflito de merge no `graph.json` é garantido — `merge=theirs` resolve automaticamente, mas exige que o usuário entenda o modelo.

### Mitigations
- Lock da versão do `graphifyy` em `pyproject.toml` por repo, pra evitar surpresa quando upstream mudar formato do JSON.
- `/sync` deve rodar `graphify .` ao final pra realinhar `graph.json` local com working tree pós-pull.
- Documentar o "lag de 1 commit" no `/graphify-init` README pra usuário saber.

## Alternatives considered

- **(A) Não-versionar `graphify-out/`** (oposto da convenção upstream) — exigiria que cada slot Boris rodasse `graphify .` após pull. Rejeitado: alto atrito de onboarding, perde benefício do hook PreToolUse que avisa o agente antes de cada `Glob`/`Grep`.
- **(B) Híbrido — versionar só `GRAPH_REPORT.md`** — análogo ao padrão llm-wiki. Rejeitado: hook PreToolUse usa `graph.json` como sentinela, então em fresh checkout o agente não seria avisado de existir grafo. Também requereria CI customizado para manter o report fresco em `main`.
- **(C) Manter llm-wiki + adotar Graphify lado-a-lado** — rejeitado: duplica esforço de manutenção e produz dois artefatos para o agente consultar.

## References

- Upstream: https://github.com/safishamsi/graphify
- README oficial linhas 183–197: "Team setup" recommending versioning of `graphify-out/`.
- Graphify hooks implementation: `graphify/hooks.py` — pula durante rebase/merge/cherry-pick; rebuild background-detached.
- LLM provider default: `graphify/llm.py:3` — "default pipeline uses Claude Code subagents via skill.md".

## Errata — 2026-05-07

A primeira encarnação de `/graphify-init` (PR #9, commit `fb555b2`) e do `bin/graphify-init.sh` chamava `graphify .` como se fosse subcomando da CLI. Isso nunca funcionou: `graphify .` é um **slash command de agente AI** (`/graphify .` em Claude Code/Cursor/etc) servido pela skill `~/.claude/skills/graphify/SKILL.md` (instalada via `graphify install`) — não há subcomando `.` no binário shell. Mesmo bug existia em `bin/checkout-sync-all.sh:92` (regenerar grafo pós-pull no `/sync`).

**Refatoração:**

- **Build inicial saiu do shell script.** Voltou a ser responsabilidade do agente que invoca `/graphify-init`. O markdown do slash (`commands/graphify-init.md`) agora orquestra dois passos: (1) `Skill(graphify)` na cwd para o build inicial, zero-cost via subagents Claude Code (subscription); (2) `bin/graphify-init.sh` para os passos shell-puros (`graphify claude install`, `graphify hook install`, `.gitignore`/`.gitattributes`, commit local).
- **`bin/graphify-init.sh` ganhou pre-flight check:** aborta se `graphify-out/graph.json` não existir (sinal de que o agente pulou o passo 1). Removidas as flags `--force`/`--skip-rebuild` do script (agora interpretadas no markdown do slash); mantida `--allow-dirty`.
- **`bin/checkout-sync-all.sh:92`:** trocado `graphify .` por `graphify update .` (CLI subcomando documentado em `--help` — AST-only, zero LLM, headless). É o comando correto pra "realinhar pós-pull" sem precisar de agente AI rodando, e a condição de existência de `graphify-out/graph.json` (já presente no script) garante o pré-requisito do `update`.

A intenção original do ADR — zero custo via subscription, knowledge graph versionado, hook AST-only — permanece intacta. O que mudou é o **mecanismo de invocação** do build inicial (e a documentação interna distinguindo CLI subcomando × slash command de agente).

## Errata — 2026-05-08

A decisão 5 dizia "Estender `/checkout-init` para rodar `graphify hook install` + `graphify claude install` em cada um dos 5 slots Boris automaticamente". A parte sobre `graphify claude install` produziu um problema operacional repetido: rodar `claude install` em cada slot modifica `CLAUDE.md` e `.claude/settings.json` (arquivos **versionados** — decisão 6) sem commitar. Resultado: todos os N slots ficavam dirty contra `origin/main`, e `/sync` bloqueava silenciosamente até intervenção manual. Observado pela primeira vez no provisionamento de `assistente-aulas` (PR #14 daquele repo).

**Refinamento — fronteira clara de responsabilidade:**

- **`/graphify-init` é o único dono da config versionada.** O script já era idempotente: `graphify claude install` retorna no-op (`"already configured in CLAUDE.md"`) quando re-rodado, e `bin/graphify-init.sh` continua aplicando os passos shell-puros idempotentemente (`grep -qxF` em `.gitignore`/`.gitattributes`, `git diff --cached --quiet` antes de commit). Cobre tanto bootstrap inicial quanto retrofit de repos que tinham `graphify-out/` mas faltavam a config claude.
- **`/checkout-init` cuida apenas dos hooks per-clone.** Hooks vivem em `.git/hooks/` (não viajam com push). `checkout-init.sh` agora chama **somente** `graphify hook install` em cada slot, e **somente** se o repo já é Graphified em main (gating: `graphify-out/graph.json` presente no slot 1 recém-clonado). A chamada `graphify claude install` foi removida.
- **`/sync` (`checkout-sync-all.sh`) reinstala hooks pós-pull idempotentemente.** Cobre o caso "repo virou Graphified depois do pool ser criado": `/graphify-init` num slot único → `/commit-push-pr` → merge → `/sync` propaga `graphify-out/` aos N slots **e** ativa hooks per-clone. Sem ação manual.

**Garantia de regressão:** novo teste `bin/tests/test_checkout_init_graphify_gating.sh` cobre 4 cenários (Graphified+CLI presente / não-Graphified / `--no-graphify` / CLI ausente) com `graphify` mockada via PATH. O teste valida que `claude install` **nunca** é invocado pelo `checkout-init` e que `hook install` só corre quando o gating positivo passa.

A intenção original — config Graphify versionada e propagada para colaboradores via clone — segue intacta. O que mudou é **quem** materializa essa config: `/graphify-init` (entry-point único), não dois caminhos paralelos com semântica diferente.

## Errata — 2026-05-12

Observação operacional: após `/sync`, todos os 5 slots ficavam dirty em `graphify-out/{.graphify_root,GRAPH_REPORT.md,graph.html,graph.json}` com diff massivo (graph.json: +9.729 / −2.802 linhas no advisory-ia), e o próximo `/sync` pulava todos por causa do dirty-check de `checkout-sync-all.sh:43`. Diagnóstico inicial atribuiu o problema a não-determinismo do `graphify update .` — incorreto.

**Causa raiz:** drift de versão da CLI graphify entre o momento em que os artefatos foram committados (PR #11 do advisory-ia: graphify 0.7.8) e a CLI local (0.7.10). A 0.7.10 mudou o extrator (267 nodes → 636 nodes no mesmo código), adicionou seção "Graph Freshness" ao `GRAPH_REPORT.md`, e ajustou o formato do título. `graphify update .` é determinístico para uma dada versão da CLI — o problema era que ninguém detectava o drift.

**Agravado por contradição lógica em `checkout-sync-all.sh`:** o regen pós-pull (linha 96) deixa `graphify-out/` dirty por design (Errata 2026-05-07), mas o dirty-check no topo do loop (linha 43) pula slot quando vê dirty. Isso quebrava idempotência: sync N produz dirt → sync N+1 pula. A Mitigação #1 do ADR ("lock da versão do `graphifyy` em `pyproject.toml` por repo") nunca foi enforçada, então drift acontecia silenciosamente a cada `graphify install`.

**Fix em três camadas:**

- **L1 — Idempotência:** `bin/checkout-sync-all.sh` agora executa `git checkout -- graphify-out/` antes do dirty-check. O regen anterior é descartado (seguro: arquivos derivados, serão refeitos pós-pull). Dirty-check passa a ver só código de usuário. Sync vira realmente idempotente sem violar a regra "graphify-out/ é versionado".
- **L2 — Detecção de drift:** novo helper compartilhado em `bin/lib/graphify_version.sh` (`_graphify_installed_version` via `uv tool list` com fallback `pip show graphifyy`; `_graphify_drift_check` compara versão local com `graphify-out/.graphify_version`). `/graphify-init` grava o arquivo durante bootstrap; `/sync` avisa quando há mismatch e sugere `/commit-push-pr 'chore: refresh graphify-out/'`. Warning não bloqueia — apenas informa.
- **L3 — Refresh one-time por repo:** repos com artefatos pré-2026-05-12 precisam de um PR de refresh manual (`graphify update . && /commit-push-pr 'chore: refresh graphify-out/ (CLI 0.7.10)'`) pra alinhar committed = output da CLI atual. Sem isso, L2 emite warning permanentemente nesses repos até alguém fazer o refresh.

**Garantia de regressão:** dois novos testes em `bin/tests/`. (a) `test_graphify_drift.sh` cobre 8 cenários unitários dos helpers (uv presente/ausente, pip fallback, drift detectado, versões iguais, arquivo ausente, arquivo vazio, indetectável). (b) `test_checkout_sync_idempotent.sh` cobre 6 cenários integração com git repo + remote real em tmpdir (slot limpo, slot dirty em graphify-out, slot dirty fora de graphify-out, sync 2× consecutivo, drift integrado, sem drift).

**Por que não as alternativas óbvias:**

- ~~`git update-index --skip-worktree graphify-out/*`~~ — local-only, perde mudanças remotas legítimas em `graph.json`, precisa repetir a cada reprovisionamento.
- ~~Mover `graphify-out/` pro `.gitignore`~~ — viola Decision 3 do ADR (versionar é proposital — onboarding + hook PreToolUse precisa do `graph.json` em fresh clone).
- ~~Investigar não-determinismo no `graphify update`~~ — não existe; é drift de versão.

**Adendo (post-fix): aceitar dirt como design via instrução na CLAUDE.md.**

Tentativa de L3 refresh (1 PR por repo) revelou causa adicional além do drift de CLI: o community detection do upstream graphify é **não-determinístico entre runs** mesmo com mesma CLI e mesmo código. Comparação direta após sync alinhar todos os slots a `origin/main`:

- slot-1 `graph.json`: 636 nodes, mesmos labels/files/ids
- slot-2 `graph.json`: 690 nodes, mesmos labels/files/ids — porém `"community": 5` onde slot-1 tinha `"community": 2` (cluster IDs reordenados)
- diff: ~1100 linhas em `graph.json` puramente por reatribuição de communities

Combinado com `.graphify_root` per-slot (`watch.py:140` grava caminho absoluto) e título de `GRAPH_REPORT.md` usando `basename(cwd)` (`watch.py:28-31`), os 4 arquivos `graphify-out/{.graphify_root,GRAPH_REPORT.md,graph.json,graph.html}` **nunca convergem entre slots Boris sem patch upstream**.

**Decisão (opção B do plan `verifique-se-a-proposta-hashed-tome.md`):** aceitar dirt como design e instruir o agente Claude via subseção dedicada na `CLAUDE.md` ("Graphify: dirt em `graphify-out/` é design, não bug"). Em vez de propagar L1 (descarte de `graphify-out/`) por N scripts mutantes (whack-a-mole), o agente reconhece o padrão e aplica `git checkout -- graphify-out/` sob demanda quando um comando do `gh`/`git` falhar com "would be overwritten by checkout" citando esses paths. Também cobre comandos ad-hoc, não só scripts em `bin/`.

Alternativas rejeitadas:

- **Reverter Decision 3 (gitignorar `graphify-out/`)** — perde hook PreToolUse em fresh clone (depende de `graph.json` presente para alertar o agente).
- **PR upstream pra clustering determinístico** — fix correto a longo prazo, mas dependência externa não-bloqueante; instrução cobre 100% dos casos hoje.
- **L1 em todos os scripts mutantes** — sustenta-se mas é whack-a-mole; cada script novo precisaria do pattern. Instrução universal cobre também comandos ad-hoc fora de `bin/`.
