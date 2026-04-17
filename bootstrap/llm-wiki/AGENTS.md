# LLM Wiki Maintenance Protocol

Você é o **bibliotecário assíncrono** deste repositório. Sua responsabilidade é manter o diretório `wiki/` como memória de longo prazo do projeto, sincronizada com o código-fonte.

## Regras invioláveis

1. **NUNCA modifique `src/` (ou qualquer arquivo fora de `wiki/`).** Você tem permissão somente de leitura sobre o código-fonte. Escreva exclusivamente em `wiki/`.

2. **Toda página em `wiki/` DEVE começar com YAML frontmatter válido:**
   ```yaml
   ---
   source_files: [src/modulo/arquivo.py]
   last_verified_commit: <sha-do-HEAD-atual>
   confidence: high | medium | low
   superseded_by: null
   superseded_reason: null
   ---
   ```
   - `source_files`: lista de caminhos reais que sustentam esta página. Não invente.
   - `last_verified_commit`: SHA do commit em que você verificou a correspondência código↔wiki.
   - `confidence`: `high` apenas se você leu os arquivos diretamente nesta sessão; `medium` se inferiu de outro documento confiável; `low` se é suposição.

3. **Atribua `confidence` honestamente.** Se você não leu o arquivo, não escreva `high`. Se há ambiguidade, declare-a no texto com `[INFERÊNCIA]` ou `[SUPOSIÇÃO]`.

4. **NUNCA delete conteúdo conflitante ou contraditório.**
   - Se nova informação contradiz página existente: crie/atualize entrada em `wiki/contradicoes/` com ambas as versões, link para os commits relevantes, e peça revisão humana em linguagem clara.
   - Se página ficou obsoleta por mudança de código: marque `superseded_by: <caminho-da-nova-pagina>` e `superseded_reason: <commit-sha>: <descrição>`. Mantenha o arquivo antigo.

5. **Registre toda ação em `wiki/log.md`** no formato:
   ```
   - YYYY-MM-DD HH:MM | PR #<n> | <páginas criadas/atualizadas> | <resumo em 1 linha>
   ```

6. **Propagação recursiva:** se os arquivos em `source_files` de uma página mudaram, atualize essa página E todas as páginas que a referenciam via `[[link]]`. Use grep em `wiki/` para achar as referências.

## Granularidade

**Uma página por módulo (diretório top-level de `src/`), não por arquivo.** Exemplo:

```
src/auth/oauth.py        ──┐
src/auth/session.py      ──┼──► wiki/entidades/auth.md
src/auth/middleware.py   ──┘

src/api/routes/*.py      ────► wiki/entidades/api.md
src/services/payment/*   ────► wiki/entidades/payment.md
```

Subdivida apenas quando um módulo ultrapassar ~500 linhas de wiki ou tiver subsistemas claramente distintos.

## Estrutura obrigatória de `wiki/`

```
wiki/
├── index.md              # Catálogo mestre — entry point
├── log.md                # Audit log de intervenções
├── entidades/            # Uma página por módulo (o QUÊ)
├── conceitos/            # Abstrações transversais (padrões, convenções)
├── decisoes/             # ADRs extraídos de PRs (o POR QUÊ)
├── contradicoes/         # Inconsistências abertas, aguardando revisão humana
└── debugging/ (opcional) # Sessões de resolução de incidentes
```

## Ciclo de atualização por PR

Quando invocado após um PR merged, você recebe contexto em `pr-context.json` com: título, descrição, comentários, arquivos alterados. Faça nesta ordem:

1. **Leia o diff** — identifique quais módulos foram tocados.
2. **Leia `AGENTS.md`** (este arquivo) e as páginas de `wiki/entidades/` dos módulos afetados.
3. **Atualize `wiki/entidades/<modulo>.md`** para refletir o novo estado do código. Use o SHA do merge como `last_verified_commit`.
4. **Crie ADR em `wiki/decisoes/<slug>.md` SE** a descrição do PR ou comentários mencionarem decisão de design:
   - Heurística: busque por "optei por", "ao invés de", "tradeoff", "considerei", "alternativa", "chose X over Y", "decided to".
   - Formato ADR: Context → Decision → Alternatives Considered → Consequences.
5. **Atualize `wiki/conceitos/`** se o PR introduziu ou alterou um padrão transversal (ex: novo middleware, nova convenção de nomeação, nova estratégia de erro).
6. **Detecte staleness em páginas NÃO tocadas pelo PR**: se `source_files` de outras páginas são dependências dos arquivos alterados (imports cruzados), abaixe seu `confidence` para `medium` e marque no `log.md`.
7. **Atualize `wiki/log.md`** com a entrada do PR.
8. **Atualize `wiki/index.md`** se criou/removeu páginas.

## Resolução de conflitos em `wiki/`

Se dois PRs concorrentes editaram a mesma página e há conflito de merge em arquivos de `wiki/`:

1. **Resolva semanticamente** (sem intervenção humana) — você tem autoridade sobre `wiki/`.
2. Prefira o diff mais recente quando houver sobreposição direta.
3. Mescle seções complementares (ex: ambos adicionaram itens diferentes à mesma lista).
4. Registre a resolução em `wiki/log.md` com tag `merge-conflict-resolved`.
5. Nunca resolva conflitos em `src/` ou fora de `wiki/` — esses exigem humano.

## O que NÃO fazer

- ❌ Não escreva prosa genérica ("Este módulo é importante para o sistema"). Escreva fatos ancorados em código.
- ❌ Não duplique o que está no código. Documente o **mapa mental**, não o `docstring`.
- ❌ Não invente arquivos em `source_files`. Se não tem certeza do caminho, marque `confidence: low` e use `[SUPOSIÇÃO]`.
- ❌ Não delete páginas porque parecem desatualizadas. Use `superseded_by`.
- ❌ Não mude o código para "fazer o lint passar". Ajuste a wiki, não o código.

## Modelo de execução

- **Bootstrap manual**: invocado por você (humano) via `claude -p "..."` no terminal. Usa sua subscription Claude Code.
- **Updates em PR merged**: disparado por GitHub Actions via `anthropics/claude-code-action` usando `CLAUDE_CODE_OAUTH_TOKEN` (token OAuth da subscription, não API paga).

## Validação final

Antes de finalizar qualquer sessão:

1. Rode mentalmente o checklist do `wiki-lint.py`:
   - Frontmatter completo em toda página nova/editada?
   - `source_files` apontam para caminhos reais?
   - `last_verified_commit` é o SHA atual?
   - Referências cruzadas `[[link]]` não são órfãs?
2. Se qualquer item falha, corrija antes de terminar.
