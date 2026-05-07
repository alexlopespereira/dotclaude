---
description: Bootstrap Graphify num repo (build inicial + hooks + .gitignore/.gitattributes + commit local, sem push)
allowed-tools: Bash(bash *), Bash(test *), Bash(chmod *), Read
argument-hint: [--force] [--skip-rebuild] [--allow-dirty]
---

Inicializa o [Graphify](https://github.com/safishamsi/graphify) (knowledge graph local) no repo do cwd. Executa os 6 passos canônicos: build inicial, `graphify claude install`, `graphify hook install`, append em `.gitignore`/`.gitattributes`, e commit local. **Não pusha** — isso é trabalho do `/commit-push-pr`.

Pré-requisito (1× por máquina, **não** instalado por este comando): `uv tool install graphifyy && graphify install`. Se a CLI estiver ausente, o script para e instrui.

Contexto da decisão: ver `docs/adr/0001-adopt-graphify-sunset-llm-wiki.md` e `CONTEXT.md` neste repo.

## Passos

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/graphify-init.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
bash "$SCRIPT" $ARGUMENTS
```

Reporte o resumo (passos executados, arquivos commitados, warnings sobre paths gitignored, sugestão de próximo `/commit-push-pr`).

## Flags

- `--force` — regenera `graphify-out/` mesmo se já existir, sem prompt interativo.
- `--skip-rebuild` — em re-init, mantém `graphify-out/` atual e só re-instala hooks (claude + git).
- `--allow-dirty` — prossegue mesmo se working tree tem mudanças não-commitadas em `CLAUDE.md`/`.gitignore`/`.gitattributes`/`.claude/settings.json` (default: aborta para evitar arrastar edits não-relacionadas pro commit Graphify).

## Guardrails

- **NUNCA** `git add -A` — só os 5 paths esperados (`graphify-out/`, `.gitignore`, `.gitattributes`, `CLAUDE.md`, `.claude/settings.json`); paths gitignored são pulados com warning (caso comum: `.claude/` ignorado no próprio `dotclaude`).
- **NUNCA** push automático.
- **NUNCA** instala `graphifyy` automaticamente — Princípio 4 do CLAUDE.md (instalação só após apresentar capacidade + estabilidade ao usuário).
- Comportamento esperado documentado: hook `post-commit` é background-detached e roda AST-only (sem LLM); `graph.json` regenerado entra no commit *seguinte* (lag de 1 commit, trade-off do ADR 0001).
