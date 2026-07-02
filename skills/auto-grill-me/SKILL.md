---
name: auto-grill-me
description: Interview adversário que classifica perguntas por rubrica quantitativa antes de interromper. Score baixo → assume silenciosamente. Score médio → assume + footnote. Score alto → pergunta. Use quando o usuário menciona "auto grill", "grille com classificação", "plano silencioso", "rubrica de decisão", ou pede grilling sem ser interrompido em tudo. Produz plano em formato /plan com DoD por artefato em .claude/plans/.
argument-hint: "[topic]"
---

# auto-grill-me

Interview the user about a plan or design. For each question in the design tree, **classify before interrupting** using the rubric in [references/RUBRICA.md](references/RUBRICA.md). Walk down each branch resolving dependencies one-by-one. Provide a recommended answer for every Tipo 1 question (verbatim grill-me style).

Topic vem de `$ARGUMENTS` se fornecido; caso contrário, usa o contexto da conversa.

## Per-question protocol

Para cada decisão da árvore de design:

1. **Gerar a próxima pergunta** (ou encerrar se shared understanding alcançado — ver §Stop criterion).
2. **Escolher domínio candidato** (eng / mkt / biz) via heurística de palavras-chave na pergunta. Empate → eng (default). Zero matches → eng + adicionar 1 a G6 (sinal de incerteza no mapping).
3. **Avaliar short-circuits** ([RUBRICA.md §1](references/RUBRICA.md), F1–F8). Se algum disparar, executar ação direta sem score.
4. **Avaliar anti-patterns** ([RUBRICA.md §2](references/RUBRICA.md), 1–10). Se algum disparar, forçar Tipo 2 silencioso (não perguntar).
5. **Calcular score** via critérios genéricos G1–G8 ([§3](references/RUBRICA.md)) + critérios de domínio ([§4](references/RUBRICA.md)), agregando por [§5](references/RUBRICA.md). G6 = verbalized_confidence − 1 (desconto fixo; sem self-consistency na Fatia 1).
6. **Aplicar threshold** ([§6](references/RUBRICA.md)):
   - `score < 35` → **Tipo 2**: assume silenciosamente, **não imprime nada** ao usuário (apenas log).
   - `35 ≤ score ≤ 60` → **Tipo 3**: assume, imprime **uma linha** `▸ assumi: <decisão em 1 frase> (footnote #N)`, armazena footnote completa em buffer (formato [§7](references/RUBRICA.md)).
   - `score > 60` → **Tipo 1**: pergunta ao usuário **uma pergunta por vez** com recomendação explícita (verbatim grill-me style). Aguarda resposta antes de continuar.
7. **Logar a decisão** em `decisions.jsonl` (ver §Audit log).
8. **Se um artefato emergir** ("vamos precisar de um hook", "isso vai virar uma skill"): usar o índice de mapping em [DOD.md](references/DOD.md) para escolher candidato de categoria/tarefa. Rodar meta-classificação via rubrica sobre o mapping (mesmo algoritmo §3–§6 — usar G3/G6 para avaliar confiança no mapping). **Copiar verbatim (bullet-por-bullet)** o `DoD-base` da categoria + a `Tarefa N` específica do DOD.md e adicioná-los à seção "Artefatos a produzir" do plano em formação. `DoD-base` aparece **1× por categoria por plano** (dedupe — por economia de ruído, não por verbatim estrito); cada `Tarefa N` é sempre verbatim integral. **Após cada bloco inserido, emite o marcador `<!-- dod-use: <id> -->`** logo abaixo dele (ver §Contadores de uso e [DOD-MAPPING.md](references/DOD-MAPPING.md)). **A skill NÃO chama `log_event`** — o Stop hook conta a partir do marcador.

## Rubrica na execução (não só no planejamento)

**A rubrica §3–§6 vale também durante a execução** — implementação, debug, entrega — não apenas na entrevista de plano (R4 de `~/analise-interrupcoes/autonomia-recomendacoes.md`: só 40% das perguntas mid-execução eram legítimas; a rubrica existia e era ignorada fora do plano). Diferenças do modo execução:

1. **Mesmos thresholds**: score < 35 → assume silenciosamente; 35–60 → assume + `[SUPOSIÇÃO]`/footnote no report; > 60 → só pergunta se **também** cai num gatilho (a)–(e) do P15 — score alto sem gatilho vira `[SUPOSIÇÃO]` destacada.
2. **Formato da pergunta legítima**: `AskUserQuestion` estruturada, nunca prosa — opção recomendada em 1º com "(Recommended)".
3. **Batch obrigatório**: junte até 4 perguntas num turno só; máx. **1 turno de perguntas por fase** (mata o ping-pong "1 ok, 2 ok, 3 ok"). Pergunta que surge depois do turno de perguntas da fase → segura para a próxima fase ou vira `[SUPOSIÇÃO]`.
4. **Sem audit log**: o `decisions.jsonl` é da entrevista; em execução, o rastro é o próprio report (footnotes/`[SUPOSIÇÃO]`).

## Stop criterion

Encerrar quando **shared understanding** for alcançado (julgamento do agente, mesmo do `grill-me` original):

- Todas as ramificações da árvore foram resolvidas.
- Nenhuma decisão Tipo 1 pendente sem resposta.
- Agente não consegue formular próxima pergunta substantiva (não-redundante).

## Output

Ao encerrar:

1. **Imprimir o buffer de footnotes Tipo 3** consolidado (numerado #1, #2, …) com `▸ assumi: <decisão>` + `alternativas:` + `trade-off:` + `reverter:` quando aplicável.
2. **Persistir o plano** em `.claude/plans/<ISO-timestamp>-<slug>.md` no formato `/plan` ReAct+Feynman (ver [skill react-feynman](../react-feynman/SKILL.md)):
   - `# Plano: <slug>`
   - `## Contexto`
   - `## Árvore de Design (decisões tomadas)` — Thought/Action/Observation por decisão, marcando resolução (Tipo 1/2/3).
   - `## Artefatos a produzir` — cada artefato com Categoria/Tarefa mapeada + DoD em checklist `- [ ]`, **seguido do marcador `<!-- dod-use: <id> -->`** por bloco (ver [DOD-MAPPING.md](references/DOD-MAPPING.md)).
   - `## Perguntas Abertas` — dúvidas residuais + grau de confiança (alta/média/baixa).
   - `## Apêndices` — A) footnotes Tipo 3, B) resumo do audit log da sessão (distribuição Tipo 1/2/3 por domínio), C) confiança geral.
3. **Anunciar o path** + listar próximos comandos sugeridos: `/adversarial-review <plan>`, `/prd-convert`, `/full-cycle`.

Slug = 5–8 palavras derivadas do tópico ou da pergunta-raiz. Criar `.claude/plans/` se não existir.

## Docs de domínio (CONTEXT.md + ADRs)

Esta skill consome a biblioteca `domain-docs` para escrever `CONTEXT.md`/`docs/adr/` — leia `~/.claude/skills/domain-docs/SKILL.md` (formatos canônicos + regras: criação lazy + anúncio de 1 linha, gate triplo de ADR, modo inline vs batch, materialização). **Não reproduza as regras de formato aqui.**

Restrição própria desta skill — **só a decisão do usuário vira termo no glossário**:

- **Tipo 1 (score > 60, pergunta efetivamente respondida pelo usuário):** se a resposta cristaliza um **termo de domínio**, escreva-o no `CONTEXT.md` **inline** (na hora, modo inline da biblioteca). É decisão do usuário → é fato do domínio.
- **Tipo 2 / Tipo 3 (score < 35 e 35–60, assunção assumida sem perguntar):** a assunção silenciosa **NÃO** vai pro `CONTEXT.md`. **Assunção silenciosa não é decisão do usuário** e o glossário canônico não registra suposição — ela fica só no log (Tipo 2) / footnote (Tipo 3) e na Árvore de Design do plano.
- **Restante (termos OBSERVADOS e ADRs propostos):** modo batch — ao persistir o plano, escreva os termos observados no `CONTEXT.md` e inclua a seção `## ADRs propostos` com o texto integral; materializam nos gates de cada fluxo (ver biblioteca). Termo CUNHADO por uma assunção silenciosa não-confirmada nunca entra no glossário, nem em batch.

## Audit log

Append por decisão (Tipo 1/2/3) em `~/.claude/cache/auto-grill/<basename-cwd>-decisions.jsonl`, schema definido em [RUBRICA.md §8](references/RUBRICA.md).

- Criar diretório lazy na primeira escrita.
- Opt-out: env `CLAUDE_AUTO_GRILL_NO_LOG=1` (sem prompt).
- `session_id` = UUID gerado no primeiro turno da sessão; mesmo valor para todas as decisões da sessão.

## Contadores de uso

Cada DoD em [`references/DOD.md`](references/DOD.md) tem dois contadores **derivados** — eles **não** vivem mais no heading (o sufixo inline `(usos: N · desde rev: N)` foi removido na migração; o `DOD.md` é source-puro: o heading é só `### <Tarefa N|DoD-base> — <Título>`):

- `usos` — histórico total de inserções deste DoD em planos produzidos pela skill.
- `desde rev` — inserções desde a última revisão substantiva dos bullets daquele DoD.

Os números são derivados sob demanda de um **log append-only per-machine** (`~/.claude/telemetry/dod-usage.<machine-id>.jsonl`) pelo fold content-based [`bin/lib/usage-fold.sh`](../../bin/lib/usage-fold.sh). A skill **não edita contador inline no `DOD.md`** e **não chama `log_event`** — apenas **insere o marcador** `<!-- dod-use: <id> -->` no plano.

### Emissão determinística via Stop hook (não prompt-driven)

A emissão dos eventos `use` é responsabilidade do Stop hook [`hooks/dod-usage-log.sh`](../../hooks/dod-usage-log.sh), **não** da skill. Por quê: a emissão antiga (a skill mandava o LLM rodar `log_event` no encerramento) **nunca disparou na prática** — 0 eventos reais em 11–15 dias nas 3 máquinas. Agora:

1. A skill insere **1 marcador `<!-- dod-use: <id> -->` por inserção de DoD** no plano persistido (ver [DOD-MAPPING.md](references/DOD-MAPPING.md)).
2. Ao fim do turno (Stop), o hook parseia o plano, computa o sha atual via `dod_bullets_sha references/DOD.md`, e emite `log_event use <id> --sha <sha> --prefix dod` — idempotente (ledger per-marcador) e anti-backfill (pré-seed dos planos pré-existentes).

O append do writer é atômico (`O_APPEND`) e **lockless**; o writer **nunca reescreve** o `DOD.md`. O marcador `<!-- dod-use: <id> -->` carrega o `dod_id` literal; o hook deriva o sha na hora, então `desde rev` continua content-based.

**O evento `use` carrega o sha atual dos bullets do DoD aplicado.** É assim que o fold deriva `desde rev` de forma content-based: `desde rev` = #eventos `use` cujo `sha` == sha atual dos bullets do DoD no `DOD.md` (computado na hora). Imune a clock-skew cross-host — não depende de ordenação por `ts`.

### Reset de "desde rev" (content-based)

Quando os bullets de um DoD mudam, o sha atual muda → os eventos `use` antigos (sha antigo) deixam de casar e `desde rev` "zera" naturalmente no fold, sem reescrever nada. Para marcar a revisão explicitamente sem esperar o próximo uso, emita um evento `revision` com o novo sha via o fallback abaixo.

Fallback manual via `bin/`:

- `bin/dod-reset-rev.sh <dod_id>` — "reset": emite 1 evento `revision` @ sha atual dos bullets (ex.: `dod-reset-rev.sh tarefa-5`). Não edita inline.
- `bin/dod-reset-rev.sh --show [--sort=desde-rev|usos|id]` — tabela derivada via fold; default ordena por `desde rev` DESC.
- `bin/dod-usage-migrate.sh` — seeder one-shot idempotente que semeia o log a partir dos contadores que eram inline (migração inicial).

(O subcomando `--gc` foi aposentado: sem snapshot `.json`, não há entradas órfãs a coletar.)

### Bootstrap zero-config

DoD inserido pela primeira vez → a skill apenas emite o evento `use` com o sha atual; o fold passa a derivar `usos: 1 · desde rev: 1` automaticamente. Não há estado a inicializar no `DOD.md` (source-puro) — o log é a única fonte de verdade dos números.

### Invariantes estruturais

- **Append-only:** `Tarefa N` e `Categoria N` são append-only — **renumeração quebra os contadores** (o `dod_id` derivado do heading — `tarefa-N`/`cat-N-base` — é a chave no log). Adicionar nova Tarefa = próximo número global livre; nunca renumerar Tarefas existentes. Renomear o `<Título>` é seguro (não entra no `dod_id` nem no sha dos bullets).
- **Dedupe DoD-base:** `DoD-base` aparece **1× por categoria por plano por economia de ruído, não por verbatim estrito**. Cada `Tarefa N` específica é sempre verbatim integral.
- **Sem subheadings dentro de Tarefa:** delimitação de bullet block usa "do heading até o próximo `###`". Adicionar `### Subtítulo` dentro de uma Tarefa quebra o sha dos bullets e cala bullets posteriores. Para subtópico use `####` ou texto plano.

<!-- FATIA-2: substituir G6 verbalized direto por self-consistency check (3 amostras, ajuste por concordância). Wang et al. ICLR 2023, arXiv:2203.11171. Atualizar §3 da RUBRICA.md em paralelo. -->

## Gotchas

**Observados na primeira sessão real (2026-05-17, dotclaude, design do `/reflect`):**

1. **Sessão pode encerrar sem nenhuma pergunta.** Quando todas as decisões da árvore caem em score < 60 (Tipo 2/3), o agente não interrompe — entrega plano direto. Pode surpreender usuário que invocou esperando ser entrevistado. Comportamento correto pela rubrica, mas vale **anunciar no início da sessão** ("classifiquei N decisões previstas; M vão pra pergunta; resto vira assume + footnote") para calibrar expectativa.

2. **Cluster de decisões score 53–60 = sinal de calibragem.** Em sessões reais é comum 2–3 decisões caírem exatamente no limite superior do Tipo 3 (perto de 60). São candidatos a força-Tipo-1 manual OU sinal de que o threshold 60 está alto demais para o domínio. Recomendação da rubrica (Sprint 3): revisar mensalmente `decisions.jsonl`; se ≥30% das decisões ficam na faixa 53–60, baixar threshold superior de 60 para 55. Antes desse volume, não recalibrar — pode ser variância normal.

3. **Concorrência entre slots Boris e edição manual de bullets.** O batch no `Stop criterion` agora só faz **append** no log per-machine (`~/.claude/telemetry/dod-usage.<machine-id>.jsonl`) — `O_APPEND` é atômico sob o lock do inode (POSIX, FS local), e cada máquina escreve seu próprio arquivo (`machine-id`, não hostname). **Não há lock `mkdir`** nem escrita compartilhada em `DOD.md`: dois slots Boris invocando `auto-grill-me` simultaneamente não colidem (paths disjuntos, sem race). **Edição manual de bullets:** quando você edita `references/DOD.md` (corrigir typo, refinar redação) sem rodar a skill, o sha atual dos bullets muda → no próximo fold os eventos `use` antigos deixam de casar e `desde rev` re-deriva pra baixo — correto se a edição foi semântica; "falso-positivo" se foi cosmética. Para marcar a revisão explicitamente: `bin/dod-reset-rev.sh <dod_id>` (emite evento `revision` @ sha atual).
