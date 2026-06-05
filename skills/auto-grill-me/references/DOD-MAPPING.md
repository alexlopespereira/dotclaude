# DoD-Mapping — referência compartilhada das skills de planejamento

> Reusada por `auto-grill-me`, `/plan` (react-feynman), `grill-me`, `grill-with-docs`
> e `/test-spec`. Define **como ligar um artefato do plano ao seu DoD** e **como
> emitir o marcador de telemetria**. Fonte de dados: [`DOD.md`](DOD.md) (índice de
> mapping Categoria/Tarefa + bullets verbatim).

## Por que existe

A telemetria de uso de DoD/test-spec era **prompt-driven** — a skill mandava o LLM
rodar `log_event` no meio da sessão. Empiricamente nunca disparou (0 eventos reais
em 11–15 dias). A correção tornou a emissão **determinística**: o Stop hook
[`hooks/dod-usage-log.sh`](../../../hooks/dod-usage-log.sh) parseia o **plano
persistido** e emite os eventos. A skill **não chama mais `log_event`** — só
**insere um marcador** por inserção de DoD. Enquanto o plano for escrito (output
primário da skill), a telemetria sai sozinha.

## Contrato com o hook (regra de ouro)

- A skill **NÃO** invoca `log_event`, `dod-reset-rev.sh`, nem edita contador inline.
- A skill insere **1 marcador por inserção de DoD** no plano (ou no destino do test-spec).
- O hook computa o sha atual e emite o evento `use` ao fim do turno (Stop). É
  idempotente (não re-emite o que já viu, mesmo se o plano for editado/appendado).

## Marcador canônico (machine-readable)

ASCII puro, invisível no render do markdown, **uma linha por inserção**, colocado
**imediatamente após** o bloco de DoD (ou de specs) inserido:

```
<!-- dod-use: <dod_id> -->          ← uso de DoD        (prefix dod)
<!-- test-spec-use: <dod_id> -->    ← uso de test-spec  (prefix test-spec)
```

- `<dod_id>` é o token **literal** `tarefa-N` ou `cat-N-base` — o mesmo usado por
  `log_event`/`dod_bullets_sha`. Charset: `^[A-Za-z0-9._-]+$`. **Sem** transformação.
- Exatamente 1 espaço de cada lado dos dois-pontos e dentro de `<!-- -->`.
- A tag visível human-facing `` `[Cat N · Tarefa M — Desc]` `` **permanece** (para
  leitura); o marcador é **adicional e adjacente**, não a substitui.

### Exemplo (na seção "## Artefatos a produzir")

```markdown
### A1 — Hook de telemetria `[Cat 1 · Tarefa 8 — Hook Stop]`

**DoD-base — Categoria 1**
- [ ] [b1] arquivo vive em ~/.claude/ ou .claude/ — escopo documentado no commit
- [ ] ...
<!-- dod-use: cat-1-base -->

**Tarefa 8 — Hook PreToolUse / Stop**
- [ ] [b1] script tem shebang explícito e é chmod +x
- [ ] ...
<!-- dod-use: tarefa-8 -->
```

## Regras de inserção

1. **Mapear:** ao descobrir um artefato, use o índice de mapping em [`DOD.md`](DOD.md)
   (trigger phrases → Categoria/Tarefa). Em ambiguidade, pergunte ao usuário.
2. **Copiar verbatim:** copie o `DoD-base` da categoria + a `Tarefa N` específica
   **bullet-por-bullet** (não parafraseie) para "## Artefatos a produzir".
3. **Marcar:** após cada bloco, emita o marcador correspondente.
4. **Dedupe DoD-base:** `cat-N-base` aparece **1× por categoria por plano** → o
   marcador `<!-- dod-use: cat-N-base -->` também aparece no máximo 1× por plano.
   `tarefa-N` é por inserção (multiplicidade preservada).
5. **Append-only:** `dod_id` deriva do heading do `DOD.md` — **nunca renumerar**
   Tarefas/Categorias (quebra a chave do log). Renomear o título é seguro.

## Persistência do plano

O hook só conta o que está **persistido** em `<projeto>/.claude/plans/<ISO>-<slug>.md`.
Skills que hoje não persistem (grill-me, grill-with-docs) só precisam persistir
**quando emerge um artefato** mapeável — entrevista exploratória sem artefato
continua efêmera (sem arquivo, sem marcador).

## test-spec (2 ramos)

- **Ramo plano** (`/test-spec <plano>`): o marcador `<!-- test-spec-use: id -->` vai
  na seção `## Test Specs` do plano (coberto pela varredura de `.claude/plans/`).
- **Ramo single-DoD** (materializa em `TEST-PATTERNS.md`): o marcador vai em
  `skills/testing/references/TEST-PATTERNS.md` (o hook também varre esse arquivo).
