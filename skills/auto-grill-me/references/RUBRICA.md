# Rubrica de Classificação "Perguntar vs. Assumir"

> Versão operacional para uso em runtime pela skill `auto-grill-me`. Fonte canônica e justificativas teóricas: `dotclaude/docs/rubrica_decisao.md`. **Sincronizar este arquivo quando a fonte mudar.**

## Algoritmo de decisão (ordem obrigatória)

Para **cada pergunta** que a árvore de design geraria:

```
1. Avaliar SHORT-CIRCUITS (F1–F8). Se algum disparar → output direto, sem score.
2. Avaliar ANTI-PATTERNS (1–10). Se algum disparar → NÃO perguntar (Tipo 2 silent).
3. Calcular SCORE (parte genérica G1–G8 + parte domínio).
4. Aplicar THRESHOLD:
     0  ≤ s < 35  →  Tipo 2 (assume silencioso)
     35 ≤ s ≤ 60  →  Tipo 3 (assume + footnote)
     s  > 60      →  Tipo 1 (PERGUNTA ao usuário)
5. Registrar decisão em .claude/decisions.jsonl (audit trail).
```

---

## 1) Short-circuits (precedência absoluta — avaliar PRIMEIRO)

| ID | Gatilho | Ação |
|----|---------|------|
| **F1** | Ação destrutiva irreversível sem confirmação (`rm -rf`, `DROP TABLE`, `git push --force` em branch protegida, envio de email/mensagem externa, publicação, transação financeira) | **→ Tipo 1** |
| **F2** | Preferência claramente expressa em memória/CLAUDE.md/conversa recente | **→ Tipo 2** |
| **F3** | Tarefa explicitamente trivial e reversível (formatar, renomear var local, comentário, log adicional) | **→ Tipo 2** |
| **F4** | Ambiguidade puramente terminológica não-resolvível por busca no contexto (ClarEval A_T crítico) | **→ Tipo 1** (pergunta "Demand Specificity") |
| **F5** | Usuário invocou explicitamente modo questionador ("me grille", "stress-test", "interview me") | **→ Tipo 1** |
| **F6** | Conflito entre alternativas com custo de teste < custo da pergunta (ex: dois designs equivalentes em A/B viável) | **→ Tipo 2 + propor experimento** |
| **F7** | Decisão de pricing, posicionamento estratégico, ou rebranding | **→ Tipo 1** |
| **F8** | Alteração em autenticação, autorização, criptografia, gestão de credenciais ou LGPD/GDPR | **→ Tipo 1** (salvo se escopo explicitamente especificado no contexto) |

---

## 2) Anti-patterns (NUNCA perguntar, mesmo se score sugerir)

1. Resposta está no contexto/codebase/CLAUDE.md — **explore primeiro**.
2. Pergunta genérica/template ("Que linguagem você prefere?" em repo 100% Python).
3. Tratar usuário como iniciante havendo sinais de expertise.
4. Pedir decisão já delegada implicitamente ("Você quer testes?" após "faça production-ready").
5. Binária quando deveria ser aberta (oferecer A ou B quando C, D, E também valem — apresente top-3 com recomendação).
6. Empilhar múltiplas decisões em uma pergunta (viola "one at a time").
7. Pedir informação comprovadamente indisponível ao usuário.
8. Refazer pergunta cuja resposta o usuário já forneceu em turno anterior.
9. Pedir permissão para algo regulado pelo tool gate ("Posso editar este arquivo?").
10. Confirmar o óbvio ("Posso prosseguir?" após instrução clara).

---

## 3) Critérios Genéricos (Parte A — peso 0.7 no score final)

Escala 0–3 por critério. Score parcial = Σ(valor × peso); normalizado para 0–100.

| # | Critério | Peso | Ancoragens (0 / 1 / 2 / 3) |
|---|----------|------|---------------------------|
| **G1** | **Reversibilidade** | **5** | 0: trivialmente reversível (renomear var local) / 1: retrabalho moderado (refactor de módulo) / 2: caro reverter (migração de schema com backfill) / 3: irreversível ou destrutivo (DROP TABLE, push --force, email enviado, publicação) |
| **G2** | **Blast radius** | **4** | 0: escopo local / 1: módulo / 2: aplicação ou time / 3: produção, clientes externos, dados de terceiros |
| **G3** | **Densidade de contexto disponível** (invertido) | **4** | 0: tudo presente / 1: maior parte inferível / 2: lacunas com pistas / 3: sem contexto útil |
| **G4** | **Divergência entre alternativas razoáveis** | **3** | 0: opções equivalentes / 1: cosméticas / 2: trade-offs conviventes / 3: incompatíveis (SQL vs NoSQL) |
| **G5** | **Sensibilidade a preferência pessoal/estilo** | **3** | 0: existe ótimo objetivo / 1: convenção dominante / 2: preferência de equipe não-registrada / 3: puro gosto (tom de copy, naming, paleta) |
| **G6** | **Confiança calibrada** (verbalized − 1, invertido) | **3** | 0: ≥90% após desconto / 1: 70–90% / 2: 50–70% / 3: <50% ou ambiguidade lexical irresolvível |
| **G7** | **Custo de perguntar** (invertido) | **2** | 0: usuário em flow profundo / 1: usuário ativo, contexto carregado / 2: pergunta isolada barata / 3: usuário convidou interrogação |
| **G8** | **Tempo até descoberta do erro** | **2** | 0: imediato (compila/testa) / 1: próxima execução / 2: dias-semanas / 3: meses ou só em produção sob load |

**Soma máxima:** 15+12+12+9+9+9+6+6 = **78**.

---

## 4) Critérios de Domínio (Parte B — peso 0.3)

Selecionar **um** domínio por pergunta. Se ambíguo, escolher o de maior `Dmax`.

### B.1) Engenharia de Software (Dmax = 42)

| # | Critério | Peso | Ancoragens |
|---|----------|------|-----------|
| **E1** | **Superfície de API exposta** (Hyrum's Law / SemVer) | **4** | 0: função privada / 1: módulo interno / 2: API entre times / 3: API pública com clientes externos |
| **E2** | **Reversibilidade de schema/dados** | **4** | 0: in-memory / 1: cache / 2: migração aditiva / 3: DROP COLUMN, perda de dados |
| **E3** | **Security/compliance footprint** | **3** | 0: nenhum dado sensível / 1: logs / 2: PII tocado / 3: credenciais, auth, criptografia, GDPR/LGPD |
| **E4** | **Ambiguidade terminológica** (ClarEval A_T) | **3** | 0: termos precisos / 1: polissemia resolúvel pelo contexto / 2: termo do usuário com múltiplas interpretações plausíveis / 3: termo crítico não-resolvível ("otimizar", "limpar", "melhorar") |

### B.2) Marketing (Dmax = 36)

| # | Critério | Peso | Ancoragens |
|---|----------|------|-----------|
| **M1** | **Permanência da peça** | **4** | 0: post efêmero, A/B / 1: campanha trimestral / 2: landing page evergreen / 3: rebrand, logo, jingle, tagline permanente |
| **M2** | **Alinhamento com identidade existente** | **3** | 0: replica voz documentada / 1: pequena extensão / 2: território adjacente / 3: ruptura com tom/posicionamento |
| **M3** | **Segmento e ICP definidos** | **3** | 0: ICP explícito no brief / 1: inferível do produto / 2: múltiplos ICPs plausíveis / 3: ICP nuclear desconhecido |
| **M4** | **Reversibilidade de canal/distribuição** | **2** | 0: tweet / 1: email / 2: anúncio pago lançado / 3: comunicado de imprensa, parcerias anunciadas |

### B.3) Business & Startups (Dmax = 45)

| # | Critério | Peso | Ancoragens |
|---|----------|------|-----------|
| **B1** | **Tipo Bezos** (1-way vs 2-way door) | **5** | 0: experimento <1 semana / 1: feature reversível / 2: pivô parcial / 3: 1-way door (aquisição, contrato longo, demissão) |
| **B2** | **Falsificabilidade da hipótese** | **3** | 0: testável <1 semana com MVP / 1: sprint / 2: requer dados inexistentes / 3: hipótese de visão de longo prazo |
| **B3** | **Compromisso financeiro/legal irrecuperável** | **4** | 0: zero burn / 1: <1% runway / 2: 1–10% runway ou contrato revisável / 3: >10% runway, exclusividade, equity |
| **B4** | **Stakeholder externo no loop** | **3** | 0: decisão interna / 1: cofundador / 2: investidor informado / 3: cliente ou board precisa aprovar |

---

## 5) Função de Agregação

```
score_final = 0.7 × (100 × ΣG / 78)
            + 0.3 × (100 × ΣD / Dmax_domínio)

onde:
  ΣG = Σ(G_i × peso_i)  para i ∈ {1..8}
  ΣD = Σ(D_j × peso_j)  para j ∈ critérios do domínio escolhido

  Dmax_eng = 42, Dmax_mkt = 36, Dmax_biz = 45
```

Score final ∈ [0, 100] sempre.

---

## 6) Thresholds e Outputs

| Score | Output | O que o agente faz |
|-------|--------|--------------------|
| **0 ≤ s < 35** | **Tipo 2 — ASSUME silenciosamente** | Toma a decisão default e segue. **Não** menciona ao usuário (a menos que ele pergunte depois). |
| **35 ≤ s ≤ 60** | **Tipo 3 — ASSUME + footnote** | Toma a decisão e registra footnote no formato §7 abaixo. Adiciona ao buffer de footnotes que será apresentado no fim. |
| **s > 60** | **Tipo 1 — PERGUNTA** | Interrompe o usuário. Apresenta a pergunta uma de cada vez, com **recomendação** (mesma regra do `grill-me` original). Aguarda resposta. |

---

## 7) Formato de Footnote (Tipo 3)

Prefixo `▸ assumi:`, ≤300 caracteres, sem markdown decorativo.

```
▸ assumi: <decisão em 1 frase>.
  alternativas: <2–3 opções separadas por |>.
  trade-off: <1 frase com a dimensão dominante>.
  reverter: <ação ou comando, opcional>.
```

**Exemplo:**
```
▸ assumi: PostgreSQL com `jsonb` para o campo de metadata.
  alternativas: tabela normalizada | DocumentDB | MongoDB.
  trade-off: flexibilidade de schema vs. queryability — escolhi `jsonb` por índices GIN + ACID.
  reverter: ALTER TABLE ... DROP COLUMN metadata.
```

**Sem** pergunta de confirmação ao final ("isso está ok?"). Sem "reverter:" se trivialmente reversível.

---

## 8) Audit log

Cada decisão (Tipo 1/2/3) é registrada em `.claude/decisions.jsonl` (cwd corrente):

```json
{"ts":"2026-05-17T14:32:00Z","question":"qual ORM?","scores":{"G":[2,1,1,2,1,1,1,1],"D":{"domain":"eng","values":[1,0,0,0]}},"score_final":34.2,"output":"tipo2","decision":"Drizzle","short_circuit":null}
```

Campos obrigatórios: `ts`, `question`, `scores`, `score_final`, `output`, `short_circuit` (id ou null), `decision`.

---

## 9) Exemplos de calibragem (referência rápida)

**Trivial → Tipo 2:** *"Adicione try/catch nesta função de parsing JSON."* G1=0, G2=0, G3=1, G4=1, G5=1, G6=0, G7=1, G8=0. ΣG=12 → 15.4 normalizado × 0.7 = **10.8**. Assume e segue.

**Médio → Tipo 3:** *"Escreva headline da landing page."* G1=1, G2=1, G3=1, G4=2, G5=3, G6=1, G7=1, G8=1. M1=2, M2=1, M3=1, M4=0. Score ≈ **43**. Assume com footnote.

**Auth → Tipo 1 por F8 short-circuit:** *"Refatore módulo de autenticação para OAuth2."* Mesmo que o score caísse em Tipo 3, **F8 dispara** → Tipo 1. Pergunta direcionada.
