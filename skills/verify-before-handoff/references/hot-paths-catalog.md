# Catálogo de caminhos quentes + classificador grosso

> Referência operacional consumida pelo hook `hooks/verify-before-handoff-guard.sh` (US-02).
> O SKILL.md tem o resumo; este arquivo tem o detalhamento. **Genérico, não Resend-específico**
> (Finding #2): nenhuma assinatura de e-mail vive no `dotclaude`; calibração fina ocorre no repo
> emissor.

## Princípio do classificador

Detectar **efeito externo mutante** — ações cujo resultado um humano veria fora da máquina e que
não são trivialmente reversíveis. Não detecta correção do output (impossível por regex no caso
geral); apenas **força a verificação** onde o caminho é detectável.

## Sinais (genéricos)

### 1. Tool MCP por verbo no nome

Nome da tool casa (case-insensitive) um destes verbos:

| Verbo     | Exemplos de tool |
|-----------|------------------|
| `send`    | `*__send_message`, `*__send_email` |
| `create`  | `*__create_draft`, `*__create_file`, `*__create_label` |
| `delete`  | `*__delete_label`, `*__delete_file` |
| `deploy`  | `*__deploy`, `*__deploy_site` |
| `publish` | `*__publish`, `*__publish_post` |

### 2. Bash HTTP mutante externo

`curl` / `http` / `wget` com método mutante contra domínio **externo**:

- método `-X POST|PUT|DELETE|PATCH`, ou payload (`--data`, `-d`, `--upload-file`, `-T`);
- host não-loopback (não `localhost`/`127.0.0.1`/`0.0.0.0`).

### 3. CLI de efeito externo não-HTTP

Disparo de efeito externo que **não** passa por cliente HTTP (escapava do sinal 2). Padrões:

- `sf apex run` / `sfdx force:apex:execute` → Apex anônimo contra org viva = efeito arbitrário
  (e-mail, DML). Assinatura `cli:sf-apex-run[:<org>]`;
- `Database.executeBatch` no corpo → batch Apex (envio em massa). Assinatura `cli:apex-executeBatch`;
- `Messaging.sendEmail`/`sendSingleEmailMessage` no corpo → envio direto. Assinatura `cli:apex-sendEmail`.

A org alvo (`--target-org`/`-o`/`-u`) entra na assinatura → **prod e sandbox promovem soft→hard
separadamente** (o hot recorrente que importa é o de produção). Origem: incidente survey-egressos
2026-07-16 (`sf apex run` → `Database.executeBatch` disparou 4.777 e-mails, passou como cold).

**E-mail com link → smoke test nas duas vias.** Quando o efeito é e-mail que leva a uma URL, o piso
de evidência inclui abrir o caminho do destinatário via **curl** (status + header `alt-svc`, pega
CDN/HTTP-3/QUIC) **e** **Playwright** (carregar real, pega falha de 1º connect). E2E que mocka a
rota (`route.fulfill`) valida o form, não substitui o smoke do caminho público DNS→CDN→origem.

## Não-hot (cold) — exemplos

- `Read`, `Glob`, `Grep`, `git status`, `git log` (leitura);
- `curl -X GET` / `curl` sem método mutante (leitura);
- POST/PUT contra `localhost` (dev local, não efeito externo observável pelo usuário);
- `sf data query` / SOQL / `sf org list` (leitura SF — não dispara o sinal 3).

## Tiers (gradiente soft → hard, espelha supply-chain cooldown→block)

- **soft (candidato):** classificador casou pela 1ª/2ª vez. Reminder **curto, não-bloqueante** —
  só sugere verificar o realizado. Cobre o cold-start.
- **hard (promovido):** assinatura vista **≥ N vezes** (N=2 default, configurável) no
  `audit.jsonl`. Reminder **forte/obrigatório**. Endurece o falso-positivo do soft sob evidência
  de recorrência real.

Intervenção humana = **1 constante** (threshold N). Tudo o mais cresce sozinho via `audit.jsonl`.

## Fixtures de referência (consumidas pelo teste do hook em US-02)

| Input | Classificação |
|-------|---------------|
| `curl -X POST https://api.externa/x` | hot |
| `git status` | cold |
| `*__create_draft` (tool MCP) | hot |
| `Read` (tool) | cold |
| `sf apex run --target-org acme-prod --file x.apex` | hot (`cli:sf-apex-run:acme-prod`) |
| `… Database.executeBatch(new …Batch(), 100) … \| sf apex run` | hot (`cli:apex-executeBatch`) |
| `… Messaging.sendEmail(msgs); … \| sf apex run -o prod` | hot (`cli:apex-sendEmail:prod`) |
| `sf data query --query "SELECT Id FROM Contact" -o prod` | cold |
