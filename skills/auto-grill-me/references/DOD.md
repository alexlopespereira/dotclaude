# Definition of Done — knowledge base operacional

> Versão lean para uso em runtime pela skill `auto-grill-me`. Fonte canônica e justificativas: `dotclaude/docs/definition_of_done.md`. **Sincronizar este arquivo quando a fonte mudar.**

Convenção: `- [ ]` = critério binário verificável. DoD-base aplica-se a **todas** as tarefas da categoria; variação específica acrescenta critérios à base.

---

## Critério cross-cutting — Cobertura por ciclo (Objetivo do ciclo #1)

Soma-se ao DoD da categoria — operacional do **Objetivo do ciclo** emitido por todo plano (`react-feynman`). Fonte canônica: `dotclaude/docs/definition_of_done.md`.

Aplicável a **toda categoria instrumentável** (código executável com toolchain de cobertura: Python `coverage.py`, JS/TS `c8`, bash `bashcov`, Liquid `liquid.js`+`c8` — Categorias 1 hooks, 4, 5, 6, 7, 9, 10 workflow). Categoria puramente não-instrumentável (docs-only, LaTeX/PDF) é **isenta** e declara a isenção no commit.

- [ ] [cov1] toda unidade/branch introduzida pelo diff é exercitada por teste — provado por `coverage-gate.sh --gate` no CI (patch 100% + ratchet do total)
- [ ] [cov2] `coverage-gate.sh --report` emite o bloco `COVERAGE_DIFF` (advisory); Codex o lê como evidência (dimensão COVERAGE em `CODE_REVIEW.md`)
- [ ] [cov3] pragma novo (`no cover`) carrega justificativa adjacente no diff — sem justificativa = finding P1
- [ ] [cov4] toolchain provisionada por `/coverage-init`; categoria não-instrumentável declara a isenção

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
| script bash utilitário, `bin/*.sh`, seam env var, stub call-log | 9 | base |
| provisioning de VM, fase `--root`, sudo/ssh -t, scp de fonte | 9 | 21 |
| captura verbatim de host remoto, unit/config de VM versionada | 9 | 22 |
| mutação remota via API (`gh api`, `gcloud`, `aws`, `netlify api`), branch protection, secret remoto | 10 | base |
| workflow CI/CD, `.github/workflows/*.yml`, lint job, release/tag, CalVer, schedule | 10 | 23 |
| mudança docs-only, README/CLAUDE.md/WORKFLOW, ref cruzada, budget de tokens | 10 | 24 |
| deprecação de slash command, header DEPRECATED, sunset | 1 | 1 |
| gate de autorização, login OIDC/OAuth/SSO, fail-closed, tag/claim de permissão, auto-link de identidade | 11 | 25 |
| provisionamento de credencial via browser, OAuth app, token/API key, lib de auth vendorizada | 11 | 26 |
| rollout com flag de habilitação, migração de schema em produção, job report-only, runbook de operação | 11 | 27 |

**Mapping não-cobertos pelo índice:** aplicar apenas o `DoD-base` da categoria mais próxima + marcar critérios derivados com `[INFERÊNCIA]`. **Não inventar critérios sem marker.**

---

## Categoria 1 — Claude Code internals (slash commands, skills, hooks, princípios globais)

### DoD-base — Categoria 1
- [ ] [b1] arquivo vive em `~/.claude/` (global) ou `.claude/` (projeto) — escopo escolhido documentado no commit
- [ ] [b2] frontmatter YAML mínimo presente (`description` + `name` quando aplicável); descrição inclui *o que faz* + *quando usar* (gatilhos)
- [ ] [b3] testado em sessão real do Claude Code (não só lido) — log do uso no commit message ou `CHANGELOG.md`
- [ ] [b4] commitado em git com mensagem `feat(claude): ...` (prefix `[US-XX]` aceito quando gerado pelo Ralph)

### Tarefa 1 — Slash command novo / refactor
- [ ] [b1] arquivo em `.claude/commands/<nome>.md` OU migrado para skill — escolha justificada (skill se houver assets/scripts)
- [ ] [b2] frontmatter declara `allowed-tools` explicitamente (ex.: `Bash(git:*), Read, Edit`) — não usar wildcard total
- [ ] [b3] argumentos via `$ARGUMENTS` ou `$1`/`$2` com `argument-hint` definido
- [ ] [b4] inline bash (`!\`git status\``) usado para pré-computar contexto e evitar round-trip do modelo
- [ ] [b5] executado 1x em sessão real e produz o output esperado sem follow-up manual
- [ ] [b6] **deprecação** de command segue formato canônico: header `> **DEPRECATED** — sunset <YYYY-MM-DD>; use /<substituto>` na 1ª linha do corpo E prefixo `DEPRECATED:` na `description` do frontmatter; sunset futura na data do commit + substituto verificado (`test -f`); mudança coberta por teste grep versionado em `bin/tests/`
- [ ] [b7] US cuja mudança em `commands/*.md` é apenas SUBSTITUIR bloco inline por invocação de script existente não herda a categoria de criação de command — specs devem derivar da categoria do artefato primário (script bash → cat-9); aplicar specs de frontmatter/argument-hint a edição pontual de command é mismatch e gera markers órfãos

### Tarefa 2 — Skill nova
- [ ] [b1] estrutura é uma **pasta** (não só arquivo) — mesmo que vazia inicialmente, prevê `examples/`, `references/`
- [ ] [b2] `SKILL.md` tem seção **Gotchas** com erros reais observados em uso
- [ ] [b3] descrição no frontmatter contém **trigger phrases**
- [ ] [b4] auto-invocação testada: prompt que *deveria* disparar a skill dispara sem `/skill-name` explícito
- [ ] [b5] `/doctor` confirma que a skill não está com descrição truncada por budget overflow

### Tarefa 3 — Princípio global na `~/.claude/CLAUDE.md`
- [ ] [b1] regra é **acionável e binária** ("nunca commitar `.env`") — não aspiracional
- [ ] [b2] tem **origem rastreável**: link para o incidente/PR/post que motivou a regra
- [ ] [b3] arquivo total continua ≤ 2.5k tokens — verificado com `wc -w` ou `/context`
- [ ] [b4] regra não duplica algo que o modelo já faz por default
- [ ] [b5] passou por uma sessão de teste onde a regra **deveria** ter sido disparada e foi

### Tarefa 8 — Hook PreToolUse / Stop
- [ ] [b1] script tem shebang explícito e é `chmod +x`
- [ ] [b2] hook **lê stdin** (JSON do evento) e respeita contrato: `exit 0` = ok, `exit 2` = block + stderr
- [ ] [b3] hooks `Stop` checam `stop_hook_active` flag para evitar loop infinito
- [ ] [b4] `matcher` é específico (ex.: `"Bash"`, `"Edit|Write"`) — nunca matcher vazio em hooks caros
- [ ] [b5] testado em modo `claude --debug` e firing confirmado no log
- [ ] [b6] timeout configurado (`"timeout": 5000`) — hook nunca trava a sessão
- [ ] [b7] commitado em `.claude/settings.json` (projeto) ou `~/.claude/settings.json` (user) — nunca em `.local.json` se compartilhável
- [ ] [b8] hook de evento não-bloqueante (`SessionStart`, `Notification`) é **best-effort**: nunca usa `exit 2`; falha interna vira log + exit 0
- [ ] [b9] operação de rede dentro de hook tem timeout explícito + `GIT_TERMINAL_PROMPT=0`; efeito remoto/mutante (auto-pull/push/install) é **opt-in explícito** via env ou marcador
- [ ] [b10] hook **bloqueante** (PreToolUse que nega) é **fail-closed**: `set -u` + `trap 'exit 2' ERR` + checagem explícita de dependências (`command -v jq`/`git`…) com stderr acionável — dep ausente ou erro interno → `exit 2`, nunca `exit 1`/`0` silencioso (contrato PreToolUse: só `exit 2` bloqueia; `set -e` sozinho é insuficiente — sai com `1`)
- [ ] [b11] hook bloqueante tem teste em `bin/tests/test_<hook>.sh` escrito ANTES (TDD vermelho) cobrindo: bloqueio (→ `exit 2`), caminho limpo (→ `exit 0`) e dependência ausente (→ `exit 2` + stderr) — dep injetável via seam (`<PREFIX>_JQ`) prova o fail-closed sem desinstalar nada
- [ ] [b12] mudança em lógica de classificação de hook (allowlist/block/cold) tem teste table-driven cobrindo cada categoria × condição nova (ex.: cost-quota com e sem ask_shape, irreversible-production intacta, ALLOWLIST_TOOLS intacta) — incluindo o caso regressivo que motivou a mudança
- [ ] [b13] hook que escreve em arquivo compartilhado fora do próprio cache (ex.: append em `~/.claude/cache/reflect/reminders.jsonl`) valida o registro escrito (jq parse do tail) e o consumidor downstream (ex.: `morning.sh`) tem teste provando que entradas de outros kinds não quebram contadores existentes
- [ ] [b14] limitação deliberada de um guard (caso conhecido que ele não cobre) está documentada no fonte E tem teste que fixa o comportamento aceito, para a limitação não ser "corrigida" acidentalmente nem silenciosamente ampliada

---

## Categoria 2 — Planejamento e revisão técnica

### DoD-base — Categoria 2
- [ ] [b1] artefato é **versionado** (markdown em git) — não chat efêmero
- [ ] [b2] linguagem segue o framework escolhido (ReAct: Thought/Action/Observation; Feynman: `[FATO]`/`[INFERÊNCIA]`/`[SUPOSIÇÃO]`) com marcadores explícitos
- [ ] [b3] declara **critério de parada** binário

### Tarefa 4 — Plano técnico ReAct+Feynman
- [ ] [b1] estrutura segue Yao et al. 2022: `Thought N → Action N → Observation N` para cada decisão não-trivial
- [ ] [b2] toda afirmação categórica marcada como `[FATO]` cita fonte; `[INFERÊNCIA]` explica o salto lógico; `[SUPOSIÇÃO]` lista o que valida/invalida
- [ ] [b3] inclui seção **"O que vai falhar primeiro"** (pre-mortem) com ≥3 modos de falha concretos
- [ ] [b4] inclui **revert path** explícito
- [ ] [b5] termina com checklist de PR
- [ ] [b6] revisado por outra sessão Claude Code antes de executar

---

## Categoria 3 — Shopify (Storefront + Dawn + design system)

### DoD-base — Categoria 3
- [ ] [b1] mudança previewada em **theme preview URL** antes do `theme push`
- [ ] [b2] Theme Check sem erros novos (`shopify theme check`)
- [ ] [b3] PageSpeed/Lighthouse mobile: nenhuma regressão >5 pontos em LCP/CLS vs baseline
- [ ] [b4] `settings_data.json` não sobrescrito sem `theme pull` prévio
- [ ] [b5] commit referencia versão do tema base (ex.: `Horizon vX.Y.Z`)

### Tarefa 5 — Página nova Storefront
- [ ] [b1] template JSON em `templates/page.<handle>.json` (não duplicar `.liquid`)
- [ ] [b2] header da página renderizado via snippet canônico (`render 'acme-section-heading'`) — sem H1 inline
- [ ] [b3] **nunca** redeclarar `max-width` dentro de `.section--page-width` (regra crítica)
- [ ] [b4] alinhamento de conteúdo via `align-items: flex-start` + tokens
- [ ] [b5] hero usa `--acme-hero-media-radius` (token CSS) — sem `border-radius` hardcoded
- [ ] [b6] `page_width: narrow` no schema quando aplicável; margens via 3 tokens (`--page-width`, `--gutter`, `--content-max`)
- [ ] [b7] testado em viewport ≤375px (iPhone SE) — Horizon é mobile-first
- [ ] [b8] cada block tem `id` único; CSS encapsulada via `{% style %}` prefixado com esse id

### Tarefa 6 — Refatoração / padronização design system
- [ ] [b1] tokens consolidados em `assets/acme-tokens.css` — nenhum valor mágico em arquivo individual
- [ ] [b2] blocos refatorados respeitam `prefers-reduced-motion`
- [ ] [b3] schemas de blocos têm **toggles** explícitos para variações (não duplicar bloco)
- [ ] [b4] regressão visual: screenshot before/after de 3+ páginas críticas (home, PDP, PLP) anexado ao PR
- [ ] [b5] mudanças em `_blocks.liquid` testadas em ≥3 níveis de nesting (Horizon suporta 8)
- [ ] [b6] arquivos custom prefixados (ex.: `acme-*`) para sobreviver a `git merge upstream/main`

### Tarefa 7 — Bug fix produção Storefront
- [ ] [b1] reproduzido em theme preview ANTES do fix
- [ ] [b2] fix tem **smallest possible diff** — refactoring proibido na mesma PR
- [ ] [b3] testado em theme preview pós-fix com URL pública compartilhada
- [ ] [b4] revert path: `theme list` confirma versão pré-fix publicável em <1min
- [ ] [b5] root cause documentado em `CHANGELOG.md` ou commit body — não só "fix"
- [ ] [b6] se causado por upstream update do Horizon: marcado com tag `upstream-conflict`

### Tarefa 17 — Tema Dawn produção (`www.exemplo-loja.com.br`)
- [ ] [b1] versão Dawn upstream registrada no commit (ex.: `Dawn 15.3.0`)
- [ ] [b2] custom code isolado em arquivos prefixados `acme-*` — **nunca** edita `theme.liquid`, `header.liquid`, `footer.liquid` core sem snippet wrapper
- [ ] [b3] `templates/` editados são duplicados (ex.: `product.acme.json`), não sobrescritos
- [ ] [b4] mudança testada em theme preview com URL pública antes de `Publish`
- [ ] [b5] backup via `shopify theme pull --live` antes de qualquer push destrutivo
- [ ] [b6] diff vs upstream Dawn salvo em `docs/acme-dawn-diff.md`

---

## Categoria 4 — Agentes autônomos (heartbeat, outer-loop, sync entre repos)

### DoD-base — Categoria 4
- [ ] [b1] agente tem **kill switch** acessível (`pkill -f <agent>` ou flag em arquivo) testado
- [ ] [b2] estado persistente (memory, `blocked.log`) em arquivo versionável — não só RAM
- [ ] [b3] cada iteração gera log estruturado (JSON ou key=value) parseável
- [ ] [b4] segredos via env vars / Secret Manager / `.env` gitignored — **nunca** hardcoded
- [ ] [b5] custo por iteração mensurado e logado — circuit breaker se ultrapassar budget

### Tarefa 9 — Agente autônomo com heartbeat loop
- [ ] [b1] intervalo configurável via `autoresearch_config.yaml` (default + override por agente)
- [ ] [b2] `bootstrap-experiments.sh` é **idempotente**
- [ ] [b3] `run-heartbeats.sh` registra cada batida em `heartbeats.log` com timestamp ISO-8601 + agent name
- [ ] [b4] `blocked.log` separado de `errors.log`
- [ ] [b5] orchestrator detecta agente travado (último heartbeat > N×intervalo) e marca como `stalled`
- [ ] [b6] revert: matar todos os agentes via `orchestrator.sh stop` em <30s
- [ ] [b7] sandbox: agente roda com `--dangerously-skip-permissions` **apenas** dentro de container/worktree isolado

### Tarefa 10 — Outer-loop mutation agent (Karpathy `program.md`)
- [ ] [b1] estrutura de 3 arquivos: `prepare.py` **read-only**, `train.py` único editável, `program.md` spec em inglês
- [ ] [b2] `program.md` declara explicitamente "**Do not modify** `prepare.py`"
- [ ] [b3] avaliação tem **budget fixo** (wall-clock 5min / tokens / steps) — agente não decide quando parar
- [ ] [b4] métrica de fitness é **scalar e determinística** (ex.: `evaluate_bpb`)
- [ ] [b5] melhorias commitadas via git automaticamente; regressões revertidas via `git reset --hard`
- [ ] [b6] `program.md` versionado e revisado como código

### Tarefa 16 — Sync entre repos relacionados (templates `.tpl`)
- [ ] [b1] placeholders seguem convenção única (`{{ AGENT_NAME }}`, `{{ CODENAME }}`) — listados em `TEMPLATE_VARS.md`
- [ ] [b2] script de sync é **dry-run capable**
- [ ] [b3] direção explícita no nome (`sync-from-template.sh` vs `sync-to-template.sh`) — nunca bidirecional implícito
- [ ] [b4] arquivos com merge conflict potencial listados em `.syncignore`
- [ ] [b5] hash do template-base registrado em `.template-version`
- [ ] [b6] CI roda sync em PR para detectar drift

---

## Categoria 5 — Backend, edge functions e observabilidade (GCP, Supabase, Sentry)

### DoD-base — Categoria 5
- [ ] [b1] secret hygiene: nenhum valor sensível em código, YAML versionado, ou logs — apenas referências
- [ ] [b2] health check ou smoke test executável (`curl /health` retorna 200 com `{status: "ok"}`)
- [ ] [b3] erros enviados para Sentry com `release` tag = commit SHA
- [ ] [b4] deploy é idempotente — rodar 2x produz mesma revisão (mesmo image digest)
- [ ] [b5] revert documentado: comando exato testado em staging
- [ ] [b6] smoke test com ramo negativo (assertion "NÃO contém X") prova precondição antes de avaliar a observable. Rejeitar `|| true` em chains críticas. Aceitar (a) HTTP 2xx assertado, (b) positive marker co-presente no mesmo response, (c) side-effect observable em backing store (cache hit/miss, log, contador).

### Tarefa 11 — Edge function (Supabase + Sentry)
- [ ] [b1] `Sentry.init` chamado no início do handler, ANTES de qualquer `await`
- [ ] [b2] tags custom: `Sentry.setTag('region', Deno.env.get('SB_REGION'))` + `execution_id`
- [ ] [b3] `tracesSampleRate` explícito — produção ≤0.1, dev = 1.0
- [ ] [b4] `try/catch` com `Sentry.captureException(e)` em torno do corpo do handler
- [ ] [b5] log drain do Supabase em projeto Sentry **separado** do app
- [ ] [b6] DSN vem de env var (`SENTRY_DSN`); testado localmente com `supabase functions serve`
- [ ] [b7] payload sensível (auth headers, PII) redacted via `beforeSend` hook

### Tarefa 12 — Backend GCP deploy (Cloud Run + Secret Manager + Cloud Build)
- [ ] [b1] `cloudbuild.yaml` em git; `gcloud builds submit` reproduz o deploy
- [ ] [b2] secrets via `--set-secrets ENV_VAR=SECRET_NAME:latest` — **nunca** `--set-env-vars` com valor sensível
- [ ] [b3] separador `^@^` usado em `--set-env-vars` quando valor contém vírgula
- [ ] [b4] service account com `roles/secretmanager.secretAccessor` no secret específico (least privilege)
- [ ] [b5] image taggeada com `$COMMIT_SHA`, não `latest`
- [ ] [b6] healthcheck `/health` retorna 200; Cloud Run startup probe configurada
- [ ] [b7] logs estruturados JSON (campos `severity`, `trace`, `service`)
- [ ] [b8] DORA metrics: deploy registrado; rollback testado em staging (MTTR <15min)
- [ ] [b9] OWASP A02/A05: secrets nunca aparecem em `gcloud run services describe` ou build logs

---

## Categoria 6 — Pipelines de dados e dashboards (cron, FastAPI/Flask)

### DoD-base — Categoria 6
- [ ] [b1] schedule UTC (não local) e documentado no header do workflow/unit file
- [ ] [b2] **idempotente**: rodar 2x no mesmo dia produz mesmo output (dedup por data ou hash)
- [ ] [b3] saída persistida em destino versionável (git, GCS bucket com versioning, ou DB com `created_at`)
- [ ] [b4] notificação de falha configurada — GitHub Actions NÃO envia email automático em scheduled workflows
- [ ] [b5] `workflow_dispatch` (ou flag manual) presente para teste sem esperar o cron

### Tarefa 13 — Pipeline de dados cron (GitHub Actions / systemd)
- [ ] [b1] schedule UTC com cron sintaticamente válido — validado em crontab.guru
- [ ] [b2] tolera atrasos — GitHub Actions pode atrasar 15min em alta carga
- [ ] [b3] filtro de domínio declarado em config, não hardcoded
- [ ] [b4] curva acumulada via `cumsum` deduplicado (servidores únicos, não eventos)
- [ ] [b5] toggle de e-mail via env var (`SEND_EMAIL=true`) — default `false` em dev
- [ ] [b6] artefato (CSV/PNG) anexado via `actions/upload-artifact`
- [ ] [b7] log inclui contagem de linhas in/out — detecta input vazio antes de overwrite

### Tarefa 14 — Dashboard web timeline (FastAPI/Flask)
- [ ] [b1] endpoint `/health` retorna 200 + JSON estruturado (não texto plano)
- [ ] [b2] logging JSON estruturado em `lifespan` (structlog ou python-json-logger)
- [ ] [b3] `/docs` (Swagger) desabilitado em produção via env (`ENV=production` → `docs_url=None`)
- [ ] [b4] KPIs em endpoint dedicado, cacheado por ≥60s
- [ ] [b5] tabela home limitada (ex.: 60 dias) com `LIMIT` hardcoded como guard
- [ ] [b6] systemd unit tem `Restart=on-failure` + `WorkingDirectory` absoluto
- [ ] [b7] frontend renderiza estado vazio sem stack trace — testado com DB vazio
- [ ] [b8] CORS configurado explicitamente; não `allow_origins=["*"]` em produção

---

## Categoria 7 — CLI tools e config de agentes secundários

### DoD-base — Categoria 7
- [ ] [b1] `<cmd> --help` executa sem erro e lista subcomandos — smoke test mínimo
- [ ] [b2] `<cmd> --version` retorna versão de `pyproject.toml` (single source of truth)
- [ ] [b3] exit codes corretos: `0` sucesso, `1` erro genérico, `2` invalid args
- [ ] [b4] sem dependências de rede no `--help`
- [ ] [b5] instalável via `pip install -e .` (entry point em `pyproject.toml`)

### Tarefa 15 — CLI tool Python (auth + integração backend)
- [ ] [b1] biblioteca CLI escolhida (argparse / Click / Typer) justificada no README
- [ ] [b2] subcomando segue padrão `gradecli register` (verbo final via `add_subparsers()`)
- [ ] [b3] auth token lido de `~/.config/gradecli/token` (chmod 600) OU env var — **nunca** flag CLI
- [ ] [b4] erro de auth tem mensagem actionable ("run `gradecli login`"); não stack trace
- [ ] [b5] integração testada via `pytest` + `CliRunner` ou `capsys` — HTTP mocked via `responses`/`httpx_mock`
- [ ] [b6] timeout default em HTTP (≥10s, ≤60s); retry com backoff em 5xx
- [ ] [b7] versão do servidor backend validada no startup

### Tarefa 18 — Config de segundo agente CLI (Codex CLI / Ralph Adversarial)
- [ ] [b1] vars `PRIMARY_AGENT` e `REVIEWER_AGENT` configuráveis em `.env` ou shell rc
- [ ] [b2] fallback para Sonnet quando Codex quota esgotada — detectado por exit code ou regex em stderr
- [ ] [b3] cada agente tem **sandbox separado** (worktree git ou container)
- [ ] [b4] loop tem `--max-iterations N` — nunca `while true` sem teto
- [ ] [b5] critério de parada binário: arquivo `<promise>DONE</promise>` OU teste/lint/build passa
- [ ] [b6] custo total (tokens × agentes × iterações) logado por loop — circuit breaker em $X
- [ ] [b7] kill switch global (`./stop-ralph.sh`) testado em <10s

---

## Categoria 8 — Conteúdo educacional e parsing de input não-estruturado

### DoD-base — Categoria 8
- [ ] [b1] artefato (PDF, dataset normalizado) versionado em git ou DVC
- [ ] [b2] build/parse é **determinístico**: input idêntico → output byte-idêntico (verificável via `sha256sum`)
- [ ] [b3] dependências externas pinadas (versão de pacote LaTeX, regex flags, locale)
- [ ] [b4] caso edge documentado em testes (input vazio, malformado, com acento)

### Tarefa 19 — Conteúdo educacional versionado (LaTeX/PDF)
- [ ] [b1] `SOURCE_DATE_EPOCH` setado no build LaTeX para PDF reproduzível byte-a-byte
- [ ] [b2] sem `\date{\today}` — data específica hardcoded ou via variável
- [ ] [b3] exercícios numerados via macro consistente (ex.: `\exercicio{N}`)
- [ ] [b4] rubrica canônica em `rubricas/<aula>.md` referenciada via `\input`
- [ ] [b5] cross-references usam `\label`/`\ref` — nunca número hardcoded
- [ ] [b6] data `disponivel_a_partir_de` declarada em frontmatter YAML do `.md` ou metadado do PDF
- [ ] [b7] CI (`xu-cheng/latex-action@v4`) compila o PDF; falha → PR bloqueado
- [ ] [b8] tag git por versão publicada (`aula-03-v1`)

### Tarefa 20 — Parsing de input não-estruturado (regex)
- [ ] [b1] regex compilado uma vez (`re.compile`) com flags explícitas — nunca inline em loop
- [ ] [b2] testes unitários cobrem ≥3 fixtures reais (anonimizadas) + ≥2 casos de borda
- [ ] [b3] normalização de anos 2-dígitos documentada (regra: `≤30 → 20YY`, `>30 → 19YY`)
- [ ] [b4] linhas no formato `N)` reconhecidas via `^\s*\d+\)\s*` (não `\d+\)`)
- [ ] [b5] lookback de calendário ≤90 dias (limite explícito)
- [ ] [b6] input bruto **arquivado** antes do parse (em `raw/<date>.eml`)
- [ ] [b7] parser registra `(matched, total, rejected)` por execução — drift detection
- [ ] [b8] PII (email, CPF) hashada ou removida nos logs

---

## Categoria 9 — Scripts bash utilitários (bin/, provisioning, helpers de harness)

### DoD-base — Categoria 9
- [ ] [b1] shebang explícito + `set -u` (e `-e`/`pipefail` quando todo erro é fatal); `chmod +x` versionado (modo 0755 no git)
- [ ] [b2] header documenta *o que faz*, *quando usar* e o fluxo ponta-a-ponta (pré-condições, invocação canônica, como encerrar)
- [ ] [b3] args inválidos/ausentes → usage em stderr + exit ≠ 0; exit 0 só no caminho feliz — provado por teste de parsing sem efeitos colaterais
- [ ] [b4] input numérico/posicional validado por forma E comprimento/range ANTES de aritmética ou exec — `[ N -lt M ]` com número gigante estoura (rc=2 lido como falso em cadeia `||`) e não pode virar caminho feliz
- [ ] [b5] dependência externa (ssh, sudo, systemctl, tmux, claude, curl…) injetável via seam env var `<PREFIX>_<DEP>` — pattern `vm-doctor`/`vm-provision`
- [ ] [b6] testes em `bin/tests/test_<script>.sh` com stubs + call-log, escritos ANTES (TDD): asserts de argv exato, ORDEM das chamadas e ausência de chamadas proibidas — **capture-proof**: assert de ausência exige assert positivo co-presente provando que o stub rodou
- [ ] [b7] idempotente: 2ª execução converge pro mesmo estado (mutação condicionada a cmp/check prévio) — provado por teste
- [ ] [b8] binário de user-install resolvido com fallback explícito (`command -v` → `~/.local/bin/<bin>`) — shell ssh não-login tem PATH básico; rc=127 não pode ser interpretado como estado de configuração
- [ ] [b9] **rename/move** de script faz varredura repo-wide por referências ao nome antigo (`grep -rn 'nome-antigo' --include='*.sh' --include='*.md'` + cópias instaladas em `~/.claude/`) com zero-órfãos provado; stub de deprecação (se houver) testado: repassa argv (`"$@"`) via exec, aviso em stderr, exit code do novo propagado
- [ ] [b10] **refactor de extração** (mover constantes/funções p/ lib comum via `source`) prova equivalência — teste before/after com stubs + call-log (argv idêntico) OU diff byte-a-byte do output em dry-run; "sem mudança de comportamento" nunca é claim sem evidência; `source` falha alto se a lib não existir (`[ -f "$LIB" ] || { echo …; exit 1; }`, path relativo a `$(dirname "$0")`)
- [ ] [b11] script gate/validador com contrato de saída multi-estado (ex.: 0=clean, 1=triggered, 2=usage/args inválidos) prova CADA código por teste dedicado — incluindo que o token de saída (`GATE_*_CLEAN`/`GATE_*_TRIGGERED`) e o exit code nunca divergem
- [ ] [b12] mecanismo de override/supressão (marcador, flag, env) é fail-closed provado por teste: override malformado ou sem motivo NÃO suprime (comportamento default dispara), e cada supressão efetiva imprime linha de auditoria citando o quê e o porquê
- [ ] [b13] extração de lógica embutida em command/skill markdown para `bin/*.sh` prova equivalência semântica caso-a-caso: uma fixture por regra/trigger original (dispara e não-dispara) passando idêntico no antes e no depois — "mesma semântica" de N regras exige N pares de fixtures, não um diff único de output
- [ ] [b14] exit code de dependência externa que conflita "falha" com "resultado vazio" (ex.: `gh pr checks` sai ≠0 tanto em check falhado quanto em PR sem checks) é desambiguado por sinal adicional (presença de stdout, campo JSON, exit code distinto) antes de propagar — provado por teste com stub cobrindo os dois casos
- [ ] [b15] wrapper de timeout (`perl -e 'alarm'`, `timeout`) tem os 3 caminhos provados por teste: comando termina antes do teto (exit propagado intacto), teto estoura (exit ≠0 distinguível de falha do comando), e override via env var (`<PREFIX>_TIMEOUT`) efetivamente altera o teto
- [ ] [b16] escrita de arquivo de estado (cache, marker, `$(git rev-parse --git-dir)/<FILE>`) condicionada a validação do valor — parse sem match → NÃO grava e preserva o estado anterior; provado por teste do caminho no-match assertando ausência de escrita (capture-proof, par com assert positivo do caminho com match)

### Tarefa 21 — Script com fase remota/privilegiada (SSH/sudo)
- [ ] [b1] separação de privilégio binária: fase default roda sem sudo e RELATA pendências da fase privilegiada; fase `--root` tem guard de OS/usuário que aborta antes de qualquer mutação
- [ ] [b2] prompt interativo (senha sudo) exige tty real: `ssh -t` sem stdin redirecionado — `ssh 'bash -s' < script` e o prefixo `!` do Claude Code matam o prompt; invocação canônica no usage/header
- [ ] [b3] rc de toda mutação crítica (apt-get, usermod, cp em /etc, daemon-reload) é checado e propaga — falha nunca retorna 0 mascarando estado parcial
- [ ] [b4] arquivos-fonte que a fase remota consome são copiados junto (scp) e apontados via seam — path relativo do repo não existe no remoto
- [ ] [b5] execução real em VM/host de verdade registrada no commit/PR — stub não pega PATH/tty/locale

### Tarefa 22 — Artefato capturado verbatim de host/VM remoto
- [ ] [b1] integridade verificada: hash/diff do conteúdo local vs fonte remota (`ssh <host> md5/sha256` ou `diff <(ssh ... cat)`) ANTES do commit
- [ ] [b2] conteúdo NUNCA reconstruído de memória — captura falhou → aborta/escala; normalizações documentadas
- [ ] [b3] fontes múltiplas (ex.: 2 VMs) comparadas entre si — divergência aborta em vez de escolher uma arbitrariamente
- [ ] [b4] `README.md` no diretório documenta origem (host:path), comando de captura e consumidor do artefato
- [ ] [b5] scan de segredos no conteúdo capturado antes do commit (padrões do Princípio 7)

---

## Categoria 10 — Infra do harness/repo (config remota via API, CI/CD, docs-only)

### DoD-base — Categoria 10
- [ ] [b1] mutação de estado remoto via API (`gh api -X PUT`, `gcloud`, `aws`, `netlify api`) é verificada por **read-back**: `GET` do mesmo recurso assertando os campos configurados — `exit 0` do PUT/POST **não** prova estado
- [ ] [b2] identificador acoplado a config remota (nome de required check, secret, env, branch) validado contra a **fonte real** (`grep` no YAML do job/manifesto) ANTES de aplicar — mismatch silencioso é catastrófico (check que nunca reporta bloqueia merges p/ sempre)
- [ ] [b3] **revert path executável** documentado: comando exato (ex.: `gh api -X DELETE …`), testado em dry-run ou sandbox — não apenas citado em prosa

### Tarefa 23 — Workflow CI/CD (lint, release, schedule)
- [ ] [b1] job de lint declara **severity explícita** (ex.: `--severity=warning`) e versão pinada do linter (tag de action ou apt version) — default upstream não pode mudar o gate silenciosamente
- [ ] [b2] todo `# shellcheck disable=SCnnnn` (ou supressão equivalente) carrega justificativa adjacente; exclusão de escopo do lint é documentada em comentário no próprio YAML
- [ ] [b3] lógica de versionamento/release extraída para script testável em `bin/` + `bin/tests/` — cobre idempotência (re-run no mesmo commit não duplica tag/release), colisão no mesmo dia (sufixo `-N`, incl. N≥2) e virada de mês/ano; git stubado, sem rede
- [ ] [b4] job novo é **required check** em PR (`pull_request` + `push` na main) — provado por um PR com violação proposital que falha o job antes do merge

### Tarefa 24 — Mudança docs-only (README/CLAUDE.md/docs)
- [ ] [b1] cada claim estrutural do doc (parágrafo, bloco, nota) tem spec **grep-verificável** (arquivo alvo + padrão esperado) — não "revisão visual"
- [ ] [b2] toda referência cruzada introduzida (ADR, plano, skill, outro doc) é validada por existência do alvo (`test -f`) — referenciar doc órfão perpetua o orfanato
- [ ] [b3] comportamento negativo documentado é assertável por comando (ex.: `git check-ignore <path>` retorna ≠ 0 p/ "não-ignorado"); edição em `CLAUDE.md` re-verifica budget (`wc -w` ≤ ~2.5k) com o número no commit body, não só a intenção

---

## Categoria 11 — Gate de autorização / provisionamento de credencial (auth OIDC/OAuth/SSO, probe de credencial, rollout com flag)

Origem: reflect `--learn` do PR #172 (login Shopify OIDC no WikiApp restrito a sócios, 2026-07-06) — a PR herdou `cat-5-base` (deploy GCP), mas o trabalho era **gate de autorização fail-closed + provisionamento de credencial validado por browser**. Os 22 findings decorrem desse mismatch: nenhuma categoria cobria rejeição-como-observable, probe de credencial com evidência reproduzível, nem rollout com flag/schema.

### DoD-base — Categoria 11
- [ ] [b1] toda probe/spike **bloqueante** (descoberta de credencial, contrato de API externa, redirect_uri) tem verdict **PASS/FAIL** com evidência reproduzível citada por `arquivo:linha` (ex.: `docs/probes-*.md`) + o comando/curl exato — verdict em prosa sem âncora é rejeitado
- [ ] [b2] premissa técnica externa (contrato de core de terceiro, lib de auth, formato de token) validada por **teste executável** que exercita o artefato real e é citado no commit — nunca por leitura de docs
- [ ] [b3] todo **desvio de acceptance criterion** registrado com (a) motivo, (b) risco residual assumido, (c) US/tarefa que absorve o follow-up; desvio sem destino = **gate de parada**
- [ ] [b4] verificação que exige recurso **indisponível aos workers** (browser autenticado per-slot, sessão admin) → a US declara o **executor** (orquestradora vs worker) e por que o handoff automatizado não se aplica, ANTES de `passes:true`
- [ ] [b5] US de segurança com `specs=[]`/`results={}` = **reprovação automática**: ao declarar "TDD antes", o bundle DEVE conter specs + markers com o caminho dos testes e o comando que os roda

### Tarefa 25 — Gate de autorização fail-closed
- [ ] [b1] gate provado por **teste de ramo negativo**: sujeito **sem** permissão (sem tag/claim) **e** erro/timeout do serviço de verificação → **NEGAÇÃO**; a rejeição é a observable — o caminho positivo sozinho não prova o gate
- [ ] [b2] auto-link de identidade só com **guard de e-mail verificado pelo IdP** (`email_authenticated`) provado por teste: tenta linkar conta existente com e-mail **NÃO** verificado e assere **recusa** (defesa contra account takeover)
- [ ] [b3] critério de parada **binário auditável**: cada cenário tem observable capturado e **arquivado** (screenshot/HTTP/log com timestamp + commit SHA); done = 100% ✅, qualquer ❌ = não entregue

### Tarefa 26 — Provisionamento de credencial / dependência de identidade
- [ ] [b1] credencial provisionada (OAuth client, token, API key) verificada por **live-probe** (chamada real → 2xx) + gravada **fora do git** (P7, mascarada); expiry/rotação no inventário de segredos
- [ ] [b2] dependência **vendorizada** (lib OIDC/crypto) com versão/commit **pinado**, origem verificável, sujeita ao cooldown/scan de supply-chain; presença provada por **teste de autoload/registro**, não só arquivos no diff

### Tarefa 27 — Rollout com flag + schema/deploy validado
- [ ] [b1] flag de habilitação com **default OFF verificado por smoke de ramo negativo** ("produção NÃO expõe o provider" antes do flip) ANTES do caminho positivo
- [ ] [b2] ligar a flag em produção **gated por evidência de suíte verde no MESMO commit** — flag flip e prova de testes coabitam o bundle
- [ ] [b3] migração de schema **ensaiada contra cópia do dump ANTES do vivo**, com **idempotência** (2ª passada = zero DDL) e tabela/coluna verificada por **introspection** — não por ausência de erro
- [ ] [b4] **revert cobre schema/estado**: rollback do schema (down-migration ou snapshot) documentado E testado em staging quando a mudança altera schema/dados
- [ ] [b5] job agendado **report-only** prova ausência de efeito colateral por ramo negativo ("NÃO escreveu/alterou X") + instalação **idempotente** (2x = mesma unit/crontab)
- [ ] [b6] **runbook verificado, não só escrito**: rotação de credencial, mudança de config e riscos residuais têm cada passo **executado** (registro) ou marcado **dry-run**
