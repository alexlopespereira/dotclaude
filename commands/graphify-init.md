---
description: Bootstrap Graphify num repo (build inicial via skill + hooks + .gitignore/.gitattributes + commit local, sem push)
allowed-tools: Bash(bash *), Bash(test *), Bash(chmod *), Bash(ls *), Bash(git *), Bash(command *), Read, Skill(graphify)
argument-hint: [--force] [--skip-rebuild] [--allow-dirty]
---

Inicializa o [Graphify](https://github.com/safishamsi/graphify) (knowledge graph local) no repo do cwd. Dois estágios: **(1) build inicial via skill `graphify`** (zero-cost via subagents Claude Code) + **(2) script bash** que faz `graphify claude install`, `graphify hook install`, append em `.gitignore`/`.gitattributes`, e commit local. **Não pusha** — isso é trabalho do `/commit-push-pr`.

Pré-requisito (1× por máquina, **não** instalado por este comando): `uv tool install graphifyy && graphify install`. Se a CLI estiver ausente, o passo 1 para e instrui.

Contexto da decisão: ver `docs/adr/0001-adopt-graphify-sunset-llm-wiki.md` (incluindo a Errata 2026-05-07 que motiva esta separação em dois estágios) e `CONTEXT.md` neste repo.

## Passos

### 1. Pre-flight
- `cd $(git rev-parse --show-toplevel)`.
- Confirme que `graphify` CLI está disponível (`command -v graphify`). Se ausente, pare e instrua instalação manual.

### 2. Build inicial via skill (zero-cost)

`graphify .` **não é CLI shell** — é o slash command `/graphify .` servido pela skill instalada (`~/.claude/skills/graphify/SKILL.md`). O build inicial usa subagents Claude Code via subscription, custo zero.

Decida pelo estado de `graphify-out/graph.json` e por `$ARGUMENTS`:

- **Não existe** → invoque `Skill(graphify)` apontando pra `.` (cwd).
- **Existe + `$ARGUMENTS` contém `--force`** → re-rode `Skill(graphify)` em `.`.
- **Existe + `$ARGUMENTS` contém `--skip-rebuild`** → pule este passo.
- **Existe sem flag** → pergunte ao usuário [y]es/[n]o-rebuild/[a]bort.

### 3. Resto via script bash

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/graphify-init.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
# Filtra --force/--skip-rebuild de $ARGUMENTS — script só aceita --allow-dirty.
ARGS_FILTERED=$(printf '%s' "$ARGUMENTS" | tr ' ' '\n' | grep -vE '^(--force|--skip-rebuild)$' | tr '\n' ' ')
bash "$SCRIPT" $ARGS_FILTERED
```

O script faz: `graphify claude install`, `graphify hook install`, `.gitignore`/`.gitattributes` append, `git add` + commit local (sem push). Aborta com erro claro se `graphify-out/graph.json` não existir — sinal de que o passo 2 foi pulado.

### 4. Reporte
Resumo: passos executados, arquivos commitados, warnings sobre paths gitignored, sugestão de próximo `/commit-push-pr`.

## Flags

- `--force` — regenera `graphify-out/` mesmo se já existir, sem prompt interativo (interpretada no passo 2 pelo agente).
- `--skip-rebuild` — em re-init, mantém `graphify-out/` atual e só re-instala hooks (interpretada no passo 2).
- `--allow-dirty` — prossegue mesmo se working tree tem mudanças não-commitadas em `CLAUDE.md`/`.gitignore`/`.gitattributes`/`.claude/settings.json` (interpretada no passo 3 pelo script).

## Guardrails

- **NUNCA** `git add -A` — só os 5 paths esperados (`graphify-out/`, `.gitignore`, `.gitattributes`, `CLAUDE.md`, `.claude/settings.json`); paths gitignored são pulados com warning (caso comum: `.claude/` ignorado no próprio `dotclaude`).
- **NUNCA** push automático.
- **NUNCA** instala `graphifyy` automaticamente — Princípio 4 do CLAUDE.md (instalação só após apresentar capacidade + estabilidade ao usuário).
- Comportamento esperado documentado: hook `post-commit` é background-detached e roda AST-only (sem LLM); `graph.json` regenerado entra no commit *seguinte* (lag de 1 commit, trade-off do ADR 0001).
