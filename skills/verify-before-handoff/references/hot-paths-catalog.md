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

## Não-hot (cold) — exemplos

- `Read`, `Glob`, `Grep`, `git status`, `git log` (leitura);
- `curl -X GET` / `curl` sem método mutante (leitura);
- POST/PUT contra `localhost` (dev local, não efeito externo observável pelo usuário).

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
