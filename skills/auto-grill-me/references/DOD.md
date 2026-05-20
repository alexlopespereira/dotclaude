# Definition of Done — knowledge base operacional

> Versão lean para uso em runtime pela skill `auto-grill-me`. Fonte canônica e justificativas: `dotclaude/docs/definition_of_done.md`. **Sincronizar este arquivo quando a fonte mudar.**

Convenção: `- [ ]` = critério binário verificável. DoD-base aplica-se a **todas** as tarefas da categoria; variação específica acrescenta critérios à base.

---

## Índice de mapping (trigger phrases → categoria/tarefa)

Use este índice para escolher um **candidato** de mapping ao descobrir um artefato. Depois rode a meta-classificação via rubrica (G3/G6) sobre o candidato. Se score > 60 ou trigger ambíguo, pergunte ao usuário.

| Trigger no artefato | Categoria | Tarefa |
|---------------------|-----------|--------|
| slash command, `/<comando>`, `.claude/commands/` | 1 | 1 |
| skill nova, SKILL.md, `.claude/skills/<nome>/` | 1 | 2 |
| princípio global, `~/.claude/CLAUDE.md`, regra acionável | 1 | 3 |
| hook PreToolUse, PostToolUse, Stop, `settings.json` | 1 | 8 |
| plano técnico, ReAct+Feynman, `.claude/plans/<...>.md` | 2 | 4 |
| página nova Storefront, template Liquid, `templates/page.<handle>.json` | 3 | 5 |
| refactor design system, tokens CSS, `acme-tokens.css` | 3 | 6 |
| bug fix produção Shopify Storefront | 3 | 7 |
| tema Dawn produção, `www.exemplo-loja.com.br`, custom prefix `acme-*` | 3 | 17 |
| agente autônomo, heartbeat loop, `autoresearch_config.yaml` | 4 | 9 |
| outer-loop mutation, `program.md`, fitness scalar | 4 | 10 |
| edge function Supabase, Sentry instrumentation | 5 | 11 |
| Cloud Run, GCP deploy, Secret Manager, `cloudbuild.yaml` | 5 | 12 |
| pipeline cron, GitHub Actions schedule, systemd timer | 6 | 13 |
| dashboard web, FastAPI/Flask, `/health`, KPI | 6 | 14 |
| CLI tool Python, argparse/Click/Typer | 7 | 15 |
| sync entre repos, templates `.tpl`, placeholders | 4 | 16 |
| Codex CLI paralelo, Ralph adversarial, segundo agente | 7 | 18 |
| LaTeX, PDF reproducível, conteúdo educacional, `\exercicio` | 8 | 19 |
| parsing regex, e-mail/calendar/form scraped | 8 | 20 |

**Mapping não-cobertos pelo índice:** aplicar apenas o `DoD-base` da categoria mais próxima + marcar critérios derivados com `[INFERÊNCIA]`. **Não inventar critérios sem marker.**

---

## Categoria 1 — Claude Code internals (slash commands, skills, hooks, princípios globais)

### DoD-base — Categoria 1 (usos: 1 · desde rev: 1)
- [ ] arquivo vive em `~/.claude/` (global) ou `.claude/` (projeto) — escopo escolhido documentado no commit
- [ ] frontmatter YAML mínimo presente (`description` + `name` quando aplicável); descrição inclui *o que faz* + *quando usar* (gatilhos)
- [ ] testado em sessão real do Claude Code (não só lido) — log do uso no commit message ou `CHANGELOG.md`
- [ ] commitado em git com mensagem `feat(claude): ...`

### Tarefa 1 — Slash command novo / refactor (usos: 1 · desde rev: 1)
- [ ] arquivo em `.claude/commands/<nome>.md` OU migrado para skill — escolha justificada (skill se houver assets/scripts)
- [ ] frontmatter declara `allowed-tools` explicitamente (ex.: `Bash(git:*), Read, Edit`) — não usar wildcard total
- [ ] argumentos via `$ARGUMENTS` ou `$1`/`$2` com `argument-hint` definido
- [ ] inline bash (`!\`git status\``) usado para pré-computar contexto e evitar round-trip do modelo
- [ ] executado 1x em sessão real e produz o output esperado sem follow-up manual

### Tarefa 2 — Skill nova (usos: 1 · desde rev: 1)
- [ ] estrutura é uma **pasta** (não só arquivo) — mesmo que vazia inicialmente, prevê `examples/`, `references/`
- [ ] `SKILL.md` tem seção **Gotchas** com erros reais observados em uso
- [ ] descrição no frontmatter contém **trigger phrases**
- [ ] auto-invocação testada: prompt que *deveria* disparar a skill dispara sem `/skill-name` explícito
- [ ] `/doctor` confirma que a skill não está com descrição truncada por budget overflow

### Tarefa 3 — Princípio global na `~/.claude/CLAUDE.md` (usos: 0 · desde rev: 0)
- [ ] regra é **acionável e binária** ("nunca commitar `.env`") — não aspiracional
- [ ] tem **origem rastreável**: link para o incidente/PR/post que motivou a regra
- [ ] arquivo total continua ≤ 2.5k tokens — verificado com `wc -w` ou `/context`
- [ ] regra não duplica algo que o modelo já faz por default
- [ ] passou por uma sessão de teste onde a regra **deveria** ter sido disparada e foi

### Tarefa 8 — Hook PreToolUse / Stop (usos: 0 · desde rev: 0)
- [ ] script tem shebang explícito e é `chmod +x`
- [ ] hook **lê stdin** (JSON do evento) e respeita contrato: `exit 0` = ok, `exit 2` = block + stderr
- [ ] hooks `Stop` checam `stop_hook_active` flag para evitar loop infinito
- [ ] `matcher` é específico (ex.: `"Bash"`, `"Edit|Write"`) — nunca matcher vazio em hooks caros
- [ ] testado em modo `claude --debug` e firing confirmado no log
- [ ] timeout configurado (`"timeout": 5000`) — hook nunca trava a sessão
- [ ] commitado em `.claude/settings.json` (projeto) ou `~/.claude/settings.json` (user) — nunca em `.local.json` se compartilhável

---

## Categoria 2 — Planejamento e revisão técnica

### DoD-base — Categoria 2 (usos: 0 · desde rev: 0)
- [ ] artefato é **versionado** (markdown em git) — não chat efêmero
- [ ] linguagem segue o framework escolhido (ReAct: Thought/Action/Observation; Feynman: `[FATO]`/`[INFERÊNCIA]`/`[SUPOSIÇÃO]`) com marcadores explícitos
- [ ] declara **critério de parada** binário

### Tarefa 4 — Plano técnico ReAct+Feynman (usos: 0 · desde rev: 0)
- [ ] estrutura segue Yao et al. 2022: `Thought N → Action N → Observation N` para cada decisão não-trivial
- [ ] toda afirmação categórica marcada como `[FATO]` cita fonte; `[INFERÊNCIA]` explica o salto lógico; `[SUPOSIÇÃO]` lista o que valida/invalida
- [ ] inclui seção **"O que vai falhar primeiro"** (pre-mortem) com ≥3 modos de falha concretos
- [ ] inclui **revert path** explícito
- [ ] termina com checklist de PR
- [ ] revisado por outra sessão Claude Code antes de executar

---

## Categoria 3 — Shopify (Storefront + Dawn + design system)

### DoD-base — Categoria 3 (usos: 0 · desde rev: 0)
- [ ] mudança previewada em **theme preview URL** antes do `theme push`
- [ ] Theme Check sem erros novos (`shopify theme check`)
- [ ] PageSpeed/Lighthouse mobile: nenhuma regressão >5 pontos em LCP/CLS vs baseline
- [ ] `settings_data.json` não sobrescrito sem `theme pull` prévio
- [ ] commit referencia versão do tema base (ex.: `Horizon vX.Y.Z`)

### Tarefa 5 — Página nova Storefront (usos: 0 · desde rev: 0)
- [ ] template JSON em `templates/page.<handle>.json` (não duplicar `.liquid`)
- [ ] header da página renderizado via snippet canônico (`render 'acme-section-heading'`) — sem H1 inline
- [ ] **nunca** redeclarar `max-width` dentro de `.section--page-width` (regra crítica)
- [ ] alinhamento de conteúdo via `align-items: flex-start` + tokens
- [ ] hero usa `--acme-hero-media-radius` (token CSS) — sem `border-radius` hardcoded
- [ ] `page_width: narrow` no schema quando aplicável; margens via 3 tokens (`--page-width`, `--gutter`, `--content-max`)
- [ ] testado em viewport ≤375px (iPhone SE) — Horizon é mobile-first
- [ ] cada block tem `id` único; CSS encapsulada via `{% style %}` prefixado com esse id

### Tarefa 6 — Refatoração / padronização design system (usos: 0 · desde rev: 0)
- [ ] tokens consolidados em `assets/acme-tokens.css` — nenhum valor mágico em arquivo individual
- [ ] blocos refatorados respeitam `prefers-reduced-motion`
- [ ] schemas de blocos têm **toggles** explícitos para variações (não duplicar bloco)
- [ ] regressão visual: screenshot before/after de 3+ páginas críticas (home, PDP, PLP) anexado ao PR
- [ ] mudanças em `_blocks.liquid` testadas em ≥3 níveis de nesting (Horizon suporta 8)
- [ ] arquivos custom prefixados (ex.: `acme-*`) para sobreviver a `git merge upstream/main`

### Tarefa 7 — Bug fix produção Storefront (usos: 0 · desde rev: 0)
- [ ] reproduzido em theme preview ANTES do fix
- [ ] fix tem **smallest possible diff** — refactoring proibido na mesma PR
- [ ] testado em theme preview pós-fix com URL pública compartilhada
- [ ] revert path: `theme list` confirma versão pré-fix publicável em <1min
- [ ] root cause documentado em `CHANGELOG.md` ou commit body — não só "fix"
- [ ] se causado por upstream update do Horizon: marcado com tag `upstream-conflict`

### Tarefa 17 — Tema Dawn produção (`www.exemplo-loja.com.br`) (usos: 0 · desde rev: 0)
- [ ] versão Dawn upstream registrada no commit (ex.: `Dawn 15.3.0`)
- [ ] custom code isolado em arquivos prefixados `acme-*` — **nunca** edita `theme.liquid`, `header.liquid`, `footer.liquid` core sem snippet wrapper
- [ ] `templates/` editados são duplicados (ex.: `product.acme.json`), não sobrescritos
- [ ] mudança testada em theme preview com URL pública antes de `Publish`
- [ ] backup via `shopify theme pull --live` antes de qualquer push destrutivo
- [ ] diff vs upstream Dawn salvo em `docs/acme-dawn-diff.md`

---

## Categoria 4 — Agentes autônomos (heartbeat, outer-loop, sync entre repos)

### DoD-base — Categoria 4 (usos: 0 · desde rev: 0)
- [ ] agente tem **kill switch** acessível (`pkill -f <agent>` ou flag em arquivo) testado
- [ ] estado persistente (memory, `blocked.log`) em arquivo versionável — não só RAM
- [ ] cada iteração gera log estruturado (JSON ou key=value) parseável
- [ ] segredos via env vars / Secret Manager / `.env` gitignored — **nunca** hardcoded
- [ ] custo por iteração mensurado e logado — circuit breaker se ultrapassar budget

### Tarefa 9 — Agente autônomo com heartbeat loop (usos: 0 · desde rev: 0)
- [ ] intervalo configurável via `autoresearch_config.yaml` (default + override por agente)
- [ ] `bootstrap-experiments.sh` é **idempotente**
- [ ] `run-heartbeats.sh` registra cada batida em `heartbeats.log` com timestamp ISO-8601 + agent name
- [ ] `blocked.log` separado de `errors.log`
- [ ] orchestrator detecta agente travado (último heartbeat > N×intervalo) e marca como `stalled`
- [ ] revert: matar todos os agentes via `orchestrator.sh stop` em <30s
- [ ] sandbox: agente roda com `--dangerously-skip-permissions` **apenas** dentro de container/worktree isolado

### Tarefa 10 — Outer-loop mutation agent (Karpathy `program.md`) (usos: 0 · desde rev: 0)
- [ ] estrutura de 3 arquivos: `prepare.py` **read-only**, `train.py` único editável, `program.md` spec em inglês
- [ ] `program.md` declara explicitamente "**Do not modify** `prepare.py`"
- [ ] avaliação tem **budget fixo** (wall-clock 5min / tokens / steps) — agente não decide quando parar
- [ ] métrica de fitness é **scalar e determinística** (ex.: `evaluate_bpb`)
- [ ] melhorias commitadas via git automaticamente; regressões revertidas via `git reset --hard`
- [ ] `program.md` versionado e revisado como código

### Tarefa 16 — Sync entre repos relacionados (templates `.tpl`) (usos: 0 · desde rev: 0)
- [ ] placeholders seguem convenção única (`{{ AGENT_NAME }}`, `{{ CODENAME }}`) — listados em `TEMPLATE_VARS.md`
- [ ] script de sync é **dry-run capable**
- [ ] direção explícita no nome (`sync-from-template.sh` vs `sync-to-template.sh`) — nunca bidirecional implícito
- [ ] arquivos com merge conflict potencial listados em `.syncignore`
- [ ] hash do template-base registrado em `.template-version`
- [ ] CI roda sync em PR para detectar drift

---

## Categoria 5 — Backend, edge functions e observabilidade (GCP, Supabase, Sentry)

### DoD-base — Categoria 5 (usos: 0 · desde rev: 0)
- [ ] secret hygiene: nenhum valor sensível em código, YAML versionado, ou logs — apenas referências
- [ ] health check ou smoke test executável (`curl /health` retorna 200 com `{status: "ok"}`)
- [ ] erros enviados para Sentry com `release` tag = commit SHA
- [ ] deploy é idempotente — rodar 2x produz mesma revisão (mesmo image digest)
- [ ] revert documentado: comando exato testado em staging

### Tarefa 11 — Edge function (Supabase + Sentry) (usos: 0 · desde rev: 0)
- [ ] `Sentry.init` chamado no início do handler, ANTES de qualquer `await`
- [ ] tags custom: `Sentry.setTag('region', Deno.env.get('SB_REGION'))` + `execution_id`
- [ ] `tracesSampleRate` explícito — produção ≤0.1, dev = 1.0
- [ ] `try/catch` com `Sentry.captureException(e)` em torno do corpo do handler
- [ ] log drain do Supabase em projeto Sentry **separado** do app
- [ ] DSN vem de env var (`SENTRY_DSN`); testado localmente com `supabase functions serve`
- [ ] payload sensível (auth headers, PII) redacted via `beforeSend` hook

### Tarefa 12 — Backend GCP deploy (Cloud Run + Secret Manager + Cloud Build) (usos: 0 · desde rev: 0)
- [ ] `cloudbuild.yaml` em git; `gcloud builds submit` reproduz o deploy
- [ ] secrets via `--set-secrets ENV_VAR=SECRET_NAME:latest` — **nunca** `--set-env-vars` com valor sensível
- [ ] separador `^@^` usado em `--set-env-vars` quando valor contém vírgula
- [ ] service account com `roles/secretmanager.secretAccessor` no secret específico (least privilege)
- [ ] image taggeada com `$COMMIT_SHA`, não `latest`
- [ ] healthcheck `/health` retorna 200; Cloud Run startup probe configurada
- [ ] logs estruturados JSON (campos `severity`, `trace`, `service`)
- [ ] DORA metrics: deploy registrado; rollback testado em staging (MTTR <15min)
- [ ] OWASP A02/A05: secrets nunca aparecem em `gcloud run services describe` ou build logs

---

## Categoria 6 — Pipelines de dados e dashboards (cron, FastAPI/Flask)

### DoD-base — Categoria 6 (usos: 0 · desde rev: 0)
- [ ] schedule UTC (não local) e documentado no header do workflow/unit file
- [ ] **idempotente**: rodar 2x no mesmo dia produz mesmo output (dedup por data ou hash)
- [ ] saída persistida em destino versionável (git, GCS bucket com versioning, ou DB com `created_at`)
- [ ] notificação de falha configurada — GitHub Actions NÃO envia email automático em scheduled workflows
- [ ] `workflow_dispatch` (ou flag manual) presente para teste sem esperar o cron

### Tarefa 13 — Pipeline de dados cron (GitHub Actions / systemd) (usos: 0 · desde rev: 0)
- [ ] schedule UTC com cron sintaticamente válido — validado em crontab.guru
- [ ] tolera atrasos — GitHub Actions pode atrasar 15min em alta carga
- [ ] filtro de domínio declarado em config, não hardcoded
- [ ] curva acumulada via `cumsum` deduplicado (servidores únicos, não eventos)
- [ ] toggle de e-mail via env var (`SEND_EMAIL=true`) — default `false` em dev
- [ ] artefato (CSV/PNG) anexado via `actions/upload-artifact`
- [ ] log inclui contagem de linhas in/out — detecta input vazio antes de overwrite

### Tarefa 14 — Dashboard web timeline (FastAPI/Flask) (usos: 0 · desde rev: 0)
- [ ] endpoint `/health` retorna 200 + JSON estruturado (não texto plano)
- [ ] logging JSON estruturado em `lifespan` (structlog ou python-json-logger)
- [ ] `/docs` (Swagger) desabilitado em produção via env (`ENV=production` → `docs_url=None`)
- [ ] KPIs em endpoint dedicado, cacheado por ≥60s
- [ ] tabela home limitada (ex.: 60 dias) com `LIMIT` hardcoded como guard
- [ ] systemd unit tem `Restart=on-failure` + `WorkingDirectory` absoluto
- [ ] frontend renderiza estado vazio sem stack trace — testado com DB vazio
- [ ] CORS configurado explicitamente; não `allow_origins=["*"]` em produção

---

## Categoria 7 — CLI tools e config de agentes secundários

### DoD-base — Categoria 7 (usos: 0 · desde rev: 0)
- [ ] `<cmd> --help` executa sem erro e lista subcomandos — smoke test mínimo
- [ ] `<cmd> --version` retorna versão de `pyproject.toml` (single source of truth)
- [ ] exit codes corretos: `0` sucesso, `1` erro genérico, `2` invalid args
- [ ] sem dependências de rede no `--help`
- [ ] instalável via `pip install -e .` (entry point em `pyproject.toml`)

### Tarefa 15 — CLI tool Python (auth + integração backend) (usos: 0 · desde rev: 0)
- [ ] biblioteca CLI escolhida (argparse / Click / Typer) justificada no README
- [ ] subcomando segue padrão `gradecli register` (verbo final via `add_subparsers()`)
- [ ] auth token lido de `~/.config/gradecli/token` (chmod 600) OU env var — **nunca** flag CLI
- [ ] erro de auth tem mensagem actionable ("run `gradecli login`"); não stack trace
- [ ] integração testada via `pytest` + `CliRunner` ou `capsys` — HTTP mocked via `responses`/`httpx_mock`
- [ ] timeout default em HTTP (≥10s, ≤60s); retry com backoff em 5xx
- [ ] versão do servidor backend validada no startup

### Tarefa 18 — Config de segundo agente CLI (Codex CLI / Ralph Adversarial) (usos: 0 · desde rev: 0)
- [ ] vars `PRIMARY_AGENT` e `REVIEWER_AGENT` configuráveis em `.env` ou shell rc
- [ ] fallback para Sonnet quando Codex quota esgotada — detectado por exit code ou regex em stderr
- [ ] cada agente tem **sandbox separado** (worktree git ou container)
- [ ] loop tem `--max-iterations N` — nunca `while true` sem teto
- [ ] critério de parada binário: arquivo `<promise>DONE</promise>` OU teste/lint/build passa
- [ ] custo total (tokens × agentes × iterações) logado por loop — circuit breaker em $X
- [ ] kill switch global (`./stop-ralph.sh`) testado em <10s

---

## Categoria 8 — Conteúdo educacional e parsing de input não-estruturado

### DoD-base — Categoria 8 (usos: 0 · desde rev: 0)
- [ ] artefato (PDF, dataset normalizado) versionado em git ou DVC
- [ ] build/parse é **determinístico**: input idêntico → output byte-idêntico (verificável via `sha256sum`)
- [ ] dependências externas pinadas (versão de pacote LaTeX, regex flags, locale)
- [ ] caso edge documentado em testes (input vazio, malformado, com acento)

### Tarefa 19 — Conteúdo educacional versionado (LaTeX/PDF) (usos: 0 · desde rev: 0)
- [ ] `SOURCE_DATE_EPOCH` setado no build LaTeX para PDF reproduzível byte-a-byte
- [ ] sem `\date{\today}` — data específica hardcoded ou via variável
- [ ] exercícios numerados via macro consistente (ex.: `\exercicio{N}`)
- [ ] rubrica canônica em `rubricas/<aula>.md` referenciada via `\input`
- [ ] cross-references usam `\label`/`\ref` — nunca número hardcoded
- [ ] data `disponivel_a_partir_de` declarada em frontmatter YAML do `.md` ou metadado do PDF
- [ ] CI (`xu-cheng/latex-action@v4`) compila o PDF; falha → PR bloqueado
- [ ] tag git por versão publicada (`aula-03-v1`)

### Tarefa 20 — Parsing de input não-estruturado (regex) (usos: 0 · desde rev: 0)
- [ ] regex compilado uma vez (`re.compile`) com flags explícitas — nunca inline em loop
- [ ] testes unitários cobrem ≥3 fixtures reais (anonimizadas) + ≥2 casos de borda
- [ ] normalização de anos 2-dígitos documentada (regra: `≤30 → 20YY`, `>30 → 19YY`)
- [ ] linhas no formato `N)` reconhecidas via `^\s*\d+\)\s*` (não `\d+\)`)
- [ ] lookback de calendário ≤90 dias (limite explícito)
- [ ] input bruto **arquivado** antes do parse (em `raw/<date>.eml`)
- [ ] parser registra `(matched, total, rejected)` por execução — drift detection
- [ ] PII (email, CPF) hashada ou removida nos logs
