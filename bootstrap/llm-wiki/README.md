# LLM Wiki Bootstrap

Template reusável para instalar uma **LLM Wiki auto-atualizada** em qualquer repositório. Inspirado no gist de Andrej Karpathy sobre wikis persistentes mantidas por LLMs.

## O que é

Um sistema onde um agente LLM:
- Lê o código e **escreve/mantém** um diretório `wiki/` persistente por módulo.
- **Atualiza automaticamente** a wiki a cada PR merged em `main`.
- **Extrai aprendizados** de PRs: o quê mudou, por quê, tradeoffs, decisões arquiteturais.
- **Valida** via lint no CI — bloqueia merge se a wiki sair de sincronia.
- **Usa sua subscription Claude Code** (não a API paga).

## Arquivos do bootstrap

| Arquivo | Destino no repo-alvo | Função |
|---------|----------------------|--------|
| `AGENTS.md` | `AGENTS.md` (raiz) | Protocolo inviolável do agente |
| `wiki-lint.py` | `wiki-lint.py` (raiz) | Validador estrutural |
| `wiki-update.yml` | `.github/workflows/wiki-update.yml` | CI trigger em PR merged |
| `wiki/index.md` | `wiki/index.md` | Template inicial |
| `install.sh` | (roda local, não copia) | Script de instalação automática |

## Instalação num repo novo

### Opção A — script automático

```bash
cd /caminho/do/bootstrap/llm-wiki
./install.sh /caminho/do/repo-alvo
```

### Opção B — manual

```bash
TARGET=/caminho/do/repo-alvo
cp AGENTS.md "$TARGET/"
cp wiki-lint.py "$TARGET/"
mkdir -p "$TARGET/.github/workflows" "$TARGET/wiki"
cp wiki-update.yml "$TARGET/.github/workflows/"
cp -r wiki/* "$TARGET/wiki/"
```

## Setup one-time por repo-alvo

```bash
cd /caminho/do/repo-alvo

# 1. Gerar OAuth token da subscription Anthropic (só 1x por máquina — token é reusável)
claude setup-token
# → copia o token

# 2. Adicionar como secret no GitHub
gh secret set CLAUDE_CODE_OAUTH_TOKEN

# 3. Bootstrap inicial da wiki (manual, usa Opus 4.7 via subscription — custo zero marginal)
claude -p "Leia todo o código-fonte deste repositório e popule wiki/ seguindo as regras em AGENTS.md. Comece pelo index.md mapeando os módulos principais. Depois crie uma página em wiki/entidades/ por módulo top-level. Respeite todas as regras invioláveis."

# 4. Validar
python wiki-lint.py

# 5. Commitar wiki inicial
git add AGENTS.md wiki-lint.py .github/workflows/wiki-update.yml wiki/
git commit -m "feat: install LLM Wiki system"
```

Pronto. A partir do próximo PR merged, a wiki se atualiza sozinha.

## Como funciona o ciclo automático

```
PR aberto → review humano → PR merged em main
                                    ↓
              GitHub Actions dispara wiki-update.yml
                                    ↓
       Extrai contexto (título, body, comments, diff files)
                                    ↓
       Claude Code (Opus 4.7 via OAuth) lê contexto + AGENTS.md
                                    ↓
       Atualiza wiki/entidades/*, wiki/decisoes/* se ADR
                                    ↓
              python wiki-lint.py (bloqueia se falhar)
                                    ↓
              Commit direto em main com [skip ci]
```

## Parâmetros de design

| Decisão | Valor | Razão |
|---------|-------|-------|
| Granularidade | Uma página por **módulo** (diretório top-level) | Arquivo é ruído, repo é granular demais |
| Modelo | **Opus 4.7 via subscription** | Custo zero marginal no plano Max |
| Merge conflicts em `wiki/` | Agente resolve | Wiki é artefato derivado, não fonte de verdade |
| Merge conflicts em `src/` | Humano resolve | Fonte de verdade nunca toca o agente |
| Fonte primária de aprendizado | PR merged (não commit) | PR tem contexto consolidado; commits têm ruído |

## Riscos conhecidos

- **Staleness**: mitigado pelo lint que valida `last_verified_commit` vs `git log` do `source_files`.
- **Alucinação**: mitigado por `source_files` obrigatório e `confidence` explícito.
- **Loop infinito no CI**: `wiki-update.yml` usa `[skip ci]` no commit auto-gerado para não re-disparar.

## Limites da subscription Claude Max

Rate limit de mensagens/tokens por janela de 5h. Para ~50 PRs/mês de update de wiki, isso é trivial. Se rodar muitos repos com wiki simultâneos **e** outros agentes pesados, pode atingir — fallback seria Gemini API (não implementado neste bootstrap).

## Atualização do bootstrap

Quando refinar o template aqui em `dotclaude/`, propague para repos-alvo:

```bash
# Em cada repo-alvo:
cd /caminho/do/repo-alvo
/caminho/para/dotclaude/bootstrap/llm-wiki/install.sh . --update
```

O `--update` sobrescreve `AGENTS.md`, `wiki-lint.py` e o workflow, mas **nunca** toca `wiki/` (conteúdo específico do repo).
