# Test Patterns — test specs Gherkin-lite derivados das DoDs

> Mirror estrutural de `skills/auto-grill-me/references/DOD.md`. Cada heading
> `### Tarefa N` ou `### DoD-base — Categoria N` aqui corresponde 1:1 ao
> heading homônimo no DOD.md. **Source-puro**: o sufixo inline
> `(usos: X · desde rev: Y)` foi removido na migração (US-03); `usos`/`desde rev`
> são **derivados** via o fold content-based
> (`bin/lib/usage-fold.sh --prefix test-spec`). O regex parser do
> `bin/test-spec-reset-rev.sh` (twin de `dod-reset-rev.sh`) é literal
> `^### Tarefa` / `^### DoD-base` — **nunca** prefixe headings com
> `Test specs para`.
>
> Convenção de granularidade (Ressalva Alta #2 da revisão adversária — não
> negociável): cada spec mapeia **1 asserção atômica**. Bullets com N
> asserções viram N specs com sufixo `-A/-B/-C`. Bullets puramente
> declarativos (review humano) recebem prefixo `[CAT3-MANUAL]` e **geram 0
> specs** automatizáveis (compatível com a sintaxe rígida da skill `prd`).
>
> Formato canônico de cada spec (Gherkin-lite, D2 do plano):
>
> ```
> - [ ] spec-N (tarefa-X-spec-N): dado <precondição>, quando <ação>, então <observable> — edge: <caso opcional>
> ```

---

## Categoria 1 — Claude Code internals (slash commands, skills, hooks, princípios globais)

### DoD-base — Categoria 1

### Tarefa 1 — Slash command novo / refactor
- [ ] spec-1-A (tarefa-1-spec-1-A): dado um slash command novo, quando inspeciono o filesystem do repo, então existe arquivo em `.claude/commands/<nome>.md` ou diretório skill `skills/<nome>/SKILL.md` — edge: ambos podem coexistir; commit body precisa justificar a escolha
- [ ] spec-1-B (tarefa-1-spec-1-B): dado a escolha entre command e skill, quando leio o commit body ou comentário interno do arquivo, então há justificativa textual citando assets/scripts (skill) ou one-shot (command) — edge: justificativa só faz sentido quando há trade-off real
- [ ] spec-2-A (tarefa-1-spec-2-A): dado o frontmatter YAML do command, quando faço `grep -n '^allowed-tools:'`, então a chave existe — edge: hífen é literal, não YAML list
- [ ] spec-2-B (tarefa-1-spec-2-B): dado a chave `allowed-tools`, quando inspeciono o valor, então não é wildcard total (`*`, `Bash`, `Bash(*)`) — edge: `Bash(git:*)` é aceito, `Bash(*)` rejeitado
- [ ] spec-3-A (tarefa-1-spec-3-A): dado o corpo do command, quando faço `grep -E '\$ARGUMENTS|\$1|\$2'`, então há ≥1 match (se o command toma input do usuário) — edge: command sem argumento dispensa essa regra
- [ ] spec-3-B (tarefa-1-spec-3-B): dado o frontmatter, quando faço `grep -n '^argument-hint:'`, então a chave está presente sempre que spec-3-A passou — edge: argument-hint vazio (`""`) é rejeitado
- [ ] spec-4 (tarefa-1-spec-4): dado o markdown do command, quando faço `grep -E '^!\`'` (linhas começando com `!` e backtick), então há ≥1 ocorrência de inline bash — edge: inline bash dentro de prosa (`!\`...\`` mid-line) também conta via `grep '!\`'`
- [ ] [CAT3-MANUAL] (tarefa-1 bullet 5): "executado 1x em sessão real e produz o output esperado sem follow-up manual" — review humano (sessão Claude Code real); não-automatizável; 0 specs.

### Tarefa 2 — Skill nova

### Tarefa 3 — Princípio global na `~/.claude/CLAUDE.md`

### Tarefa 8 — Hook PreToolUse / Stop

---

## Categoria 2 — Planejamento e revisão técnica

### DoD-base — Categoria 2

### Tarefa 4 — Plano técnico ReAct+Feynman

---

## Categoria 3 — Shopify (Storefront + Dawn + design system)

### DoD-base — Categoria 3

### Tarefa 5 — Página nova Storefront

### Tarefa 6 — Refatoração / padronização design system

### Tarefa 7 — Bug fix produção Storefront

### Tarefa 17 — Tema Dawn produção (`www.exemplo-loja.com.br`)

---

## Categoria 4 — Agentes autônomos (heartbeat, outer-loop, sync entre repos)

### DoD-base — Categoria 4

### Tarefa 9 — Agente autônomo com heartbeat loop

### Tarefa 10 — Outer-loop mutation agent (Karpathy `program.md`)

### Tarefa 16 — Sync entre repos relacionados (templates `.tpl`)

---

## Categoria 5 — Backend, edge functions e observabilidade (GCP, Supabase, Sentry)

### DoD-base — Categoria 5

### Tarefa 11 — Edge function (Supabase + Sentry)

### Tarefa 12 — Backend GCP deploy (Cloud Run + Secret Manager + Cloud Build)

---

## Categoria 6 — Pipelines de dados e dashboards (cron, FastAPI/Flask)

### DoD-base — Categoria 6

### Tarefa 13 — Pipeline de dados cron (GitHub Actions / systemd)

### Tarefa 14 — Dashboard web timeline (FastAPI/Flask)

---

## Categoria 7 — CLI tools e config de agentes secundários

### DoD-base — Categoria 7

### Tarefa 15 — CLI tool Python (auth + integração backend)

### Tarefa 18 — Config de segundo agente CLI (Codex CLI / Ralph Adversarial)

---

## Categoria 8 — Conteúdo educacional e parsing de input não-estruturado

### DoD-base — Categoria 8

### Tarefa 19 — Conteúdo educacional versionado (LaTeX/PDF)

### Tarefa 20 — Parsing de input não-estruturado (regex)

