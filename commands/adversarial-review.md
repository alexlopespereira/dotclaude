---
description: Gera revisão adversária (Red Team) de um plano usando o template Feynman
allowed-tools: Read, Glob, Grep, Workflow
argument-hint: [caminho do plano ou "último plano"]
---

Você é agora o **Agente Revisor Adversário**. Seu objetivo é ENCONTRAR FALHAS, não confirmar o plano.

A invocação deste slash command **é o opt-in explícito** exigido pela Workflow tool (mesmo racional do Princípio 11: a existência do comando é o gate de alto nível; o usuário interrompe via Ctrl-C). Por isso o modo principal abaixo pode chamar a Workflow tool sem perguntar.

## Passos comuns (ambos os modos)

1. Leia `~/.claude/skills/react-feynman/SKILL.md` para carregar o **Template: Revisão Adversária**.
2. Localize e leia o plano: $ARGUMENTS (se vazio ou "último plano", pegue o `.md` mais recente em `.claude/plans/`).
3. Escolha o modo:
   - **Modo Workflow (principal):** use quando a Workflow tool está disponível E o plano é não-trivial (mais de uma decisão técnica, ou toca migração/auth/custo/dependência nova).
   - **Modo single-agent (fallback):** use quando **a Workflow tool está indisponível** (não aparece na lista de tools) **ou o plano é trivial** (decisão única, ≤1 arquivo, sem risco estrutural) — nesse caso o overhead de fan-out não se paga.

---

## Modo Workflow (principal)

Invoque a **Workflow tool** com um pipeline de duas fases nomeadas: **Find** (finders por dimensão, em paralelo) → **Verify** (refutador adversário por finding). Consolide o resultado no Template Revisão Adversária.

### Schema de findings (cada finder retorna)

Cada finder devolve `{ findings: Finding[] }`, onde `Finding` é:

```json
{
  "decisaoAlvo": "string — qual decisão técnica do plano este finding ataca (cite # da tabela ou trecho)",
  "descricao":   "string — a falha, específica e acionável (não 'melhorar X')",
  "severidade":  "Crítica | Alta | Média | Baixa",
  "cenarioFalha":"string — o cenário concreto em que o plano quebra por causa disto"
}
```

### Fase Find — um finder por dimensão (paralelo)

Quatro finders, cada um lê o plano inteiro e devolve findings **apenas da sua dimensão** (as 4 dimensões da tabela "Falhas Encontradas" do template):

- **Lógica** — contradições, raciocínio inválido, passos que não se seguem das premissas.
- **Suposições** — cada `[SUPOSIÇÃO]` do plano: tente REFUTÁ-la; toda premissa adotada sem verificação é um finding candidato.
- **Lacunas** — o que o plano NÃO considerou: caminhos de erro, casos de borda, ACs ausentes, frontmatter/config incompleto.
- **Riscos** — o que pode dar errado na execução: irreversibilidade, custo, acoplamento, dependência externa, segurança.

Aplique o **Teste Feynman** em todas as dimensões: se o Planejador nomeou um padrão/conceito sem explicar o mecanismo, é finding.

Após a fase Find, **dedupe** os findings entre dimensões (mesma `decisaoAlvo` + descrição equivalente → um só, mantendo a maior severidade).

### Fase Verify — refutador adversário por finding

Para CADA finding deduplicado, rode um agente refutador independente cuja missão é **derrubar o finding** (provar que é falso positivo): ele relê o trecho-alvo do plano e tenta argumentar que a falha não procede. Retorne `{ procede: boolean, justificativa: string }`. **Default: `procede=true` só se o refutador NÃO conseguir derrubar.** Findings refutados com sucesso são descartados (ou rebaixados a nota), não entram no veredicto.

### Esqueleto da chamada Workflow

```js
export const meta = {
  name: 'adversarial-review',
  description: 'Revisão adversária de um plano: finders por dimensão → verify refutador',
  phases: [{ title: 'Find' }, { title: 'Verify' }],
}
const PLAN = /* conteúdo do plano lido no passo 2 */
const DIMENSOES = [
  { key: 'Lógica',     foco: 'contradições e raciocínio inválido' },
  { key: 'Suposições', foco: 'refutar cada [SUPOSIÇÃO] do plano' },
  { key: 'Lacunas',    foco: 'o que o plano não considerou' },
  { key: 'Riscos',     foco: 'o que pode dar errado na execução' },
]
const FINDING_SCHEMA = { /* { findings: [{ decisaoAlvo, descricao, severidade, cenarioFalha }] } */ }
const VERDICT_SCHEMA = { /* { procede, justificativa } */ }

// Find: finders em paralelo (barrier — preciso de TODOS antes de dedupar entre dimensões)
const achados = (await parallel(DIMENSOES.map(d => () =>
  agent(`Revise este plano pela dimensão ${d.key} (${d.foco}). Plano:\n${PLAN}`,
        { label: `find:${d.key}`, phase: 'Find', schema: FINDING_SCHEMA })
))).filter(Boolean).flatMap(r => r.findings)
const deduped = dedupePorAlvoEDescricao(achados)  // código, não agente

// Verify: refutador por finding (paralelo)
const verificados = await parallel(deduped.map(f => () =>
  agent(`Tente DERRUBAR este finding (prove que é falso positivo). Default procede=true se não conseguir. Finding: ${JSON.stringify(f)}\nPlano:\n${PLAN}`,
        { label: `verify:${f.decisaoAlvo}`, phase: 'Verify', schema: VERDICT_SCHEMA })
    .then(v => ({ ...f, verdict: v }))
))
// verdict == null ⇒ o refutador não rodou (erro de API): pela regra "default procede=true",
// o finding SOBREVIVE — não pode ser descartado por uma falha de infra do verificador.
return verificados.filter(Boolean).filter(f => f.verdict == null || f.verdict.procede)
```

Use `parallel()` na fase Find porque a deduplicação entre dimensões precisa de **todos** os findings juntos (barrier justificado). Escale o número de finders/refutadores à profundidade pedida (plano grande/crítico → considere 2–3 refutadores por finding e voto majoritário).

### Consolidação

Com os findings confirmados (que sobreviveram ao refutador), produza o parecer no **Template: Revisão Adversária** (ver Saída abaixo).

---

## Modo single-agent (fallback)

Quando a Workflow tool está indisponível **ou** o plano é trivial, execute como agente único (comportamento histórico):

1. Para CADA decisão técnica do plano:
   - Aplique o ciclo ReAct: raciocine sobre a decisão, teste hipóteses contrárias, observe inconsistências.
   - Tente REFUTAR cada `[SUPOSIÇÃO]` listada.
   - Aplique o Teste Feynman: se o Planejador usou nome de padrão sem explicar mecanismo, aponte.
2. Seja específico nas sugestões — "melhorar X" não é sugestão, "trocar X por Y porque Z" é.

---

## Saída (obrigatória em ambos os modos)

Produza o parecer usando o **Template: Revisão Adversária** da skill react-feynman, mantendo todas as seções:

- **Veredicto** (APROVADO / APROVADO COM RESSALVAS / REPROVADO)
- **Falhas Encontradas** — tabela `| # | Tipo | Descrição | Severidade | Sugestão |` (no modo Workflow, uma linha por finding confirmado)
- **Suposições Refutadas** — `[SUPOSIÇÃO original] → [contra-argumento ou cenário de falha]`
- **Teste Feynman** — trechos onde o Planejador nomeou sem explicar o mecanismo
- **Perguntas que o Planejador Deveria Ter Feito**
- **Recomendação** — específica

**MENTALIDADE:** Pergunte-se "Em que cenário este plano falha?" e "O que o Planejador não considerou?"

## Reconciliação do corpo (obrigatória quando há findings Crítica/Alta)

O parecer acima é **aditivo** — ele descreve o que está errado, mas **não
reescreve o plano**. O `prd-convert` lê **só o corpo** do plano (Decisões
técnicas + fatias), não o parecer. Se você anexar o parecer e parar, uma
decisão condenada continua no corpo e vira user story executável (incidente-fonte:
uma story "CMDT default false" que secaria uma fila de produção).

Portanto, quando o veredito for **REPROVADO** ou **APROVADO COM RESSALVAS** com
findings de severidade **Crítica/Alta**:

1. **Edite o CORPO do plano** — para cada finding Crítica/Alta, remova/corrija a
   decisão condenada na tabela de Decisões técnicas / nas fatias, de modo que o
   corpo descreva a solução final, não a proposta rejeitada.
2. **Carimbe** `<!-- plan-reconciled: <verdict-slug> -->` no topo do corpo.
3. O gate `plan-verdict-gate.sh` (rodado pelo `/prd-convert`) recusa converter
   sem esse marcador — é o backstop determinístico que impede o corpo defasado
   de virar PRD.

Se o veredito for **APROVADO limpo** (sem findings Crítica/Alta), o corpo já
descreve a solução final — nada a reconciliar.
