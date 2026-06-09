---
name: verify-before-handoff
description: Operacional do Princípio 14 — verificar funcionalmente o output antes de qualquer claim de conclusão ou de pedir verificação ao usuário. Confirma o resultado REALIZADO (não a intenção), com auto-fix 3x para falha mecânica e escala para ambíguo/destrutivo. Use ao verificar antes de entregar, confirmar output, auto-verificação, antes de dizer "feito"/"enviei"/"funciona", ou antes de pedir ao usuário para olhar algo que você produziu (email, deploy, arquivo, output externo). Delega a verify/testing no caso código.
---

# verify-before-handoff — operacional

Operacional pra Claude **confirmar funcionalmente o resultado que produziu antes de entregá-lo**.
Governado pelo **Princípio 14** da `CLAUDE.md`. Companheira determinística: hook
`hooks/verify-before-handoff-guard.sh` (US-02) nos caminhos quentes detectáveis.

> **Origem (rastreável):** sessão `/grill-me` 2026-06-05. Incidente motivador: Claude montou e
> mandou enviar e-mails de teste **vazios** (corpo em branco) e pediu ao usuário para olhar a
> caixa de entrada — verificou a **intenção** ("montei e disparei"), nunca o **resultado**
> ("o e-mail que chegou tem corpo?"). Plano-fonte: `.claude/plans/2026-06-06T02-02-40Z-verify-before-handoff.md`.

## Gatilho (largo, Decisão 2)

Dispara em **qualquer claim de conclusão** — "feito", "pronto", "enviei", "funciona", "deployado",
"o arquivo está lá" — **e** em qualquer **handoff de verificação** (pedir ao usuário para olhar /
confirmar algo que você produziu). O handoff é a instância de **tolerância zero**: nunca é
dispensável, porque é exatamente onde o e-mail vazio passou.

Regra binária: **antes de afirmar ou pedir, observe o realizado.**

## Padrão de evidência (Decisões 3 e 4)

Confirmação **funcional ponta-a-ponta**, sempre — não a intenção. "Intenção ≠ resultado: observe o
realizado." O custo é aceito em troca de margem zero.

Fronteiras da palavra "funcional" (para não virar regresso infinito e-mail → link → servidor → …):

- **Teto = valor de usuário.** Siga a cadeia de efeito até onde um humano veria valor: não só
  "o e-mail saiu", mas "o e-mail que chegou tem corpo"; não só "subiu o deploy", mas "a página
  carrega". Esse é o **bar máximo**, atingido **só quando a tarefa o define** (ver Tensão abaixo).
- **Fronteira operacional = critério de aceitação.** Quando existe DoD/AC, ele fixa onde parar:
  verifique até satisfazer o critério, não além.
- **Piso prático = observar o artefato realizado.** Sem DoD explícito, o mínimo não-negociável é
  **olhar o resultado concreto** — abrir o e-mail enviado, ler o arquivo escrito, fazer GET do
  recurso criado, rodar o binário gerado. Nunca inferir sucesso da ausência de erro.

Caso **código**: **delega** para a skill `verify` (rodar o app e observar) e `testing` (TDD /
asserções fortes). Esta skill não reimplementa verificação de código.
Caso **não-código** (e-mail, deploy, arquivo, output externo): esta skill **agrega o valor** —
é onde `verify`/`testing` não alcançam.

## Loop de auto-fix quando a verificação PEGA um problema (Decisão 6)

Híbrido por natureza da falha:

1. **Falha mecânica óbvia** (corpo vazio, status HTTP errado, arquivo truncado, campo faltando):
   **auto-fix limitado a 3 tentativas** (alinhado ao `/ship`).
2. **Falha ambígua ou destrutiva** (causa não-clara, ou o fix pode piorar/apagar estado):
   **escala imediato** — para e reporta ao usuário, não tenta adivinhar.

Invariante crítico: **cada tentativa re-roda a MESMA verificação funcional** (o padrão de evidência
acima). É "fix → re-verifica → repete", **nunca** "fix → assume resolvido". Estourou 3× sem passar
a verificação funcional → para e reporta (auto-fix cego em falha mal-diagnosticada gera 3 commits
piorando o estado).

## Caminhos quentes — classificador grosso (Decisão 5, escopo do Finding #2)

Catálogo + classificador que o hook backstop (US-02) usa para *forçar* verificação onde dá pra
detectar. O classificador é **genérico, não Resend-específico** — não há caminho de envio de e-mail
no repo `dotclaude`; a calibração fina de assinatura de e-mail ocorre **no repo que de fato envia**.
Sinais genéricos (efeito externo mutante):

- **Tool MCP** cujo nome casa o verbo `send | create | delete | deploy | publish`.
- **Bash HTTP mutante externo:** `curl`/`http`/`wget` com `-X POST|PUT|DELETE|PATCH` (ou
  `--data`/`--upload`) contra domínio **externo**.

Detalhamento (regex, fixtures, tiers soft/hard, auto-promoção por `audit.jsonl`):
`references/hot-paths-catalog.md`.

## Tensão com o Princípio 1 (tarefas triviais isentas)

O Princípio 1 isenta tarefas triviais (renomear, formatar, lint) do ciclo ReAct. Aplicar
"cadeia até valor de usuário" a um rename de variável é absurdo e custa tempo/tokens.

Resolução: **"valor de usuário" é o TETO**, atingido **só quando a tarefa o define** (há um critério
de aceitação que aponta para lá). Para a tarefa trivial, o **piso prático** se aplica: observar o
artefato realizado (o rename compila? o lint passou de fato?) — não escalar a cadeia até o usuário.
A skill não contradiz o Princípio 1: ela usa o critério de aceitação como fronteira e o
artefato-realizado como piso, em vez de exigir a cadeia completa em todo caso.

## Gotchas (erros reais observados)

- **E-mail vazio entregue (incidente motivador).** Claude verificou que *montou e mandou enviar* o
  e-mail e pediu ao usuário para olhar — o corpo chegou **em branco**. Verificar a intenção
  ("disparei") não é verificar o resultado ("o que chegou tem corpo?"). Sempre **abra/leia o
  artefato realizado**, mesmo quando "não deu erro". Ausência de erro **não** é evidência funcional.
- **Falso-positivo do classificador soft.** O tier soft dispara em **todo** POST externo-mutante,
  inclusive POSTs inofensivos (telemetria, health-ping, append de log). Risco: fadiga de reminder →
  o modelo passa a ignorar o sinal. Por isso o soft só **sugere** (texto curto, não bloqueia); só o
  tier **promovido** (assinatura vista ≥ N vezes via `audit.jsonl`) injeta reminder forte. Se a taxa
  de disparo soft ficar alta demais, **aperte o classificador** — não trate todo reminder soft como
  obrigação de verificação pesada.

## Deploy / propagação

Esta skill vive no repo `dotclaude` (fonte versionada) e propaga para `~/.claude/skills/` via
`sync.sh install`. O **registro** do hook companheiro em `~/.claude/settings.json` também é feito
pelo `sync.sh install` (`register_verify_handoff_hook`, matcher `Bash|mcp__.*`, timeout 5000ms,
command com `$CLAUDE_DIR` portável /Users↔/home) — US-02 reverteu a decisão machine-local de
registro manual (Finding #4), que falhou empiricamente em 2 de 3 máquinas.
