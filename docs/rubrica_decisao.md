# Rubrica Numérica Ponderada para Decisão "Perguntar vs. Assumir" em Skill do Claude Code

> **Status — referência, não gate.** O scoring desta rubrica é aplicado pelo **LLM em runtime** via a skill `auto-grill-me`; **não** existe hook que calcule os pesos. Os números abaixo orientam a decisão do agente, não um corte determinístico.

## TL;DR

- **Calibragem assimétrica para "assumir mais":** thresholds em escala 0–100 com cortes **0 ≤ s < 35 → ASSUME silencioso (tipo 2)**, **35 ≤ s ≤ 60 → ASSUME + footnote (tipo 3)**, **s > 60 → PERGUNTA (tipo 1)**.
- **Agregação:** soma ponderada de critérios genéricos (peso 0.7) + critérios de domínio (peso 0.3), com normalizador específico por domínio (`Dmax_eng = 42`, `Dmax_mkt = 36`, `Dmax_biz = 45`) e **oito short-circuits hard** que dominam a rubrica (irreversibilidade destrutiva → tipo 1; auth/security → tipo 1; preferência registrada em memória → tipo 2; ambiguidade terminológica → tipo 1; etc).
- **Justificativa teórica:** Bezos one-way/two-way doors (peso máximo em reversibilidade — *"Type 2 decisions can and should be made quickly by high judgment individuals or small groups… [the] end result [de tratá-las como Tipo 1] is slowness, unthoughtful risk aversion, failure to experiment sufficiently, and consequently diminished invention"*, Carta aos Acionistas Amazon 2015), EVPI de Raiffa & Schlaifer (1961) traduzido em "custo do erro × probabilidade − custo de perguntar", e verbalized confidence descontado pelo viés de overconfidence (Xiong et al. 2023, arXiv:2306.13063).

---

## Key Findings (fundamentos)

1. **Skill original `grill-me` (Matt Pocock).** Disponível em github.com/mattpocock/skills. Texto verbatim: *"Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer. Ask the questions one at a time. If a question can be answered by exploring the codebase, explore the codebase instead."* Esta rubrica preserva o ganho de alinhamento, mas substitui a interrogação relentless por decisão calibrada.

2. **CLARITI** (Vijayvargiya, Viswanathan & Neubig, *"Asking What Matters: Reward-Driven Clarification for Software Engineering Tasks"*, arXiv:2604.14624, abr/2026). O paper identifica duas propriedades operacionais — **task relevance** (qual informação prediz sucesso) e **user answerability** (o que o usuário consegue realisticamente fornecer) — operacionalizadas via Shapley attribution e treinadas como rewards de RL multi-stage. O modelo de 8B parâmetros iguala a taxa de resolução do GPT-5 em issues subespecificadas **gerando 41% menos perguntas**.

3. **ClarEval** (Li, Wu & Chang, Jilin University, arXiv:2603.00187, fev/2026). Define três classes de ambiguidade testáveis em código: **Missing Goal (A_G), Missing Premises (A_P), Ambiguous Terminology (A_T)** (Seção 3.1). *Ambiguous Terminology* é catastrófica — na Seção 5.1, Pass@1 de **6.71% sob A_T contra 89.02% no clarified upper bound** — o que justifica empiricamente o short-circuit F4 e o critério E4 da rubrica.

4. **CLAM** (Kuhn, Gal & Farquhar, arXiv:2212.07769) estabelece *selective clarification*: LLMs raramente perguntam quando deveriam e tendem a respostas confiantes sob ambiguidade. A rubrica explícita corrige esse viés direcional.

5. **Bezos one-way/two-way doors** (carta de 2015) é o eixo dominante: peso máximo de reversibilidade na parte genérica e short-circuit hard para 1-way doors.

6. **EVPI de Raiffa & Schlaifer (1961)** fundamenta o cálculo "custo esperado do erro − custo de perguntar"; quando negativo ou desprezível, assume.

7. **Verbalized confidence é miscalibrado.** Wang & Stengel-Eskin, *"Calibrating Verbalized Confidence with Self-Generated Distractors"* (arXiv:2509.25532v2): *"verbalized LLM-generated confidence scores have empirically been found to be miscalibrated, reporting high confidence on instances with low accuracy and thereby harming trust and safety."* Por isso G6 desconta 1 nível.

8. **AI-induced cognitive fatigue.** Shalu, Verma et al., *"The Cognitive Cost of AI: How AI Anxiety and Attitudes Influence Decision Fatigue in Daily Technology Use"* (Annals of Neurosciences, 2025, DOI: 10.1177/09727531251359872, PMC12367725). Sustenta empiricamente que uso prolongado de IA produz cognitive strain e decision fatigue — justifica thresholds altos para perguntar.

---

## A Rubrica Completa

### A) Parte Genérica (peso 0.7 no score final)

Escala **0–3** por critério (Likert reduzida; escalas maiores aumentam ruído sem aumentar sinal). Score parcial = Σ(valor × peso); normalizado para 0–100.

| # | Critério | Definição | Peso | Ancoragens (0 / 1 / 2 / 3) |
|---|----------|-----------|------|---------------------------|
| **G1** | **Reversibilidade** (Bezos) | Custo de desfazer se errada | **5** | 0: trivialmente reversível (renomear var local) / 1: retrabalho moderado (refactor de módulo) / 2: caro reverter (migração de schema com backfill) / 3: irreversível ou destrutivo (DROP TABLE, push --force, deletar arquivo, email enviado, publicação) |
| **G2** | **Blast radius** | Sistemas/pessoas/artefatos afetados | **4** | 0: escopo local / 1: módulo / 2: aplicação ou time / 3: produção, clientes externos, dados de terceiros |
| **G3** | **Densidade de contexto disponível** | Informação já em memória/codebase/conversa | **4** (invertido) | 0: tudo presente (CLAUDE.md, código adjacente, histórico explícito) / 1: maior parte inferível / 2: lacunas com pistas / 3: sem contexto útil |
| **G4** | **Divergência entre alternativas razoáveis** | Quão diferentes são as top-K opções | **3** | 0: opções funcionalmente equivalentes / 1: cosméticas / 2: trade-offs conviventes / 3: incompatíveis (SQL vs NoSQL, monolito vs microsserviços) |
| **G5** | **Sensibilidade a preferência pessoal/estilo** | Resposta correta depende de gosto | **3** | 0: existe ótimo objetivo / 1: convenção dominante / 2: preferência de equipe esperada não-registrada / 3: puro gosto (tom de copy, naming pessoal, paleta) |
| **G6** | **Confiança calibrada do agente** (verbalized − 1) | Auto-avaliação descontada por overconfidence | **3** (invertido) | 0: ≥90% após desconto / 1: 70–90% / 2: 50–70% / 3: <50% ou ambiguidade lexical irresolvível |
| **G7** | **Custo de perguntar** | Atrito cognitivo no momento | **2** (invertido) | 0: usuário em flow profundo / 1: usuário ativo, contexto carregado / 2: pergunta isolada barata / 3: usuário convidou interrogação |
| **G8** | **Tempo até descoberta do erro** | Quanto demora para perceber a assunção errada | **2** | 0: imediato (compila/testa) / 1: próxima execução / 2: dias-semanas / 3: meses ou só em produção sob load |

**Soma máxima:** 15+12+12+9+9+9+6+6 = **78**.

**Justificativa dos pesos:** G1 (reversibilidade) recebe peso máximo seguindo Bezos — é o único critério que, isoladamente, justifica perguntar mesmo sem outros sinais. G2 e G3 codificam respectivamente "magnitude do erro" (numerador do EVPI) e "economia de perguntar" (contexto já presente). G7 e G8 têm pesos baixos porque tratam do *custo* de perguntar, deliberadamente subponderado para favorecer "assumir mais".

### B) Parte Específica por Domínio (peso 0.3)

Cada domínio: 4 critérios em escala 0–3, com `Dmax` próprio.

#### B.1) Engenharia de Software (Dmax = 42)

| # | Critério | Peso | Ancoragens |
|---|----------|------|-----------|
| **E1** | **Superfície de API exposta** (Hyrum's Law / SemVer) | **4** | 0: função privada / 1: módulo interno / 2: API entre times / 3: API pública com clientes externos |
| **E2** | **Reversibilidade de schema/dados** | **4** | 0: in-memory / 1: cache / 2: migração aditiva / 3: DROP COLUMN, perda de dados |
| **E3** | **Security/compliance footprint** | **3** | 0: nenhum dado sensível / 1: logs / 2: PII tocado / 3: credenciais, auth, criptografia, GDPR/LGPD |
| **E4** | **Ambiguidade terminológica** (ClarEval A_T) | **3** | 0: termos precisos / 1: polissemia resolúvel pelo contexto / 2: termo do usuário com múltiplas interpretações plausíveis no codebase / 3: termo crítico não-resolvível ("otimizar", "limpar", "melhorar") |

Soma máxima: (4+4+3+3) × 3 = **42**. Alinhado com ADR de Nygard: decisões arquiteturalmente significativas merecem registro *e* clarificação.

#### B.2) Marketing (Dmax = 36)

| # | Critério | Peso | Ancoragens |
|---|----------|------|-----------|
| **M1** | **Permanência da peça** (Sharp/Romaniuk — distinctive brand assets) | **4** | 0: post efêmero, A/B / 1: campanha trimestral / 2: landing page evergreen / 3: rebrand, logo, jingle, tagline permanente |
| **M2** | **Alinhamento com identidade existente** | **3** | 0: replica voz já documentada / 1: pequena extensão / 2: território adjacente / 3: ruptura com tom/posicionamento atual |
| **M3** | **Segmento e ICP definidos** (Dunford) | **3** | 0: ICP explícito no brief / 1: inferível do produto / 2: múltiplos ICPs plausíveis / 3: ICP nuclear desconhecido |
| **M4** | **Reversibilidade de canal/distribuição** | **2** | 0: tweet / 1: email / 2: anúncio pago lançado / 3: comunicado de imprensa, parcerias anunciadas |

Soma máxima: (4+3+3+2) × 3 = **36**.

#### B.3) Business & Startups (Dmax = 45)

| # | Critério | Peso | Ancoragens |
|---|----------|------|-----------|
| **B1** | **Tipo Bezos** (1-way vs 2-way door, explícito) | **5** | 0: experimento <1 semana / 1: feature reversível / 2: pivô parcial / 3: 1-way door (aquisição, contrato longo, demissão, encerramento de linha) |
| **B2** | **Falsificabilidade da hipótese** (Ries — validated learning) | **3** | 0: testável <1 semana com MVP / 1: sprint / 2: requer dados inexistentes / 3: hipótese de visão de longo prazo, não-experimental |
| **B3** | **Compromisso financeiro/legal irrecuperável** | **4** | 0: zero burn / 1: <1% runway / 2: 1–10% runway ou contrato revisável / 3: >10% runway, exclusividade, equity |
| **B4** | **Stakeholder externo no loop** | **3** | 0: decisão interna / 1: cofundador / 2: investidor informado / 3: cliente ou board precisa aprovar |

Soma máxima: (5+3+4+3) × 3 = **45**.

### C) Função de Agregação

```
score_final = 0.7 × (100 × ΣG  / 78)
            + 0.3 × (100 × ΣD  / Dmax_domínio)

onde:
  ΣG = Σ(G_i × peso_i)  para i ∈ {1..8}
  ΣD = Σ(D_j × peso_j)  para j ∈ critérios do domínio

  Dmax_eng = 42
  Dmax_mkt = 36
  Dmax_biz = 45
```

Equivalente prático: cada parte (genérica e de domínio) é normalizada independentemente para 0–100, depois combinada como média ponderada 70/30. Score final ∈ [0, 100] sempre.

- **Soma ponderada** (não média não-ponderada): permite que um critério altamente pontuado (ex: G1=3 × peso 5 = 15) puxe o score, refletindo a dominância da reversibilidade.
- **Não usar máximo:** colapsaria a granularidade necessária para o tipo-3 (footnote).
- **Não usar produto** (ICE/RICE): produto colapsa a zero quando um fator é zero, desejável em prioritização mas indesejado aqui (reversibilidade=0 não deve forçar perguntar=0 se outros sinais forem altos).
- **70/30 entre genérico e domínio:** critérios genéricos capturam a maior parte do sinal em decisões agnósticas a domínio; o overlay de domínio refina sem substituir. Esta é uma escolha de design.

### D) Thresholds de Decisão

| Faixa | Output | Racional |
|-------|--------|----------|
| **0 ≤ score < 35** | **Tipo 2 — ASSUME silenciosamente** | Default agressivo. CLARITI mostra que perguntas bem-escolhidas capturam grande parte do ganho de informação com 41% menos turns; o regime "<35" cai no que CLARITI penaliza como baixa task relevance. |
| **35 ≤ score ≤ 60** | **Tipo 3 — ASSUME + footnote** | Faixa larga (25 pontos) porque é o output preferido em ambiguidade real. Cria audit trail estilo ADR-light de Nygard mas sem bloquear momentum. |
| **score > 60** | **Tipo 1 — PERGUNTA** | Para atingir >60 sem short-circuit é preciso pelo menos G1=3 + G2=2 + G3=2 (=31 pontos genéricos brutos = 39.7 normalizados × 0.7 = 27.8) somado a sinais consistentes de domínio. Decisões verdadeiramente "1-way door + alto blast radius + baixo contexto" ultrapassam facilmente; decisões reversíveis raramente passam mesmo com baixa confiança. |

### E) Exemplos Worked

**Exemplo 1 — Engenharia, score baixo → Tipo 2:**
> *"Adicione tratamento de erro nesta função de parsing JSON."*
>
> G1=0, G2=0, G3=1, G4=1, G5=1, G6=0, G7=1, G8=0. E1=0, E2=0, E3=0, E4=0.
>
> ΣG = 0+0+4+3+3+0+2+0 = 12. Genérica normalizada = 100 × 12/78 = 15.4. × 0.7 = **10.8**. ΣD = 0 → 0 × 0.3 = 0. **Score = 10.8 → Tipo 2.** Assume `try/catch` com log estruturado seguindo padrão do arquivo.

**Exemplo 2 — Engenharia, security force-trigger via short-circuit F8:**
> *"Refatore o módulo de autenticação para suportar OAuth2."*
>
> G1=2, G2=2, G3=2, G4=3, G5=1, G6=2, G7=1, G8=1. E1=2, E2=0, E3=3, E4=2.
>
> ΣG = 10+8+8+9+3+6+2+2 = 48. Genérica normalizada = 100 × 48/78 = 61.5. × 0.7 = 43.1. ΣD = 8+0+9+6 = 23. Domínio normalizada = 100 × 23/42 = 54.8. × 0.3 = 16.4. **Score = 59.5 → cairia em Tipo 3** pela rubrica. **MAS F8 dispara** (alteração em autenticação) → **Tipo 1 por short-circuit**. Pergunta direcionada: *"OAuth2 para que fluxo: login de usuário final (auth code + PKCE) ou serviço-a-serviço (client_credentials)?"*

> *Nota de design:* O short-circuit F8 é a forma correta de tratar essa classe. Manipular pesos para forçar Tipo 1 distorceria a rubrica para decisões análogas em outros domínios.

**Exemplo 3 — Marketing, score médio → Tipo 3:**
> *"Escreva o headline da nova landing page do feature X."*
>
> G1=1, G2=1, G3=1, G4=2, G5=3, G6=1, G7=1, G8=1. M1=2, M2=1, M3=1, M4=0.
>
> ΣG = 5+4+4+6+9+3+2+2 = 35. Genérica normalizada = 100 × 35/78 = 44.9. × 0.7 = 31.4. ΣD = 8+3+3+0 = 14. Domínio normalizada = 100 × 14/36 = 38.9. × 0.3 = 11.7. **Score = 43.1 → Tipo 3.** Assume default e reporta: *"Optei pelo benefício funcional como anchor por aderir ao tom existente da homepage; alternativas testadas em comentário."*

**Exemplo 4 — Business, todos os critérios em 3 → Tipo 1 (e short-circuits F1+F7):**
> *"Devo aceitar a oferta de aquisição de $5M da Empresa Y?"*
>
> Todos os critérios em 3. ΣG = 78. Genérica normalizada = 100 × 78/78 = 100. × 0.7 = 70. ΣD = 45. Domínio normalizada = 100 × 45/45 = 100. × 0.3 = 30. **Score = 100 → Tipo 1.** Os short-circuits F1 (1-way door financeiramente material) e F7 (pricing/posicionamento estratégico/rebranding) também disparariam antes da pontuação.

**Exemplo 5 — Genérico, trivial → Tipo 2 via F3:**
> *"Renomeie a variável `tmp` para algo mais descritivo."* — F3 short-circuit. Tipo 2 trivial.

### F) Heurísticas de Short-Circuit (precedência absoluta sobre a soma)

Avaliar nesta ordem **antes** da pontuação:

| Short-circuit | Ação | Fundamento |
|---------------|------|-----------|
| **F1** — Ação destrutiva irreversível sem confirmação explícita (`rm -rf`, `DROP TABLE`, `git push --force` em branch protegida, envio de email/mensagem externa, publicação, transação financeira) | **→ Tipo 1, sempre** | Bezos: 1-way door dominante; custo do erro >> custo de perguntar |
| **F2** — Preferência claramente expressa em memória/CLAUDE.md/conversa recente | **→ Tipo 2, sempre** | Densidade de contexto saturada; perguntar viola Grice's maxim of Quantity |
| **F3** — Tarefa explicitamente trivial e reversível (formatar, renomear var local, comentário, log adicional) | **→ Tipo 2** | EVPI ≈ 0 |
| **F4** — Ambiguidade puramente terminológica não-resolvível por busca no contexto (ClarEval A_T crítico) | **→ Tipo 1**, pergunta tipo "Demand Specificity" | A_T causa Pass@1 de 6.71% vs 89.02% (ClarEval, Seção 5.1) |
| **F5** — Usuário invocou explicitamente o modo questionador ("me grille", "stress-test", "interview me") | **→ Tipo 1** | Custo de perguntar invertido |
| **F6** — Conflito entre alternativas com custo de teste < custo da pergunta (ex: dois designs equivalentes em A/B viável) | **→ Tipo 2 + propor experimento** | Lean Startup build-measure-learn supera deliberar |
| **F7** — Decisão de pricing, posicionamento estratégico, ou rebranding | **→ Tipo 1** | Dunford: positioning é fundação; Sharp: distinctive assets são de longo prazo |
| **F8** — Alteração em autenticação, autorização, criptografia, gestão de credenciais ou LGPD/GDPR | **→ Tipo 1, salvo se escopo explicitamente especificado no contexto** | Erros nesta classe são caros e frequentemente irreversíveis (vazamento, compliance); blast radius alto; superfície de ataque alterada |

### G) Anti-patterns Explícitos (NUNCA perguntar, mesmo se a rubrica sugerir)

1. **Resposta está no contexto/codebase/CLAUDE.md** — explore primeiro. Regra do `grill-me` original: *"If a question can be answered by exploring the codebase, explore the codebase instead"*.
2. **Pergunta genérica/template** ("Que linguagem você prefere?" em repo 100% Python).
3. **Tratar usuário como iniciante havendo sinais de expertise** (PhD ITA: não explicar O(n log n)).
4. **Pedir decisão já delegada implicitamente** ("Você quer testes?" após "faça production-ready").
5. **Binária quando deveria ser aberta** (oferecer A ou B quando C, D, E também valem — apresente top-3 com recomendação).
6. **Empilhar múltiplas decisões em uma pergunta** (viola "one at a time" do `grill-me` original).
7. **Pedir informação comprovadamente indisponível ao usuário** — ex: "p99 latency" sem instrumentação.
8. **Refazer pergunta cuja resposta o usuário já forneceu** em turno anterior da conversa.
9. **Pedir permissão para algo regulado pelo tool gate** ("Posso editar este arquivo?").
10. **Confirmar o óbvio** ("Posso prosseguir?" após instrução clara).

### H) Formato de Reporte para Output Tipo 3 (footnote)

**1–3 linhas, prefixo `▸ assumi:`, ≤300 caracteres, sem markdown decorativo.**

```
▸ assumi: <decisão em 1 frase>.
  alternativas: <2–3 opções separadas por |>.
  trade-off: <1 frase com a dimensão dominante>.
  reverter: <ação ou comando, opcional>.
```

**Exemplos:**

> ▸ assumi: PostgreSQL com `jsonb` para o campo de metadata.
> alternativas: tabela normalizada | DocumentDB | MongoDB.
> trade-off: flexibilidade de schema vs. queryability — escolhi `jsonb` por ter índices GIN e manter ACID.
> reverter: `ALTER TABLE ... DROP COLUMN metadata`.

> ▸ assumi: headline focado em benefício funcional ("Deploy em 30 segundos").
> alternativas: social proof ("usado por X startups") | curiosity gap.
> trade-off: tom existente do site é direto e técnico; testar variações via A/B na próxima sprint.

**Princípios:** sem pergunta de confirmação ao final ("isso está ok?") — o usuário corrige se quiser; "reverter:" omitido se trivialmente reversível.

---

## Recommendations (staged)

1. **Imediato (primeiro commit do SKILL.md):** implemente Parte A + short-circuits F1–F5, F8 + formato de footnote. Adicione logging local em `.claude/decisions.jsonl` desde o dia 1 (sem isso, calibragem subsequente é impossível).
2. **Sprint 1:** adicione um domínio por vez (engenharia primeiro). Instrumente: rastreie razão tipo-1 / tipo-2 / tipo-3.
3. **Calibragem após acúmulo de decisões logadas:** se razão de tipo-1 ficar consistentemente alta, suba threshold superior de 60 para 65; se tipo-2 gerar correções frequentes, abaixe inferior de 35 para 30. Os cortes 35 e 60 são heurísticos — calibre com seu próprio uso.
4. **Sprint 2:** introduza self-consistency check para G6 (Wang, Wei, Schuurmans, Le, Chi, Narang, Chowdhery & Zhou, *"Self-Consistency Improves Chain of Thought Reasoning in Language Models"*, ICLR 2023, arXiv:2203.11171; ganhos reportados de +17.9% em GSM8K, +11.0% em SVAMP, +12.2% em AQuA sobre greedy decoding). Gerar 3 candidatos internos, medir concordância; alta concordância → descontar mais 1 nível em G6, baixa → adicionar 1. Custo: ~3× tokens em decisões ambíguas.
5. **Sprint 3:** revise mensalmente os tipo-3 footnotes em `.claude/decisions.jsonl` (ADR-light). Quando uma preferência repetida emergir, migre para CLAUDE.md — reduz G3 (densidade de contexto) em decisões futuras.

**Sinais para recalibrar:**
- Correções frequentes a assunções tipo-2 → calibragem agressiva demais; suba threshold inferior.
- Usuário expressar frustração com perguntas → reforce F2 + auditing dos anti-patterns 1, 4, 10.
- Footnotes tipo-3 ignoradas (nenhum override) → considere unificar tipos 2 e 3 para reduzir ruído visual.

---

## Caveats

1. **Calibragem inicial é heurística.** Pesos derivam da combinação de literatura (Bezos para reversibilidade, ClarEval/CLARITI para SWE, Dunford/Sharp/Romaniuk para marketing, Ries para business), não de validação experimental neste contexto. Trate as constantes como hipóteses operacionais.
2. **Verbalized confidence é estruturalmente miscalibrado** (Wang & Stengel-Eskin, arXiv:2509.25532v2). O desconto de 1 nível em G6 é correção grosseira, não calibragem formal.
3. **Rubrica favorece falsos negativos** (não-perguntar quando deveria) sobre falsos positivos (perguntar à toa), por construção. Isso é intencional dada a preferência por "assumir mais", mas amplifica risco em 1-way doors se F1, F4, F7, F8 falharem. Mitigação: short-circuits têm precedência absoluta sobre a soma.
4. **Datas e identificadores das fontes principais:** CLARITI (Vijayvargiya, Viswanathan, Neubig) — arXiv:2604.14624, submetido 16 abr/2026. ClarEval (Li, Wu, Chang; School of AI, Jilin University) — arXiv:2603.00187, submetido fev/2026. CLAM — arXiv:2212.07769. Wang & Stengel-Eskin — arXiv:2509.25532. Self-consistency — arXiv:2203.11171. Shalu et al. — DOI 10.1177/09727531251359872 / PMC12367725.
5. **A rubrica não substitui julgamento;** é um *prior* calibrado. Em ambiguidade real o agente ainda pode errar — daí a importância do formato tipo-3 como mecanismo de audit barato e de logar todas as decisões.

---

## Tabela de Completude

| Item | Coberto? | Seção |
|------|----------|-------|
| A) Parte genérica 6–10 critérios | ✅ 8 critérios (G1–G8) | A |
| B) Parte específica 3–5 por domínio | ✅ 4 por domínio (E1–E4, M1–M4, B1–B4) | B |
| C) Função de agregação justificada | ✅ Soma ponderada 70/30 com `Dmax` específico por domínio | C |
| D) Thresholds 3 faixas | ✅ 0–34 / 35–60 / >60 | D |
| E) 3–5 exemplos worked | ✅ 5 exemplos | E |
| F) Short-circuits | ✅ 8 regras (F1–F8) | F |
| G) Anti-patterns | ✅ 10 anti-patterns | G |
| H) Formato de reporte tipo 3 | ✅ Template ≤300 chars + 2 exemplos | H |
| Calibragem "assumir mais" | ✅ Cortes assimétricos, faixa Tipo 3 larga, peso baixo em G7/G8 | A, D |
| Linguagem técnica PhD | ✅ Sem simplificações | Tudo |
| Pronto para SKILL.md | ✅ Markdown estruturado | — |
