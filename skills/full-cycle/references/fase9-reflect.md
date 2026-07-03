# Fase 9 — Reflexão sobre DoD: heurística de modo + verificação

> Reference do `/full-cycle` e `/full-cycle-simple`. A invocação
> (`claude -p "/reflect ..."` em background) vive no corpo do comando — aqui
> ficam a heurística de modo (só `/full-cycle`) e os checklists de verificação.

## Gate heurístico `--learn` vs `--baseline` (só /full-cycle)

O modo é decidido por gate heurístico inline (AC9 do US-02): `--learn` quando o
ciclo correu **anômalo** (precisa LLM analisar a TDD-chain por US), `--baseline`
quando correu **limpo** (compliance retroativa basta). O `/full-cycle-simple`
não usa esta heurística — vai direto de `--baseline --quick`.

```bash
# Gate heurístico: NEED_LEARN se QUALQUER destes for verdadeiro
NEED_LEARN=false

# (a) prd.json tem alguma US escalada
if test -f prd.json && jq -e '.userStories[]? | select(.passes=="ESCALATED")' prd.json >/dev/null 2>&1; then
  NEED_LEARN=true
fi

# (b) progress.txt registrou ≥2 REVIEW_BLOCK ou REVIEW_REQUEST_CHANGES.
# Gotcha: `grep -c` exit 1 em zero matches imprime "0" no stdout — combinar
# com `|| echo 0` produz "0\n0" e quebra `[ -ge ]` ("integer expression
# expected"). Padrão correto: `VAR=$(...) || VAR=0` (fallback substitui,
# não concatena).
if test -f progress.txt; then
  REVIEW_COUNT=$(grep -cE 'REVIEW_BLOCK|REVIEW_REQUEST_CHANGES' progress.txt 2>/dev/null) || REVIEW_COUNT=0
  if [ "$REVIEW_COUNT" -ge 2 ]; then NEED_LEARN=true; fi
fi

# (c) auto-fix loop disparou (marcador AUTOFIX_TRIGGERED em progress.txt)
if test -f progress.txt && grep -q 'AUTOFIX_TRIGGERED' progress.txt 2>/dev/null; then
  NEED_LEARN=true
fi

REFLECT_MODE=$([ "$NEED_LEARN" = "true" ] && echo --learn || echo --baseline)
```

Ao invocar (corpo do comando), exporte também:
`REFLECT_NESTED=1 REFLECT_LEARN_GATE=$([ "$NEED_LEARN" = "true" ] && echo 1 || echo 0)`.

## Notas de invocação (ambos os comandos)

- O subprocess é um processo `claude` novo: usa o **modelo padrão configurado**
  do Claude Code (settings/`/model`), não herda o modelo volátil da sessão pai
  (pattern slash-command-via-claude-p já em produção em
  `bin/reflect-retro-due.sh`). Para pinar um modelo, acrescente `--model <id>`
  manualmente — os comandos NÃO pinam por default.
- `--quick` (só `/full-cycle-simple`) reduz a comparação à categoria detectada +
  pula fetch de PR comments — custo de tokens reduzido, espírito enxuto.
- A falha do subprocess (PR não correlaciona com plano, `gh` offline, sessão
  `/auto-grill-me` ausente, modelo indisponível) **NÃO interrompe o pipeline** —
  reflexão é auditoria, não gate; o exit code do background job nem é colhido.
  O pipeline já considerou a Fase 8 (sync) como término efetivo da entrega.

## Verificação (humano pós-merge — Cat 3 explícito)

**Classificação:** AC8/AC9 (US-02, `/full-cycle`) e AC5 (US-03,
`/full-cycle-simple`) são **Cat 3 (humano-validated post-merge)** por limite
físico do Ralph adversarial — slash command recursivo dentro do worker é
inviável (loop infinito `/full-cycle` → `/reflect` → `/full-cycle`...).
Convenção geral: qualquer AC prefixado `[CAT3-MANUAL]` em qualquer PRD é
filtrado pelo Ralph antes do prompt; validação por checklist humano pós-merge.
Sintaxe formal em `skills/prd/SKILL.md`.

### Checklist /full-cycle (rode UMA vez após merge do próximo PR)

- [ ] **AC8 — Baseline gravado.** Inspecione
  `.claude/reflections/<ts>-<slug>-baseline.md` no cwd (ou
  `~/.claude/cache/reflect/<repo>/<ts>-<slug>-baseline.md` em fallback).
  Deve conter: `Plan match: <marker|slug-exact|fuzzy|none>`,
  `Session correlated: <true|false>`, seção `CI checks` com ≥1 check (ou
  `ci_checks: nenhum`), e `Aviso retrospectiva` com data D+7 ≈ correta.
- [ ] **AC8b — Reminder agendado.** `tail -1 ~/.claude/cache/reflect/reminders.jsonl`
  mostra entrada com `pr` da PR mergeada, `repo` correto e `retro_due_at`
  ISO-8601 ≈ D+7.
- [ ] **AC9 — Sugestão `/reflect --on-failure N` em Fases 3/5/6.** Trigger UMA
  parada deliberada (erro no plano → REPROVADO; P0 simulado no review; teste
  falhando 3×).
- [ ] **AC9b — Output contém markdown explícito.** `/full-cycle` imprime
  `**Antes de escalar para humano:** sugira /reflect --on-failure <N> ...` no
  momento da parada — no output da sessão, não só no arquivo.

### Checklist /full-cycle-simple (rode UMA vez após merge do próximo PR)

- [ ] **AC5a — Baseline `--quick` gravado.** Relatório contém `Quick mode: true`
  no front-matter e `Camada #6 (PR comments): pulada (--quick)`.
- [ ] **AC5b — Reminder agendado.** Mesma evidência do AC8b.
- [ ] **AC5c — Sugestão `--quick` em paradas Fase 5/6.** Output contém
  `sugira /reflect --on-failure <N> --quick ...` — note o `--quick` explícito.

**Nota sobre divergência semântica da AC1 (vs prd.json original do US-03):** o
prd definia `--quick` como "subset do --baseline; só camadas 1 e 2", mas
`--baseline` não roda algoritmo D1 (camadas — exclusivas do `--retro`). A
definição implementada em `commands/reflect.md` é coerente: `--quick` com
`--baseline` reduz comparação à categoria detectada + pula PR comments; com
`--on-failure` reduz cross-ref à categoria da fase parada; com `--retro` é
rejeitado. Divergência nominal — semântica preserva a intenção (modo enxuto
barato).

### Smoke test parcial (histórico — Cat 1, executado na implementação)

A resolução do `PR_NUMBER` foi validada:
`gh pr list --state merged --limit 1 --base main --json number --jq '.[0].number'`
→ retornou número válido; cobre (a) `gh` autenticado, (b) filtro correto,
(c) jq não erra em json vazio.
