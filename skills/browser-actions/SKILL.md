---
name: browser-actions
description: Operacional do Princípio 12 (browser-as-agent). Setup do MCP Playwright com Chrome dedicado, auth assistida via cookie pre-check, blocklist de Zona 3 (irreversíveis), lock multi-slot, troubleshooting. Use quando a escada de precedência cair em (4) Playwright MCP.
---

# browser-actions

Operacional pra Claude agir em nome do usuário via browser, quando CLI/MCP/API de domínio falham. Governado pelo **Princípio 12** da `CLAUDE.md`.

A precedência é definida no Princípio 12 — esta skill cobre só o "como" do nível (4) Playwright MCP. Não revisita o "quando".

Pareia com `browser-inspect` (leitura runtime + execução efêmera de debug, sem mutação real no mundo). Esta skill (`browser-actions`) cobre **ações mutativas** (cliques de pagamento, submits, navegação destrutiva). Pra leitura de `console.log`, network requests, `evaluate` read-only ou synthetic clicks de debug → `~/.claude/skills/browser-inspect/SKILL.md`.

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

Antes de qualquer ação que assume sessão autenticada, validar que a sessão está ativa — não confiar em cookies herdados do perfil.

### Sinais de auth — ordenados por confiabilidade

**1. Redirect pra login após `browser_navigate` no endpoint privado alvo (sinal mais forte).**
Tentar a navegação direto. Se a URL final contém `/login`, `/signin`, `/auth/`, ou a resposta é 401/403, a sessão está ausente/expirada. Não dá falso positivo. Validado 2026-05-06: `github.com/settings/repositories` → `github.com/login?return_to=...` quando deslogado; URL idêntica preservada quando logado.

**2. Meta tag de identidade (forte quando o site expõe).**
Sites bem comportados expõem `<meta name="user-login" content="...">` (GitHub) ou similar (`og:profile`, etc.). Presente = logado; ausente em endpoint privado = deslogado. Validado 2026-05-06 (`user_login: "octocat"` apareceu na meta após login).

**3. `document.cookie` pre-check (sinal fraco — só triagem).**
Validado empiricamente em 2026-05-06: dá **falso positivo** (cookies de tracking populam mesmo deslogado — `_octo`, `cpu_bucket`, `tz` no GitHub) e **falso negativo** (cookies de sessão modernos são `httpOnly`/`SameSite=Strict` e **não aparecem** em `document.cookie`, ex: `user_session`, `_gh_sess`). **Não confie isoladamente.**

### Sequência recomendada

```
1. browser_navigate(url=endpoint privado alvo)
2. browser_evaluate(() => ({
     url: location.href,
     userMeta: document.querySelector('meta[name="user-login"]')?.content
   }))
3. Se URL final contém /login OU userMeta ausente em endpoint privado:
     → ANUNCIAR: "Vou abrir [domínio] no Chrome dedicado. Faça login e me avise quando estiver pronto."
     → Esperar resposta do usuário no chat ("ok", "pronto", ENTER).
     → Re-navegar. Se ainda redireciona, perguntar de novo.
4. Se sessão ativa: prosseguir com a ação alvo.
```

### Anti-pattern

`browser_evaluate(() => document.cookie)` como **único** sinal — falha silenciosa em ambas as direções.

**Auth ausente NUNCA é skip pro próximo nível** (regra do Princípio 12 — "auth ausente nunca é skip"). Sempre pede ao usuário.

## Cadência do anúncio

Anuncia abertura do browser:

1. **Primeira chamada de browser na conversa** — sempre.
2. **Mudança de eTLD+1** — re-anuncia. Exemplos:
   - `accounts.google.com` → `mail.google.com` — **sem reanúncio** (mesmo `google.com`).
   - `github.com` → `accounts.google.com` — **com reanúncio** (mudou o registrable domain).

### Extração do eTLD+1

**Antes de decidir reanunciar, executar o algoritmo passo-a-passo no raciocínio (Chain-of-Thought explícito).** A regra é determinística — basta seguir as 3 etapas na ordem.

**Exercitada empiricamente — vide tabela de casos de teste** abaixo.

#### Algoritmo (3 etapas, ordem importa)

1. **IP literal ou `localhost`** → host único: `eTLD+1 = hostname` (sem fatiamento). Detecção: regex `^[0-9.:]+$` para IP, ou hostname == `localhost`. Hostnames com `:porta` (ex: `localhost:3000`) são tratados pelo `URL.hostname` que já remove a porta — usar `URL.hostname` como entrada.
2. **Suffix multi-label conhecido** (tabela abaixo) → últimos **3 labels**. Match: `hostname` termina com `.<suffix>` (ponto antes — `gov.br` direto NÃO bate em `*.gov.br`, ver nota). Se hostname tem <3 labels, cai no fallback (etapa 3).
3. **Fallback** → últimos **2 labels** (`hostname.split('.').slice(-2).join('.')`). Cobre `.com`/`.org`/`.net`/`.io`/etc.

#### Tabela de suffixes multi-label conhecidos (top-N curado)

| Suffix    | Origem        | Uso esperado                          |
|-----------|---------------|---------------------------------------|
| `*.com.br`| BR comercial  | bancos, e-commerce, serviços online BR|
| `*.gov.br`| BR governo    | gov serviços                          |
| `*.org.br`| BR org        | ONGs, comunidades                     |
| `*.net.br`| BR rede       | infraestrutura                        |
| `*.edu.br`| BR educação   | universidades                         |
| `*.co.uk` | UK comercial  | empresas UK                           |
| `*.ac.uk` | UK acadêmico  | universidades UK                      |
| `*.gov.uk`| UK governo    | gov UK                                |
| `*.com.au`| AU comercial  | empresas AU                           |
| `*.com.mx`| MX comercial  | empresas MX                           |
| `*.co.jp` | JP comercial  | empresas JP                           |

#### Tabela de casos de teste (oráculo)

| URL                                     | Hostname              | Algoritmo aplicado          | eTLD+1 esperado     |
|-----------------------------------------|-----------------------|-----------------------------|---------------------|
| `https://github.com/user/repo`          | `github.com`          | etapa 3 (slice -2)          | `github.com`        |
| `https://accounts.google.com/signin`    | `accounts.google.com` | etapa 3                     | `google.com`        |
| `https://mail.google.com/inbox`         | `mail.google.com`     | etapa 3                     | `google.com`        |
| `https://www.bbc.co.uk/news`            | `www.bbc.co.uk`       | etapa 2 (`*.co.uk`)         | `bbc.co.uk`         |
| `https://www.itau.com.br/empresas`      | `www.itau.com.br`     | etapa 2 (`*.com.br`)        | `itau.com.br`       |
| `https://gov.br/saude`                  | `gov.br`              | etapa 2 não bate → fallback | `gov.br`            |
| `https://192.168.1.1/foo`               | `192.168.1.1`         | etapa 1 (IP)                | `192.168.1.1`       |
| `https://localhost:3000/dev`            | `localhost`           | etapa 1 (host único)        | `localhost`         |
| `https://api.itau.com.br/v1`            | `api.itau.com.br`     | etapa 2                     | `itau.com.br`       |
| `https://www.uol.com.br/noticias`       | `www.uol.com.br`      | etapa 2                     | `uol.com.br`        |
| `https://www.bb.com.br/pessoas`         | `www.bb.com.br`       | etapa 2                     | `bb.com.br`         |
| `https://www.example.com.au/`           | `www.example.com.au`  | etapa 2 (`*.com.au`)        | `example.com.au`    |
| `https://www.example.com.mx/`           | `www.example.com.mx`  | etapa 2 (`*.com.mx`)        | `example.com.mx`    |
| `https://www.example.co.jp/`            | `www.example.co.jp`   | etapa 2 (`*.co.jp`)         | `example.co.jp`     |
| `https://algo.empresa.com.tr/`          | `algo.empresa.com.tr` | fail-safe (≥3 labels, suffix não listado, última label 2 letras) | reanúncio conservador |
| `https://api.atlassian.com/v1`          | `api.atlassian.com`   | etapa 3 (fail-safe NÃO dispara: `com` tem 3 letras) | `atlassian.com` |

#### Nota sobre `gov.br` direto vs `*.gov.br`

`gov.br` (host único, portal federal) é uma entidade distinta de `saude.gov.br` (subdomínio governamental). O algoritmo trata corretamente:
- `gov.br` → etapa 2 não bate (precisa de `.gov.br` com algo antes), cai no fallback (etapa 3) → `gov.br`.
- `saude.gov.br` → etapa 2 bate em `*.gov.br` → `saude.gov.br`.

Resultado: navegar de `gov.br` para `saude.gov.br` produz eTLD+1 diferentes — **reanúncio dispara**, que é o comportamento correto (são entidades distintas).

#### Fail-safe — detector mecânico

**Se hostname não bate em nenhuma entrada da tabela de suffixes E tem ≥3 labels E sua última label tem exatamente 2 letras (provável ccTLD), reanunciar conservadoramente em vez de aplicar `slice(-2)` cegamente.**

Mecanismo: `≥3 labels + suffix não listado + última label com 2 letras` é o sinal de "possível ccTLD multi-label que não está na tabela top-N". TLDs ccTLD são quase todos códigos ISO 3166-1 alpha-2 (2 letras: `.tr`, `.cn`, `.in`, `.fr`...); gTLDs históricos têm 3+ letras (`.com`, `.org`, `.net`, `.io`, `.app`...). A condição "última label = 2 letras" filtra subdomínios de gTLD comuns: `accounts.google.com` → última label `com` (3 letras) → fail-safe **NÃO** dispara → cai corretamente na etapa 3 → `google.com`. Custo de falso positivo (reanunciar quando não precisava) = uma linha extra de mensagem. Custo de falso negativo (silêncio em mudança real de eTLD+1) = violação silenciosa do Princípio 12. Otimizar para fail-safe.

Exemplos:
- `algo.qualquer.com.tr` (Turquia, fora da tabela) → 4 labels, suffix `*.com.tr` não listado, última label `tr` (2 letras) → **fail-safe dispara**, reanunciar.
- `accounts.google.com` → 3 labels, suffix `*.com` não está na tabela, mas última label `com` (3 letras) → fail-safe **NÃO** dispara → etapa 3 → `google.com` (consistente com os casos de teste para `*.google.com`).

#### Suposições abertas (registradas como risco conhecido)

- **[SUPOSIÇÃO]** Os 11 suffixes cobrem ≥95% do uso esperado. Aceito como risco conhecido — se a regra falhar em sessões reais com >5% de frequência, expandir a tabela (ex: `*.com.tr`, `*.com.cn`, `*.co.in` sob demanda).
- **[SUPOSIÇÃO]** Fail-safe (reanunciar em dúvida) não vira spam de reanúncio. Aceito como risco conhecido sem ação preventiva — se usuário reclamar de reanúncios redundantes, ajustar.

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
| `document.cookie` vazio (ou só com tracking) mesmo logado | Cookies de sessão são `httpOnly`/`SameSite=Strict` | Validado 2026-05-06. Sinais primários: **redirect-pra-login** ou **meta `user-login`** (ver "Protocolo de auth assistida"). `document.cookie` só serve como triagem. |
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

**Limpeza por domínio** (futuro): granularidade por host ainda não existe. Manualmente: abrir o perfil, DevTools → Application → Cookies → deletar.

## Manutenção do perfil

Dois slash commands operam direto no SQLite de cookies (`~/.claude/chrome-profile/Default/Cookies`):

- **`/browser-status`** — read-only. Abre o DB com URI `file:...?mode=ro&immutable=1` (não disputa lock, não cria journal/-wal/-shm) e imprime tabela agregada por `host_key`: DOMAIN, COUNT, LAST_ACCESS (datetime localtime), EXPIRES (date ou `session`). Detecta MCP rodando via `~/.claude/chrome-profile/.lock/pid` + `kill -0` e avisa que cookies dos últimos segundos podem não aparecer no snapshot. Se o perfil ainda não foi inicializado (Default/Cookies inexistente), imprime mensagem amigável e exit 0.
- **`/browser-logout-all [--confirm]`** — destrutivo. Sem `--confirm`: preview (status do lock + contagem). Com `--confirm` e lock liberado: `PRAGMA wal_checkpoint(TRUNCATE)` → `DELETE FROM cookies` → `VACUUM` em batch. Aborta com exit 1 se MCP vivo (concorrência em WAL pode corromper). VACUUM é necessário porque DELETE só marca páginas como livres — sem VACUUM o arquivo não shrinka.

**Escopo restrito — apenas cookies HTTP.** Local Storage, IndexedDB e cache do browser **não** são afetados. Para reset total, encerre o MCP e rode:

```bash
rm -rf ~/.claude/chrome-profile/
mkdir -p ~/.claude/chrome-profile
chmod 700 ~/.claude/chrome-profile
```

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
