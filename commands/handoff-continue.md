---
description: Destila contexto da sessão atual em handoff doc + cria ponteiro pending + lazy-installa hook SessionStart. Trigger phrases — "handoff-continue", "continuar com contexto limpo", "retomar pós-clear". Imprime handoff completo no chat e pede ao usuário rodar /clear manualmente. NÃO invoca /clear.
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

Destila o estado atual da sessão em um handoff doc estruturado, cria ponteiro `.claude/handoff-pending`, e garante que o hook `SessionStart → handoff-resume.sh` está registrado em `~/.claude/settings.json`. Após o comando, o usuário roda `/clear` manualmente — o hook re-injeta o handoff como `additionalContext` na nova sessão fresca.

**Restrição:** `/clear` é built-in do harness Claude Code. O agente **não tem tool** para dispará-lo. Este comando prepara o terreno — o usuário fecha o ciclo.

## Passos

### 0. Garantir diretórios necessários

Em cwd "limpo" (sem `.claude/plans/`), o Write do handoff e o `printf > .claude/handoff-pending` falham. Criar diretório de antemão é mandatório:

```bash
mkdir -p .claude/plans
```

`mkdir -p` é idempotente — não falha se já existe.

### 1. Destilar contexto em handoff doc

Componha um arquivo Markdown destilando o estado da sessão atual. Use o contexto pré-computado acima + memória da sessão (decisões, arquivos tocados, próximos passos).

**Caminho:** `.claude/plans/<TS>-handoff.md` onde `<TS>` é o `timestamp UTC` pré-computado acima.

**Seções obrigatórias (todas devem aparecer):**

- **Objetivo** — 1-2 frases sobre o que esta sessão está tentando alcançar. Se `$ARGUMENTS` veio preenchido, use como ênfase.
- **Estado / progresso até agora** — bullets do que foi feito (arquivos editados, decisões fechadas, achados). Cite paths reais quando aplicável.
- **Próximo passo concreto** — UMA ação acionável (não "investigar X" — algo como "implementar `foo()` em `src/foo.ts` cobrindo AC3"). Se a sessão está concluída, escreva `Próximo passo: nenhum — trabalho DONE.`
- **Arquivos relevantes** — lista de paths críticos para a retomada (ler primeiro). Marque com 📌 se for ponto de partida obrigatório.
- **Decisões fechadas** — bullets de o-que-foi-decidido e por-quê (rationale curto). Inclui trade-offs já avaliados que NÃO devem ser re-discutidos.
- **Status** — `WIP` (trabalho em andamento) **ou** `DONE` (concluído; comando ainda pode ser usado pra documentar fim).

Escreva o arquivo via Write tool. Conteúdo deve ser destilação (não cópia da sessão).

### 2. Criar ponteiro `.claude/handoff-pending`

Resolva o caminho absoluto do handoff doc e escreva uma única linha sem trailing whitespace em `.claude/handoff-pending`. Padrão:

```bash
ABS_HANDOFF="$(realpath .claude/plans/<TS>-handoff.md)"
printf '%s\n' "$ABS_HANDOFF" > .claude/handoff-pending
```

Validação obrigatória: `test -f .claude/handoff-pending && wc -l < .claude/handoff-pending` deve retornar **1** (uma única linha terminada por newline — sem espaços/tabs no fim do path, sem linhas extras).

### 3. Lazy-install do hook em `~/.claude/settings.json`

Verifique se o hook já está registrado:

```bash
HOOK_REGISTERED=$(jq -e '
  .hooks.SessionStart // []
  | map(.hooks // [])
  | flatten
  | map(select(.command? // "" | endswith("handoff-resume.sh")))
  | length > 0
' ~/.claude/settings.json 2>/dev/null && echo yes || echo no)
```

Se `HOOK_REGISTERED=no`, adicione via `jq` com lock e atomic write:

```bash
LOCKDIR=~/.claude/settings.lock
TMPFILE=$(mktemp ~/.claude/settings.json.XXXXXX)
trap 'rmdir "$LOCKDIR" 2>/dev/null; rm -f "$TMPFILE"' EXIT

# Lock via mkdir (macOS não tem flock; mkdir é atômico nos FS POSIX).
# Flag explícita: test -d $LOCKDIR só prova "alguém criou", não "fomos nós".
# Se outro processo possui o lock o dir existe e o teste passaria errado.
GOT_LOCK=0
for i in 1 2 3 4 5; do
  if mkdir "$LOCKDIR" 2>/dev/null; then
    GOT_LOCK=1
    break
  fi
  sleep 0.5
done
test "$GOT_LOCK" = 1 || { echo "ERRO: não consegui lock de settings.json após 5 tentativas (outro processo segura $LOCKDIR) — abortando install do hook"; exit 1; }

# Preserva todos os hooks existentes; adiciona entry SessionStart (cria array se ausente)
# Falha do jq NÃO pode resultar em $TMPFILE vazio sobrescrevendo settings.json — checar exit.
jq '
  .hooks //= {} |
  .hooks.SessionStart //= [] |
  .hooks.SessionStart += [{
    "matcher": "",
    "hooks": [{
      "type": "command",
      "command": "/Users/dev/.claude/hooks/handoff-resume.sh",
      "timeout": 5000
    }]
  }]
' ~/.claude/settings.json > "$TMPFILE" || {
  rm -f "$TMPFILE"
  rmdir "$LOCKDIR"
  echo "ERRO: jq falhou ao montar settings.json — settings.json original intocado; abortando install."
  exit 1
}

# Validação dupla: tmp não-vazio e JSON parseável (jq -e .) antes do swap.
test -s "$TMPFILE" && jq -e . "$TMPFILE" >/dev/null 2>&1 || {
  rm -f "$TMPFILE"
  rmdir "$LOCKDIR"
  echo "ERRO: tmpfile vazio ou JSON inválido pós-jq — settings.json intocado; abortando install."
  exit 1
}

# Atomic swap
mv "$TMPFILE" ~/.claude/settings.json
rmdir "$LOCKDIR"
trap - EXIT
```

Anuncie no chat se acabou de instalar ("Hook SessionStart → handoff-resume.sh adicionado a ~/.claude/settings.json") ou se já estava lá ("Hook já registrado — nada a fazer em settings.json").

**Importante:** o script `handoff-resume.sh` em si é criado pela US-02 deste mesmo ciclo. Este comando assume que existirá em `/Users/dev/.claude/hooks/handoff-resume.sh` no momento da invocação real. Se ainda não existir, anuncie warning no chat ("⚠️ Hook script não existe ainda em ~/.claude/hooks/handoff-resume.sh — registro feito, mas /clear será no-op até o script estar instalado.") mas **não aborte** — registro em settings.json é idempotente.

### 4. Imprimir handoff completo + instrução literal

Após escrever o handoff doc, imprima o conteúdo completo no chat (preview — usuário valida antes de `/clear`). Formato:

```
--- HANDOFF DOC (preview) ---
<conteúdo integral do .claude/plans/<TS>-handoff.md>
--- FIM DO HANDOFF ---

Ponteiro criado: .claude/handoff-pending → <ABS_HANDOFF>
Hook SessionStart: <registrado | já existia>

Para retomar com contexto limpo, rode /clear agora.
```

A frase **literal** "Para retomar com contexto limpo, rode /clear agora." deve aparecer no output (caractere por caractere) — é gatilho visual pro usuário.

### 5. Anunciar caveat `--resume`

Imprima também:

```
⚠️ O hook dispara em /clear ou nova sessão. claude --resume NÃO dispara — use /clear.
```

Esta linha é obrigatória (achado adversário #4 do plano de origem).

### 6. NÃO invocar /clear

Sob nenhuma circunstância chame Bash com `/clear` ou similar. `/clear` é built-in do harness — só o usuário pode disparar manualmente após ler o preview. Não há tool disponível para o agente.

## Notas operacionais

- **Race condition:** invocação dupla no mesmo cwd sobrescreve `.claude/handoff-pending` (último-gana — aceito; usuário não invoca 2× sem motivo).
- **Cwd diferente para /clear:** o hook lê `$CWD/.claude/handoff-pending` — `/clear` precisa rodar no mesmo cwd do `/handoff-continue`. Se mudar de repo entre comando e `/clear`, hook sai inerte (correto, mas usuário pode estranhar).
- **Cap 10KB:** o hook (US-02) emite warning em stderr se o handoff > 10240 bytes, sem abortar. Mantém destilações concisas.
- **GC de `.consumed`:** o hook move `.claude/handoff-pending` → `.claude/handoff-pending.consumed.<timestamp>` pós-injeção. Acumula no diretório; limpeza manual quando necessário.
