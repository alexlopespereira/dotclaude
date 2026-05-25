---
name: react-feynman
description: Framework ReAct (Reasoning+Acting) com honestidade intelectual Feynman para planejamento e revisão adversária. Use para produzir planos técnicos, revisar decisões arquiteturais, ou executar ciclo completo de planejamento+revisão.
---

# Skill: ReAct + Feynman

## Quando usar

- Planejamento de features, arquitetura ou decisões técnicas não-triviais
- Revisão adversária de planos antes da implementação
- Qualquer decisão com impacto > 1 dia de trabalho ou > 3 arquivos

## Ciclo ReAct

Cada iteração segue estritamente:

### Thought #N
[raciocínio em linguagem natural — o que sei, o que não sei, qual hipótese estou testando]

### Action #N
[exatamente UMA ação: buscar info, ler código, rodar teste, consultar docs]

### Observation #N
[resultado factual, sem interpretação prematura]

Repetir até resposta fundamentada ou declarar explicitamente que a informação é insuficiente.

## Marcadores Feynman

Toda afirmação técnica deve ser classificada:

- `[FATO]` — Verificado ou verificável agora (ex: "A API retorna 404 para esse endpoint" após testar)
- `[INFERÊNCIA]` — Conclusão lógica de fatos, mas que pode estar errada (ex: "Provavelmente o rate limit é por IP")
- `[SUPOSIÇÃO]` — Premissa adotada sem verificação; PRECISA ser validada antes da implementação

### Teste Feynman

Se você usou o NOME de um padrão/conceito mas não explicou o MECANISMO por baixo, é violação Feynman. Exemplos:

- ❌ "Vamos usar o padrão Strategy aqui"
- ✅ "Vamos extrair o algoritmo de cálculo para uma interface separada, permitindo trocar a implementação em runtime sem alterar o código que consome. Isso funciona porque o chamador depende da abstração, não da implementação concreta."

## Template: Plano (Claude como Planejador)

## Plano: [Título]
**Confiança Geral:** [ALTA / MÉDIA / BAIXA] — [justificativa em 1 linha]

### Contexto e Objetivo
[O que estamos resolvendo e por quê — máximo 3 parágrafos]

### Ciclo ReAct
[Thought/Action/Observation iterados — quantos forem necessários]

### Decisões Técnicas
| # | Decisão | Alternativas | Justificativa (mecanismo, não nome) |
|---|---------|-------------|-------------------------------------|
| 1 | ...     | ...         | ...                                 |

### Suposições a Validar
- [ ] [SUPOSIÇÃO] ...
- [ ] [SUPOSIÇÃO] ...

### Perguntas Abertas
- ...

### Próxima Fatia
[O menor incremento implementável que entrega valor]

### Custos recorrentes
Sempre presente; "Nenhum." se o plano não envolve SaaS pago.

| Serviço | Custo/mês (BRL) | Free tier suficiente? | Alternativa gratuita avaliada? | Custo de migrar para alternativa (h) |
|---------|-----------------|-----------------------|-------------------------------|--------------------------------------|
|         |                 |                       |                               |                                      |

## Modo HST — Hierarchical Systems Thinking (`/plan --hst`)

Quando `/plan` recebe `--hst`, produza o plano nas **6 fases HST abaixo** em vez do **Template: Plano** padrão. Regras que continuam valendo *dentro* das fases:

- **ReAct** (Thought → Action → Observation) roda durante a exploração de cada fase.
- **Marcadores Feynman** (`[FATO]`/`[INFERÊNCIA]`/`[SUPOSIÇÃO]`) anotam toda afirmação.
- O plano ainda termina com **Custos recorrentes** (tabela acima) e segue para **revisão adversária**.
- Não comece detalhando componentes nem propondo tarefas isoladas — desça a hierarquia de cima pra baixo.

### Fase 1 — System Intent (com gate de persistência na "wiki")

Itens, divididos em dois tiers:

- **Projeto** (perguntado **uma vez** por repo, depois reusado): `usuários` · `stakeholders` · `restrições globais`
- **Feature** (por plano): `objetivo central da solução` · `entradas` · `saídas` · `fora-de-escopo`

**Protocolo do gate** (a ordem importa):

1. **Detectar storage** da wiki:
   - Se `graphify-out/graph.json` existe → `STORE=graphify-out/memory/` (graphify ingere o arquivo como nó → `graphify query`/`explain` de bônus).
   - Senão → `STORE=.claude/intent/` (criar com `mkdir -p`).
   - O **formato do arquivo é idêntico** nos dois casos — graphify é enhancement, não requisito.
   - **Verificar versionamento** (a promessa "pergunta uma vez, reusa entre máquinas/colaboradores" só vale se o intent for pro git): rodar `git check-ignore "$STORE/system_intent_project.md"`. Se **ignorado** (ex: repo com `.claude/` no `.gitignore` — comum), **AVISAR**: `⚠ intent ficará LOCAL nesta máquina (não compartilhado via git)` e oferecer: (a) `git add -f` ao persistir (force-track só o intent); (b) um path versionado que o repo não ignore; (c) aceitar local-only. `graphify-out/memory/` em geral **não** é ignorado (convenção Graphify versiona) → repos graphified não disparam o aviso. **Não** prometer "versionado" sem essa checagem.
2. **Fundamentar** as respostas plausíveis: explore o repo + `$ARGUMENTS` + `CONTEXT.md`/`docs/adr/`/`README` antes de propor qualquer resposta. "Plausível" sem exploração é chute.
3. **Tier de projeto:**
   - Ler `$STORE/system_intent_project.md`. **Se existe → carregar, usar, NÃO perguntar** (imprimir 1 linha: `System Intent de projeto carregado de <path>`).
   - Se ausente → para **cada** item (usuários, stakeholders, restrições globais), gere uma resposta plausível + 1–2 alternativas e pergunte via `AskUserQuestion`, com a recomendada primeiro e `"Other"` para edição livre. **Batch:** os 3 itens cabem em **1 tela** (≤4 perguntas/chamada). Persistir (ver Persistência).
4. **Tier de feature:**
   - Derivar um `slug` do enunciado do problema. **Listar** os `system_intent_feature_*.md` existentes em `$STORE`. **Mostrar** o slug proposto + os existentes e deixar o usuário **confirmar ou apontar para um existente** (via `AskUserQuestion`).
   - Se o arquivo do slug resolvido existe → carregar, usar, **NÃO perguntar**.
   - Se ausente → para **cada** item (objetivo, entradas, saídas, fora-de-escopo), pergunte via `AskUserQuestion` (os 4 itens cabem em **1 tela**). Persistir.
5. **`--refresh-intent`:** ignora o hit, re-pergunta e sobrescreve (via delete-then-rewrite).

**Persistência (delete-then-rewrite — idempotente):**

- Projeto: `$STORE/system_intent_project.md` · Feature: `$STORE/system_intent_feature_<slug>.md`.
- Ao **atualizar** um arquivo que já existe: **apague-o antes de reescrever**. Em repo graphified isso é o que garante update limpo do conceito — o arquivo deletado entra em `prune_sources` no próximo `graphify update` (remove os nós antigos), e a reescrita regrava (regrow limpo). Sem o delete, o build "only grows" e deixa nós stale (graphify atualiza por *delete→prune→regrow*, não por overwrite).
- O **lookup do gate lê o arquivo direto** (autoritativo, determinístico). Não dependa de `graphify query` para decidir pular as perguntas — o grafo pode estar momentaneamente stale.
- Frontmatter (ingestable pelo graphify *e* legível como arquivo plano):

```yaml
---
type: "system-intent"
scope: "project"        # ou "feature"
feature_slug: "<slug>"  # só no tier de feature
date: "<ISO-8601>"
contributor: "claude-code"
---
```

Corpo: cada item do tier como uma subseção (`## Usuários`, `## Stakeholders`, …) com o conteúdo confirmado.

`[SUPOSIÇÃO]` Repo multi-contexto (`CONTEXT-MAP.md`): MVP usa **um** `system_intent_project.md` na raiz; estender para um por contexto se necessário.

### Fase 2 — High-Level Architecture
Visão arquitetural de alto nível: divida a solução em grandes camadas/blocos e explique a função de cada um em 1–2 frases. Sem entrar em componente individual ainda.

### Fase 3 — Modular Breakdown
Para **cada módulo**: Responsabilidade · Entradas · Saídas · Dependências · Regras de negócio · Riscos · Critérios de sucesso.

### Fase 4 — Interaction Map
Como os módulos interagem; fluxo principal de ponta a ponta; gargalos, dependências críticas e pontos de falha.

### Fase 5 — Component Deep Dive
Para **cada componente**: dados necessários · processos internos · exceções · integrações.

### Fase 6 — Roadmap (compatível com `/prd-convert`)
Organize a implementação em fases: **MVP** · **melhorias** · **versão escalável**. **Cada item do MVP é uma "fatia"/user story** — esse é o formato que `/prd-convert` consome para gerar `prd.json`, então um plano `--hst` continua alimentando o loop Ralph sem adaptação. Termine com **Decisões Pendentes** e a tabela de **Custos recorrentes**.

## Template: Revisão Adversária (Codex como Red Team)

## Revisão Adversária: [Título do Plano]
**Veredicto:** [APROVADO / APROVADO COM RESSALVAS / REPROVADO]

### Falhas Encontradas
| # | Tipo | Descrição | Severidade | Sugestão |
|---|------|-----------|------------|----------|
| 1 | [Lógica / Suposição / Lacuna / Risco] | ... | [Crítica / Alta / Média / Baixa] | ... |

### Suposições Refutadas
- [SUPOSIÇÃO original] → [Contra-argumento ou cenário de falha]

### Teste Feynman
[Trechos onde o Planejador nomeou sem explicar o mecanismo]

### Perguntas que o Planejador Deveria Ter Feito
- ...

### Recomendação
[O que precisa mudar antes de prosseguir — ser específico]

## Regras do Fluxo

1. **Máximo 3 ciclos** de revisão. Após 3, escalar para o humano com resumo das divergências.
2. **Nenhum código de produção antes da aprovação** (ou aprovação com ressalvas).
3. **O humano tem autoridade final** e pode intervir em qualquer ponto.
4. **Adversariedade é colaboração:** o objetivo é tornar o plano mais robusto, não destruí-lo.