---
description: Destila contexto da sessão atual em handoff doc + cria ponteiro pending + verifica hook SessionStart. Trigger phrases — "handoff-continue", "continuar com contexto limpo", "retomar pós-clear". Imprime handoff completo no chat e pede ao usuário rodar /clear manualmente. NÃO invoca /clear. Após o /clear o handoff entra como contexto SILENCIOSO (invisível) e NÃO inicia o trabalho sozinho — digite "continuar" pra retomar.
argument-hint: [foco opcional do handoff]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(pwd), Bash(date:*), Bash(git status:*), Bash(git log:*), Bash(git diff:*), Bash(git rev-parse:*), Bash(gh pr view:*), Bash(jq:*), Bash(test:*), Bash(cat:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(rmdir:*), Bash(wc:*), Bash(ls:*), Bash(echo:*), Bash(printf:*), Bash(chmod:*), Bash(realpath:*), Bash(readlink:*)
---

# /handoff-continue — destila e prepara retomada pós-/clear

Foco opcional: $ARGUMENTS

## Contexto pré-computado (inline bash — evita round-trip do modelo)

- cwd: !`pwd`
- git status: !`git status --short`
- git log (últimos 5): !`git log --oneline -5`
- timestamp UTC: !`date -u +%Y-%m-%dT%H-%M`

## O que este comando faz

Destila o estado da sessão em um handoff doc, cria ponteiro `.claude/handoff-pending` e verifica que o hook `SessionStart → handoff-resume.sh` está registrado. Após o comando, o usuário roda `/clear` manualmente — o hook re-injeta o handoff como `additionalContext` na sessão fresca. **Restrição:** `/clear` é built-in do harness; o agente **não tem tool** para dispará-lo.

## Passos

### 0. Garantir diretórios

`mkdir -p .claude/plans` (idempotente; em cwd sem `.claude/plans/` o Write do handoff e o ponteiro falham).

### 1. Destilar contexto em handoff doc

Escreva (Write) `.claude/plans/<TS>-handoff.md` (`<TS>` = timestamp pré-computado). Destilação, não cópia da sessão. **Seções obrigatórias (todas):**

- **Objetivo** — 1-2 frases; se `$ARGUMENTS` veio, use como ênfase.
- **Estado / progresso até agora** — bullets do feito (arquivos, decisões, achados; paths reais).
- **Próximo passo concreto** — UMA ação acionável (não "investigar X"; algo como "implementar `foo()` em `src/foo.ts` cobrindo AC3"). Sessão concluída → `Próximo passo: nenhum — trabalho DONE.`
- **Arquivos relevantes** — paths críticos para a retomada; 📌 = ponto de partida obrigatório.
- **Decisões fechadas** — o-que-foi-decidido + rationale curto; trade-offs que NÃO devem ser re-discutidos.
- **Status** — `WIP` ou `DONE`.

### 2. Criar ponteiro `.claude/handoff-pending`

```bash
ABS_HANDOFF="$(realpath .claude/plans/<TS>-handoff.md)"
printf '%s\n' "$ABS_HANDOFF" > .claude/handoff-pending
```

Validação obrigatória: `test -f .claude/handoff-pending && wc -l < .claude/handoff-pending` retorna **1** (uma linha com newline, sem whitespace no fim, sem linhas extras).

### 3. Verificar hook em `~/.claude/settings.json`

```bash
jq -e '.hooks.SessionStart // [] | map(.hooks // []) | flatten
       | map(select(.command? // "" | endswith("handoff-resume.sh"))) | length > 0' \
  ~/.claude/settings.json >/dev/null 2>&1 && echo registrado || echo ausente
```

- `registrado` → anuncie "Hook já registrado — nada a fazer em settings.json".
- `ausente` → anuncie "⚠️ Hook handoff-resume.sh não registrado — sem ele o /clear NÃO re-injeta o handoff." e registre-o via skill `update-config` (entry `SessionStart` → command `/Users/dev/.claude/hooks/handoff-resume.sh`, timeout 5000). O doc + ponteiro já estão em disco; registre o hook ANTES de o usuário rodar `/clear`. Se o script `~/.claude/hooks/handoff-resume.sh` não existir, avise que o registro será no-op até `./sync.sh install` do dotclaude instalá-lo — não aborte.

### 4. Imprimir handoff completo + instruções literais

Imprima o conteúdo integral do doc entre `--- HANDOFF DOC (preview) ---` e `--- FIM DO HANDOFF ---`, seguido de:

```
Ponteiro criado: .claude/handoff-pending → <ABS_HANDOFF>
Hook SessionStart: <registrado | já existia>

Para retomar com contexto limpo, rode /clear agora.
Depois do /clear, digite "continuar" — a sessão NÃO inicia sozinha.
```

A frase **literal** "Para retomar com contexto limpo, rode /clear agora." deve aparecer caractere por caractere — é gatilho visual pro usuário. Logo abaixo, imprima também (**obrigatório** — corrige a expectativa de "resume automático"):

```
ℹ️ Após o /clear, a sessão abre EM BRANCO — o handoff foi carregado como contexto
   SILENCIOSO (system reminder; você não vê nada na tela). Para retomar, digite
   "continuar" (ou qualquer mensagem) — só então o Claude lê o handoff e segue do
   "Próximo passo". O /clear NÃO inicia o trabalho automaticamente; nenhum hook do
   Claude Code dispara um turno do assistente sozinho.
```

```
⚠️ O hook dispara em /clear ou nova sessão. claude --resume NÃO dispara — use /clear.
   O hook apenas INJETA o handoff como contexto silencioso; ele não inicia o trabalho.
```

(A linha do `--resume` é obrigatória — achado adversário #4 do plano de origem.)

### 5. NÃO invocar /clear

Sob nenhuma circunstância chame Bash com `/clear` ou similar — só o usuário dispara, após ler o preview.

## Notas operacionais

- **Race condition:** invocação dupla no mesmo cwd sobrescreve `.claude/handoff-pending` (último-ganha — aceito).
- **Cwd diferente:** o hook lê `$CWD/.claude/handoff-pending` — o `/clear` precisa rodar no mesmo cwd do `/handoff-continue`; em cwd diferente o hook sai inerte.
- **Cap 10KB:** o hook emite warning em stderr se o handoff > 10240 bytes, sem abortar. Mantém destilações concisas.
- **GC de `.consumed`:** o hook move o ponteiro para `.claude/handoff-pending.consumed.<timestamp>` pós-injeção; limpeza manual quando necessário.
