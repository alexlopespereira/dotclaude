---
name: browser-secrets
description: Provisiona credenciais via browser proativamente — escreve no .env e verifica antes de reportar. Quando usar: criar token, gerar API key, provisionar secret, fazer setup ferramenta web, falha 401/403 / env var ausente mid-task, renovar credencial expirada, ou rotacionar secret por higiene. O que faz: checa se já existe, captura sem vazar no transcript, escreve no .env (guarda .gitignore), verifica com live probe, reporta mascarado, registra no inventário de expiração; renovação/rotação com probe OK antes de revogar a antiga; free/low-risk proativo, Zona 3/custo/destrutivo mantém confirm gate. Delega browser a browser-actions.
---

# browser-secrets — operacional

Operacional pra Claude **provisionar credenciais e fazer setup em ferramentas web por conta
própria**, em vez de empurrar a tarefa pro usuário. Governado pelo **Princípio 12** da
`CLAUDE.md` (ramo 1B da entrevista de design).

> **Origem (rastreável):** sessão `/grill-me` 2026-06-08. Pedido do usuário: "Claude deve usar
> o Playwright sempre que precisar criar token/secret/key ou fazer setup numa ferramenta web já
> cadastrada; ferramentas ficam autenticadas no navegador; agir com proatividade e reportar
> depois." Plano-fonte: `.claude/plans/2026-06-08T11-33-20Z-browser-secrets-proativo.md`.

## Relação com o Princípio 12 (ramo 1B) — autonomia, não precedência

Esta skill **vive DENTRO da escada** do Princípio 12, não a substitui. A escada de precedência
continua valendo na ordem **CLI > MCP > API > Playwright MCP**.

O que esta skill muda é **autonomia, não precedência**: hoje Claude tende a parar e **empurrar**
o setup web pro usuário ("crie a key no dashboard e me passe"). A regra nova é que Claude **faz
ele mesmo** quando a escada cai naturalmente na UI web.

**CLI vence quando há caminho limpo.** Se existe subcomando de domínio que cria a credencial sem
browser — ex.: `aws iam create-access-key`, `gh auth token`, `gcloud iam service-accounts keys
create` — usa a CLI e **não abre o browser**. O browser (nível 4) só entra quando CLI/MCP/API
não cobrem a criação (a maioria dos dashboards de API key — OpenAI, Vercel, Resend — não tem CLI
de criação). `[INFERÊNCIA]` o gap real do pedido não é "qual ferramenta" e sim a autonomia de
agir no nível 4 sem devolver a tarefa pro humano.

## Gatilhos (3 fontes) + check-exists-first

> **Preflight consolidado:** em tarefa longa multi-serviço, o gatilho 1 (falha mid-task) deve
> ser antecipado pelo probe único do início de tarefa — skill `auth-preflight`
> (`bin/auth-preflight.sh`), que agrega todas as renovações num pedido só.

A skill dispara em **qualquer** dos 3 gatilhos:

1. **Falha de auth mid-task (401/403).** Uma chamada autenticada falha no meio de outra tarefa —
   sinal de credencial ausente/expirada pra aquela ferramenta.
2. **Intent de setup.** O usuário pede explicitamente pra criar token / gerar API key /
   provisionar secret / configurar ("setup") uma ferramenta web.
3. **Env var referenciada-mas-ausente.** O código/tarefa referencia uma env var (ex.:
   `OPENAI_API_KEY`) que não existe no `.env` nem no ambiente.

### Precondição: check-exists-first (antes de provisionar)

**Nunca crie uma credencial nova sem antes checar se já existe.** Verifica, nesta ordem:

1. **`.env` do projeto** — `grep` pela chave alvo (`OPENAI_API_KEY=...` com valor não-vazio).
2. **`~/.claude/secrets/`** — store local de segredos por ferramenta, se presente.
3. **CLI da tool** — se a ferramenta tem CLI que reporta credencial existente (ex.: `gh auth
   status`, `aws configure list`), consulta antes de criar uma nova.

Se já existe e é válida (passa o probe da seção de verificação), **não cria outra** — reusa.

### Regra de desambiguação

**Pergunta se a tool ou a credencial é ambígua.** Se não está claro qual ferramenta provisionar,
qual tipo de credencial, ou qual escopo, **pausa e pergunta 1x** antes de agir — não inventa.

## Destino `.env` + guarda de `.gitignore` (Princípio 7)

O segredo é escrito no **`.env` do projeto corrente** (`./.env`), nunca em arquivo versionado.

**Guarda obrigatória — verifica ANTES de escrever:** confirma que o `.gitignore` do projeto
cobre `.env`. Se **não** cobre, **adiciona a entrada `.env` ao `.gitignore` ANTES** de escrever o
segredo. Isso fecha o vetor do Princípio 7 (nunca versionar segredo) na origem — sem depender só
do secret-scan do commit como backstop. Sem `.gitignore` cobrindo `.env`, **não escreve**.

## Captura em camadas (R2) — não inventa segredo

Não existe seletor DOM universal entre dashboards heterogêneos. A captura é **em 3 camadas**, em
ordem de preferência:

1. **Primário — regex de prefixo conhecido.** Casa um prefixo de API key estável (`sk-`, `ghp_`,
   `re_`, `xoxb-`, `xoxp-`, `glpat-`, `AIza`, ...) sobre o **texto da página logo após o submit**.
   Prefixos de API key são distintivos e estáveis entre redesigns de layout. Catálogo de prefixos
   em `references/probe-endpoints.md`.
2. **Secundário — seletor DOM perto de Copy/Reveal.** Se o regex não casa, lê o campo adjacente
   ao botão "Copy"/"Reveal"/"Show" via `browser_evaluate`.
3. **Ambos falham → pausa e pede ao usuário colar.** Se nenhuma camada captura, **não inventa** e
   **não reporta sucesso** — pausa e pede pro usuário colar a key no chat.

A captura nunca ecoa o segredo cru: escreve direto no `.env`, e o `browser_evaluate` retorna
apenas confirmação mascarada (ver abaixo) — nunca o valor cru no tool-output persistido.

**Caminho de captura fora do transcript:** `bin/secret-capture.sh` (dotclaude) empacota as
camadas 1–2 num wrapper que captura via driver Playwright local (ou drop file com
`--from-drop`), escreve no `.env` com guarda de `.gitignore` e chmod 600, roda probe opcional e
emite **só o tail mascarado no stdout** — o valor cru nunca passa pelo transcript nem por argv.
Prefira-o à captura manual via `browser_evaluate` quando o wrapper cobre o caso.

Duas restrições do wrapper (deliberadas):

- **Zona 3:** `--url` em domínio sensível da blocklist da `browser-actions` é **bloqueado
  (exit 7)** — o driver navega o Chrome autenticado fora do alcance do hook MCP. Confirme com o
  humano e re-rode com `--allow-sensitive` (override auditado em stderr).
- **Lock do perfil:** se o MCP Playwright está vivo no mesmo slot, o driver **aborta (exit 4)**
  em vez de cair num profile efêmero — captura precisa dos cookies autenticados do perfil real.
  Feche o MCP do slot (ou use `--slot` de um perfil livre e logado) antes de capturar.

## Confirmação MASCARADA no chat (Princípio 7)

A confirmação no chat **sempre** mascara o segredo: mostra só os **últimos 4 chars** com o
prefixo, ex.: `sk-...AbCd`. O **segredo cru nunca é ecoado no transcript** — nem no chat, nem no
retorno de tool, nem no audit log.

## Verificação antes de reportar (Princípio 14)

Antes de qualquer claim de "pronto", verifica **funcionalmente** a credencial — delega a
`verify-before-handoff` (operacional do Princípio 14). Caminho de verificação, em ordem:

1. **Live probe (preferido).** Uma chamada autenticada barata: `GET /v1/models` (OpenAI),
   `gh api user` (GitHub), etc. — catálogo em `references/probe-endpoints.md`. `200` = key real e
   válida.
2. **Fallback assert de formato.** Se a ferramenta não tem probe conhecido, valida formato
   (prefixo + comprimento esperado). Sinal mais fraco — **declarado como tal no report**.
3. **Loop auto-fix 3x.** Se o probe falha (401/403/formato inválido), **regenera** a credencial e
   re-verifica, até 3 tentativas. Probe falho com formato OK pode ser escopo errado → ajusta
   escopo (least-privilege) e re-tenta.
4. **Escala.** Após 3 falhas, para e reporta o estado pro usuário — não afirma sucesso.

O **report nomeia explicitamente o caminho de verificação usado** (live probe vs fallback de
formato), pra o usuário saber a força da garantia.

## Proatividade tiered (R3) + gates de custo/risco

A proatividade é **condicionada a profile autenticado quente** (ver Gotchas). Quando o profile
está logado:

| Categoria | Comportamento |
|-----------|---------------|
| **Free / low-risk** (criar API key num dashboard já autenticado) | **Proativo, sem perguntar.** Cria, escreve, verifica, reporta depois. |
| **Zona 3** (`*.stripe.com`, bancos, healthcare) | Mantém **confirm gate** da `browser-actions` (blocklist) + Princípio 11. |
| **Custo** (Princípio 11 ramos b, c — recurso pago, billing) | Mantém confirm gate do P11 — **pergunta antes**. |
| **Destrutivo** (revogar/deletar credencial existente) | Mantém confirm gate (blocklist + P11 a). |
| **OAuth / multi-valor / input-inventado** (redirect URI, webhook endpoint, client secret + ID) | **Pergunta 1x** — não inventa valores estruturais. |

As exceções (a)–(e) do Princípio 11 e a blocklist de Zona 3 do Princípio 12 **continuam
valendo** — esta skill não as relaxa; só autoriza proatividade no caso free/low-risk.

## Renovação reativa autônoma (tiered)

Credencial que **falha mid-task (401/403) ou está expirada** (aviso do inventário via
`auth-preflight`/auto-morning, ou recusa do provedor) **não devolve a tarefa pro usuário**:
Claude renova ele mesmo, pela **escada do Princípio 12** (CLI > MCP > API > Playwright MCP), e
retoma a tarefa original do ponto onde falhou. A regra é
**renovar e reportar mascarado, não devolver a tarefa**.

O tiering vem do campo `tier` do inventário (`bin/secrets-expiry.sh list`); sem entrada no
inventário, infira pelo domínio (na dúvida, trate como paid):

| Tier | Comportamento na renovação |
|------|---------------------------|
| **free-low** | Renova **sem perguntar** — cria a nova, escreve no `.env`, verifica com probe, reporta mascarado depois. |
| **paid / zona3 / produção** | **confirma 1×** antes de renovar (gates P11 b–e + blocklist Zona 3); confirmado, segue autônomo até o report. |

Renovação **não é** rotação: renovar responde a uma falha/expiração; rotação é higiene
planejada (seção seguinte). A ordem de troca, porém, é a mesma ordem canônica da rotação —
nunca revogue a antiga antes da nova provar que funciona.

## Rotação (higiene)

Ordem canônica (criar nova → probe OK → revogar antiga → propagar → registrar) — cada passo
só depois do anterior confirmado; a âncora é **probe OK antes de revogar a antiga**:

1. **Criar a credencial nova** — fluxo normal de provisionamento desta skill (check-exists não
   se aplica: rotação cria de propósito uma segunda credencial coexistindo com a antiga).
2. **Probe da nova** — live probe do catálogo `references/probe-endpoints.md`.
3. **SÓ ENTÃO revogar a antiga** — usando o link de revogação do mesmo catálogo
   (`references/probe-endpoints.md`). Probe falhou → **não revoga**; a antiga continua válida
   enquanto se corrige a nova.
4. **Propagar aos consumers** — o campo `consumers` do inventário dirige a propagação: cada
   consumer listado (`.env`s de outros checkouts, keyrings de VMs, CI secrets) recebe o valor
   novo **antes** de a rotação contar como concluída. Consumer inacessível no momento →
   reporta como pendência explícita, não silencia.
5. **Registrar** — upsert via `bin/secrets-expiry.sh add` com a nova `--expires-at` (ver
   Registro no inventário, abaixo).

> **Incidente-fonte (rastreável):** o auto-pull da VM1 ficou quebrado **~1 semana** porque um
> PAT foi revogado sem propagar o valor novo ao keyring da VM — consumer não mapeado, quebra
> silenciosa só descoberta ao investigar o sync. A ordem canônica e a propagação dirigida por
> `consumers` existem por causa disso.

## Report + audit log

### Report no chat (sempre mascarado)

Após cada provisionamento, reporta no chat (segredo sempre mascarado): **tool**, **tipo** de
credencial, **escopo**, **destino** (`.env` do projeto), **verificação** (caminho usado +
resultado), **trigger** (qual dos 3 disparou), e **ação-do-usuário** necessária (se houver, ex.:
"logue no profile X").

### Link de revogação (R4 — best-effort)

O report emite **link de revogação quando conhecido** (catálogo em `references/probe-endpoints.md`);
se desconhecido, **aponta a página genérica de settings/tokens** da ferramenta. Best-effort, não
bloqueia.

### Registro no inventário de expiração (obrigatório)

Registrar a credencial no inventário é **passo obrigatório pós-provisão/renovação** — todo
provisionamento (e toda renovação/rotação) termina com upsert via **`bin/secrets-expiry.sh
add`** (`--key`, `--provider`, `--expires-at`, `--renewal-method`, `--tier`, `--consumers`).
Só metadados, **nunca o valor**. É esse registro que alimenta os avisos proativos
(auto-morning + `auth-preflight`), fornece o `tier` da renovação reativa e o `consumers` da
propagação na rotação.

### Audit log append-only

Acrescenta **uma linha** em `~/.claude/cache/browser-secrets/audit.jsonl` (criado on-demand,
espelha o padrão do `supply-chain-guard`; **não versionado**). Campos: `timestamp`, `tool`,
`domínio`, `tipo` de credencial, `tail` mascarado, `destino`, `resultado` da verificação.
**Nunca o segredo cru.** Exemplo de linha em `examples/report-and-audit.md`.

## Delegação a browser-actions (não duplica)

Toda a **mecânica de browser** é delegada a `browser-actions` — esta skill **não duplica**:

- **Auth pre-check** (redirect-pra-login / meta `user-login`) — `browser-actions`.
- **Anúncio de abertura + reanúncio por mudança de eTLD+1** — `browser-actions`.
- **Blocklist de Zona 3** (domínios sensíveis, trigger words, formulários de pagamento) —
  `browser-actions`.

Esta skill foca no **fluxo de credencial** (gatilho → check-exists → captura → `.env` →
verificação → report → inventário); o "como abrir/autenticar/proteger o browser" é
responsabilidade da `browser-actions`.

## Gotchas

- **(a) [R3] Proatividade é condicionada a profile autenticado quente.** Os profiles Chrome são
  **per-slot** (`browser-actions`); o **primeiro uso por profile/slot pode pausar 1x para login**
  — o protocolo de auth assistida da `browser-actions` dispara, anuncia e pede login. Ou seja:
  "proativo" não significa "nunca pausa"; significa "não devolve a tarefa pro usuário". Anuncie a
  pausa quando ela ocorrer.
- **(b) Key revelada-uma-vez é perdida se o scrape erra.** Muitos dashboards mostram o segredo
  **só 1x**; se a captura pega placeholder/campo errado, a key real se perde e só resta
  **regenerar** (não re-revelar). Por isso o assert de formato roda **antes** de fechar o modal, e
  o loop 3x regenera em vez de tentar re-ler.
- **(c) Scope inference / least-privilege.** Ao criar PAT/token com escopos, infira o **escopo
  mínimo** casado ao need detectado — nem amplo demais (risco), nem estreito demais (probe falha).
  Escopo incerto → pergunta (regra de desambiguação).
- **(d) Revogação prematura quebra consumers em silêncio.** Revogar a credencial antiga antes
  do probe OK da nova — ou sem propagar aos `consumers` do inventário — quebra consumidores
  remotos sem nenhum alarme local. Incidente real: o auto-pull da VM1 ficou quebrado
  **~1 semana** após rotação de PAT sem propagação ao keyring da VM. A ordem canônica da seção
  Rotação (probe OK antes de revogar a antiga → propagar → registrar) não é opcional.

## Referência rápida

- Princípio 12 — `CLAUDE.md` (escada CLI > MCP > API > Playwright MCP).
- Mecânica de browser — `~/.claude/skills/browser-actions/SKILL.md`.
- Verificação funcional — `~/.claude/skills/verify-before-handoff/SKILL.md`.
- Probe endpoints + prefixos + links de revogação — `references/probe-endpoints.md`.
- Exemplo de report + linha de audit — `examples/report-and-audit.md`.
- Audit log — `~/.claude/cache/browser-secrets/audit.jsonl` (on-demand, não versionado).
