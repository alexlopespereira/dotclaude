---
description: Gera test specs Gherkin-lite derivados de DoDs do auto-grill-me e anexa em skills/testing/references/TEST-PATTERNS.md (single-DoD) ou em "## Test Specs" do plano (plan-path). Trigger phrases — "tactical test spec", "gerar test spec", "test spec por tarefa", "TDD a partir de DoD". Use após DoDs estabilizadas para materializar specs táticos consumidos por humano/Ralph.
argument-hint: "[tarefa-N | cat-N-base | <plan-path>] [--regenerate]"
allowed-tools: Read, Edit, Write, Bash(pwd), Bash(ls *), Bash(test *), Bash(cat *), Bash(grep *), Bash(awk *), Bash(sed *), Bash(find *), Bash(realpath *), Bash(basename *), Bash(dirname *), Bash(git:*), Bash(jq *)
---

# /test-spec — gera test specs Gherkin-lite a partir de DoDs

Espelha o lifecycle das DoDs (`skills/auto-grill-me/references/DOD.md`) num
artefato versionado `skills/testing/references/TEST-PATTERNS.md`: 1 unidade
contável por spec. Os contadores `usos`/`desde rev` são **derivados** via o fold
(`bin/lib/usage-fold.sh --prefix test-spec`, US-02) — **não** ficam mais inline no
heading (sufixo `(usos: X · desde rev: Y)` removido na migração US-03). Formato
canônico de cada spec (D2 do plano, Gherkin-lite):

```
- [ ] spec-N (tarefa-X-spec-N): dado <precondição>, quando <ação>, então <observable> — edge: <caso opcional>
```

> **Granularidade (Ressalva Alta #2 da revisão adversária — não-negociável).**
> Cada spec mapeia **exatamente 1 asserção atômica**. Bullets de DoD com N
> asserções viram N specs com sufixo `-A/-B/-C` (`spec-3-A`, `spec-3-B`).
> Bullets puramente declarativos (review humano) recebem prefixo
> `[CAT3-MANUAL]` na descrição e **geram 0 specs** — compatível com a sintaxe
> rígida da skill `prd` (filtrada pelo Ralph antes do prompt).

> **Heading idêntico ao DOD.md (Ressalva Alta #1 — não-negociável).** Use
> `### Tarefa N — <título>` e `### DoD-base — Categoria N` no TEST-PATTERNS.md —
> SOURCE-PURO, **sem** o sufixo `(usos…)` (AC3: a regex de heading casa o heading
> sem sufixo). **Nunca** prefixe `Test specs para` — o regex de
> `bin/test-spec-reset-rev.sh` (clone de `bin/dod-reset-rev.sh`) é literal
> `^### Tarefa` / `^### DoD-base`.

## Preflight (inline bash — pré-computa contexto antes do modelo)

!`pwd`
!`ls -t .claude/plans/*.md 2>/dev/null | head -5 || echo "(sem .claude/plans/ no cwd)"`
!`REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; DOD="$REPO_ROOT/skills/auto-grill-me/references/DOD.md"; test -f "$DOD" && echo "DOD.md: $DOD" || echo "(DOD.md ausente em $REPO_ROOT/skills/auto-grill-me/references/ — fonte canônica obrigatória)"`
!`REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; TP="$REPO_ROOT/skills/testing/references/TEST-PATTERNS.md"; test -f "$TP" && echo "TEST-PATTERNS.md: $TP" || echo "(TEST-PATTERNS.md ausente — US-02 do plano tdd-spec-lifecycle-from-dod ainda não landada; single-DoD mode aborta com erro claro)"`

## Argumento

`$ARGUMENTS` = `$ARGUMENTS` (primeiro token posicional = `$1`).

## Parse de argumentos

1. **Flag `--regenerate`** — pode aparecer em qualquer posição. Extraia e
   remova de `$ARGUMENTS`; o resto é o "alvo".
2. **Sem alvo restante** → Ramo 1 (auto-detect plano).
3. **Alvo casa `^(tarefa-[0-9]+|cat-[0-9]+-base)$`** → Ramo 2 (single-DoD).
4. **Alvo contém `/`** → Ramo 3 (plan-path).
5. **Qualquer outro padrão** → erro `argumento inválido — esperado tarefa-N, cat-N-base, <plan-path>, ou vazio` e aborta.

## Ramo 1 — sem-arg → auto-detect plano mais recente

1. Pega o primeiro path em `ls -t .claude/plans/*.md` (mais recente).
2. Se a lista estiver vazia → erro `nenhum plano em .claude/plans/ — passe explicitamente <plan-path> ou tarefa-N` e aborta.
3. Trata o path resolvido como entrada do Ramo 3 (plan-path mode).

## Ramo 2 — `tarefa-N` / `cat-N-base` → single-DoD mode

1. Verifique que `skills/testing/references/TEST-PATTERNS.md` existe (preflight
   acima já reportou). Se ausente, **PARE** com `TEST-PATTERNS.md não existe — landar US-02 antes (skill testing estendida)`.
2. Leia `skills/auto-grill-me/references/DOD.md` e localize a seção do
   `tarefa-N` ou `cat-N-base` informado:
   - Para `tarefa-N`: heading `^### Tarefa N — `.
   - Para `cat-N-base`: heading `^### DoD-base — Categoria N `.
   Se o id não existir no DOD.md, erro `id desconhecido: <id> — não encontrado em DOD.md` e aborta.
3. Para cada bullet `- [ ] ...` na seção:
   - Decompose em **asserções atômicas**. Bullet puramente declarativo (sem
     observable testável binário, ex.: "revisado por outra sessão") recebe
     marker `[CAT3-MANUAL]` e gera 0 specs.
   - Para cada asserção atômica gere 1 spec no formato Gherkin-lite. Sufixo
     `-A/-B/-C` quando o mesmo bullet origina múltiplas asserções.
   - Numeração `spec-1`, `spec-2`, ... reinicia por bloco de tarefa.
4. Abra `skills/testing/references/TEST-PATTERNS.md` e localize o heading
   correspondente (`### Tarefa N — <título>` ou `### DoD-base — Categoria N` —
   SOURCE-PURO, sem o sufixo `(usos…)`).
5. **Comportamento `--regenerate`:**
   - Sem `--regenerate`: se o bloco já tem bullets populados, **não duplicar**
     — emita `bloco já populado; use --regenerate para forçar`.
   - Com `--regenerate`: substitui o corpo do bloco pelas specs novas. O hash
     dos bullets muda → o fold (content-based, US-02) deriva `desde rev` só dos
     usos no sha atual; `bin/test-spec-reset-rev.sh` registra a revisão. **Não**
     edite contador inline (não existe mais).
6. **NÃO edite contador inline no heading** (removido em US-03) e **NÃO chame
   `log_event`** — a emissão é determinística via Stop hook (ver
   [DOD-MAPPING.md](../skills/auto-grill-me/references/DOD-MAPPING.md)). Após
   materializar o bloco (Ramo 2, criação OU `--regenerate` que de fato substitui),
   **emita o marcador `<!-- test-spec-use: <id> -->`** logo após o bloco no
   `TEST-PATTERNS.md`. O Stop hook [`hooks/dod-usage-log.sh`](../hooks/dod-usage-log.sh)
   varre o `TEST-PATTERNS.md`, computa o sha via `dod_bullets_sha`, e emite o
   evento `use --prefix test-spec` (idempotente). Não emita marcador quando o
   bloco já está populado e você abortou sem mexer (no-op).
7. Append/replace o bloco verbatim no TEST-PATTERNS.md preservando demais
   blocos. Use Edit/Write conforme a operação.
8. Resumo final no chat: `spec_id_base=tarefa-N | cat-N-base`, contador derivado
   (via fold), nº de specs gerados, nº de bullets `[CAT3-MANUAL]`.

## Ramo 3 — `$1` contém `/` → plan-path mode

1. Verifique que o path existe (`test -f "$1"`); se não, erro
   `plano não encontrado: $1` e aborta.
2. Extraia todos os ids referenciados no plano via grep
   `grep -oE '(tarefa-[0-9]+|cat-[0-9]+-base)' "$1" | sort -u`.
   Se zero ids encontrados, erro `nenhum tarefa-N/cat-N-base referenciado em $1` e aborta.
3. Para cada id encontrado, gere o bloco de specs como no Ramo 2 (a partir
   do DOD.md). Não precisa atualizar TEST-PATTERNS.md neste ramo — o destino
   é o próprio plano.
4. Abra o plano e localize ou crie a seção `## Test Specs`:
   - **Ausente:** crie no fim do arquivo (após eventual `## Revisão Adversária`
     ou `## Próximos comandos`). Append.
   - **Presente sem `--regenerate`:** anuncie `seção ## Test Specs já existe; use --regenerate para sobrescrever` e termine.
   - **Presente com `--regenerate`:** substitua o conteúdo entre `## Test Specs`
     e o próximo `## ` (ou EOF).
5. Conteúdo da seção: sub-heading `### Specs para <id>` por id encontrado,
   contendo o bloco Gherkin-lite. Cada spec usa o mesmo formato canônico.
   **Após cada bloco `### Specs para <id>`, emita o marcador
   `<!-- test-spec-use: <id> -->`** — o Stop hook o conta ao varrer
   `.claude/plans/` (ver [DOD-MAPPING.md](../skills/auto-grill-me/references/DOD-MAPPING.md)).
6. Resumo final no chat: `plan=<path>`, ids cobertos, total de specs gerados.

## Flag `--regenerate`

- Ramo 2: força regeneração do bloco do id alvo no TEST-PATTERNS.md (substitui
  bullets existentes). O sha dos bullets muda → o fold (content-based, US-02)
  deriva `desde rev` apenas dos usos no sha atual; `bin/test-spec-reset-rev.sh`
  registra a revisão (evento `revision`), sem editar contador inline.
- Ramo 3: força regeneração da seção `## Test Specs` do plano (substitui).
- Ramo 1: aplicado ao plano auto-detectado (mesmo comportamento Ramo 3).
- Sem o flag, o comando é **idempotente** — re-invocações sobre o mesmo alvo
  não duplicam specs (os contadores são derivados via fold, não editados inline).

## Saída esperada (resumo da sessão)

Após executar, imprima 3–5 linhas:

- ramo escolhido (1/2/3)
- alvo resolvido (id ou plan-path)
- arquivo modificado (TEST-PATTERNS.md ou plano)
- counts: `specs_gerados=N`, `cat3_manual=M`, `usos_derivado=K` (via fold)
- aviso opcional se `bin/test-spec-reset-rev.sh` não existir ainda
  (US-02 pendente)

## Não faça

- Não invente headings com prefixo `Test specs para` — quebra o regex parser
  clonado de `dod-reset-rev.sh`.
- Não gere specs múltiplas para o mesmo bullet sem distinção atômica — viola
  política de granularidade (Ressalva Alta #2).
- Não edite `skills/auto-grill-me/references/DOD.md` — TEST-PATTERNS é mirror,
  não fonte; alterações na DoD partem da skill `auto-grill-me`.
- Não edite contador inline no heading do TEST-PATTERNS.md — o sufixo `(usos…)`
  foi removido em US-03; `usos`/`desde rev` são derivados via fold. O subcomando
  `--gc` foi aposentado (sem snapshot `.json`, não há entradas órfãs a coletar).
