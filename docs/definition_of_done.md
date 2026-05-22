# Definitions of Done — CLAUDE.md operacional (Dev / ACME / EduOrg)

> Convenção: `- [ ]` = critério binário verificável. Categorias agrupam DoD-base (aplicável a todas as tarefas da categoria) + variações específicas por tarefa. Marcadores `[INFERÊNCIA]` indicam critério inferido de docs adjacentes quando não há fonte canônica direta.

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

**Total de critérios:** ~144 (8 DoDs-base × ~3 + 20 variações × ~6).