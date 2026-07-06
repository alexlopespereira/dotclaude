# Definitions of Done — CLAUDE.md operacional (Dev / ACME / EduOrg)

> Convenção: `- [ ]` = critério binário verificável. Categorias agrupam DoD-base (aplicável a todas as tarefas da categoria) + variações específicas por tarefa. Marcadores `[INFERÊNCIA]` indicam critério inferido de docs adjacentes quando não há fonte canônica direta.

---

## Critério cross-cutting — Cobertura por ciclo (Objetivo do ciclo #1)

Origem: Objetivo do ciclo #1 (cobertura por ciclo), 2026-06-19. Soma-se ao DoD da categoria — **não** o substitui. É o operacional do **Objetivo do ciclo** emitido por todo plano (skill `react-feynman`).

Aplicável a **toda categoria instrumentável** — qualquer tarefa cujo artefato é código executável com toolchain de cobertura (Python `coverage.py`, JS/TS `c8`, bash `bashcov`, Liquid `liquid.js`+`c8`): Categorias 1 (hooks), 4, 5, 6, 7, 9 e 10 (workflow/release). Categorias puramente não-instrumentáveis (docs-only, LaTeX/PDF) estão **isentas** e declaram a isenção no commit.

- [ ] toda unidade/branch introduzida pelo diff é exercitada por teste — provado por `coverage-gate.sh --gate` no CI (patch coverage 100% via `diff-cover --fail-under=100` + ratchet do total via `.coverage-baseline.json`)
- [ ] `coverage-gate.sh --report` (advisory) emite o bloco `COVERAGE_DIFF` em `progress.txt`; o reviewer Codex o lê como evidência (dimensão **COVERAGE** em `skills/ralph-adversarial/CODE_REVIEW.md`)
- [ ] pragma novo (`no cover`/`c8 ignore`/`:nocov:`) carrega justificativa adjacente no próprio diff — pragma sem justificativa é finding P1 no review
- [ ] toolchain provisionada por `/coverage-init` (`commands/coverage-init.md`); categoria não-instrumentável declara a isenção em vez de burlar o gate

---

## Categoria 1 — Claude Code internals (slash commands, skills, hooks, princípios globais)

**DoD base (todas as tarefas desta categoria):**
- [ ] arquivo vive em `~/.claude/` (global) ou `.claude/` (projeto) — escopo escolhido documentado no commit
- [ ] frontmatter YAML mínimo presente (`description` + `name` quando aplicável); descrição inclui *o que faz* + *quando usar* (gatilhos), conforme padrão Anthropic Skills
- [ ] testado em sessão real do Claude Code (não só lido) — log do uso colado no commit message ou em `CHANGELOG.md`
- [ ] commitado em git com mensagem `feat(claude): ...` — versionado como código, não como rascunho

### 1. Slash command novo / refactor
- [ ] arquivo em `.claude/commands/<nome>.md` OU migrado para skill (`.claude/skills/<nome>/SKILL.md`) — escolha justificada (skill se houver assets/scripts; command se prompt puro)
- [ ] frontmatter declara `allowed-tools` explicitamente (ex.: `Bash(git:*), Read, Edit`) — não usar wildcard total
- [ ] argumentos via `$ARGUMENTS` ou `$1`/`$2` com `argument-hint` definido
- [ ] inline bash (`!\`git status\``) usado para pré-computar contexto e evitar round-trip do modelo (padrão Boris Cherny `/commit-push-pr`)
- [ ] executado 1x em sessão real e produz o output esperado sem follow-up manual
- [ ] **deprecação** de command segue formato canônico: header `> **DEPRECATED** — sunset <YYYY-MM-DD>; use /<substituto>` na 1ª linha do corpo E prefixo `DEPRECATED:` na `description` do frontmatter; sunset futura na data do commit + substituto verificado (`test -f`); mudança coberta por teste grep versionado em `bin/tests/` (origem: reflect --learn PR #65, US-06)
- [ ] US cuja mudança em `commands/*.md` é apenas SUBSTITUIR bloco inline por invocação de script existente não herda a categoria de criação de command — specs devem derivar da categoria do artefato primário (script bash → Categoria 9); aplicar specs de frontmatter/argument-hint a edição pontual de command é mismatch e gera markers órfãos (origem: reflect --learn PR #87, US-02 — 7/7 markers ausentes eram specs de tarefa-1 inaplicáveis à extração do gate-e3)

### 2. Skill nova
- [ ] estrutura é uma **pasta** (não só arquivo) — mesmo que vazia inicialmente, prevê `examples/`, `references/` (padrão Anthropic Skills)
- [ ] `SKILL.md` tem seção **Gotchas** com erros reais observados em uso (não inventados)
- [ ] descrição no frontmatter contém **trigger phrases** (palavras que devem aparecer no prompt do usuário)
- [ ] auto-invocação testada: prompt que *deveria* disparar a skill dispara sem `/skill-name` explícito
- [ ] `/doctor` confirma que a skill não está com descrição truncada por budget overflow

### 3. Princípio global na `~/.claude/CLAUDE.md`
- [ ] regra é **acionável e binária** ("nunca commitar `.env`") — não aspiracional ("priorize qualidade")
- [ ] tem **origem rastreável**: link para o incidente/PR/post que motivou a regra. Boris Cherny, X, 2 jan 2026: *"Anytime we see Claude do something incorrectly we add it to the CLAUDE.md, so Claude knows not to do it next time."*
- [ ] arquivo total continua ≤ 2.5k tokens (benchmark pessoal de Boris Cherny; ~100 linhas, confirmado em howborisusesclaudecode.com) — verificado com `wc -w` ou `/context`
- [ ] regra não duplica algo que o modelo já faz por default (não desperdiça contexto)
- [ ] passou por uma sessão de teste onde a regra **deveria** ter sido disparada e foi

### 8. Hook PreToolUse / Stop
- [ ] script tem shebang explícito e é `chmod +x`
- [ ] hook **lê stdin** (JSON do evento) e respeita contrato: `exit 0` = ok, `exit 2` = block + stderr para Claude (Anthropic Hooks reference)
- [ ] hooks `Stop` checam `stop_hook_active` flag para evitar loop infinito
- [ ] `matcher` é específico (ex.: `"Bash"`, `"Edit|Write"`) — nunca matcher vazio em hooks caros
- [ ] testado em modo `claude --debug` e firing confirmado no log
- [ ] timeout configurado (`"timeout": 5000`) — hook nunca trava a sessão
- [ ] commitado em `.claude/settings.json` (projeto) ou `~/.claude/settings.json` (user) — nunca em `.local.json` se for compartilhável
- [ ] hook de evento não-bloqueante (`SessionStart`, `Notification`) é **best-effort**: nunca usa `exit 2`; falha interna vira log + exit 0 (origem: reflect --learn PR #49)
- [ ] operação de rede dentro de hook tem timeout explícito + `GIT_TERMINAL_PROMPT=0`; efeito colateral remoto/mutante (auto-pull/push/install) é **opt-in explícito** via env ou marcador (origem: reflect --learn PR #49)
- [ ] hook **bloqueante** (PreToolUse que nega) é **fail-closed**: `set -u` + `trap 'exit 2' ERR` + checagem explícita de dependências (`command -v jq`/`git`…) com stderr acionável — dep ausente ou erro interno → `exit 2`, nunca `exit 1`/`0` silencioso (contrato PreToolUse: só `exit 2` bloqueia; `set -e` sozinho é insuficiente — sai com `1`). Origem: code-review P0 do PR #65
- [ ] hook bloqueante tem teste em `bin/tests/test_<hook>.sh` escrito ANTES (TDD vermelho) cobrindo: bloqueio (→ `exit 2`), caminho limpo (→ `exit 0`) e dependência ausente (→ `exit 2` + stderr) — dep injetável via seam (`<PREFIX>_JQ`) prova o fail-closed sem desinstalar nada
- [ ] mudança em lógica de classificação de hook (allowlist/block/cold) tem teste table-driven cobrindo cada categoria × condição nova (ex.: cost-quota com e sem ask_shape, irreversible-production intacta, ALLOWLIST_TOOLS intacta) — incluindo o caso regressivo que motivou a mudança (origem: reflect --learn PR #87, US-01 — os 3 falsos positivos do audit de 2026-07-02 eram exatamente o caso regressivo que deveria virar fixture)
- [ ] hook que escreve em arquivo compartilhado fora do próprio cache (ex.: append em `~/.claude/cache/reflect/reminders.jsonl`) valida o registro escrito (jq parse do tail) e o consumidor downstream (ex.: `morning.sh`) tem teste provando que entradas de outros kinds não quebram contadores existentes (origem: reflect --learn PR #87, US-01 — contador do morning.sh precisou de fix por não filtrar kind)
- [ ] limitação deliberada de um guard (caso conhecido que ele não cobre) está documentada no fonte E tem teste que fixa o comportamento aceito, para a limitação não ser "corrigida" acidentalmente nem silenciosamente ampliada (origem: reflect --learn PR #87, US-01 — turno hot com palavra-tema incidental segue allowlisted por decisão, não por acidente)

**Referências consultadas:**
- Anthropic Claude Code docs — Slash Commands, Hooks reference, Skills (code.claude.com/docs)
- Anthropic Skills repo (github.com/anthropics/skills) + "Complete Guide to Building Skills for Claude" PDF
- Boris Cherny — Threads/X workflow posts (jan-fev 2026), Pragmatic Engineer interview, "How Boris Uses Claude Code" (howborisusesclaudecode.com)
- ClaudeLog hooks mechanics, Blake Crosley "95 hooks" post

---

## Categoria 2 — Planejamento e revisão técnica

**DoD base (todas as tarefas desta categoria):**
- [ ] artefato é **versionado** (markdown em git) — não chat efêmero
- [ ] linguagem segue o framework escolhido (ReAct: Thought/Action/Observation; Feynman: `[FATO]`/`[INFERÊNCIA]`/`[SUPOSIÇÃO]`) com marcadores explícitos
- [ ] declara **critério de parada** binário (quando o plano está pronto para virar implementação)

### 4. Plano técnico ReAct+Feynman
- [ ] estrutura segue Yao et al. 2022 (arXiv:2210.03629): `Thought N → Action N → Observation N` para cada decisão não-trivial
- [ ] toda afirmação categórica marcada como `[FATO]` cita fonte (link, arquivo, comando) — `[INFERÊNCIA]` explica o salto lógico — `[SUPOSIÇÃO]` lista o que valida/invalida
- [ ] inclui seção **"O que vai falhar primeiro"** (pre-mortem) com ≥3 modos de falha concretos
- [ ] inclui **revert path** explícito ("se X quebrar, rodar Y para voltar")
- [ ] termina com checklist de PR (não com prosa)
- [ ] revisado por outra sessão Claude Code antes de executar (segunda opinião como verifier — pattern Boris Cherny "subagent verifier")

**Referências consultadas:**
- Yao et al., "ReAct: Synergizing Reasoning and Acting in Language Models" (arXiv:2210.03629, ICLR 2023)
- Prompt Engineering Guide — ReAct (promptingguide.ai)
- Google SRE Book, cap. "Postmortem Culture" (princípio do pre-mortem)
- Boris Cherny — plan-mode workflow (Shift+Tab twice → plan → auto-accept)

---

## Categoria 3 — Shopify (Storefront + Dawn + design system)

**DoD base (todas as tarefas desta categoria):**
- [ ] mudança previewada em **theme preview URL** (não só local) antes do `theme push`
- [ ] Theme Check sem erros novos (`shopify theme check`)
- [ ] PageSpeed/Lighthouse mobile: nenhuma regressão >5 pontos em LCP/CLS vs baseline pré-mudança
- [ ] settings do merchant preservados: `settings_data.json` não sobrescrito sem `theme pull` prévio
- [ ] commit referencia versão do tema base (ex.: `Horizon vX.Y.Z`) para permitir merge de upstream depois

### 5. Página nova Shopify (Storefront) — [INFERÊNCIA a partir de Shopify theme architecture + Online Store 2.0 + Dawn/Horizon refs]
- [ ] template JSON em `templates/page.<handle>.json` (não duplicar `.liquid`) — segue Online Store 2.0 spec
- [ ] header da página renderizado via snippet canônico (`render 'acme-section-heading'`) — sem H1 inline
- [ ] **nunca** redeclarar `max-width` dentro de `.section--page-width` (regra crítica: causa double-gutter no Storefront)
- [ ] alinhamento de conteúdo via `align-items: flex-start` + tokens — não margin hacks
- [ ] hero usa `--acme-hero-media-radius` (token CSS) — sem `border-radius` hardcoded
- [ ] `page_width: narrow` definido no schema da seção quando aplicável; margens via 3 tokens (`--page-width`, `--gutter`, `--content-max`)
- [ ] testado em viewport ≤375px (iPhone SE) — Horizon é mobile-first; default styles priorizam telas pequenas
- [ ] cada block tem `id` único; CSS encapsulada via `{% style %}` prefixado com esse id (padrão Horizon upgrade-safe — `mintlify.wiki/Shopify/horizon`)

### 6. Refatoração / padronização design system (Shopify Storefront)
- [ ] tokens consolidados em `assets/acme-tokens.css` (ou snippet `{% style %}` global) — nenhum valor mágico em arquivo individual
- [ ] blocos refatorados respeitam `prefers-reduced-motion` (toggle on/off de animação)
- [ ] schemas de blocos têm **toggles** explícitos para variações (não duplicar bloco) — best practice Horizon
- [ ] regressão visual: screenshot before/after de 3+ páginas críticas (home, PDP, PLP) anexado ao PR
- [ ] mudanças em `_blocks.liquid` ou seções nested testadas em ≥3 níveis de nesting (Horizon suporta 8)
- [ ] arquivos custom prefixados (ex.: `acme-*`) para sobreviver a `git merge upstream/main` do Horizon

### 7. Bug fix produção (Shopify Storefront)
- [ ] reproduzido em theme preview ANTES do fix
- [ ] fix tem **smallest possible diff** — refactoring proibido na mesma PR
- [ ] testado em theme preview pós-fix com URL pública compartilhada
- [ ] revert path: `theme list` confirma que a versão pré-fix continua publicável em <1min
- [ ] root cause documentado em `CHANGELOG.md` ou commit body — não só "fix"
- [ ] se causado por upstream update do Horizon: marcado com tag `upstream-conflict` para revisitar no próximo merge

### 17. Tema Shopify Dawn (não-Storefront, store de produção `www.exemplo-loja.com.br`)
- [ ] versão Dawn upstream registrada no commit (ex.: `Dawn 15.3.0`)
- [ ] custom code isolado em arquivos prefixados `acme-*` em `sections/`, `snippets/`, `assets/` — **nunca** edita `theme.liquid`, `header.liquid`, `footer.liquid` core sem snippet wrapper
- [ ] `templates/` editados são duplicados (ex.: `product.acme.json`), não sobrescritos
- [ ] mudança testada em theme preview com URL pública compartilhada antes de `Publish`
- [ ] backup da versão publicada via `shopify theme pull --live` antes de qualquer push destrutivo (Shopify Help Center: *"You should always save a copy of any customized code before updating your theme."*)
- [ ] diff vs upstream Dawn salvo em `docs/acme-dawn-diff.md` para facilitar próximo upgrade

**Referências consultadas:**
- shopify.dev — Theme architecture, Liquid templating, Online Store 2.0, Theme Check
- Shopify Help Center — "Updating themes" (preservação de customizações)
- Horizon theme reference (mintlify.wiki/Shopify/horizon, Neat Digital guide, GemPages handbook)
- Dawn theme repo (github.com/Shopify/dawn) — convenções de prefixo e structure
- Polaris Design System (polaris.shopify.com) — tokens e a11y

---

## Categoria 4 — Agentes autônomos (heartbeat, outer-loop, sync entre repos)

**DoD base (todas as tarefas desta categoria):**
- [ ] agente tem **kill switch** acessível (`pkill -f <agent>` ou flag em arquivo de estado) testado
- [ ] estado persistente (memory, `blocked.log`) gravado em arquivo versionável — não só em RAM
- [ ] cada iteração gera log estruturado (JSON ou key=value) parseável por `jq`/`grep`
- [ ] segredos via env vars carregados de Secret Manager / `.env` gitignored — **nunca** hardcoded em `autoresearch_config.yaml`
- [ ] custo por iteração mensurado e logado (tokens in/out × preço) — circuit breaker se ultrapassar budget

### 9. Agente autônomo com heartbeat loop
- [ ] intervalo do heartbeat configurável via `autoresearch_config.yaml` (default + override por agente)
- [ ] `bootstrap-experiments.sh` é **idempotente** — rodar 2x não cria estado duplicado
- [ ] `run-heartbeats.sh` registra cada batida em `heartbeats.log` com timestamp ISO-8601 + agent name
- [ ] `blocked.log` separado de `errors.log` — bloqueios humanos ≠ erros técnicos
- [ ] orchestrator detecta agente travado (último heartbeat > N×intervalo) e marca como `stalled`
- [ ] revert: matar todos os agentes via `orchestrator.sh stop` em <30s
- [ ] sandbox: agente roda com `--dangerously-skip-permissions` **apenas** dentro de container/worktree isolado. Geoffrey Huntley (ghuntley.com/ralph): *"a sandbox becomes your only security boundary. Philosophy: 'It's not if it gets popped, it's when.'"*

### 10. Outer-loop mutation agent (estilo Karpathy `program.md`)
- [ ] estrutura de 3 arquivos respeitada (Karpathy autoresearch): `prepare.py` **read-only**, `train.py` = único editável, `program.md` = spec em inglês
- [ ] `program.md` declara **explicitamente** "**Do not modify** `prepare.py`" (verbatim do repo karpathy/autoresearch) — agente é instruído e validado
- [ ] avaliação tem **budget fixo** (wall-clock — autoresearch usa **5 minutos de treino**, tokens, ou steps) — agente não decide quando parar
- [ ] métrica de fitness é **scalar e determinística** (ex.: `evaluate_bpb` val bits-per-byte no autoresearch — quanto menor, melhor)
- [ ] melhorias commitadas via git automaticamente; regressões revertidas via `git reset --hard`
- [ ] `program.md` versionado e revisado como código — Karpathy framing: "research org code written in English" (cf. seu tweet de 2023: *"The hottest new programming language is English"*, x.com/karpathy/status/1617979122625712128)

### 16. Sync entre repos relacionados (templates `.tpl` + placeholders)
- [ ] placeholders seguem convenção única (`{{ AGENT_NAME }}`, `{{ CODENAME }}`) — listados em `TEMPLATE_VARS.md` no repo origem
- [ ] script de sync é **dry-run capable** (`--dry-run` mostra diff sem aplicar)
- [ ] sync direction explícita no nome (`sync-from-template.sh` vs `sync-to-template.sh`) — nunca bidirecional implícito
- [ ] arquivos com merge conflict potencial (ex.: `CLAUDE.md`, `autoresearch_config.yaml`) listados em `.syncignore`
- [ ] hash do template-base registrado em `.template-version` de cada repo derivado — permite saber qual versão sincronizar
- [ ] CI roda sync em PR para detectar drift (template atualizado mas agentes não)

**Referências consultadas:**
- Karpathy — `github.com/karpathy/autoresearch` (program.md spec, "Do not modify prepare.py", 5-min training budget, `evaluate_bpb` metric)
- Karpathy — "Software Is Changing (Again)" YC AI Startup School keynote (jun/2025): *"LLMs have properties of utilities, of fabs, and of operating systems => New LLM OS, fabbed by labs, and distributed like utilities."* + push by `llms.txt` for machine-consumable docs
- Geoffrey Huntley — "Ralph Wiggum as a 'software engineer'" (ghuntley.com/ralph, jul/2025): *"In its purest form, Ralph is a Bash loop"*; *"Sit on the loop, not in it"*
- Anthropic Claude Code — plugin oficial `ralph-wiggum` (github.com/anthropics/claude-code)
- Google SRE Book — incident response, circuit breaker patterns

---

## Categoria 5 — Backend, edge functions e observabilidade (GCP, Supabase, Sentry)

**DoD base (todas as tarefas desta categoria):**
- [ ] secret hygiene: nenhum valor sensível em código, YAML versionado, ou logs — apenas referências (`SECRET_NAME:latest` no Cloud Run; `wrangler secret put` no Workers; env var em Edge Functions)
- [ ] health check ou smoke test executável (`curl /health` retorna 200 com JSON `{status: "ok"}`)
- [ ] erros enviados para Sentry (ou equivalente) com `release` tag = commit SHA
- [ ] deploy é idempotente — rodar 2x produz a mesma revisão (mesmo image digest)
- [ ] revert documentado: comando exato (`gcloud run services update-traffic --to-revisions=PREV=100`) testado em staging
- [ ] smoke test com ramo negativo (assertion "NÃO contém X") prova precondição antes de avaliar a observable. Rejeitar `|| true` em chains críticas. Aceitar (a) HTTP 2xx assertado, (b) positive marker co-presente no mesmo response, (c) side-effect observable em backing store (cache hit/miss, log, contador).

**Anti-vacuous em ramo negativo.** Smoke tests que afirmam "NÃO contém X" são especialmente perigosos quando o caminho que dispara o ramo negativo pode falhar silenciosamente upstream (HTTP error swallowed, CSRF block, parser cache stale, network timeout). O teste passa verde sem nunca exercer o caminho que diz testar — *vacuous PASS*. Para defender:

- **Não use `|| true`** em chains que disparam o caminho do ramo negativo. O exit code da request precisa ser assertado.
- Provas aceitáveis de que a precondição foi exercida:
  - **(a)** HTTP 2xx (ou 303 se redirect) na request que dispara o caminho — assertado explicitamente.
  - **(b)** Positive marker co-presente no mesmo response que indica que o handler rodou (ex: presença de `class="wikiapp-leaderboard"` confirma que o parser tag PHP foi executado, antes de checar ausência de `NAME_NEG`).
  - **(c)** Side-effect observable num backing store: `memcached_get` direto da chave esperada, log de hit/miss, contador Prometheus incrementado.

Caso real (PR #88 wikiapp-2, 2026-05-21): smoke `action=purge` retornava 4xx silencioso (anônimo sem CSRF), parser cache nunca era limpo, e o GET subsequente lia cache stale sem o `NAME_NEG` esperado — teste passava verde por motivo errado. Reviewer Codex (Claude Sonnet fallback iter4) capturou apenas como P1 REQUEST_CHANGES; com a cláusula CODE_REVIEW.md anti-vacuous, viraria P0 BLOCK direto na iter1.

### 11. Edge function instrumentation (Supabase + Sentry)
- [ ] `Sentry.init` chamado no início do handler, ANTES de qualquer `await`
- [ ] tags custom registradas: `Sentry.setTag('region', Deno.env.get('SB_REGION'))` e `Sentry.setTag('execution_id', Deno.env.get('SB_EXECUTION_ID'))` (padrão Supabase docs)
- [ ] `tracesSampleRate` configurado explicitamente (não default) — produção ≤0.1, dev = 1.0
- [ ] `try/catch` com `Sentry.captureException(e)` em torno do corpo do handler — erros não engolidos
- [ ] log drain do Supabase configurado para projeto Sentry **separado** do app (recomendação Sentry: *"Use a dedicated Sentry project for the log drain. Mixing infrastructure logs with application errors makes both harder to triage."*)
- [ ] DSN vem de env var (`SENTRY_DSN`), nunca inline; testado localmente com `supabase functions serve` antes de `supabase functions deploy`
- [ ] payload sensível (auth headers, PII) redacted via `beforeSend` hook

### 12. Backend GCP deploy (Cloud Run + Secret Manager + Cloud Build)
- [ ] `cloudbuild.yaml` em git; `gcloud builds submit` reproduz o deploy
- [ ] secrets via `--set-secrets ENV_VAR=SECRET_NAME:latest` (ou versão pinned em produção) — **nunca** `--set-env-vars` com valor sensível
- [ ] separador `^@^` (ou outro custom) usado em `--set-env-vars` quando valor contém vírgula. Cloud Run docs: *"Because the comma character `,` is used to split environment variables, if your environment variable contains comma characters as values, you need to escape those delimiters by specifying a different delimiter character, for example, `@`: `--set-env-vars "^@^KEY1=value1,value2,value3@KEY2=..."`"*
- [ ] service account com `roles/secretmanager.secretAccessor` no secret específico (least privilege) — não default compute SA
- [ ] image taggeada com `$COMMIT_SHA`, não `latest` (provenance / SLSA L1+)
- [ ] healthcheck endpoint `/health` retorna 200; Cloud Run startup probe configurada
- [ ] logs estruturados JSON (campos `severity`, `trace`, `service`) — searchable no Cloud Logging
- [ ] DORA metrics: deploy registrado em dashboard (deployment frequency); rollback path testado em staging (MTTR <15min, faixa "elite" do DORA: *"Elite teams recover in under an hour"*)
- [ ] OWASP A02/A05: secrets nunca aparecem em `gcloud run services describe` output ou em build logs

**Referências consultadas:**
- cloud.google.com/run — Configure secrets, environment variables, Cloud Build YAML
- supabase.com/docs — Edge Functions logging, Sentry monitoring example
- sentry.io — Supabase integration, log drain cookbook, Deno SDK config
- OWASP Secrets Management Cheat Sheet + Serverless FaaS Security Cheat Sheet
- DORA — dora.dev/guides/dora-metrics-four-keys + Accelerate (Forsgren/Humble/Kim)
- SLSA framework v1.0 (slsa.dev) — Build Level 1 (provenance), L2 (signed)
- Google SRE Book — Release Engineering, error budgets

---

## Categoria 6 — Pipelines de dados e dashboards (cron, FastAPI/Flask)

**DoD base (todas as tarefas desta categoria):**
- [ ] schedule UTC (não local) e documentado no header do workflow/unit file
- [ ] **idempotente**: rodar 2x no mesmo dia produz o mesmo output (deduplication por data ou hash)
- [ ] saída persistida em destino versionável (git, GCS bucket com versioning, ou DB com `created_at`)
- [ ] notificação de falha configurada — GitHub Actions NÃO envia email automático em scheduled workflows
- [ ] `workflow_dispatch` (ou flag manual) presente para teste sem esperar o cron

### 13. Pipeline de dados cron (GitHub Actions / systemd)
- [ ] schedule UTC com cron sintaticamente válido — validado em crontab.guru ou similar
- [ ] tolera atrasos — GitHub Actions docs: *"The `schedule` event can be delayed during periods of high loads of GitHub Actions workflow runs. High load times include the start of every hour. If the load is sufficiently high enough, some queued jobs may be dropped."* — pipeline não falha se rodar 15min tarde
- [ ] filtro de domínio aplicado (ex.: `esfera=Federal`) declarado em config, não hardcoded
- [ ] curva acumulada calculada via `cumsum` deduplicado (servidores únicos por CPF/ID, não por evento)
- [ ] toggle de e-mail via env var (`SEND_EMAIL=true`) — default `false` em dev
- [ ] artefato (CSV/PNG da curva) anexado ao run via `actions/upload-artifact`
- [ ] log inclui contagem de linhas in/out — detecta input vazio antes de overwriter dashboard

### 14. Dashboard web timeline (FastAPI/Flask + frontend)
- [ ] endpoint `/health` retorna 200 + JSON estruturado (não texto plano) — padrão Kubernetes liveness/readiness
- [ ] logging JSON estruturado configurado em `lifespan` (não em ad-hoc `print`) — padrão FastAPI production logging (structlog ou python-json-logger)
- [ ] `/docs` (Swagger) desabilitado em produção via env (`ENV=production` → `docs_url=None`)
- [ ] KPIs (ex.: "Total a receber") calculados em endpoint dedicado, cacheado por ≥60s
- [ ] tabela home limitada (ex.: 60 dias) com query parametrizada — `LIMIT` hardcoded como guard
- [ ] systemd unit (ou `gunicorn` config) tem `Restart=on-failure` + `WorkingDirectory` absoluto
- [ ] frontend renderiza estado vazio (sem dados) sem stack trace — testado com DB vazio
- [ ] CORS configurado explicitamente; não `allow_origins=["*"]` em produção

**Referências consultadas:**
- docs.github.com/actions — Scheduled workflows, secrets, workflow_dispatch
- crontab.guru, "GitHub Actions Cron Schedule" gotchas (cronbuilder.dev)
- fastapi.tiangolo.com — Lifespan, dependencies, settings via Pydantic
- python-json-logger, structlog — structured logging patterns
- Google SRE Book — Monitoring distributed systems, four golden signals
- systemd docs — service hardening

---

## Categoria 7 — CLI tools e config de agentes secundários

**DoD base (todas as tarefas desta categoria):**
- [ ] `<cmd> --help` executa sem erro e lista subcomandos — smoke test mínimo
- [ ] `<cmd> --version` retorna versão de `pyproject.toml` (single source of truth)
- [ ] exit codes corretos: `0` sucesso, `1` erro genérico, `2` invalid args (convenção argparse/click)
- [ ] sem dependências de rede no `--help` (não validar token só pra listar comandos)
- [ ] instalável via `pip install -e .` (entry point em `pyproject.toml [project.scripts]`)

### 15. CLI tool Python (com auth + integração com backend)
- [ ] biblioteca CLI escolhida (argparse stdlib / Click / Typer) justificada no README
- [ ] subcomando segue padrão `gradecli register` (verbo final via `add_subparsers()` ou `@click.group`) — não `gradecli --register`
- [ ] auth token lido de `~/.config/gradecli/token` (chmod 600) OU env var `GRADECLI_TOKEN` — **nunca** flag CLI (vaza no histórico do shell)
- [ ] erro de auth tem mensagem actionable ("run `gradecli login`"); não stack trace
- [ ] integração com backend testada via `pytest` + `CliRunner` (Click) ou `capsys` (argparse) — mocking de HTTP via `responses`/`httpx_mock`
- [ ] timeout default em chamadas HTTP (≥10s, ≤60s); retry com backoff em 5xx
- [ ] versão do servidor backend validada no startup (warn se incompatível)

### 18. Config de segundo agente CLI (Codex CLI paralelo ao Claude — Ralph Adversarial)
- [ ] vars `PRIMARY_AGENT` e `REVIEWER_AGENT` configuráveis em `.env` ou shell rc — default documentado
- [ ] fallback para Sonnet quando Codex quota esgotada — detectado por exit code ou regex em stderr
- [ ] cada agente tem **sandbox separado** (worktree git ou container). Huntley, ghuntley.com/ralph: *"In its purest form, Ralph is a Bash loop"* — sandbox é o único limite de segurança quando se usa `--dangerously-skip-permissions`
- [ ] loop tem `--max-iterations N` (convenção do plugin Anthropic `ralph-wiggum`) — nunca `while true` sem teto
- [ ] critério de parada binário: arquivo `<promise>DONE</promise>` (convention Anthropic plugin) OU teste/lint/build passa — backpressure por gates automáticos, **não** por segundo LLM reviewer (Huntley evita multi-agent na forma canônica)
- [ ] custo total (tokens × agentes × iterações) logado por loop — circuit breaker em $X
- [ ] kill switch global (`./stop-ralph.sh`) testado em <10s; operador "sit on the loop, not in it" (Huntley)

**Referências consultadas:**
- docs.python.org — argparse subcommands, exit codes
- click.palletsprojects.com — CliRunner, testing
- typer.tiangolo.com — type-hint-driven CLI
- Geoffrey Huntley — "Ralph Wiggum as a 'software engineer'" (ghuntley.com/ralph, jul/2025); how-to-ralph-wiggum playbook
- github.com/anthropics/claude-code — plugin `ralph-wiggum` oficial (Stop hook + max-iterations + `<promise>DONE</promise>` sentinel)
- OWASP Secrets Management — never pass secrets via CLI args

---

## Categoria 8 — Conteúdo educacional e parsing de input não-estruturado

**DoD base (todas as tarefas desta categoria):**
- [ ] artefato (PDF, dataset normalizado) versionado em git ou DVC — não só compartilhado por link
- [ ] build/parse é **determinístico**: input idêntico → output byte-idêntico (verificável via `sha256sum`)
- [ ] dependências externas pinadas (versão de pacote LaTeX, regex flags, locale)
- [ ] caso edge documentado em testes (input vazio, malformado, com acento)

### 19. Conteúdo educacional versionado (LaTeX/PDF + rubricas + cross-reference)
- [ ] `SOURCE_DATE_EPOCH` setado no build LaTeX para PDF reproduzível byte-a-byte (spec do Reproducible Builds project — respeitado por `lualatex` e por `pdfx` package)
- [ ] sem `\date{\today}` — data específica hardcoded ou via variável
- [ ] exercícios numerados via macro consistente (ex.: `\exercicio{N}`) — renumeração automática
- [ ] rubrica canônica em `rubricas/<aula>.md` referenciada via `\input` ou inclusão controlada
- [ ] cross-references usam `\label`/`\ref` — nunca número hardcoded ("ver exercício 3.2")
- [ ] data `disponivel_a_partir_de` declarada em frontmatter YAML do `.md` ou metadado do PDF — parseable
- [ ] CI (GitHub Actions com `xu-cheng/latex-action@v4`) compila o PDF; falha → PR bloqueado
- [ ] tag git por versão publicada (`aula-03-v1`, `aula-03-v2`) — reprodutibilidade arquivística

### 20. Parsing de input não-estruturado (regex sobre e-mail/calendar/scraped form)
- [ ] regex compilado uma vez (`re.compile`) com flags explícitas (`re.MULTILINE | re.IGNORECASE`) — nunca inline em loop
- [ ] testes unitários cobrem ≥3 fixtures reais (anonimizadas) + ≥2 casos de borda (vazio, malformado)
- [ ] normalização de anos 2-dígitos documentada (regra: `≤30 → 20YY`, `>30 → 19YY` ou similar) — versionada
- [ ] linhas no formato `N)` reconhecidas via `^\s*\d+\)\s*` (não `\d+\)` que casaria "Item 1) Item 2)")
- [ ] lookback de calendário ≤90 dias (limite explícito) — evita parser rodando em histórico infinito
- [ ] input bruto **arquivado** antes do parse (em `raw/<date>.eml`) — permite re-rodar parser corrigido
- [ ] parser registra `(matched, total, rejected)` por execução — drift detection
- [ ] PII (email, CPF) hashada ou removida nos logs — OWASP A02 / LGPD princípio da minimização

**Referências consultadas:**
- Reproducible Builds — `SOURCE_DATE_EPOCH` spec (reproducible-builds.org)
- arXiv:2010.01482 ("Reproducible Science with LaTeX") + Shen Hong "Creating Fully Reproducible, PDF/A Compliant Documents in LaTeX"
- github.com/xu-cheng/latex-action — CI compilation
- docs.python.org/3/library/re.html — regex flags, compile
- Friedl, "Mastering Regular Expressions" (3rd ed.) — anchoring patterns, backtracking
- OWASP A02:2021 Cryptographic Failures + Lei 13.709/2018 (LGPD) art. 6º, III

---

## Categoria 9 — Scripts bash utilitários (bin/, provisioning, helpers de harness)

Origem: ciclo `/full-cycle` vm-provisioning (PRs #52/#53, 2026-06-10) + reflect `--learn` dos ciclos #49 e #52 — ambos apontaram que specs de slash command (tarefa 1/8) vestem mal artefatos bash-script; e a execução real expôs três classes de bug que stubs não pegam (overflow aritmético do `test`, PATH de shell ssh não-login, sudo sem tty).

**DoD base (todas as tarefas desta categoria):**
- [ ] shebang explícito + `set -u` (e `-e`/`pipefail` quando todo erro é fatal); `chmod +x` versionado (modo 0755 no git)
- [ ] header documenta *o que faz*, *quando usar* e o fluxo ponta-a-ponta (pré-condições, invocação canônica, como encerrar)
- [ ] args inválidos/ausentes → usage em stderr + exit ≠ 0; exit 0 só no caminho feliz — provado por teste de parsing sem efeitos colaterais
- [ ] input numérico/posicional validado por forma E comprimento/range ANTES de aritmética ou exec — `[ N -lt M ]` com número gigante estoura ("integer expression expected", rc=2 lido como falso em cadeia `||`) e não pode virar caminho feliz
- [ ] dependência externa (ssh, sudo, systemctl, tmux, claude, curl…) injetável via seam env var `<PREFIX>_<DEP>` — pattern `vm-doctor`/`vm-provision`
- [ ] testes em `bin/tests/test_<script>.sh` com stubs + call-log, escritos ANTES (TDD): asserts de argv exato, ORDEM das chamadas e ausência de chamadas proibidas — **capture-proof**: todo assert de ausência tem um assert positivo co-presente provando que o stub rodou (origem: reflect --learn PR #52)
- [ ] idempotente: 2ª execução converge pro mesmo estado (mutação condicionada a cmp/check prévio) — provado por teste
- [ ] binário de user-install resolvido com fallback explícito (`command -v` → `~/.local/bin/<bin>`) — shell ssh não-login tem PATH básico; rc=127 não pode ser interpretado como estado de configuração
- [ ] **rename/move** de script faz varredura repo-wide por referências ao nome antigo (`grep -rn 'nome-antigo' --include='*.sh' --include='*.md'` + cópias instaladas em `~/.claude/`) com zero-órfãos provado; stub de deprecação (se houver) testado: repassa argv (`"$@"`) via exec, aviso em stderr, exit code do novo propagado (origem: reflect --learn PR #65, US-05)
- [ ] **refactor de extração** (mover constantes/funções p/ lib comum via `source`) prova equivalência — teste before/after com stubs + call-log (argv idêntico) OU diff byte-a-byte do output em dry-run; "sem mudança de comportamento" nunca é claim sem evidência; `source` falha alto se a lib não existir (`[ -f "$LIB" ] || { echo …; exit 1; }`, path relativo a `$(dirname "$0")`). Origem: reflect --learn PR #65, US-10
- [ ] script gate/validador com contrato de saída multi-estado (ex.: 0=clean, 1=triggered, 2=usage/args inválidos) prova CADA código por teste dedicado — incluindo que o token de saída (`GATE_*_CLEAN`/`GATE_*_TRIGGERED`) e o exit code nunca divergem (origem: reflect --learn PR #87, US-02 — contrato tri-state do gate-e3 sem exigência de prova por código)
- [ ] mecanismo de override/supressão (marcador, flag, env) é fail-closed provado por teste: override malformado ou sem motivo NÃO suprime (comportamento default dispara), e cada supressão efetiva imprime linha de auditoria citando o quê e o porquê (origem: reflect --learn PR #87, US-02 — pattern recorrente: gate-e3-override, CLAUDE_SC_REASON, autonomy-guard)
- [ ] extração de lógica embutida em command/skill markdown para `bin/*.sh` prova equivalência semântica caso-a-caso: uma fixture por regra/trigger original (dispara e não-dispara) passando idêntico no antes e no depois — "mesma semântica" de N regras exige N pares de fixtures, não um diff único de output (origem: reflect --learn PR #87, US-02 — 6 triggers T1-T6 extraídos exigem 12 fixtures mínimas)
- [ ] exit code de dependência externa que conflita "falha" com "resultado vazio" (ex.: `gh pr checks` sai ≠0 tanto em check falhado quanto em PR sem checks) é desambiguado por sinal adicional (presença de stdout, campo JSON, exit code distinto) antes de propagar — provado por teste com stub cobrindo os dois casos (origem: reflect --learn PR #87, US-03 — defeito escapou do gate do Ralph e foi corrigido pós-aprovação no commit ee37513)
- [ ] wrapper de timeout (`perl -e 'alarm'`, `timeout`) tem os 3 caminhos provados por teste: comando termina antes do teto (exit propagado intacto), teto estoura (exit ≠0 distinguível de falha do comando), e override via env var (`<PREFIX>_TIMEOUT`) efetivamente altera o teto (origem: reflect --learn PR #87, US-03 — timeout não testado só falha em produção, num watch de 30min)
- [ ] escrita de arquivo de estado (cache, marker, `$(git rev-parse --git-dir)/<FILE>`) condicionada a validação do valor — parse sem match → NÃO grava e preserva o estado anterior; provado por teste do caminho no-match assertando ausência de escrita (capture-proof, par com assert positivo do caminho com match) (origem: reflect --learn PR #87, US-03 — Falha #2 da Revisão Adversária do CPP_LAST_PR)

### 21. Script com fase remota/privilegiada (SSH/sudo)
- [ ] separação de privilégio binária: fase default roda sem sudo e RELATA pendências da fase privilegiada; fase `--root` tem guard de OS/usuário que aborta antes de qualquer mutação
- [ ] prompt interativo (senha sudo) exige tty real: `ssh -t` sem stdin redirecionado — `ssh 'bash -s' < script` e o prefixo `!` do Claude Code matam o prompt; a invocação canônica vai no usage/header
- [ ] rc de toda mutação crítica (apt-get, usermod, cp em /etc, daemon-reload) é checado e propaga — falha nunca retorna 0 mascarando estado parcial
- [ ] arquivos-fonte que a fase remota consome são copiados junto (scp) e apontados via seam — path relativo do repo não existe no remoto
- [ ] execução real em VM/host de verdade registrada no commit/PR — stub não pega PATH/tty/locale (origem: claude 127 + sudo sem tty nos PRs #52/#53)

### 22. Artefato capturado verbatim de host/VM remoto
Origem: reflect --learn PR #52 (US-01 — unit systemd capturada das VMs).
- [ ] integridade verificada: hash/diff do conteúdo local vs fonte remota (`ssh <host> md5/sha256` ou `diff <(ssh ... cat)`) ANTES do commit
- [ ] conteúdo NUNCA reconstruído de memória — captura falhou → aborta/escala; normalizações (ex.: strip de comentário do `systemctl cat`) documentadas
- [ ] fontes múltiplas (ex.: 2 VMs) comparadas entre si — divergência aborta em vez de escolher uma arbitrariamente
- [ ] `README.md` no diretório documenta origem (host:path), comando de captura e consumidor do artefato
- [ ] scan de segredos no conteúdo capturado antes do commit (padrões do Princípio 7)

---

## Categoria 10 — Infra do harness/repo (config remota via API, CI/CD, docs-only)

Origem: reflect `--learn` do PR #65 — a US-01 (branch protection via `gh api`) sofreu retrabalho (commit "validador versionado") por falta de read-back; o code-review pegou um P0 de fail-closed; e a curadoria de docs deixou refs órfãs e budget de CLAUDE.md estourado. Nenhuma categoria anterior cobria mutação de estado remoto, workflow CI/release, nem mudança docs-only verificável.

**DoD base (todas as tarefas desta categoria):**
- [ ] mutação de estado remoto via API (`gh api -X PUT`, `gcloud`, `aws`, `netlify api`) é verificada por **read-back**: `GET` do mesmo recurso assertando os campos configurados — `exit 0` do PUT/POST **não** prova estado
- [ ] identificador acoplado a config remota (nome de required check, secret, env, branch) validado contra a **fonte real** (`grep` no YAML do job/manifesto) ANTES de aplicar — mismatch silencioso é catastrófico (check que nunca reporta bloqueia merges p/ sempre)
- [ ] **revert path executável** documentado: comando exato (ex.: `gh api -X DELETE …`), testado em dry-run ou sandbox — não apenas citado em prosa

### 23. Workflow CI/CD (lint, release, schedule)
- [ ] job de lint declara **severity explícita** (ex.: `--severity=warning`) e versão pinada do linter (tag de action ou apt version) — default upstream não pode mudar o gate silenciosamente
- [ ] todo `# shellcheck disable=SCnnnn` (ou supressão equivalente) carrega justificativa adjacente; exclusão de escopo do lint é documentada em comentário no próprio YAML
- [ ] lógica de versionamento/release extraída para script testável em `bin/` + `bin/tests/` — cobre idempotência (re-run no mesmo commit não duplica tag/release), colisão no mesmo dia (sufixo `-N`, incl. N≥2) e virada de mês/ano; git stubado, sem rede
- [ ] job novo é **required check** em PR (`pull_request` + `push` na main) — provado por um PR com violação proposital que falha o job antes do merge

### 24. Mudança docs-only (README/CLAUDE.md/docs)
- [ ] cada claim estrutural do doc (parágrafo, bloco, nota) tem spec **grep-verificável** (arquivo alvo + padrão esperado) — não "revisão visual"
- [ ] toda referência cruzada introduzida (ADR, plano, skill, outro doc) é validada por existência do alvo (`test -f`) — referenciar doc órfão perpetua o orfanato
- [ ] comportamento negativo documentado é assertável por comando (ex.: `git check-ignore <path>` retorna ≠ 0 p/ "não-ignorado"); edição em `CLAUDE.md` re-verifica budget (`wc -w` ≤ ~2.5k) com o número no commit body, não só a intenção

---

## Categoria 11 — Gate de autorização / provisionamento de credencial (auth OIDC/OAuth/SSO, probe de credencial, rollout com flag)

Origem: reflect `--learn` do PR #172 (login Shopify OIDC no WikiApp restrito a sócios, 2026-07-06) — a PR herdou `cat-5-base` (deploy/observabilidade GCP), mas o trabalho real era **gate de autorização fail-closed + provisionamento de credencial validado por browser autenticado**. Os 22 findings das 4 USes decorrem todos desse mismatch: nenhuma categoria anterior cobria rejeição-como-observable, probe de credencial com evidência reproduzível, nem rollout com flag/schema em produção.

**DoD base (todas as tarefas desta categoria):**
- [ ] toda probe/spike **bloqueante** (descoberta de credencial, contrato de API externa, redirect_uri) tem verdict **PASS/FAIL** com evidência **reproduzível** citada por `arquivo:linha` (ex.: `docs/probes-*.md`) + o comando/curl exato que a produziu — verdict em prosa ("PASSOU") sem âncora é rejeitado
- [ ] premissa técnica externa (contrato de core de terceiro, lib de auth, formato de token) validada por **teste executável** que lê/exercita o artefato real e é citado no commit — nunca afirmada por leitura de docs
- [ ] todo **desvio de acceptance criterion** é registrado com (a) motivo, (b) risco residual assumido, (c) US/tarefa que absorve o follow-up; desvio sem destino explícito é **gate de parada**, não nota de rodapé
- [ ] verificação que exige recurso **indisponível aos workers** (browser autenticado per-slot, sessão admin) → a US declara explicitamente o **executor** (orquestradora vs worker) e por que o handoff automatizado não se aplica, ANTES de marcar `passes:true`
- [ ] US de segurança com `specs=[]`/`results={}` no bundle é **reprovação automática**: quando declara "TDD antes da implementação", o bundle DEVE conter os specs + markers com o caminho dos testes e o comando que os roda

### 25. Gate de autorização fail-closed
- [ ] gate provado por **teste de ramo negativo**: sujeito **sem** permissão (sem tag/claim) **e** resposta de erro/timeout do serviço de verificação → **NEGAÇÃO** de acesso; a rejeição é a observable — o caminho positivo (sujeito autorizado entra) sozinho não prova o gate
- [ ] vínculo/merge de identidade (auto-link) só ocorre com **guard de e-mail verificado pelo IdP** (`email_authenticated`) provado por teste: spec que tenta linkar conta existente com e-mail **NÃO** verificado e assere **recusa** (defesa contra account takeover)
- [ ] critério de parada **binário auditável**: cada cenário de aceitação tem observable capturado e **arquivado** (screenshot/HTTP/log com timestamp + commit SHA); done = 100% ✅, qualquer ❌ = não entregue — 'passa' sem evidência anexada é rejeitado

### 26. Provisionamento de credencial / dependência de identidade
- [ ] credencial provisionada (OAuth client, access token, API key) verificada por **live-probe** (chamada real que retorna 2xx no recurso alvo) + gravada **fora do git** (P7, mascarada no report); expiry/rotação registrada no inventário de segredos
- [ ] dependência **vendorizada** (lib OIDC/crypto) com versão/commit **pinado** registrado, origem verificável, sujeita ao cooldown/scan de supply-chain; presença provada por **teste de autoload/registro**, não só arquivos no diff

### 27. Rollout com flag + schema/deploy validado
- [ ] flag de habilitação tem **default OFF verificado por smoke de ramo negativo** (assertion "produção NÃO expõe o provider" antes do flip) ANTES de qualquer avaliação do caminho positivo
- [ ] ligar a flag em produção é **gated por evidência de suíte verde anexada no MESMO commit** — o flag flip e a prova de testes verdes coabitam o bundle, não em commits separados sem link
- [ ] migração de schema (`update.php`/migration) **ensaiada contra cópia do dump de produção ANTES do vivo**, com **idempotência** (2ª passada = zero DDL) e a tabela/coluna criada verificada por **introspection** — não por ausência de erro
- [ ] **revert cobre schema/estado**, não só imagem: rollback do schema (down-migration ou snapshot) documentado E testado em staging quando a mudança altera schema/dados
- [ ] job agendado **report-only** prova ausência de efeito colateral por ramo negativo (assertion "NÃO escreveu/alterou X no backing store") + instalação **idempotente** (2x = mesma unit/crontab)
- [ ] **runbook verificado, não só escrito**: rotação de credencial, mudança de config e riscos residuais têm cada passo **executado** (registro do sucesso) ou marcado **dry-run** — 'documentado' sem execução comprovada não conta

---

## Tabela de cobertura

| # | Tarefa | Categoria | DoD-base aplicado | Variação específica |
|---|---|---|---|---|
| 1 | Slash command | 1 | ✅ | ✅ |
| 2 | Skill nova | 1 | ✅ | ✅ |
| 3 | Princípio global CLAUDE.md | 1 | ✅ | ✅ |
| 4 | Plano ReAct+Feynman | 2 | ✅ | ✅ |
| 5 | Página nova Storefront | 3 | ✅ | ✅ |
| 6 | Refactor design system | 3 | ✅ | ✅ |
| 7 | Bug fix produção Storefront | 3 | ✅ | ✅ |
| 8 | Hook PreToolUse/Stop | 1 | ✅ | ✅ |
| 9 | Agente com heartbeat | 4 | ✅ | ✅ |
| 10 | Outer-loop mutation agent | 4 | ✅ | ✅ |
| 11 | Edge fn Supabase+Sentry | 5 | ✅ | ✅ |
| 12 | Backend GCP deploy | 5 | ✅ | ✅ |
| 13 | Pipeline cron | 6 | ✅ | ✅ |
| 14 | Dashboard timeline | 6 | ✅ | ✅ |
| 15 | CLI Python | 7 | ✅ | ✅ |
| 16 | Sync repos templates | 4 | ✅ | ✅ |
| 17 | Tema Dawn produção | 3 | ✅ | ✅ |
| 18 | Codex CLI / Ralph | 7 | ✅ | ✅ |
| 19 | Conteúdo educacional LaTeX | 8 | ✅ | ✅ |
| 20 | Parsing input não-estruturado | 8 | ✅ | ✅ |
| 21 | Script bash remoto/sudo | 9 | ✅ | ✅ |
| 22 | Artefato capturado verbatim | 9 | ✅ | ✅ |
| 23 | Workflow CI/CD (lint/release) | 10 | ✅ | ✅ |
| 24 | Mudança docs-only | 10 | ✅ | ✅ |
| 25 | Gate de autorização fail-closed | 11 | ✅ | ✅ |
| 26 | Provisionamento de credencial | 11 | ✅ | ✅ |
| 27 | Rollout com flag + schema | 11 | ✅ | ✅ |

**Total de critérios:** ~188 (10 DoDs-base + 23 variações; Categoria 9 cobre scripts bash utilitários só com a base quando não há fase remota; Categoria 10 cobre infra do harness/repo — origem reflect --learn PR #65; +10 bullets do reflect --learn PR #87 em Tarefa 8, Tarefa 1 e cat-9-base).