---
name: prd
description: Converte um plano aprovado (de .claude/plans/) em prd.json no formato Ralph. Cada fatia do plano vira uma user story com acceptance criteria, prioridade e status passes:false. Use quando um plano ReAct+Feynman foi aprovado e precisa ser convertido para execução no loop Ralph.
---

# Skill: Conversão Plano → prd.json

## Quando usar
- Após aprovação de um plano pelo full-cycle ou pelo adversarial-review
- Quando o usuário pedir para converter um plano em tarefas executáveis

## Entrada
Arquivo de plano em `.claude/plans/[nome].md` contendo:
- Decisões técnicas (tabela)
- Suposições a validar
- Próxima Fatia (e fatias subsequentes, se houver)

## Saída
Arquivo `prd.json` na raiz do repositório com este formato:

```json
{
  "projectName": "[extraído do título do plano]",
  "branchName": "feat/[slug-do-plano]",
  "sourcePlan": ".claude/plans/[nome].md",
  "userStories": [
    {
      "id": "US-01",
      "title": "[título curto da fatia]",
      "description": "[o que implementar]",
      "acceptanceCriteria": [
        "AC1: [critério verificável]",
        "AC2: [critério verificável]"
      ],
      "priority": 1,
      "passes": false
    }
  ]
}
```

## Regras de conversão

1. **Uma fatia do plano = uma user story.** Se o plano tem uma seção "Próxima Fatia" e outras fatias implícitas nas decisões técnicas, cada uma vira uma story separada.

2. **Cada story deve ser completável em um context window.** Se uma fatia é grande demais, quebre em sub-stories. Regra prática: se a implementação tocaria mais de 5 arquivos ou exigiria mais de ~200 linhas de código novo, quebre.

3. **Acceptance criteria devem ser testáveis.** Não aceite "funciona corretamente" — exija condições verificáveis: "retorna 401 para token expirado", "cria registro no banco com campos X, Y, Z".

4. **Suposições do plano viram AC de validação.** Cada [SUPOSIÇÃO] listada no plano que afeta a story deve virar um AC tipo "Validar que [suposição] é verdadeira antes de implementar".

5. **Prioridade segue a ordem do plano.** A "Próxima Fatia" é priority 1, as demais incrementam.

6. **Preserve rastreabilidade.** O campo `sourcePlan` referencia o plano original. O Claude Code no loop Ralph deve poder ler o plano para contexto.
