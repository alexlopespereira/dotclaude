# Context — dotclaude

## Glossary

### Graphify
Gerador de knowledge graph de código escolhido para substituir o `bootstrap/llm-wiki/` neste repo. Pacote PyPI `graphifyy` (com double-y). Repo upstream: https://github.com/safishamsi/graphify.

Produz 3 artefatos em `graphify-out/` por projeto:
- `graph.json` — grafo serializado (fonte do viewer)
- `graph.html` — viewer interativo standalone
- `GRAPH_REPORT.md` — relatório markdown lido pelo agente

**Não usa banco de dados.** Não há servidor, ChromaDB, FAISS ou store vetorial — é JSON local + HTML estático.

**Convenção upstream (oficial, README:183–197):** `graphify-out/` **deve ser commitado** ("meant to be committed to git so everyone on the team starts with a map"). Excluir via `.gitignore`:
- `graphify-out/manifest.json` (mtime-based, quebra após `git clone`)
- `graphify-out/cost.json` (local-only)
- `graphify-out/cache/` (opcional)

Nota: o repo upstream do próprio Graphify ignora `graphify-out/` no seu `.gitignore`, mas isso é porque é o repo da própria ferramenta (meta-recursivo) — não é padrão recomendado pra usuários.

### llm-wiki (removido em 2026-05-07)
Sistema anterior em `bootstrap/llm-wiki/` que mantinha `wiki/` markdown versionado, com auto-update via GitHub Action em PR merged. Substituído por Graphify e diretório deletado na mesma migração — registro completo em `docs/adr/0001-adopt-graphify-sunset-llm-wiki.md`.

### Decisão: estratégia de versionamento Graphify
Seguir padrão oficial do autor (README:183–197): **versionar `graphify-out/` inteiro**, com `.gitignore` excluindo apenas `manifest.json`, `cost.json` e `cache/`. Manter fresco via `graphify hook install` (git post-commit + post-checkout, AST-only, sem custo de LLM). Sem CI customizado.

### Decisão: bootstrap pra repos novos
Criar slash command `/graphify-init` (executa os 6 passos: build inicial, `graphify claude install`, `graphify hook install`, `.gitignore`, `.gitattributes`, commit). Estender `/checkout-init` pra rodar `graphify hook install` + `graphify claude install` em cada um dos 5 slots Boris automaticamente. Deletar `bootstrap/llm-wiki/` na mesma migração.

### Decisão: hook PreToolUse — per-repo
`graphify claude install` mantém comportamento default: grava hook em `.claude/settings.json` **versionado no repo**, não no `~/.claude/settings.json` global. Coexiste sem conflito com hook global de secret-scan (`block-dangerous-git.sh`). Colaboradores que clonem o repo herdam o hook automaticamente. `/graphify-init` deve incluir o passo `graphify claude install` por repo.

### Decisão: estratégia de merge para `graphify-out/graph.json`
`.gitattributes` com `graphify-out/graph.json merge=theirs` — em conflito, sempre preserva a versão de `origin/main`. Após `git pull` / `/sync`, rodar `graphify .` localmente pra regenerar refletindo o working tree do slot. Hook permanece no modo `post-commit` padrão (background, assíncrono, lag de 1 commit aceito). Fluxo: `/sync` → resolve conflitos via merge=theirs → `graphify .` → próximo commit traz `graph.json` re-alinhado.

### Instalação Graphify (dois níveis)
- **Nível máquina (1× por máquina):** `uv tool install graphifyy && graphify install` — instala CLI globalmente e registra slash command `/graphify` no Claude Code.
- **Nível repo (por projeto):** `graphify .` para gerar artefatos + `graphify claude install` para gravar hook PreToolUse no `.claude/` local que faz o agente consultar `GRAPH_REPORT.md` antes de ler arquivos.

### `graphify hook install`
Comando separado de `graphify claude install`. Instala **git hooks** (`post-commit` + `post-checkout`) no `.git/hooks/` local, que **reconstroem `graphify-out/` automaticamente** após cada commit ou checkout. Rebuild é **AST-only — sem chamada a LLM, sem custo de API**. É o mecanismo oficial pra manter `graphify-out/` fresco sem CI.
