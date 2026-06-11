---
name: domain-docs
description: Biblioteca interna (não-invocável) com os formatos canônicos de CONTEXT.md e docs/adr/ e as regras de escrita compartilhadas pelas 6 skills de planejamento. O que faz — centraliza formato + regras de criação lazy, gate triplo de ADR, modo inline vs batch, transbordo HST e materialização. Quando usar — referência lida via Read pelas skills consumidoras (grill-me, grill-with-docs, auto-grill-me, react-feynman) e pelos commands planejadores (/plan, /full-planning-cycle, /full-cycle, /full-cycle-simple); não é disparada pelo usuário.
disable-model-invocation: true
---

# domain-docs — biblioteca de docs de domínio

Fonte única dos formatos de `CONTEXT.md` (glossário de domínio) e `docs/adr/`
(decisões hard-to-reverse) e das regras de **quando** e **como** escrevê-los. As 6
skills/commands de planejamento consomem daqui em vez de duplicar as regras —
correção de formato propaga sem sincronização manual (mesma mecânica do
`auto-grill-me/references/DOD-MAPPING.md`).

Formatos canônicos:

- [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md) — estrutura do glossário (`**Termo**: def` + `_Avoid_` + Relationships), single vs multi-context (`CONTEXT-MAP.md`).
- [ADR-FORMAT.md](./ADR-FORMAT.md) — template do ADR (`docs/adr/NNNN-slug.md`, 1–3 frases), seções opcionais, numeração.

## Como as consumidoras usam esta biblioteca (mecanismo de consumo)

As skills consumidoras **leem os arquivos desta biblioteca via `Read`** num caminho
fixo — `~/.claude/skills/domain-docs/SKILL.md`, `.../CONTEXT-FORMAT.md`,
`.../ADR-FORMAT.md` — e seguem as regras inline. Não há auto-invocação de skill no
caminho: `disable-model-invocation: true` **só impede o disparo espontâneo** desta
skill pelo modelo; ela continua plenamente legível por path. É uma biblioteca de
referência, não um gatilho. (O caminho versionado no repo é `skills/domain-docs/`;
`./sync.sh install` o espelha pra `~/.claude/skills/domain-docs/`.)

## Criação lazy + anúncio de 1 linha

Crie arquivos **só quando há algo pra escrever**. Sem `CONTEXT.md`? Crie um quando o
**primeiro termo de domínio** for resolvido. Sem `docs/adr/`? Crie o diretório quando
o **primeiro ADR** for necessário. Sessão sem termo de domínio não cria nada.

Não pergunte antes de criar — **anuncie em 1 linha** no chat (ex: "Criando
`CONTEXT.md` — primeiro termo de domínio resolvido: **Slot**."). O gate é semântico
(sem termo, sem arquivo); o anúncio + o diff do PR dão visibilidade sem interromper o
fluxo.

Não acople o `CONTEXT.md` a detalhes de implementação. Só termos significativos pra um
especialista de domínio — antes de adicionar, pergunte "isto é único deste contexto ou
é conceito geral de programação?". Só o primeiro entra (regra completa em
CONTEXT-FORMAT.md).

## Gate triplo de ADR

Só ofereça/crie um ADR quando **as três** forem verdade:

1. **Hard to reverse** — o custo de mudar de ideia depois é relevante.
2. **Surprising without context** — um leitor futuro vai se perguntar "por que fizeram assim?".
3. **The result of a real trade-off** — havia alternativas genuínas e uma foi escolhida por razões específicas.

Se qualquer uma faltar, pule o ADR. (Detalhe e exemplos do que qualifica em ADR-FORMAT.md.)

## Termo OBSERVADO vs termo CUNHADO pela solução

Escrever `CONTEXT.md` antes da aprovação do plano é seguro **só pra terminologia que é
fato do domínio**. Distinga:

- **Termo OBSERVADO** — existe no repo/código/conversa **independente da solução
  proposta** (ex: o domínio já fala de "Fulfillment"; o código já tem "Slot"). É fato.
  → **Escreve no `CONTEXT.md` ao persistir o plano** (modo batch), mesmo antes da aprovação.
- **Termo CUNHADO pela solução** — vocabulário que **só existe porque esta solução o
  introduziu** (ex: a abordagem proposta inventa "SlotLease"). Não é fato ainda — se o
  adversarial review derrubar a abordagem, o glossário ficaria poluído com vocabulário
  de uma solução morta. → **Viaja com os `## ADRs propostos` do plano e materializa no
  `CONTEXT.md` só na aprovação**, junto com os ADRs.

Na dúvida, trate como cunhado (espera a aprovação) — falso-negativo custa 1 linha
tardia; falso-positivo polui o glossário canônico.

## Modo inline (grills) vs modo batch (planejamento não-interativo)

O **timing** da escrita é híbrido por maturidade da decisão.

### Modo inline — grills interativos

Usado por `grill-me`, `grill-with-docs`, `auto-grill-me` e a Fase 0 dos ciclos. No
grill, a **decisão cristalizada com o usuário JÁ é a decisão** — escreva na hora:

- Termo resolvido → atualize o `CONTEXT.md` ali mesmo (não acumule em batch).
- Decisão que passa no gate triplo → ofereça o ADR e, aceito, escreva em `docs/adr/`.
- Desafie contra o glossário, sharpen de termos vagos, cross-reference com o código —
  tudo capturado inline conforme acontece.

`auto-grill-me` tem uma restrição extra: só a **pergunta efetivamente respondida pelo
usuário** vira termo no glossário. Assunção silenciosa (score baixo/médio, assumida sem
perguntar) **não** é decisão do usuário e **não** vai pro `CONTEXT.md`.

### Modo batch — planejamento não-interativo (persiste plano)

Usado por `/plan` (react-feynman) e pela produção do plano nos ciclos. A decisão só
existe quando alguém com autoridade a aceitou; no fluxo de plano o aceite é a
**aprovação do plano**, não a redação dele. Então:

- **Ao persistir o plano:** escreva no `CONTEXT.md` apenas os **termos OBSERVADOS**
  (modo batch, com anúncio de 1 linha).
- **ADRs ficam pendentes:** o plano carrega uma seção `## ADRs propostos` com o **texto
  INTEGRAL** de cada ADR (não só o título). Plano rejeitado → nada toca `docs/adr/`.
- **Termos cunhados pela solução** ficam dentro dos `## ADRs propostos` e materializam
  junto, na aprovação.

### Gates de materialização (por fluxo)

A seção `## ADRs propostos` vira arquivo(s) em `docs/adr/` (e os termos cunhados entram
no `CONTEXT.md`) no momento do **aceite de cada fluxo** — numeração resolvida na hora:

| Fluxo | Gate de materialização |
|-------|------------------------|
| `/plan` standalone | aceite do usuário no plano — materialize **ANTES de qualquer outra ação** |
| `/full-planning-cycle` | veredito **APROVADO** da revisão adversária (se **APROVADO COM RESSALVAS**, incorpore as ressalvas no texto **primeiro** — o ADR registra a decisão final, não a proposta) |
| `/full-cycle` e `/full-cycle-simple` | início da fase de execução (pós-gate de aprovação) |

### Marcador de quitação

Ao materializar, emita o marcador `<!-- adr-materialized -->` na seção `## ADRs
propostos` do plano (idealmente com uma linha apontando o(s) arquivo(s) criados). O
marcador **quita** a seção: silencia o warning best-effort do Stop hook
(`hooks/adr-materialize-warn.sh`) que cobre o caso de plano aprovado cujos ADRs nunca
viraram arquivo. Seção sem marcador + sem mudança em `docs/adr/` = ADR esquecido.

## Conflito add/add em `docs/adr/NNNN-*`

A numeração é resolvida na materialização, então dois slots/branches concorrentes podem
materializar ADRs **com o mesmo número** (`docs/adr/0004-*.md` em ambos) e colidir no
merge. Regra: em conflito **add/add**, **renumere pro próximo número livre** — a
numeração é ordinal cosmético; **o slug identifica a decisão**. Não há merge de
conteúdo a fazer: são decisões distintas que pegaram o mesmo ordinal. (Buraco na
sequência por revert também é aceitável: numeração é append-only.)

## Transbordo HST (Hierarchical Systems Thinking)

No Modo HST do `react-feynman`, o **System Intent** (Fase 1) permanece em store próprio
(cache de Q&A por tier projeto/feature, lifecycle delete-then-rewrite) — **não** vai pro
`CONTEXT.md`. Regra de transbordo pra não prender conhecimento no cache:

- **Termo de domínio** resolvido em qualquer fase HST → transborda pro `CONTEXT.md`
  (glossário curado e versionado).
- **Restrição global** que passa no **gate triplo** → vira **ADR proposto** (entra nos
  `## ADRs propostos`, materializa na aprovação — Fase 6/Roadmap).

## Gotchas

- **Ponteiro vs canônico (deriva de formato):** `skills/grill-with-docs/CONTEXT-FORMAT.md`
  e `.../ADR-FORMAT.md` são **ponteiros de 1 linha** pra cá — não edite o formato lá. A
  fonte da verdade é `skills/domain-docs/`. Editar o ponteiro recria a duplicação que
  esta biblioteca existe pra matar.
- **`disable-model-invocation` ≠ ilegível:** a flag impede o disparo espontâneo da skill,
  **não** o `Read` por path. Consumidora que tentar "invocar" a skill em vez de ler os
  arquivos falha silenciosamente — o contrato é ler `~/.claude/skills/domain-docs/*.md`.
- **Gate de materialização é prompt-driven:** instrução de prompt sem backstop não dispara
  — foi a classe de falha que zerou a telemetria DoD (0 eventos em 11–15 dias até virar
  Stop hook determinístico). Por isso o marcador `<!-- adr-materialized -->` + o warning
  do Stop hook existem: a instrução sozinha não basta.
- **`CONTEXT.md` inchado com termo genérico:** planejadora não-interativa tende a registrar
  termo de programação geral (timeout, retry, error type), proibido pelo formato. Aplique
  o teste "único deste contexto?" antes de cada termo.
- **Sync obrigatório:** `~/.claude/skills/` **não** é symlink do repo. Editar
  `skills/domain-docs/` só vale após `./sync.sh install` (laptop) ou o auto-sync do
  `.vm-profile` (VMs). Mudança não-sincronizada não é vista pelas consumidoras.
