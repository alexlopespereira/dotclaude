# ADR 0002 — Supply-chain Cooldown Gate

## Status

Accepted — 2026-05-13

## Context

Em 2026 a comunidade JS sofreu uma escalada de ataques tipo **Mini Shai-Hulud** (TanStack, Mistral, UiPath compromise — **169 pacotes / 373 versões maliciosas**) que executam payload em `preinstall`/`prepare` lifecycle hooks durante `npm install`. O vetor primário rouba GitHub tokens, npm tokens, AWS creds e env vars assim que qualquer install dispara em uma máquina com tokens populados — incluindo máquinas de devs, CIs efêmeros e qualquer ambiente onde um agente como Claude rode comandos de install.

A vítima **nunca instala o pacote malicioso diretamente**. Os ataques exploram dois vetores transitivos:

1. **Cooldown miss em registry:** o atacante toma conta de um pacote popular (account takeover, NPM/PyPI), publica uma versão maliciosa nova. Quem rodar `npm install` num projeto que tem range semver dependente dessa lib via 3 camadas de dependência (raiz → A → B → libsequestrada) puxa a versão envenenada — antes que ferramentas de detecção pública (Socket, Aikido, GitHub Advisory) consigam classificar.
2. **Git-URL dep opcional:** atacante publica dep opcional `github:tanstack/router#<sha-malicioso>` num pacote legítimo. Não tem versão de registry, então cooldown não vê. Lifecycle hook do clone executa o payload assim que `npm install` resolve a dep opcional.

Como `dotclaude` é o **policy hub** que orienta Claude em toda a frota de projetos, este é o lugar arquitetural correto pra interceptar o vetor — Claude executa install commands em ~99% dos cenários reais via `Bash` tool, e um hook `PreToolUse` global vê todos eles antes da execução.

Pré-requisitos arquiteturais existentes (não introduzidos por esta decisão):

- Hooks `PreToolUse` globais em `~/.claude/settings.json` com matcher `Bash` (mesmo padrão de `block-dangerous-git.sh`, `block-browser-mutations.sh`).
- Hook `exit 2 + stderr` é mecanismo canônico de bloqueio reconhecido pelo Claude Code.
- Cache local em `~/.claude/cache/` já é convenção.

## Decision

Implementar defesa **fail-closed** em camadas:

### 1. Cooldown de **14 dias** desde publish (raiz + transitivos)

Qualquer pacote (raiz **ou** transitivo) cuja versão resolvida foi publicada há menos de **14 dias** é bloqueado. Validação cobre **árvore inteira resolvida** via `--dry-run` do gerenciador (`npm install --dry-run --json`, `pip install --dry-run --report -`, `uv pip install --dry-run`).

### 2. Hard-block, não advisory

Comando bloqueado sai com `exit 2` e stderr explicativo. Sem soft-launch / N dias em modo advisory.

### 3. Bypass **granular** com REASON obrigatório

4 envs distintas que liberam camadas individuais:

- `CLAUDE_SC_BYPASS_COOLDOWN=1` — libera idade < 14d
- `CLAUDE_SC_BYPASS_GIT_DEPS=1` — libera git-url deps (D1)
- `CLAUDE_SC_BYPASS_SCRIPTS=1` — libera `--ignore-scripts` ausente (D2)
- `CLAUDE_SC_BYPASS_LOCKFILE=1` — libera `npm install` sem args sem `--frozen-lockfile`

Todas exigem `CLAUDE_SC_REASON="..."` não-vazio. Bypass sem REASON = bloqueio.

### 4. `--ignore-scripts` mandatório (D2)

Comandos `npm/pnpm/yarn/bun install/add/update` sem `--ignore-scripts` são bloqueados com sugestão de comando corrigido. Mata o **mecanismo de execução** do payload. Custo aceito: rebuild manual de binários nativos via `npm rebuild <pkg>`.

### 5. Bloqueio de git-url deps explícitas e em manifest (D1)

Specs como `github:user/repo`, `github:user/repo#sha`, `git+https://...`, `user/repo` shorthand → bloqueio.

### 6. Forçar `--frozen-lockfile` em projeto com lockfile

`npm install` (sem args) em projeto com `package-lock.json` sem `--frozen-lockfile`/`npm ci` → bloqueio com sugestão.

### 7. Skip-list de tipos não-registry

`workspace:*`, `workspace:^`, `workspace:1.0.0`, `file:./`, `link:./`, `portal:./`, `catalog:`, tarballs locais (`./pkg-1.tgz`), alias `npm:@scope/pkg@1.0.0` → passa sem checar cooldown (não vêm de registries públicos, fail-closed quebraria onboarding de monorepos legítimos).

### 8. Audit log JSONL persistente

Cada decisão (allow/block/bypass) é registrada em `~/.claude/cache/supply-chain/audit.jsonl` com timestamp, cwd, command, decision, reason. Rotação simples a >10MB (5 históricos).

### 9. Cache de timestamps com TTL infinito

Timestamp de publish é **imutável** no registry. Cache em `~/.claude/cache/supply-chain/registry-times/<registry>/<pkg>/<v>.iso` pode viver pra sempre. Primeira validação ~5-15s; subsequentes <1s. Escrita atômica via `mv tmp.$$ final` (POSIX atomic rename, evita race condition entre hook invocations paralelos).

### 10. Cobertura inicial: Node + Python

- **Node:** npm, pnpm, yarn, bun
- **Python:** pip, pipx, uv (`uv pip install`, `uv tool install`)
- **Ephemeral:** npx, uvx, bunx, `pipx run`, `uv tool run`, `pnpm dlx`, `yarn dlx`

Cargo, Gem, Go: backlog (não-uso ativo do usuário). Brew: explicitamente **fora** do escopo (curado, baixo risco, alto uso).

## Trade-offs aceitos

- **Rebuild manual de binários nativos.** `--ignore-scripts` mandatório significa que `sharp`, `puppeteer`, `prisma`, `bcrypt` exigem `npm rebuild <pkg>` supervisionado após instalação. Aceitamos o atrito porque o ganho é eliminar o mecanismo de execução do payload.
- **Atraso de 14 dias em bugfixes legítimos.** Patches de segurança em pacotes legítimos têm que esperar 14 dias ou usar bypass com REASON. Aceitável porque a janela de detecção pública é <7d na maioria dos ataques históricos.
- **Performance da primeira validação de árvore grande.** Projeto com 500 transitivos pode levar 10-30s na primeira validação (cache miss). Subsequentes <100ms (cache hit). Aceitamos porque é one-shot por (registry, pkg, version).
- **Comandos com wrapper/subshell escapam do gate.** `bash -c "npm install ..."`, `eval $(...)` não são parseados. Documentado como limite conhecido na skill. Princípio 13 instrui Claude a **não** usar wrappers pra contornar.
- **Falso positivo em fail-closed.** Network down / registry 5xx / timeout → bloqueio (não permite). Trade-off explícito: "não sei" é o caminho que o atacante procura. Bypass granular + REASON dá escape válido.

## Alternativas consideradas e rejeitadas

### (A) Cooldown de 7 dias

Mais permissivo. Rejeitado: 4 dos ataques Shai-Hulud foram detectados publicamente entre dia 5 e 8 após publish; 7d ficaria no limite. 14d dá margem real.

### (B) Cooldown de 30 dias

Sugestão original. Rejeitado: atrasa bugfixes legítimos em 1 mês inteiro, dor real pra deps que recebem patches frequentes (TanStack, Prisma, Stripe SDK). 14d é o sweet spot.

### (C) Validar apenas raiz + filhos diretos

Mais rápido (não precisa dry-run). Rejeitado: o vetor canônico Shai-Hulud é **transitivo profundo** (raiz → A → B → libsequestrada). Validar só raiz deixa o vetor aberto.

### (D) Bypass monolítico (`CLAUDE_SC_BYPASS=1`)

Mais simples de usar. Rejeitado: defesa em profundidade exige bypass cirúrgico. Bypassar D2 (`--ignore-scripts`) pra rebuild de `sharp` **não deve** abrir cooldown e D1 simultaneamente.

### (E) Bypass sem REASON

Mais ergonômico. Rejeitado: audit log precisa de pegada forense. Sem REASON, impossível revisar periodicamente bypasses passados ("eu bypassei isso por quê mesmo?"). Forçar REASON cria fricção produtiva.

### (F) Advisory mode (warn-only) com N dias antes de hard-block

Migração gradual. Rejeitado: advisory raramente vira hard-block (defer indefinido). Override granular com REASON já serve como "advisory sob demanda". Testes bash sólidos mitigam medo de falso positivo.

### (G) Audit-only (registra mas não bloqueia)

Detecção pós-fato. Rejeitado: payload já rodou — tokens podem ter vazado. Único ponto onde o ataque **ainda não rodou** é `PreToolUse`.

### (H) Sandbox de filesystem / `sandbox-exec` / namespaces Linux

Isolar install em sandbox sem acesso a tokens. Rejeitado por: (1) macOS `sandbox-exec` é deprecated; (2) Linux namespaces exigem privilegios; (3) UX horrível pra workflow de dev local; (4) custo de manter perfis de sandbox por gerenciador.

### (I) Ferramenta externa (Socket CLI, Aikido CLI, npm audit)

Delegar pra serviço pago/free de scanning. Rejeitado por: (1) Socket CLI free-tier tem rate limit incompatível com agente que roda dezenas de installs/dia; (2) dependência externa de SaaS introduz superfície nova; (3) ataques recentes foram **classificados como benignos por Socket/Aikido** nos primeiros 3-5 dias (janela exata que cooldown 14d fecha); (4) sem garantia de classificação proativa — esperar Socket marcar não escala pra zero-day.

### (J) `--ignore-scripts` allowlist (pacotes confiáveis podem rodar scripts)

Permitir lifecycle scripts pra `sharp`, `prisma`, etc., bloqueando o resto. Rejeitado: allowlist vira backdoor — atacante toma conta de pacote da allowlist e executa script. Mandatory `--ignore-scripts` + rebuild manual é mais simples e seguro.

### (K) Hook em Python/Node/Go

Mais robusto, melhor parsing. Rejeitado: coerência com hooks existentes (`block-dangerous-git.sh`, `block-browser-mutations.sh` são bash); zero dependência runtime; auditabilidade trivial (~250 linhas bash total). Bash é suficiente pra regex + jq + curl + npm view.

### (L) Hook per-repo (não global)

Versionado no repo, herdado por colaboradores. Rejeitado: `dotclaude` é o policy hub **global** — install commands acontecem antes de Claude conhecer o repo (ex: `git clone && npm install`). Hook global captura todos. Skill documenta como rollback (remover entrada de `~/.claude/settings.json`) se workflow específico precisar desabilitar temporariamente.

## Consequences

### Positive

- Defesa preventiva contra Shai-Hulud e variantes futuras que usem lifecycle hooks ou git-url deps.
- Zero custo recorrente (registries públicos free, cache local).
- Auditabilidade trivial (~250 linhas bash + audit.jsonl forense).
- Bypass granular permite continuar workflows legítimos sem desativar gate.

### Negative

- Custo cognitivo: usuário/agente precisa lembrar de `--ignore-scripts` e `npm rebuild` quando relevante.
- Atraso de 14 dias em bugfixes (mitigado por bypass).
- Primeira validação lenta em projetos grandes (mitigado por cache imutável).
- Wrappers/subshells escapam (mitigado por princípio + documentação).

### Mitigations

- Mensagem de bloqueio **agregada** com comando copy-paste-able já corrigido + env vars exatas de bypass com REASON template — evita ping-pong de re-emissão.
- Skill `supply-chain-guard` lista workflows dotclaude conhecidos que podem precisar bypass (`/checkout-init` com graphify, `/graphify-init` com `uv tool install graphifyy`).
- Slash command `/supply-chain-audit` permite revisão periódica de bypasses (`reason` field) pra detectar abuso.
- Documentar rollback: remover entrada de `~/.claude/settings.json` desabilita o hook sem deletar arquivos.

## Open questions / Backlog

- Eviction de cache se crescer >100MB algum dia (atualmente TTL infinito sem limite).
- Cobertura Cargo / Gem / Go quando usuário começar a usar.
- Integração opcional com Socket/Aikido pra cross-check (não substituto, apenas sinal adicional).
- Como o hook se comporta em CI/CD se um dia rodarmos Claude lá (provavelmente bypass com REASON via env do CI).

## References

- Shai-Hulud TanStack attack writeup (2026)
- Padrão de hook: `hooks/block-dangerous-git.sh` (já no repo)
- Princípio 13 em `CLAUDE.md`
- Skill operacional: `skills/supply-chain-guard/SKILL.md`
