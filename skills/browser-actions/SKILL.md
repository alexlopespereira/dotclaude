---
name: browser-actions
description: Operacional do Princípio 12 (browser-as-agent). Setup do MCP Playwright com Chrome dedicado, auth assistida via cookie pre-check, blocklist de Zona 3 (irreversíveis), lock multi-slot, troubleshooting. Use quando a escada de precedência cair em (4) Playwright MCP.
---

# browser-actions

Operacional pra Claude agir em nome do usuário via browser, quando CLI/MCP/API de domínio falham. Governado pelo **Princípio 12** da `CLAUDE.md`.

A precedência é definida no Princípio 12 — esta skill cobre só o "como" do nível (4) Playwright MCP. Não revisita o "quando".

## Quando usar / quando NÃO usar

**Use quando:**
- Não existe CLI de domínio capaz da operação (ou ela está em modo (b)/(c)).
- Não existe MCP de domínio capaz (idem).
- Não existe API documentada/permitida (idem).
- O alvo é uma UI web e a ação não tem endpoint público.

**NÃO use quando:**
- A operação é puramente de leitura local (Read, Bash, Grep resolvem).
- Existe `gh`, `aws`, `netlify`, `stripe`, `gcloud`, `kubectl`, etc. com o subcomando alvo. **Sempre tente CLI primeiro.**
- O usuário pediu "abre no browser" como navegação humana — abrir manual, sem MCP.
- O alvo está na blocklist e não há confirmação humana — pausar e perguntar.

## Setup operacional

MCP registrado no escopo `user` apontando pro wrapper de lock:

```bash
claude mcp remove playwright
claude mcp add --transport stdio --scope user playwright -- \
  /Users/dev/.claude/skills/browser-actions/wrapper-launch.sh
```

Wrapper internamente lança:
```
npx -y @playwright/mcp@latest \
  --user-data-dir "$HOME/.claude/chrome-profile" \
  --browser chrome
```

**Pré-requisitos** (provisionados pela Fatia 1 do handoff):
- `~/.claude/chrome-profile/` existe, `chmod 700`, excluído do Time Machine.
- `/Applications/Google Chrome.app/` instalado (verificado).
- Wrapper executável (`chmod +x`).

**Validação:** `claude mcp list | grep playwright` deve mostrar `✓ Connected`.

## Protocolo de auth assistida

Antes de qualquer ação que assume sessão autenticada, fazer **cookie pre-check** — não confiar que sessão herdada do perfil ainda é válida.

Sequência:

```
1. mcp__playwright__browser_navigate(url=alvo)
2. mcp__playwright__browser_evaluate(function="() => document.cookie")
3. Se vazio ou claramente sem cookie de sessão do domínio:
     → ANUNCIAR: "Vou abrir [domínio] no Chrome dedicado. Faça login e me avise quando estiver pronto."
     → Esperar resposta do usuário no chat ("ok", "pronto", ENTER).
     → Após resposta, re-checar cookie. Se ainda vazio, perguntar de novo.
4. Se houver cookie: tentar a ação. Se redirecionar pra /login → tratar como expirada → re-auth.
```

**Limitação conhecida (S1 do handoff):** `document.cookie` **não enxerga cookies httpOnly** (a maioria dos cookies de sessão modernos são httpOnly). Em casos de falso negativo:
- Tentar ação alvo direto.
- Se redirecionar pra /login ou retornar 401/403 → trigger fluxo de re-auth.
- Se possível, usar `mcp__playwright__browser_network_requests` pra inspecionar `Set-Cookie` em resposta de navegação inicial.

**Auth ausente NUNCA é skip pro próximo nível** (regra do Princípio 12 — (a) "auth ausente nunca é skip"). Sempre pede ao usuário.

## Cadência do anúncio

Anuncia abertura do browser:

1. **Primeira chamada de browser na conversa** — sempre.
2. **Mudança de eTLD+1** — re-anuncia. Exemplos:
   - `accounts.google.com` → `mail.google.com` — **sem reanúncio** (mesmo `google.com`).
   - `github.com` → `accounts.google.com` — **com reanúncio** (mudou o registrable domain).

Extração do eTLD+1 (heurística simples; suficiente pra domínios comuns):

```js
// Pega últimos 2 labels. Funciona pra .com/.org/.net/.io/etc.
// Falha em ccTLDs de 2 níveis (.com.br, .co.uk) — tratar caso a caso.
const url = new URL(pageUrl);
const parts = url.hostname.split('.');
const etld1 = parts.slice(-2).join('.');
```

Para `.com.br`/`.co.uk`/`.gov.br`/etc., usar últimos 3 labels. Lista mínima:
- `*.com.br`, `*.gov.br`, `*.org.br`, `*.net.br` → 3 labels.
- `*.co.uk`, `*.ac.uk`, `*.gov.uk` → 3 labels.

Anúncio template: *"Vou abrir `{eTLD+1}` no Chrome dedicado em `~/.claude/chrome-profile/`."*

## Blocklist de Zona 3 (irreversíveis / sensíveis)

Pausa e pergunta humano antes de clicar/submeter quando **qualquer** dos critérios bate. Hook PreToolUse enforça subset crítico mecanicamente; modelo é responsável pelos demais.

| Critério | Detecção | Ação |
|----------|----------|------|
| `accessibleName` do botão contém trigger word (PT+EN) | Snapshot + match case-insensitive em `blocklist.json:trigger_words` | Pergunta humano antes do click |
| Form contém campo de pagamento | Input com `name=cardnumber\|cvv\|cvc\|cc-number` (ver `payment_form_inputs`) | Pergunta humano antes do submit |
| URL bate com domínio sensível | Regex em `blocklist.json:sensitive_domains_regex` (`*.stripe.com`, `*.bank*`, `*.itau*`, `*.bb.com.br`, `*.santander*`) | Pergunta humano em **toda** ação mutativa |
| Modal de confirmação nativa | `window.confirm`, `role=alertdialog` | **Nunca** auto-aceita; sempre pergunta |
| Healthcare / saúde | URL ou conteúdo com termos médicos sensíveis (subjetivo — modelo decide) | Pergunta humano |

Trigger words PT+EN (lista canônica em `blocklist.json`):

```
delete, excluir, remover, remove, cancel subscription, cancelar assinatura,
unsubscribe, pay, pagar, buy, comprar, purchase, subscribe, assinar,
publish, publicar, post, postar, send, enviar, make public, tornar público,
transfer, transferir, withdraw, sacar, confirm purchase
```

**Regra:** quando bater, pausar e dizer textualmente *"Vou clicar em **'{accessibleName}'** em `{url}` — confirma?"*. Esperar `ok`/`sim` antes de prosseguir. Recusa = aborta a ação.

**Exceções (a)–(e) do Princípio 11 também se aplicam.** Blocklist do P12 é **adicional**, não substitui.

## Lock multi-slot (workflow Boris)

Workflow Boris Cherny tem 5 checkouts paralelos (`~/Projects/checkouts/<repo>-{1..5}`). 2+ sessões Claude Code podem tentar usar o browser ao mesmo tempo. Chromium tem ProcessSingleton: o segundo processo apontando pro mesmo `--user-data-dir` quebra (lockfile + processo zumbi).

`wrapper-launch.sh` resolve via `mkdir` atomic lock em `~/.claude/chrome-profile/.lock` (diretório, não arquivo):

- Primeira invocação: `mkdir` cria o diretório atomicamente, lança `@playwright/mcp@latest`. Lock vive enquanto o processo wrapper vive.
- Segunda invocação concorrente: `mkdir` falha (errno EEXIST), wrapper aborta com exit 99 + mensagem clara. Claude Code da segunda sessão recebe erro do MCP, deve reportar ao usuário ("outro slot está usando o browser").
- Quando primeira sessão termina (Claude Code encerra ou MCP é morto via SIGTERM/SIGINT/SIGHUP): trap do wrapper roda `rmdir` e libera o lock pra próxima sessão.

**macOS não tem `flock` CLI nativo** (só a syscall em libc). `mkdir` atomic lock é a alternativa POSIX-portável usada aqui — zero dependência externa. Validado empiricamente durante a Fatia 1 (S3 do handoff falhou; trocamos por `mkdir`).

**Se o lock ficar travado** (processo zumbi após crash duro): `rmdir ~/.claude/chrome-profile/.lock` resolve. O diretório é puramente um marcador — vazio, sem estado.

## Troubleshooting

| Problema | Sintoma | Resolução |
|----------|---------|-----------|
| Captcha (reCAPTCHA, hCaptcha) | Página exibe widget de captcha | **Pausar**, dizer "tem captcha, resolve aí pra mim e me avise". Esperar humano. |
| 2FA por SMS / authenticator | Após login, página pede código | Idem captcha — pausa + pede. |
| Sessão expirada | Cookie presente, mas resposta 401/403 ou redirect pra /login | Trigger fluxo de re-auth (anuncia + espera login). |
| `document.cookie` retorna vazio mas usuário diz que está logado | Cookies httpOnly | S1 — falso negativo conhecido. Tentar ação direto e usar redirect/erro como sinal. |
| localStorage-only auth (raro) | Sem cookies, auth via JWT em localStorage | Aceitar fricção: pre-check via `browser_evaluate(() => localStorage.getItem('token'))`. |
| Extensões bloqueando seletores | Snapshot retorna estranho, click falha em elementos visíveis | Lock garante que é Chrome dedicado sem extensões — descartar essa hipótese cedo. Se acontecer mesmo assim, abrir DevTools e inspecionar. |
| MCP não conecta após reconfig | `claude mcp list` mostra erro de timeout/conexão | (1) wrapper executável? `ls -l wrapper-launch.sh`. (2) lock órfão? `rmdir ~/.claude/chrome-profile/.lock`. (3) Chrome instalado? `ls /Applications/Google\ Chrome.app`. (4) `flock` CLI ausente — usar `mkdir` atomic lock (já default). |
| `--browser chrome` falha | MCP sobe mas browser não abre | Fallback: editar wrapper pra usar `--executable-path "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"` (S4 do handoff). |

## Delimitação vs skill `testing`

A skill `testing` tem a regra **"Playwright CLI > MCP"** — isso se refere ao **test runner** (`npx playwright test`), pra executar suítes de teste e2e.

**Browser-as-agent é categoria distinta:** controle de browser via Playwright **MCP** pra agir em nome do usuário em sites externos. Governado por este SKILL.md + Princípio 12.

Não há conflito — são domínios diferentes.

## Acumulação do perfil dedicado

`~/.claude/chrome-profile/` acumula cookies, localStorage, IndexedDB, histórico, indefinidamente. Não rotaciona automaticamente.

**Limpeza geral** (força re-login em tudo): `rm -rf ~/.claude/chrome-profile/ && mkdir -p ~/.claude/chrome-profile && chmod 700 ~/.claude/chrome-profile`. Sugerido **trimestralmente** ou após exposição (laptop emprestado, suspeita de comprometimento).

**Limpeza por domínio** (futuro): comando `/browser-logout-all` ou `/browser-status` — ainda não existem. Manualmente: abrir o perfil, DevTools → Application → Cookies → deletar.

## Site list explícito

Sites em que Claude já operou via este perfil (manter manualmente nesta seção; futuro: auto-incrementar):

- _(vazio — ainda não operou em nenhum site após Fatia 1)_

Quando Claude operar num novo domínio (eTLD+1), adicionar uma linha aqui com data + propósito principal.

## Referência rápida

- Princípio 12 — `CLAUDE.md` (escada CLI > MCP > API > Playwright MCP).
- Hook de blocklist — `~/.claude/hooks/block-browser-mutations.sh`.
- Lockfile — `~/.claude/chrome-profile/.lock`.
- Perfil — `~/.claude/chrome-profile/`.
- Wrapper — `~/.claude/skills/browser-actions/wrapper-launch.sh`.
- Blocklist estrutural — `~/.claude/skills/browser-actions/blocklist.json`.
