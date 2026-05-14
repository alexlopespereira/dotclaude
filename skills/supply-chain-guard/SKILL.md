---
name: supply-chain-guard
description: Hook PreToolUse global em ~/.claude/settings.json (supply-chain-guard.sh) que bloqueia install commands inseguros — pacotes recém-publicados (cooldown 14d), git-url deps, lifecycle scripts (sem --ignore-scripts), e lockfile não-frozen. Use quando precisar entender por que um install foi bloqueado, configurar bypass granular com REASON, rollback do hook, ou diagnosticar interação com workflows dotclaude conhecidos.
---

# Supply-chain Guard — operacional

> **Status (US-01):** stub foundational. O hook (`hooks/supply-chain-guard.sh`) e as libs (`bin/lib/supply-chain/*.sh`) ainda **não** existem — são implementados em US-02..US-05. Este SKILL.md documenta o **contrato** que o usuário/agente verá quando o hook estiver ativo. Princípio 13 em `~/.claude/CLAUDE.md` é a fonte normativa.

## (a) Quando usar esta skill

Invoque mentalmente esta skill quando:

- Um comando de install foi **bloqueado** com mensagem citando "supply-chain-guard" / "cooldown" / "ignore-scripts" / "git-deps" / "lockfile" e você precisa entender qual camada disparou.
- Você precisa **bypass intencional** pra um install legítimo (rebuild de binário nativo, bugfix urgente <14d, dep git interna).
- Você precisa **desabilitar temporariamente** o hook (rollback) porque ele está quebrando um workflow crítico.
- Você está adicionando workflow novo ao dotclaude que envolve install command e quer saber se vai colidir.

## (b) Como o hook decide bloqueio (3 camadas + lockfile)

O hook é invocado em cada `Bash` tool call. Fluxo:

```
INPUT (stdin JSON) -> jq -r .tool_input.command  -> CMD
CMD -> sc_parse_command (US-02) -> JSON {manager, op, pkgs[], flags}
op == "other" -> exit 0 (permite)
op in {install, add, update, run-ephemeral} -> validar 4 camadas:

  Camada 1 (Cooldown 14d):
    - sc_resolve_tree (US-03) chama dry-run apropriado → lista pkg@version (raiz + transitivos)
    - Para cada pkg@version: sc_get_publish_time (US-03) → ISO timestamp (cache hit ou miss)
    - Se (now - publish_time) < 14 dias e CLAUDE_SC_BYPASS_COOLDOWN != 1: marcar problema
    - Skip-list (workspace:*, file:./, link:./, portal:./, catalog:, tarball local, npm:@alias): não checa

  Camada 2 (D1 — git-url deps):
    - Se algum pkg.type == "git-url" e CLAUDE_SC_BYPASS_GIT_DEPS != 1: marcar problema

  Camada 3 (D2 — ignore-scripts mandatório):
    - Se manager in {npm, pnpm, yarn, bun} e op in {install, add, update}
      e "--ignore-scripts" not in flags
      e CLAUDE_SC_BYPASS_SCRIPTS != 1: marcar problema

  Camada 4 (Lockfile forçado):
    - Se manager == "npm" e op == "install" e pkgs == [] (sem args)
      e existe ./package-lock.json
      e "--frozen-lockfile" not in flags
      e CLAUDE_SC_BYPASS_LOCKFILE != 1: marcar problema (sugere "npm ci")

Se ANY problema marcado E ANY bypass usado:
  - CLAUDE_SC_REASON vazio/ausente -> bloqueio dizendo "REASON obrigatório"
  - CLAUDE_SC_REASON presente -> permite + audit log decision:bypass + reason

Se ANY problema marcado E NENHUM bypass:
  - exit 2 com mensagem agregada (todos os problemas + comando corrigido + env vars de bypass)
  - audit log decision:block + motivo

Senão:
  - exit 0 (permite) + audit log decision:allow
```

Decisão é registrada em `~/.claude/cache/supply-chain/audit.jsonl` (uma linha JSON por decisão).

## (c) Variáveis de bypass com exemplos

**Todas exigem `CLAUDE_SC_REASON` não-vazio.** Sem REASON, bypass é bloqueado.

### Bypass cooldown (pacote < 14d)

```bash
CLAUDE_SC_BYPASS_COOLDOWN=1 \
CLAUDE_SC_REASON="security patch CVE-2026-1234 acabou de sair, validado manualmente em GitHub release notes" \
npm install --ignore-scripts express@4.21.3
```

### Bypass git-url deps (D1)

```bash
CLAUDE_SC_BYPASS_GIT_DEPS=1 \
CLAUDE_SC_REASON="fork interno da org github:myorg/internal-lib#main, code reviewed offline" \
npm install --ignore-scripts github:myorg/internal-lib
```

### Bypass ignore-scripts (D2 — rebuild de binário nativo)

```bash
CLAUDE_SC_BYPASS_SCRIPTS=1 \
CLAUDE_SC_REASON="rebuild manual de sharp pra arquitetura local, em diretório de projeto isolado sem tokens populados" \
npm rebuild sharp
```

### Bypass lockfile forçado

```bash
CLAUDE_SC_BYPASS_LOCKFILE=1 \
CLAUDE_SC_REASON="atualizando lockfile intencionalmente após adicionar dep nova revisada" \
npm install
```

### Combinar múltiplos bypasses

Cada env é independente — combine quando legítimo:

```bash
CLAUDE_SC_BYPASS_SCRIPTS=1 \
CLAUDE_SC_BYPASS_LOCKFILE=1 \
CLAUDE_SC_REASON="primeiro install do projeto, rebuild esperado, lockfile ainda não existe" \
npm install
```

**Anti-pattern:** `CLAUDE_SC_REASON="bypass"` — REASON tem que ter conteúdo justificativo, não placeholder. O hook não valida o conteúdo (heurística é frágil), mas audit log captura tudo e revisão periódica via `/supply-chain-audit` detecta abuso.

## (d) Workflows dotclaude conhecidos que podem precisar bypass

Estes slash commands rodam install commands internamente. Documentado pra agente não ficar surpreso quando hook disparar:

### `/checkout-init <repo>` — quando graphify está disponível

Roda `graphify hook install` + `graphify claude install` em cada slot, que internamente pode disparar dependências Python via `uv`. Se hook bloquear:

```bash
CLAUDE_SC_BYPASS_COOLDOWN=1 \
CLAUDE_SC_BYPASS_SCRIPTS=1 \
CLAUDE_SC_REASON="checkout-init bootstrap, graphify upstream confiável instalado via uv tool" \
/checkout-init <repo>
```

### `/graphify-init` — primeira instalação

Pré-requisito documentado em `docs/adr/0001-adopt-graphify-sunset-llm-wiki.md`: `uv tool install graphifyy` — se a versão atual do `graphifyy` no PyPI for <14d, cooldown bloqueia.

```bash
CLAUDE_SC_BYPASS_COOLDOWN=1 \
CLAUDE_SC_REASON="graphifyy upstream release recente, projeto open-source MIT, ADR-0001 docs decision" \
uv tool install graphifyy
```

### `/full-cycle` no meio do Ralph

Se a story implementa feature que requer install (npm add nova lib, pip install nova dep), o hook dispara no meio do loop. Comportamento esperado:

- Comando falha com `exit 2` + stderr da mensagem do hook
- Agente Ralph lê stderr, decide se bypass é justificado pelo PRD
- Se sim: reemite com bypass + REASON citando US-XX do PRD
- Se não: PRD provavelmente lista pacote inseguro, escalonar pro humano

## (e) Limites conhecidos

O hook **não enxerga** dentro destes padrões — comando passa sem validação:

- **Subshells:** `bash -c "npm install foo"`, `sh -c "..."`, `zsh -c "..."`
- **Eval/exec dinâmico:** `eval $(echo "npm install foo")`, `eval "$CMD"`
- **Background com wrapper:** `(npm install) &`, `nohup npm install &`
- **Heredoc / arquivo intermediário:** `cat > install.sh <<EOF\nnpm install foo\nEOF; bash install.sh`
- **Comandos via Makefile / package.json scripts:** `make install`, `npm run prepare` (que internamente roda `npm install`)
- **SSH / remote exec:** `ssh server "npm install"` — fora do escopo (máquina remota tem seu próprio dotclaude ou não)

**Política:** Princípio 13 instrui Claude a **não** usar wrappers/subshells pra contornar o gate. Se um comando legítimo está sendo bloqueado por falso positivo, o caminho correto é bypass granular com REASON, **não** subshell.

Outros limites:

- **Private registries com auth (`~/.npmrc` com token):** `npm view` herda o auth. Se token expirou, hook retorna NETWORK_ERROR e fail-closes. Workflow: renovar token antes de install.
- **Gerenciadores fora de cobertura inicial:** Cargo, Gem, Go modules, brew formula install, `docker pull`, `apt install`. Estes não são interceptados — risco aceito por escopo.
- **Mudança de manifesto local sem install command:** alguém edita `package.json` à mão e roda `node` — o hook não vê. Próxima vez que `npm install` rodar, valida na hora.

## (f) Como rollback do hook

O hook é registrado em `~/.claude/settings.json` no array `PreToolUse[matcher=Bash].hooks`. Remoção:

### Rollback temporário (1 sessão)

Editar `~/.claude/settings.json` e remover o item do array que aponta pra `supply-chain-guard.sh`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/block-dangerous-git.sh" }
          // remover este item:
          // { "type": "command", "command": "~/.claude/hooks/supply-chain-guard.sh" }
        ]
      }
    ]
  }
}
```

Recarregar Claude Code (CMD+R no app, ou reiniciar sessão CLI).

### Rollback permanente

Mesma edição acima + opcionalmente deletar `~/.claude/hooks/supply-chain-guard.sh`. O backup feito em US-05 (`settings.json.bak.<timestamp>`) permite rollback rápido se preciso (`cp settings.json.bak.<ts> settings.json`).

### Verificar que hook está desativado

```bash
echo '{"tool_input":{"command":"npm install some-very-new-package"}}' | bash ~/.claude/hooks/supply-chain-guard.sh
echo $?  # se 0, foi removido do PATH/registry; se 2, hook ainda roda mas via PATH direto (não via settings.json)
```

O sinal real é: rodar `npm install <pkg-novo>` via Bash tool no Claude — se passa sem bloqueio, está desativado.

## (g) Audit log e revisão periódica

Cada decisão vai pra `~/.claude/cache/supply-chain/audit.jsonl`. Use `/supply-chain-audit` (US-06) pra ver:

- Total de decisões últimos 7 dias
- Breakdown por decision (allow/block/bypass)
- Lista de bypasses com timestamp + comando + REASON
- Contagem de arquivos em `registry-times/` (proxy de cache hit rate)

Revisão recomendada: 1x por semana. Procure padrões de bypass com REASON genérico ("bypass", "ok", "test") — indica abuso e merece refinar política.

## Referências

- **Princípio 13** em `~/.claude/CLAUDE.md` (fonte normativa)
- **ADR-0002** em `docs/adr/0002-supply-chain-cooldown-gate.md` (trade-offs e alternativas rejeitadas)
- **Plano original:** `.claude/plans/supply-chain-cooldown-gate.md`
- **Padrão de hook:** `hooks/block-dangerous-git.sh` (estilo bash já estabelecido)
- **PRD:** `prd.json` (user stories US-01..US-07)
