# Probe endpoints, prefixos de key e links de revogação

Catálogo consumido pelo `SKILL.md` (captura camada 1, verificação live-probe, link de revogação
do report). Manter enxuto — adicionar ferramenta sob demanda quando o usuário a usar na prática.

> **[SUPOSIÇÃO]** o conjunto abaixo cobre as ferramentas mais usadas. Ferramenta sem probe
> conhecido cai no **fallback de formato** (mais fraco, declarado no report).

## Tabela por ferramenta

| Ferramenta | Prefixo da key (camada 1) | Live probe (camada 1 da verificação) | Link de revogação (report R4) |
|------------|---------------------------|--------------------------------------|-------------------------------|
| OpenAI     | `sk-`, `sk-proj-`         | `GET https://api.openai.com/v1/models` (header `Authorization: Bearer`) | https://platform.openai.com/api-keys |
| GitHub     | `ghp_`, `github_pat_`     | `gh api user` (ou `GET https://api.github.com/user`) | https://github.com/settings/tokens |
| Resend     | `re_`                     | `GET https://api.resend.com/api-keys` | https://resend.com/api-keys |
| Slack      | `xoxb-`, `xoxp-`          | `GET https://slack.com/api/auth.test` | https://api.slack.com/apps (Tokens & Scopes) |
| GitLab     | `glpat-`                  | `GET https://gitlab.com/api/v4/user`  | https://gitlab.com/-/user_settings/personal_access_tokens |
| Google API | `AIza`                    | endpoint específico do serviço habilitado | https://console.cloud.google.com/apis/credentials |
| Vercel     | (sem prefixo estável)     | `GET https://api.vercel.com/v2/user`  | https://vercel.com/account/tokens |

## Notas

- **Camada 1 da captura** usa a coluna "Prefixo da key" como regex de busca sobre o texto da
  página pós-submit. Prefixos sem padrão estável (ex.: Vercel) caem direto na camada 2 (DOM) ou 3
  (pede ao usuário colar).
- **Live probe** é a verificação preferida (Princípio 14): `200` = key real. `401`/`403` =
  inválida ou escopo errado → entra no loop auto-fix 3x.
- **Fallback de formato** (quando não há probe): valida prefixo + comprimento esperado. Declarar
  no report que a garantia é mais fraca.
- **Link de revogação** é best-effort (R4): se a ferramenta não está na tabela, o report aponta a
  página genérica de settings/tokens da ferramenta.
