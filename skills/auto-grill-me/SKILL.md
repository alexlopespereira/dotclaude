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
8. **Se um artefato emergir** ("vamos precisar de um hook", "isso vai virar uma skill"): usar o índice de mapping em [DOD.md](references/DOD.md) para escolher candidato de categoria/tarefa. Rodar meta-classificação via rubrica sobre o mapping (mesmo algoritmo §3–§6 — usar G3/G6 para avaliar confiança no mapping). **Copiar verbatim (bullet-por-bullet)** o `DoD-base` da categoria + a `Tarefa N` específica do DOD.md e adicioná-los à seção "Artefatos a produzir" do plano em formação. `DoD-base` aparece **1× por categoria por plano** (dedupe — por economia de ruído, não por verbatim estrito); cada `Tarefa N` é sempre verbatim integral. Incremento de `usos` é acumulado em memória e aplicado em batch no `Stop criterion` (ver §Contadores de uso).

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
   - `## Artefatos a produzir` — cada artefato com Categoria/Tarefa mapeada + DoD em checklist `- [ ]`.
   - `## Perguntas Abertas` — dúvidas residuais + grau de confiança (alta/média/baixa).
   - `## Apêndices` — A) footnotes Tipo 3, B) resumo do audit log da sessão (distribuição Tipo 1/2/3 por domínio), C) confiança geral.
3. **Anunciar o path** + listar próximos comandos sugeridos: `/adversarial-review <plan>`, `/prd-convert`, `/full-cycle`.

Slug = 5–8 palavras derivadas do tópico ou da pergunta-raiz. Criar `.claude/plans/` se não existir.

## Audit log

Append por decisão (Tipo 1/2/3) em `~/.claude/cache/auto-grill/<basename-cwd>-decisions.jsonl`, schema definido em [RUBRICA.md §8](references/RUBRICA.md).

- Criar diretório lazy na primeira escrita.
- Opt-out: env `CLAUDE_AUTO_GRILL_NO_LOG=1` (sem prompt).
- `session_id` = UUID gerado no primeiro turno da sessão; mesmo valor para todas as decisões da sessão.

## Contadores de uso

Cada DoD em [`references/DOD.md`](references/DOD.md) carrega dois contadores no próprio heading:

```
### <Tarefa N|DoD-base> — <Título> (usos: X · desde rev: Y)
```

- `usos` — histórico total de inserções deste DoD em planos produzidos pela skill.
- `desde rev` — inserções desde a última revisão substantiva dos bullets daquele DoD.

### Regex parser único

```
^### (Tarefa \d+|DoD-base) — (.+?) \(usos: (\d+) · desde rev: (\d+)\)$
```

Captura: `dod_kind` (`Tarefa N` ou `DoD-base`), `title_current`, `usos`, `desde rev`. O snapshot em `references/.dod-revision-state.json` indexa por `dod_id` — `tarefa-N` para Tarefas, `cat-N-base` para DoD-base — com `slug`, `title_current`, `bullets_sha256` e `last_seen_iso` como metadata.

### Incremento (batch no Stop criterion)

Durante a sessão a skill acumula `Map<dod_id, {delta_usos, delta_rev, hash_recalculado}>` em memória conforme insere DoDs no plano em formação. **Apenas no encerramento (Stop criterion)** — antes de imprimir o plano final — aplica todos os deltas em uma única passagem por `DOD.md`, sob lock `mkdir <lockdir>` (macOS-compatível; `flock` não existe no Darwin). Lock falhou após retry → aborta com exit 3 e instrui rodar de novo.

### Reset de "desde rev" (hash-driven)

Para cada DoD inserido na sessão:

1. Recalcula `sha256` do bullet block (heading exclusive até o próximo `###` exclusive; trailing whitespace removido por linha antes do hash).
2. Compara com `bullets_sha256` registrado em `.dod-revision-state.json`.
3. Hash divergiu → zera `desde rev` e atualiza snapshot. Hash igual → incrementa `desde rev` normal.

Fallback manual via `bin/`:

- `bin/dod-reset-rev.sh <dod_id>` — zera `desde rev` explicitamente (ex.: `dod-reset-rev.sh tarefa-5`).
- `bin/dod-reset-rev.sh --show [--sort=desde-rev|usos|id]` — tabela legível; default ordena por `desde rev` DESC.
- `bin/dod-reset-rev.sh --gc` — remove entries órfãs do snapshot.
- `bin/dod-migrate-add-counters.sh` — one-shot idempotente que injeta o padrão `(usos: 0 · desde rev: 0)` nos 28 headings e cria o snapshot inicial.

### Bootstrap zero-config

Heading sem o padrão `(usos: N · desde rev: N)` na primeira inserção pela skill → a skill cria com `(usos: 1 · desde rev: 1)` automaticamente e gera entry correspondente no snapshot. Semanticamente correto: foi inserida agora, então foi usada 1× desde sua criação. Não há estado `(0 · 0)` produzido pela skill em runtime — só pelo script de migração inicial.

### Invariantes estruturais

- **Append-only:** `Tarefa N` e `Categoria N` são append-only — **renumeração quebra contadores** (a chave do snapshot é `tarefa-N`/`cat-N-base`, não slug). Adicionar nova Tarefa = próximo número global livre; nunca renumerar Tarefas existentes. Renomear o `<Título>` é seguro (preservado em `title_current` como metadata).
- **Dedupe DoD-base:** `DoD-base` aparece **1× por categoria por plano por economia de ruído, não por verbatim estrito**. Cada `Tarefa N` específica é sempre verbatim integral.
- **Sem subheadings dentro de Tarefa:** delimitação de bullet block usa "do heading até o próximo `###`". Adicionar `### Subtítulo` dentro de uma Tarefa quebra o hash e cala bullets posteriores. Para subtópico use `####` ou texto plano.

<!-- FATIA-2: substituir G6 verbalized direto por self-consistency check (3 amostras, ajuste por concordância). Wang et al. ICLR 2023, arXiv:2203.11171. Atualizar §3 da RUBRICA.md em paralelo. -->

## Gotchas

**Observados na primeira sessão real (2026-05-17, dotclaude, design do `/reflect`):**

1. **Sessão pode encerrar sem nenhuma pergunta.** Quando todas as decisões da árvore caem em score < 60 (Tipo 2/3), o agente não interrompe — entrega plano direto. Pode surpreender usuário que invocou esperando ser entrevistado. Comportamento correto pela rubrica, mas vale **anunciar no início da sessão** ("classifiquei N decisões previstas; M vão pra pergunta; resto vira assume + footnote") para calibrar expectativa.

2. **Cluster de decisões score 53–60 = sinal de calibragem.** Em sessões reais é comum 2–3 decisões caírem exatamente no limite superior do Tipo 3 (perto de 60). São candidatos a força-Tipo-1 manual OU sinal de que o threshold 60 está alto demais para o domínio. Recomendação da rubrica (Sprint 3): revisar mensalmente `decisions.jsonl`; se ≥30% das decisões ficam na faixa 53–60, baixar threshold superior de 60 para 55. Antes desse volume, não recalibrar — pode ser variância normal.

3. **Concorrência entre slots Boris e drift de snapshot.** O batch de incremento no `Stop criterion` serializa escrita em `references/DOD.md` via `mkdir <lockdir>` — `flock` não está instalado no macOS (Darwin), então o padrão clássico de fd-lock não funciona; `mkdir` é atomic em qualquer POSIX. Se dois slots Boris invocarem `auto-grill-me` simultaneamente, o segundo a chegar no lock retenta com `sleep 0.1` até ~5s e aborta com exit 3 se não conseguir — rodar de novo após o primeiro liberar. **Drift de snapshot:** quando você edita `references/DOD.md` manualmente (corrigir typo num bullet, refinar redação) sem rodar a skill, o `bullets_sha256` em `.dod-revision-state.json` fica defasado. A próxima invocação da skill detectará divergência de hash e zerará `desde rev` — correto se a edição foi semântica; falso-positivo se foi cosmética. Para reset explícito sem esperar a próxima invocação: `bin/dod-reset-rev.sh <dod_id>`.
