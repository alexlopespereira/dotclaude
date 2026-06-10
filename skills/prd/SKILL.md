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

8. **Gere o DAG (`dependsOn` / `touchesFiles`) quando o PRD será rodado em paralelo.** O dispatcher paralelo (`/ralph-adversarial --parallel`) co-despacha stories em slots distintos do pool; esses dois campos opcionais dizem ao dispatcher o que pode rodar junto e o que precisa serializar. Veja a seção "Campos de DAG paralelo" abaixo. Ambos são **opcionais e aditivos** — um prd.json sem eles continua válido e a validação jq da Fase 4 do `/full-cycle` passa normalmente (campos ausentes = sem restrição extra; o dispatcher trata cada story como independente).

## Campos de DAG paralelo: `dependsOn` e `touchesFiles`

Estes campos são lidos pelo dispatcher em `skills/ralph-adversarial/lib/dispatch.sh`. **Ambos são opcionais.** A semântica do default ausente é deliberada: **ausência ≡ sem restrição** (a story é despachável sem esperar ninguém e sem reservar arquivos). Preencha-os apenas quando o PRD for executado em modo paralelo e a story tiver, de fato, pré-requisito ou risco de colisão de arquivos.

### `dependsOn` — pré-requisitos de ordem

- **Tipo:** array de `id`s de outras stories do mesmo prd.json.
- **Semântica:** a story só é despachada quando **toda** story listada em `dependsOn` tem `passes: true` (literal `true` — `"ESCALATED"` **não** satisfaz a dependência; uma story escalada bloqueia suas dependentes até resolução humana).
- **Quando preencher:** quando a story consome um artefato (função, schema, contrato, arquivo) produzido por outra story do PRD. Ex.: US-04 implementa um gate que usa a especificação escrita por US-03 → `"dependsOn": ["US-03"]`.
- **Default ausente / `[]`:** sem pré-requisito; despachável imediatamente.
- **Ciclos são proibidos.** O dispatcher roda `detect_dependsOn_cycle` (DFS) e aborta com `ciclo detectado: A → B → A` se o grafo tiver ciclo. Nunca crie dependência circular.

### `touchesFiles` — globs estimados de arquivos tocados

- **Tipo:** array de globs (estilo path glob) que o Planejador **estima** que a story vai criar/modificar.
- **Semântica:** duas stories sem relação de `dependsOn` só co-despacham se seus `touchesFiles` **não intersectam** (ver algoritmo abaixo). Interseção ⇒ serializa (a segunda espera a primeira sair de voo).
- **Quando preencher:** sempre que possível em PRDs paralelos — é o que permite ao dispatcher evitar que dois workers editem o mesmo arquivo e gerem conflito de merge. Use os mesmos paths que você colocaria mentalmente no "arquivos tocados" da fatia.
- **Default ausente:** sem reserva de arquivos; a story não impõe restrição de colisão **nem sofre** restrição vinda de outra (campo ausente em qualquer um dos lados = sem interseção). É o comportamento conservador-permissivo: só serializa quando **ambas** declaram e os prefixos colidem.
- **Conservadorismo intencional:** a estimativa pode errar para mais (falso-positivo de interseção) — isso apenas **serializa desnecessariamente**, nunca corrompe. Errar para menos (esquecer um arquivo realmente compartilhado) degrada para conflito de merge na integração serial, que já escala para humano. Prefira listar de mais a de menos.

### Algoritmo de interseção de `touchesFiles` (implementável)

O gate de disjunção (US-04, `lib/dispatch.sh`) decide se dois globs intersectam por **prefixo literal**, não por matching de glob completo. É deliberadamente conservador:

1. **Normalize cada glob para seu prefixo literal:** pegue a substring do início até (exclusivo) o **primeiro metacaractere glob** (`*`, `?`, `[`). Se não houver metacaractere, o prefixo literal é o glob inteiro.
   - `bin/*.sh` → prefixo `bin/`
   - `bin/tests/x.sh` → prefixo `bin/tests/x.sh` (sem metacaractere)
   - `skills/prd/SKILL.md` → prefixo `skills/prd/SKILL.md`
   - `lib/[ab].sh` → prefixo `lib/`
2. **Dois prefixos intersectam ⇔ um é prefixo (string) do outro.** Compare os dois prefixos literais como strings: se `prefixoA` começa com `prefixoB` **ou** `prefixoB` começa com `prefixoA`, há interseção → serializa.
   - `bin/` vs `bin/tests/x.sh` → `bin/` é prefixo de `bin/tests/x.sh` → **intersecta** (serializa).
   - `bin/foo.sh` vs `bin/` → `bin/` é prefixo de `bin/foo.sh` → **intersecta**.
   - `bin/a.sh` vs `docs/b.md` → nenhum é prefixo do outro → **disjunto** (co-despacha).
3. **Duas listas de `touchesFiles` intersectam se existe pelo menos um par (gA, gB), gA na primeira e gB na segunda, cujos prefixos intersectam.** Basta um par colidir para serializar as duas stories.

> Por que prefixo literal e não glob real: matching de glob completo é caro e ambíguo entre shells; o prefixo literal é barato, determinístico e **conservador** — ele nunca declara disjunção falsa (que corromperia), só pode declarar interseção falsa (que no pior caso serializa algo que poderia ter paralelizado).

### Exemplo completo — prd.json com DAG de 3 stories

```json
{
  "projectName": "Exemplo DAG",
  "branchName": "feat/exemplo-dag",
  "sourcePlan": ".claude/plans/exemplo-dag.md",
  "hasFinancialCost": false,
  "userStories": [
    {
      "id": "US-01",
      "title": "Schema de validação em lib/schema.sh",
      "description": "Define o contrato consumido por US-02 e US-03.",
      "dependsOn": [],
      "touchesFiles": ["lib/schema.sh", "tests/test_schema.sh"],
      "acceptanceCriteria": ["AC1: lib/schema.sh exporta validate() testado em tests/test_schema.sh"],
      "priority": 1,
      "passes": false
    },
    {
      "id": "US-02",
      "title": "Endpoint que usa o schema",
      "description": "Consome validate() de US-01; toca apenas a camada de API.",
      "dependsOn": ["US-01"],
      "touchesFiles": ["api/handler.sh", "tests/test_handler.sh"],
      "acceptanceCriteria": ["AC1: api/handler.sh rejeita payload inválido via validate()"],
      "priority": 2,
      "passes": false
    },
    {
      "id": "US-03",
      "title": "Docs do schema",
      "description": "Documenta o contrato; só toca docs/, disjunto de US-02.",
      "dependsOn": ["US-01"],
      "touchesFiles": ["docs/schema.md"],
      "acceptanceCriteria": ["AC1: docs/schema.md descreve cada campo de validate()"],
      "priority": 3,
      "passes": false
    }
  ]
}
```

Leitura do DAG acima pelo dispatcher: US-01 despacha primeiro (sem deps). Quando US-01 vira `passes: true`, US-02 e US-03 ficam ambas elegíveis (dependem só de US-01); como seus `touchesFiles` são disjuntos (`api/` + `tests/test_handler.sh` vs `docs/`), **co-despacham no mesmo tick** em slots distintos. Se US-02 também tocasse `docs/`, o gate de interseção serializaria as duas.

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
