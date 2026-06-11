# Context — dotclaude

Glossário de domínio do `dotclaude` para a integração de **knowledge graph** (Graphify) que substituiu o gerador de wiki próprio (llm-wiki). As decisões hard-to-reverse desta área estão registradas em [ADR 0001 — Adopt Graphify; sunset llm-wiki](docs/adr/0001-adopt-graphify-sunset-llm-wiki.md); este arquivo é só o glossário.

## Language

**Graphify**:
Gerador de knowledge graph de código (PyPI `graphifyy`, com double-y; upstream `safishamsi/graphify`) que materializa o grafo como JSON local + HTML estático, sem banco de dados, ChromaDB, FAISS ou store vetorial.
_Avoid_: graph tool, wiki, vector store

**llm-wiki**:
Sistema predecessor (removido em 2026-05-07) que versionava `wiki/` markdown com auto-update via GitHub Action em PR merged.
_Avoid_: wiki, repo wiki

**graphify-out/**:
Diretório versionado onde o Graphify grava seus artefatos por projeto, com `.gitignore` excluindo apenas `manifest.json`, `cost.json` e `cache/`.
_Avoid_: build dir, output dir

**GRAPH_REPORT.md**:
Artefato em `graphify-out/` — relatório markdown que o agente consulta antes de ler arquivos do repo.
_Avoid_: report, wiki page

**graph.json**:
Artefato em `graphify-out/` — grafo serializado que alimenta o viewer e serve de sentinela pro hook PreToolUse do Graphify.
_Avoid_: graph data, dump

**graph.html**:
Artefato em `graphify-out/` — viewer interativo standalone do grafo.
_Avoid_: viewer, dashboard

## Relationships

- **Graphify** substituiu **llm-wiki** — migração e trade-offs em [ADR 0001](docs/adr/0001-adopt-graphify-sunset-llm-wiki.md).
- **Graphify** produz três artefatos dentro de **graphify-out/**: **GRAPH_REPORT.md**, **graph.json** e **graph.html**.
- **graphify-out/** é versionado no git ([ADR 0001](docs/adr/0001-adopt-graphify-sunset-llm-wiki.md), Decision 3); o `.gitignore` exclui só `manifest.json`, `cost.json` e `cache/`.
- **graph.json** resolve conflito de merge via `merge=theirs` ([ADR 0001](docs/adr/0001-adopt-graphify-sunset-llm-wiki.md), Decision 4).
- Bootstrap de repos novos (`/graphify-init`) e o escopo per-repo do hook PreToolUse são Decisions 5 e 6 do mesmo [ADR 0001](docs/adr/0001-adopt-graphify-sunset-llm-wiki.md).

## Example dialogue

> **Dev:** "Onde fica o relatório que o agente lê antes de abrir um arquivo?"
> **Domain expert:** "É o **GRAPH_REPORT.md**, dentro de **graphify-out/** — quem mantém esse diretório fresco é o **Graphify** via git hook, sem custo de LLM."

## Flagged ambiguities

- "wiki" já significou tanto **llm-wiki** (sistema removido) quanto o conceito genérico — resolvido: **llm-wiki** é o sistema específico descontinuado em favor do **Graphify**; não use "wiki" pra falar do estado atual.
