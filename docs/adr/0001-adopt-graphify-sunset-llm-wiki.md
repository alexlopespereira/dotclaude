# ADR 0001 — Adopt Graphify; sunset llm-wiki

## Status

Accepted — 2026-05-03

## Context

Antes desta decisão, o repo `dotclaude` mantinha em `bootstrap/llm-wiki/` um sistema próprio para gerar e manter "wikis de repositório" via LLM. O sistema:

- Mantinha `wiki/` markdown versionado por módulo top-level no repo-alvo.
- Atualizava automaticamente em PR merged via GitHub Action (`wiki-update.yml`) usando subscription Claude Code via OAuth token.
- Validava estrutura via `wiki-lint.py` (lint bloqueava merge se wiki saísse de sincronia).
- Era instalado em repos novos via `bootstrap/llm-wiki/install.sh`.

Em paralelo, surgiu o projeto open-source [Graphify](https://github.com/safishamsi/graphify) (PyPI: `graphifyy`), que produz **knowledge graph** local (não wiki) sobre o código do repo. Trade-offs comparativos:

| Aspecto | llm-wiki (próprio) | Graphify (externo) |
|---|---|---|
| Output | Markdown por módulo | `graph.json` + `graph.html` viewer + `GRAPH_REPORT.md` |
| Auto-update | GitHub Action em PR merged (LLM cost por PR) | Git hook post-commit/post-checkout local (AST-only, zero API cost) |
| Query/exploração | Apenas leitura de markdown | Knowledge graph queriable: `graphify query`, `graphify path`, MCP server |
| Custo de manutenção (do código do bootstrap) | Alto — script bash, workflow YAML, lint Python, AGENTS.md template | Zero — projeto upstream mantém |
| Lock-in | Próprio | Externo (mas open source MIT) |
| Provedor LLM | Claude Code OAuth via Action | Claude Code subagent via skill.md (subscription) — default zero-cost |
| Determinismo / staleness | Lint bloqueia merge se stale | Hook git rebuild automático após cada commit |

## Decision

1. **Adotar Graphify como sistema de knowledge graph para repos pessoais e de produto.**
2. **Descontinuar `bootstrap/llm-wiki/`** — diretório será deletado.
3. **Versionar `graphify-out/`** seguindo recomendação oficial do autor (README:183–197), com `.gitignore` excluindo apenas `manifest.json`, `cost.json` e `cache/`.
4. **Estratégia de merge:** `.gitattributes` com `graphify-out/graph.json merge=theirs` — em conflito durante `git pull`/`/sync`, preserva versão de `origin/main`. Após pull, regenerar localmente via `graphify .` para realinhar.
5. **Bootstrap pra repos novos:** criar slash command `/graphify-init` que executa os 6 passos canônicos (build inicial, `graphify claude install`, `graphify hook install`, `.gitignore`, `.gitattributes`, commit). Estender `/checkout-init` para rodar `graphify hook install` + `graphify claude install` em cada um dos 5 slots Boris automaticamente.
6. **Hook PreToolUse per-repo (não global):** seguir default de `graphify claude install` (grava em `.claude/settings.json` versionado no repo). Garante que colaboradores que clonem herdem o hook automaticamente; coexiste sem conflito com hook global de secret-scan.

## Consequences

### Positive
- Zero custo de LLM em rebuilds incrementais (hook AST-only, sem API call).
- Primeira build (`graphify .`) usa subscription Claude Code via subagent — zero custo de API.
- Onboarding: novo dev/slot dá `git pull` e já tem o grafo (artefato versionado).
- Eliminação de manutenção de código (~200 linhas Python+bash+YAML do llm-wiki).
- Slash commands `graphify query`, `graphify path` adicionam capacidades novas vs. wiki estática.

### Negative
- Dependência externa (PyPI `graphifyy`) — bug upstream pode bloquear workflow.
- `graph.json` versionado polui PR diff (JSON denso, ~MB em repos grandes).
- `merge=theirs` significa que `graph.json` no `main` reflete sempre o último PR merged — pode estar momentaneamente fora-de-sincronia com working tree local até `graphify .` rodar.
- `post-commit` hook é background-detached; commit que faz mudança grande de código produz `graph.json` regenerado em commit *seguinte*, não no atual (lag de 1 commit).
- Quando 2 slots Boris tocam código no mesmo intervalo, conflito de merge no `graph.json` é garantido — `merge=theirs` resolve automaticamente, mas exige que o usuário entenda o modelo.

### Mitigations
- Lock da versão do `graphifyy` em `pyproject.toml` por repo, pra evitar surpresa quando upstream mudar formato do JSON.
- `/sync` deve rodar `graphify .` ao final pra realinhar `graph.json` local com working tree pós-pull.
- Documentar o "lag de 1 commit" no `/graphify-init` README pra usuário saber.

## Alternatives considered

- **(A) Não-versionar `graphify-out/`** (oposto da convenção upstream) — exigiria que cada slot Boris rodasse `graphify .` após pull. Rejeitado: alto atrito de onboarding, perde benefício do hook PreToolUse que avisa o agente antes de cada `Glob`/`Grep`.
- **(B) Híbrido — versionar só `GRAPH_REPORT.md`** — análogo ao padrão llm-wiki. Rejeitado: hook PreToolUse usa `graph.json` como sentinela, então em fresh checkout o agente não seria avisado de existir grafo. Também requereria CI customizado para manter o report fresco em `main`.
- **(C) Manter llm-wiki + adotar Graphify lado-a-lado** — rejeitado: duplica esforço de manutenção e produz dois artefatos para o agente consultar.

## References

- Upstream: https://github.com/safishamsi/graphify
- README oficial linhas 183–197: "Team setup" recommending versioning of `graphify-out/`.
- Graphify hooks implementation: `graphify/hooks.py` — pula durante rebase/merge/cherry-pick; rebuild background-detached.
- LLM provider default: `graphify/llm.py:3` — "default pipeline uses Claude Code subagents via skill.md".
