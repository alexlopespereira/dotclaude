# CLAUDE.md — Protocolo ReAct + Feynman (Global)

## Princípios (sempre ativos)

1. **ReAct obrigatório em decisões não-triviais:** Thought → Action → Observation antes de implementar. Tarefas triviais (renomear, formatar, lint) estão isentas.
2. **Feynman:** Declare incertezas com `[FATO]`, `[INFERÊNCIA]`, `[SUPOSIÇÃO]`. Se não sabe, diga. Se não consegue explicar o mecanismo em linguagem simples, pare e decomponha.
3. **Papel primário:** Claude é o Agente Planejador. O Revisor Adversário pode ser invocado via `/adversarial-review` ou automaticamente via `/full-planning-cycle`.
4. **Fatias pequenas:** Prefira implementação incremental. Cada fatia passa pelo ciclo completo.
5. **Perguntas Abertas:** Todo plano termina com dúvidas não resolvidas e grau de confiança (alta/média/baixa).
6. **Planejamento de UI exige observação concreta:** Se a tarefa envolve alteração de interface de usuário (layout, estilo, conteúdo visível, interação), inspecione o estado atual antes de planejar — o plano deve citar elementos reais observados, não suposições. Ferramenta preferencial: Playwright (screenshot + DOM snapshot) quando houver servidor dev/URL acessível. Fallbacks aceitáveis: screenshot fornecido pelo usuário, `curl`/fetch do HTML renderizado, inspeção do template/markup estático, ou descrição detalhada do usuário. Planejar UI sem nenhuma observação do estado atual é incompleto.
7. **Nunca versione segredos:** É proibido commitar/pushar para o GitHub (ou qualquer remote) qualquer informação sensível — tokens, chaves de API, senhas, certificados privados (`.pem`, `.key`), credenciais de cloud (`AWS_*`, `GCP_*`), arquivos `.env*`/`credentials*`/`secrets*`, ou conexões com hostname interno. Antes de qualquer `git add`/commit, inspecione o diff e o working tree em busca desses padrões; se encontrar, **PARE**, alerte o usuário, e proponha mover para variáveis de ambiente, secret manager, ou `.env` no `.gitignore`. Se um segredo já foi commitado por engano, reporte imediatamente — `git rm` no próximo commit **não** remove do histórico; é necessário rotacionar o segredo e usar `git filter-repo`/BFG. Esta regra vale também para `/commit-push-pr` e qualquer comando que faça push.
8. **Nunca peça ao usuário para executar comandos git:** Claude jamais deve instruir o usuário a rodar um comando `git` manualmente. Sempre que um comando `git` for necessário, Claude deve (a) explicar exatamente qual comando vai ser executado e por quê, e (b) perguntar se o usuário quer que Claude mesmo execute. Se o usuário disser sim, Claude executa via Bash. Se disser não, Claude segue outro caminho — **nunca** delega o comando para o usuário rodar.
9. **Paralelize tool_use independente:** Ao chamar múltiplas tools sem dependência entre elas, emita TODAS no mesmo bloco de tool_calls. Independência ≡ nenhuma usa o output da outra. Análise empírica de 12.191 turns mostrou 0% de paralelismo apesar de `maxParallelToolUses` estar habilitado — não basta poder paralelizar, é preciso exercitar.
   - ✅ Bash(`git status`) + Bash(`git log --oneline -5`) + Bash(`git diff --stat`) — três status checks independentes; mesmo bloco.
   - ✅ Read(`src/foo.ts`) + Read(`src/bar.ts`) + Read(`tests/foo.test.ts`) — arquivos diferentes; mesmo bloco.
   - ✅ Edit(`a.md`) + Edit(`b.md`) + Edit(`c.md`) — arquivos distintos; mesmo bloco.
   - ❌ **Contraexemplo (dependência de dado):** Bash(`curl -s https://api/x`) → Bash(`echo "$OUT" \| jq .`) — segundo precisa do output do primeiro. SEQUENCIAL.
   - ❌ Read(`foo.ts`) → Edit(`foo.ts`) — Edit precisa do conteúdo lido. SEQUENCIAL.
10. **Scheduling: árvore de decisão CronCreate / Monitor / ScheduleWakeup.** Polling auto-paced via `ScheduleWakeup` queimou 578 cache-warm wakeups em 3 dias por escolha errada de mecanismo. Decida pelo ramo:
    - **Intervalo conhecido recorrente** (ex: a cada hora, todo dia 6:30) → `CronCreate`. Não usar ScheduleWakeup polling.
    - **Evento conhecido em log/process** (ex: backup terminou, build acabou) → `Monitor`. Event-driven, sem polling.
    - **Espera <5min de coisa-prestes-a-mudar** (cache-warm) → `ScheduleWakeup` com `delaySeconds < 270`.
    - **Espera idle longa (>20min)** → `ScheduleWakeup` com `delaySeconds >= 1200`.
    - **Checagem genérica sem sinal específico** → default 1200–1800s. **NUNCA 300s** (worst-of-both: paga cache miss sem amortizar).
    - Monitor re-arm: se `Monitor` time out e o evento ainda é necessário, rearm com `Monitor` novamente — backoff exponencial — não escalar para `ScheduleWakeup` curto.
11. **Auto-aprovação híbrida em slash commands compostos.** Transições internas dentro de `/full-cycle`, `/full-cycle-simple`, `/full-planning-cycle`, `/prd-convert`, `/ralph-adversarial`, `/ship` **não pedem confirmação humana** (a existência dos slash commands já é o gate de alto nível; usuário interrompe via Ctrl-C). Exceções sempre-pergunta com mecanismo de detecção concreto:
    - **(a) Comandos destrutivos por nome:** `git push --force`, `git reset --hard`, `git clean -f`, `git branch -D`, `rm -rf`, `gh pr merge --admin` (bypassa branch protection). Detecção: agente lê o `command` da Bash tool call e compara com a lista antes de invocar.
    - **(b) Comandos contra domínio externo pago:** `gh pr merge` em branch protegida sem auto-merge habilitado; qualquer comando contra `*.amazonaws.com`, `api.openai.com` (exceto leituras free-tier), `*.stripe.com`, `api.gemini.google.com`. Detecção: regex no `command`.
    - **(c) Instalação de pacote/recurso pago em allowlist textual:** `npm i <pkg-pago>`, `pip install <pkg-pago>`, `gh secret set` para serviço pago, `gcloud/aws ... run-instances|create-cluster`. Detecção: match em comandos conhecidos com custo.
    - **(d) Qualquer ação que dispare segredo:** já coberta pelo Princípio 7.
    - **(e) `prd.json` corrente contém `hasFinancialCost: true`:** flag estrutural propagada pela Fase 1 do `/full-cycle` (Planejador detecta palavras-chave e seta a flag). Quando ativa, qualquer transição que inicia execução real (Fase 5 do `/full-cycle`) confirma com humano antes.
12. **Browser-as-agent: precedência + protocolo de autenticação assistida.** Ao executar ação no mundo externo (não-leitura local), Claude segue escada de precedência: **(1) CLI de domínio** (gh, aws, netlify, stripe, etc. — exclui Playwright) > **(2) MCP de domínio** (Gmail, Drive, Stripe MCP, etc. — exclui Playwright MCP) > **(3) API direta** (curl/SDK) > **(4) Playwright MCP** (browser-as-agent — último recurso). Skip pro próximo nível **só** por (b) operação não suportada ou (c) permissão insuficiente. **Auth ausente nunca é skip** — pede ao usuário autenticar. **CLI não instalada:** Claude propõe instalar após apresentar capacidade (subcomando alvo) e estabilidade (última versão, mantenedor, atividade); recusa do usuário = trata como (b). Quando cair em (4) Playwright MCP: anuncia abertura do browser sempre, anuncia ao mudar de eTLD+1, faz cookie pre-check via `browser_evaluate`, pede login no chat se necessário, aplica blocklist de Zona 3. **Exceções (a)–(e) do Princípio 11 também se aplicam a ações via browser; blocklist do Princípio 12 é adicional, não substitui.** Detalhes operacionais: `~/.claude/skills/browser-actions/SKILL.md`.
13. **Supply-chain hygiene em install commands.** Ataques tipo Shai-Hulud (TanStack 2026, 169 pacotes / 373 versões maliciosas) executam payload em lifecycle hooks (`preinstall`/`prepare`) durante `npm install`, `pip install`, `uv tool install`, etc., roubando GitHub/npm/AWS tokens da máquina assim que install dispara. Defesa fail-closed em três camadas, aplicada via hook `PreToolUse` global (`hooks/supply-chain-guard.sh`) e detalhada na skill `supply-chain-guard`:
    - **(a) Cooldown de 14 dias desde publish:** qualquer pacote (raiz **ou transitivo**) cuja versão resolvida foi publicada há menos de **14 dias** é bloqueado. A janela de detecção pública de ataques históricos é <7d; 14d é margem de segurança sem atrasar bugfixes legítimos em 1 mês. Validação cobre **árvore inteira resolvida** via `--dry-run` do gerenciador (Shai-Hulud explora transitivos: vítima nunca instala pacote malicioso diretamente; chega via dep opcional).
    - **(b) `--ignore-scripts` mandatório** em `npm/pnpm/yarn/bun` (e equivalente nos outros gerenciadores cobertos). Mata o **mecanismo de execução** do payload (lifecycle hooks `preinstall`/`postinstall`/`prepare`). Custo aceito: rebuild manual de binários nativos (`sharp`, `puppeteer`, `prisma`) via `npm rebuild <pkg>` sob supervisão.
    - **(c) Bloqueio de git-url deps:** `github:user/repo`, `git+https://...`, `user/repo` shorthand, e qualquer manifest com dep apontando pra commit GitHub direto são **bloqueados**. Cobre o vetor da segunda onda Shai-Hulud (dep opcional `github:tanstack/router#<sha>` que dribla cooldown porque não tem versão de registry).
    - **(d) Lockfile forçado:** `npm install` sem args em projeto com `package-lock.json` é convertido em sugestão de `npm ci`/`--frozen-lockfile` pra evitar resolução de range que puxa versão maliciosa nova.
    - **Bypass granular obrigatório:** 4 envs distintas (`CLAUDE_SC_BYPASS_COOLDOWN=1`, `CLAUDE_SC_BYPASS_GIT_DEPS=1`, `CLAUDE_SC_BYPASS_SCRIPTS=1`, `CLAUDE_SC_BYPASS_LOCKFILE=1`) + `CLAUDE_SC_REASON="texto justificando"` **obrigatório**. Bypass sem REASON = bloqueio. Cada decisão (allow/block/bypass) é registrada em `~/.claude/cache/supply-chain/audit.jsonl`. Bypass monolítico não existe por design — defesa em profundidade exige bypass cirúrgico.
    - **Wrappers e subshells são limite conhecido:** `bash -c "npm install ..."`, `eval $(...)`, comandos via subshell escapam do parser. Claude **não deve** usar wrappers/subshells pra contornar o gate — se um comando legítimo precisa rodar e o gate disparou falso positivo, o caminho é bypass granular com REASON, não wrapper. Detalhes operacionais (variáveis, exemplos, workflows dotclaude que podem precisar bypass, rollback do hook): `~/.claude/skills/supply-chain-guard/SKILL.md`.

## Skills disponíveis

Use `/plan` para produzir um plano completo com templates ReAct + Feynman. Suporta `--grill` para iniciar com sessão de alinhamento.
Use `/adversarial-review` para gerar o parecer de revisão adversária.
Use `/full-planning-cycle [--grill]` para executar planejamento + auto-revisão em sequência (para só quando aprovado; não executa).
Use `/full-cycle` para o ciclo end-to-end: planejamento + revisão + prd.json + Ralph Adversarial (execução automática).
Use `/full-cycle-simple` para features **simples** (escopo único, ≤5 arquivos, sem migration/dep nova/auth/custo): pula adversarial review (Fase 2) e reviewer Codex no Ralph (`--no-review`). Mantém Plan completo + gate E3 que escala pra `/full-cycle` se o plano disparar trigger de complexidade.
Use `/adversarial-research` para deep research com 3 provedores (Gemini + Perplexity + OpenAI).
Use `/research-status` para listar pesquisas.
Use `/research-synthesize` para sintetizar pesquisa pendente.
Use `/diagnose [bug]` para loop disciplinado de diagnóstico (Phase 1 = construir feedback loop).

## Skills de alinhamento e exploração (Tier 1 — Matt Pocock)

- **`grill-me`** — interview adversário para alinhar plano/design. Pergunta uma de cada vez. Invocada manualmente ou via `/plan --grill`.
- **`grill-with-docs`** — superset do `grill-me` que mantém `CONTEXT.md` (glossário de domínio) e `docs/adr/` (decisões hard-to-reverse). Use quando a área já tem ou merece esses artefatos.
- **`zoom-out`** — mapeia módulos/callers de uma área desconhecida usando o vocabulário do domínio. Usado por `/plan` e `/techdebt` quando o contexto de código está raso.
- **`diagnose`** — protocolo de 6 fases (feedback loop → reproduzir → hipotetizar → instrumentar → fix+regressão → cleanup). Invocada por `/diagnose` ou pelo `ralph-adversarial` após 2 falhas consecutivas.
- **`git-guardrails-claude-code`** — hook PreToolUse global em `~/.claude/settings.json` (`block-dangerous-git.sh`). **Apenas secret scan**: bloqueia `commit`/`push` se o diff staged contém segredos (Stripe/GH/Netlify/AWS/Google/Slack/PEM) ou arquivos `.env`/`credentials`/`*.pem`/`*.key`. Operações destrutivas (`--force`, `reset --hard`, `clean -f`, `branch -D`) **não são bloqueadas** — Princípio 7 cobre só segredos.

## Workflow Boris Cherny — Checkouts paralelos + branch efêmera no push

Modelo: 5 cópias físicas do repo (`~/Projects/checkouts/<repo>-{1..5}`), todas em `main` local. **Trabalho acontece em `main` local**; **branch só é criada no momento do push**, com nome derivado da mensagem (Conventional Commits). PR aberto via `gh`. Branch protection mantida.

Ciclo: `main` local trabalha → `/commit-push-pr "feat: ..."` (branch efêmera + PR) → review/merge no GitHub → `/checkout-sync-all` (atualiza todos os slots, remove branches mergeadas).

Use `/checkout-init <repo-url>` para provisionar 5 checkouts paralelos. Quando `graphify` CLI está disponível, instala git hooks Graphify (`hook install` + `claude install`) em cada slot — pule com `--no-graphify`.
Use `/graphify-init [--force] [--skip-rebuild]` para bootstrap Graphify (knowledge graph local) num repo: build inicial + hooks PreToolUse/post-commit + `.gitignore`/`.gitattributes` + commit local (sem push). Pré-requisito 1× por máquina: `uv tool install graphifyy && graphify install`. Decisão completa em `docs/adr/0001-adopt-graphify-sunset-llm-wiki.md` do dotclaude.
Use `/morning <repo>` para rotina de manhã: sync + abrir abas (atalho de `/checkout-sync-all` + `/checkout-launch`).
Use `/checkout-launch <repo>` para abrir 5 abas do terminal (1 janela), opcionalmente com `claude --name` por slot.
Use `/checkout-use <repo> <slot> [label]` para preparar slot — atualiza `main`, **não cria branch**.
Use `/checkout-status [repo]` para ver estado dos slots.
Use `/sync` (ou `/checkout-sync-all <repo>`) para sincronizar slots com `origin/main` e podar branches mergeadas. `/sync` auto-detecta o pool a partir do cwd. Em slots com Graphify configurado, regenera `graphify-out/` localmente após o pull (compensa `merge=theirs` em `graph.json`).
Use `/commit-push-pr ["msg"]` para criar branch efêmera + commit + push + PR (substitui `/pr`). Argumentos opcionais — Claude infere mensagem/branch do contexto. Auto-merge é default (squash + delete-branch quando CI passa). **Modo A (inferência) sem prompt y/n** — anuncia e executa direto; mantém guardrails fail-closed de segredo no diff e inferência fraca.
Use `/ship ["msg"]` para auto-pipeline de entrega: testes pré-merge (loop 3x auto-fix) → PR → auto-merge (ou force-merge soft em não-protegida) → deploy (se `.claude/ship.json` configura) → e2e pós-merge contra URL real (loop 3x hotfix por iteração). Standalone ou invocado por `/full-cycle*` na fase final. Config per-repo em `.claude/ship.json` (cascata: config > auto-detect > flag CLI).
Use `/force-merge [PR|branch] [--wait] [--admin]` para mergear PR aberto agora; auto-sync do pool após merge. Cobre o caso onde `gh pr merge --auto` não pegou (ex: repo sem `allow_auto_merge` ligado, branch protection exigindo reviews que não chegaram, ou repo solo onde você quer mergear sem esperar). Modos: soft (default — mergeia agora), `--wait` (aguarda CI até timeout 30min, override `--wait-timeout=Nm`), `--admin` (bypassa proteção; sempre confirma).
Use `/techdebt [escopo]` para análise + plano de limpeza de tech debt.
Use `/create-worktree <slug>` *(legado)* para git worktree isolado.
Use `/delete-worktree [path|slug]` *(legado)*.
Use `/export-report` para exportar a última resposta como arquivo Markdown.
Use `/prd-convert` para converter plano aprovado em prd.json (formato Ralph).
Use `/ralph-adversarial` para executar loop de implementação com revisão Codex.
Use `/e2e [fluxo]` para gerar/rodar testes E2E Playwright.
Use `/browser-status` para listar cookies do perfil Chrome dedicado (read-only).
Use `/browser-logout-all [--confirm]` para limpar todos os cookies do perfil Chrome dedicado (destrutivo, exige MCP encerrado).

### Graphify: dirt em `graphify-out/` é design, não bug

Em slots de repos Graphified, os arquivos `graphify-out/{.graphify_root, GRAPH_REPORT.md, graph.json, graph.html}` ficam dirty após qualquer commit ou branch switch — os hooks `post-commit`/`post-checkout` do graphify regeneram em background, e parte do output é estruturalmente per-slot (caminho absoluto em `.graphify_root`, `basename(cwd)` no título do `GRAPH_REPORT.md`) ou não-determinística entre runs (community IDs do clustering). **Isso é design conhecido — ADR 0001 Errata 2026-05-12.**

Comportamento esperado:

- **Não tratar como user work-in-progress.** São arquivos derivados.
- **Não commitar a dirt isoladamente** — não tem valor semântico per-slot (vira ruído no diff do próximo PR).
- **Não tentar `git stash`** — stash pop conflita quando outro slot atualizou os mesmos paths.
- **Antes de comandos que fazem checkout interno** (`gh pr merge --delete-branch`, `git rebase`, `git switch <branch>`) em slot Graphified: descartar com `git checkout -- graphify-out/`. Pattern canônico em `bin/checkout-sync-all.sh:49-56`.
- **Se um git/gh command falhar com `"would be overwritten by checkout"` citando `graphify-out/`:** descartar com `git checkout -- graphify-out/` e re-executar. Não stash, não commit.

## Testing (sempre ativo)

TDD red-green-refactor obrigatório. Nunca implemente antes do teste.
Playwright CLI > MCP (token-efficient). Detalhes: skill `testing`.

Comandos:
- Fast:   npx playwright test --reporter=line --max-failures=3
- Last:   npx playwright test --last-failed --reporter=line
- Single: npx playwright test <path> --reporter=line

Subagente `test-runner` roda proativamente após mudanças de código.
Templates de bootstrap em `~/.claude/skills/testing/templates/`.

## Referência rápida

- Templates completos: `~/.claude/skills/react-feynman/SKILL.md`
- Adversarial research: `~/.claude/skills/adversarial-research/SKILL.md`
- Ralph adversarial: `~/.claude/skills/ralph-adversarial/SKILL.md`
- Rubrica de code review: `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md`
- Testing (TDD + Playwright): `~/.claude/skills/testing/SKILL.md`
- Workflow integrado: `~/.claude/WORKFLOW.md`
