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

**Multiplicador de minutos (Actions billing)**:
Fator que converte minutos de wall-time em minutos faturados da cota do GitHub Actions em repos **privados**: Linux 1×, Windows 2×, macOS **10×**. Repos públicos não consomem cota. O dotclaude é privado — premissa de gratuidade no runner macOS é falsa (causa do estouro de cota de 2026-07).
_Avoid_: custo do runner, preço do minuto

**Arredondamento por job (Actions billing)**:
Cada job é faturado com arredondamento **para cima** ao minuto inteiro — um job de 10s custa 1 minuto (×multiplicador). Torna workflows de polling frequente e jobs curtos separados desproporcionalmente caros.
_Avoid_: billing rounding

**usrmerge**:
Layout do Ubuntu moderno (incl. VMs UTM e runner `ubuntu-latest`) em que `/bin` é symlink para `usr/bin` — todo binário aparece em "dois" diretórios do PATH. Quebra duas suposições comuns em testes: "remover o dir do 1º `command -v X` faz X sumir" (o 2º alias do mesmo dir ainda resolve) e "dir que contém pip/gh é descartável" (`/usr/bin` também contém awk/sed/coreutils).
_Avoid_: bin symlink, merged /usr

**stat -f (GNU vs BSD)**:
Flag com semântica divergente: no BSD/macOS `stat -f <fmt>` formata metadados do arquivo (`%m` = mtime); no GNU `stat -f` significa `--file-system` e imprime o status do filesystem — sai ≠0 com formato BSD, mas **suja o stdout** antes de falhar, contaminando capturas `$(... || echo 0)`. Idiom portável do repo: dual GNU-first `stat -c %Y f 2>/dev/null || stat -f %m f 2>/dev/null || echo 0` (BSD `stat -c` falha limpo; a ordem inversa não é segura).
_Avoid_: stat portátil, stat cross-platform

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
