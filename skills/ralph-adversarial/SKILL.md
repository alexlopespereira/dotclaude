---
name: ralph-adversarial
description: Loop de implementação autônomo baseado no padrão Ralph com revisão adversária do Codex. Claude Code implementa uma user story por iteração com contexto fresco. Codex revisa o código usando a rubrica em skills/ralph-adversarial/CODE_REVIEW.md. Use após converter um plano aprovado em prd.json.
---

# Skill: Ralph Adversarial Loop

## Pré-requisitos
- prd.json na raiz do repositório (gerado pela skill prd)
- Rubrica de revisão em `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md`
- Template de prompt do Primary em `~/.claude/skills/ralph-adversarial/IMPL_PROMPT.md` (sem interpolação shell; story corrente é anexada via jq sob `## Story atual`)
- Notas informativas Fase 2 em `~/.claude/skills/ralph-adversarial/IMPL_PROMPT.fase2-notes.md` (NÃO injetado no prompt do agente)
- Claude Code CLI e jq instalados
- Codex CLI (opcional, recomendado). Se ausente ou se a OpenAI retornar
  quota/rate-limit, o loop cai automaticamente para uma instância
  `claude --model sonnet` aplicando a mesma rubrica — a troca fica
  registrada em `progress.txt` como `CODEX_QUOTA`.
- `.gitignore` do projeto-alvo deve ignorar artefatos do framework
  (`progress-*.txt`, `agents-delta-*.md`, `.ralph/`, `.ralph-review-*/`,
  `.claude/`). Rode `bash skills/ralph-adversarial/apply-gitignore.sh
  [--pool]` uma vez por projeto para adicionar idempotentemente. Em
  layouts Boris Cherny (5 slots), use `--pool` para commitar +
  propagar via push/pull aos slots irmãos. Defesa em camadas: o
  orquestrador também escreve patterns em `.git/info/exclude` de
  cada slot via `ensure_slot_excludes_deltas` no preflight, então
  pools provisionados antes de aplicar o `.gitignore` continuam
  protegidos automaticamente.

## Arquitetura

Cada iteração do loop:
1. Script bash spawna Claude Code com contexto fresco
2. Claude lê prd.json, progress.txt, git log
3. Claude implementa 1 story + roda checks + preenche ac_trace no commit
4. Script spawna o reviewer (Codex por padrão; Claude Sonnet em fallback)
5. Reviewer aplica rubrica de `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md`
6. Se MERGE: marca story passes:true, próxima iteração
7. Se BLOCK/REQUEST_CHANGES: feedback vai para progress.txt, Claude corrige na próxima iteração
8. Se 2 iterações consecutivas da mesma story falham: invocar `/diagnose <story-id>` (skill `diagnose`) para construir feedback loop e ranquear hipóteses **antes** da 3ª iteração. Persistir achados em progress.txt.
9. Se 3 iterações consecutivas falham mesmo após `/diagnose`: escalar ao humano.

## Fallback de reviewer
- Detector: `detect-quota.sh::is_codex_fallback_error` (alias legado:
  `is_codex_quota_error`) identifica padrões de quota/rate-limit
  (HTTP 429, `insufficient_quota`, "exceeded your current quota", etc.)
  e de auth morta (`token_expired`, refresh token reutilizado,
  `401 Unauthorized`).
- Gatilhos: Codex ausente no PATH no início do loop, ou output de uma
  execução contém sinal de quota.
- Estado: uma vez ativado, `CODEX_UNAVAILABLE=true` persiste pelo resto
  da execução para não desperdiçar iterações chamando um provedor que
  acabou de falhar.
- Saída do reviewer: o Claude Sonnet fallback termina com `## Verdict:
  MERGE|BLOCK|REQUEST_CHANGES`, já reconhecido pelo `parse-verdict.sh`.
- Arquivo de review: salvo em `.claude/research/review-<STORY>-iter<N>-<reviewer>.txt`.

## Memória entre iterações (estado no disco, não no contexto)
- prd.json: quais stories faltam (passes: true/false)
- progress.txt: aprendizados, feedback do Codex, gotchas
- git history: código já produzido
- AGENTS.md: convenções descobertas durante implementação

## API timeout retry budget

Ralph detecta a string `API Error: Stream idle timeout` no log do agente
primary (case-insensitive, regex `API Error:[[:space:]]*Stream idle timeout`).
A regex é **restrita** — `"partial response received"` sozinho e
`'"verdict": "partial"'` (ac_trace tag) **não** disparam o detector. Test
fixtures: `tests/test_stream_timeout_detect.sh` (regex AC7) e
`tests/test_stream_timeout_behavior.sh` (paths AC5/AC6: dry-run vs. active
retry vs. budget esgotado, com sentinel grep contra drift).

- **Dry-run (default) — `RALPH_API_TIMEOUT_RETRY=0`:** ao detectar a regex,
  Ralph apenas registra `API_TIMEOUT_CANDIDATE` em `progress.txt` e segue
  pelo caminho original (`FALHA_COMMIT` + `set_retry_count`). Útil para
  medir o falso-positivo antes de ativar retry de produção.
- **Ativo — `RALPH_API_TIMEOUT_RETRY=1`:** ao detectar a regex, Ralph
  registra `API_TIMEOUT` em `progress.txt`, **incrementa contador
  separado** (não bumpa `set_retry_count` da story) e segue para a próxima
  iteração tentando a mesma story.
- **Budget — `MAX_API_TIMEOUT_RETRIES` (default 3):** quando o contador
  separado esgota, Ralph registra `API_BUDGET_EXHAUSTED` e marca a story
  com `passes="ESCALATED_API_TIMEOUT"` (distinto do `ESCALATED` normal de
  `MAX_RETRIES_PER_STORY`).

**Tags em `progress.txt`:**

| Tag                        | Quando                                                                         |
| -------------------------- | ------------------------------------------------------------------------------ |
| `API_TIMEOUT_CANDIDATE`    | Dry-run, regex match (não-bloqueante).                                          |
| `API_TIMEOUT`              | Ativo, regex match + retry (budget ainda disponível).                          |
| `API_BUDGET_EXHAUSTED`     | Ativo, budget `MAX_API_TIMEOUT_RETRIES` esgotado → escalação separada.         |

A detecção roda no caminho `wait_with_timeout` natural-exit do serial loop
(arquivo: `skills/ralph-adversarial/ralph-adversarial.sh`, próximo a
`API_TIMEOUT_DETECTED`). Hang path (kill via timeout do shell) **não**
dispara o detector — esse caso já é coberto por `HANG`/`HANG_RACE_RESCUED`.

## Filtro [CAT3-MANUAL]

ACs prefixados com `[CAT3-MANUAL]` (regex ancorada `^AC<N>(\.[a-z])?:\s*\[CAT3-MANUAL\]`, case-insensitive) são **humano-validated pós-merge** e ficam invisíveis para Claude (implementer) E Codex (reviewer).

- **Ponto único de filtro:** `ralph-adversarial.sh` aplica o filtro jq na linha onde `STORY_BLOCK` é construído (próximo a `select(.id == $id)`). O `STORY_BLOCK` já filtrado alimenta o prompt do implementer; os ACs extraídos via `STORY_ACS_FILTERED` alimentam o prompt do reviewer (substituindo o "consulte prd.json para os ACs" antigo).
- **Convenção e sintaxe formal:** documentadas em `~/.claude/skills/prd/SKILL.md` (seção "ACs [CAT3-MANUAL] — validação manual pós-merge"). Inclui exemplos de prefixo válido vs. menção-no-meio (não filtrada).
- **Test fixture:** `tests/test_cat3_manual_filter.sh` cobre 4 cenários (prefixo, sem marker, menção-no-meio, case-mixed) + integridade (PRD sem markers passa inalterado).
- **Checklist humano:** Cat 3 ACs **não** desaparecem do `prd.json`; o checklist manual pós-merge geralmente vive em `commands/full-cycle.md` ou seção equivalente do projeto.

## Logs estruturados em progress.jsonl

`parse-verdict.sh` expõe `emit_progress_event` — escreve em paralelo em `progress.txt` (humano-legível, pipe-concat compat com formato atual) E em `progress.jsonl` (estruturado, evidences como **array** de strings, não string concatenada).

**Schema** (uma linha JSON por evento):

| Campo       | Tipo                  | Notas                                                        |
| ----------- | --------------------- | ------------------------------------------------------------ |
| `ts`        | string ISO-8601       | `date -Iseconds` (ex: `2026-05-19T21:18:52-03:00`)            |
| `event`     | string                | tag (`REVIEW_BLOCK`, `MERGE`, `ESCALAÇÃO`, `API_TIMEOUT`, …)  |
| `story_id`  | string                | id da user story (ex: `US-03`)                                |
| `evidences` | array<string>         | uma entrada por finding; array vazio quando não há evidence  |
| `verdict`   | string \| null        | string vazia ao chamar vira `null` no JSON                    |

**Uso:**

```bash
# shellcheck source=skills/ralph-adversarial/parse-verdict.sh
source skills/ralph-adversarial/parse-verdict.sh

# Múltiplas evidences: passar string newline-separated (1 evidence por linha).
EVS=$(printf 'finding 1\nfinding 2\nfinding 3')
emit_progress_event "REVIEW_REQUEST_CHANGES" "US-03" "REQUEST_CHANGES" "$EVS"
```

**Exemplo de linha gerada em `progress.jsonl`:**

```json
{"ts":"2026-05-19T21:18:52-03:00","event":"REVIEW_REQUEST_CHANGES","story_id":"US-03","evidences":["finding 1","finding 2","finding 3"],"verdict":"REQUEST_CHANGES"}
```

**Linha correspondente em `progress.txt` (mesma chamada):**

```
2026-05-19T21:18:52-03:00 | REVIEW_REQUEST_CHANGES | US-03 | finding 1|finding 2|finding 3
```

`progress.jsonl` é efêmero (ignorado em `.gitignore` junto com `progress.txt`) — destinado a consumo programático por ferramentas downstream (dashboards, métricas, parsers). Test fixture: `tests/test_progress_jsonl.sh` cobre 1 evidence, 5 evidences, zero evidences, verdict null + validação completa do schema.

## Integração com o sistema ReAct+Feynman
O plano aprovado no full-planning-cycle é a FONTE do prd.json.
O fluxo manual (3 passos) é:
  /full-planning-cycle → plano aprovado
  → /prd-convert → prd.json
  → /ralph-adversarial → implementação com revisão

Alternativa automática (1 passo): /full-cycle executa os três acima em sequência,
parando no gate de aprovação se o plano for REPROVADO.
