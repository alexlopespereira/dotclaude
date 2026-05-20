---
name: prd
description: Converte um plano aprovado (de .claude/plans/) em prd.json no formato Ralph. Cada fatia do plano vira uma user story com acceptance criteria, prioridade e status passes:false. Use quando um plano ReAct+Feynman foi aprovado e precisa ser convertido para execução no loop Ralph.
---

# Skill: Conversão Plano → prd.json

## Quando usar
- Após aprovação de um plano pelo full-planning-cycle, full-cycle ou adversarial-review
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
  "hasFinancialCost": false,
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

**Campo `hasFinancialCost`** (opcional, default `false`): flag estrutural lida pelo Princípio 11 cláusula (e) do CLAUDE.md global. Quando `true`, transições do `/full-cycle` que iniciam execução real param para confirmar com o humano. Como decidir o valor:
- Se o plano-fonte tem seção `## Custos recorrentes` com **alguma linha não-`Nenhum`/não-vazia** OU se há marker `HAS_FINANCIAL_COST=true` em `.claude/plans/<slug>.flags` (escrito pelo step shell da Fase 1 do `/full-cycle`), gere `hasFinancialCost: true`.
- Caso contrário, `hasFinancialCost: false`.

## Regras de conversão

1. **Uma fatia do plano = uma user story.** Se o plano tem uma seção "Próxima Fatia" e outras fatias implícitas nas decisões técnicas, cada uma vira uma story separada.

2. **Cada story deve ser completável em um context window.** Se uma fatia é grande demais, quebre em sub-stories. Regra prática: se a implementação tocaria mais de 5 arquivos ou exigiria mais de ~200 linhas de código novo, quebre.

3. **Acceptance criteria devem ser testáveis.** Não aceite "funciona corretamente" — exija condições verificáveis: "retorna 401 para token expirado", "cria registro no banco com campos X, Y, Z".

4. **Suposições do plano viram AC de validação.** Cada [SUPOSIÇÃO] listada no plano que afeta a story deve virar um AC tipo "Validar que [suposição] é verdadeira antes de implementar".

5. **Prioridade segue a ordem do plano.** A "Próxima Fatia" é priority 1, as demais incrementam.

6. **Preserve rastreabilidade.** O campo `sourcePlan` referencia o plano original. O Claude Code no loop Ralph deve poder ler o plano para contexto.

7. **Propague `hasFinancialCost`.** Aplicar regra documentada na seção "Saída" acima. Adição é aditiva (campo opcional); prd.json sem o campo continua válido (default `false`).

## ACs [CAT3-MANUAL] — validação manual pós-merge

Alguns critérios são **Categoria 3 (humano-validated post-merge)** — não podem ser automaticamente verificados pelo agente Claude (implementer) nem pelo Codex (reviewer) dentro do loop Ralph, tipicamente por limite físico (slash command recursivo, dependência de UI ao vivo, side-effect contra serviço externo pago, validação subjetiva de UX). Para sinalizar isso, marque o AC com o prefixo `[CAT3-MANUAL]` logo após o número do AC.

### Sintaxe rígida

A regex de filtro é **ancorada** — o marker deve aparecer **imediatamente após** `ACN:` (com whitespace opcional). Menção a `[CAT3-MANUAL]` no meio do texto **não** caracteriza Cat 3 e o AC continua sendo enviado para Claude/Codex.

Pattern (case-insensitive): `^AC[0-9]+(\.[a-z])?:\s*\[CAT3-MANUAL\]`

### Exemplos

- ✅ Filtrado (prefixo válido):
  ```
  "AC7: [CAT3-MANUAL] Após merge, abra o dashboard em produção e confirme que o gráfico de latência cai abaixo de 200ms."
  ```
- ✅ Filtrado (sufixo `.a`, prefixo válido):
  ```
  "AC3.a: [CAT3-MANUAL] Visualmente: o botão CTA aparece centralizado em telas <768px."
  ```
- ❌ NÃO filtrado (menção no meio — continua indo para o agente):
  ```
  "AC5: o script registra evento ANALYTICS_CAT3-MANUAL no log estruturado."
  ```

### Comportamento do Ralph

O filtro é aplicado **uma única vez** em `skills/ralph-adversarial/ralph-adversarial.sh` (ponto único de injeção do `STORY_BLOCK`) antes de o prompt ser enviado tanto ao **implementer** (Claude) quanto ao **reviewer** (Codex ou Claude Sonnet fallback). Os ACs marcados ficam **invisíveis** para ambos. Veja `skills/ralph-adversarial/SKILL.md` para o ponto de implementação.

### Onde a validação manual mora

Cat 3 ACs **não** desaparecem — eles ficam no `prd.json` para auditoria, e o checklist humano pós-merge geralmente vive em `commands/full-cycle.md` (seção "Verificação humano pós-merge"). Após cumprir o checklist, marque a story como `passes: true` manualmente.
