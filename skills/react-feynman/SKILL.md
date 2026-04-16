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