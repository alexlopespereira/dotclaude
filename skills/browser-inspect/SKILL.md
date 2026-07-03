---
name: browser-inspect
description: Use quando precisar diagnosticar runtime de página web — ler console.log, erros JS, network requests, ou estado JS via evaluate; também cobre execução efêmera (synthetic clicks de debug, instrumentação ad-hoc). PROIBIDO pedir ao usuário pra colar JS no console se a página é acessível ao Playwright MCP — invoque esta skill primeiro. Delega pra browser-actions se o domínio é sensível (banco, pagamento, Zona 3).
---

# browser-inspect

Skill operacional pra Claude inspecionar runtime de uma página web já acessível via MCP Playwright. Substitui o anti-pattern *"cola este JS no console e me passa o output"*.

Pareia com `browser-actions` (ações mutativas, governadas pelo Princípio 12). `browser-inspect` cobre leitura passiva de runtime + execução efêmera com fim de observação. Mutações reais (cliques de pagamento, submits de cadastro, navegação destrutiva) ficam em `browser-actions`.

## Quando usar / quando NÃO usar

**Use quando:**
- Precisa ler `console.log` / errors de uma página web já acessível.
- Precisa observar XHR/fetch (URL, método, status, payload).
- Precisa inspecionar estado JS (`mw.config`, `window.foo`, `getComputedStyle`, etc.).
- Precisa disparar synthetic click / `dispatchEvent` pra **observar** comportamento de um event listener (analytics, GA4, debounce, etc.).
- Precisa instrumentar página ad-hoc (override `console.log`, monkey-patch `fetch`, etc.).

**NÃO use quando:**
- A operação é leitura local (Read, Grep resolvem) — você quer ler código, não runtime.
- A página alvo está em domínio sensível (`*.stripe.com`, `*.bank*`, `*.itau*`, `*.bb.com.br`, `*.santander*`, etc.) — escala pra `browser-actions`.
- A operação é mutação real solicitada pelo usuário (clicar "Pagar agora", submeter form de cadastro, deletar recurso) — `browser-actions`.
- A página exige login que o perfil dedicado ainda não tem — escala pra `browser-actions` (auth assistida).

## Tools disponíveis

Validadas empiricamente em logs reais. Todas no namespace `mcp__playwright__*`.

**Leitura passiva:**

| Tool | Uso |
|---|---|
| `browser_console_messages` | Ler `console.log`/`console.error` desde load |
| `browser_network_requests` | Ler requests HTTP da aba ativa (URL, método, status) |
| `browser_evaluate` | Executar JS arbitrário no contexto da página, retorna valor |
| `browser_snapshot` | DOM accessibility tree (ARIA, roles) |
| `browser_take_screenshot` | Captura visual |

**Preparação / sincronização:**

| Tool | Uso |
|---|---|
| `browser_navigate` | Abrir URL na aba ativa |
| `browser_tabs` | Listar/trocar abas |
| `browser_wait_for` | Esperar por seletor ou tempo |

**Execução efêmera (fim de debug):**

| Tool | Uso |
|---|---|
| `browser_evaluate` | Synthetic click, `dispatchEvent`, monkey-patch (ver Padrão 4.3) |
| `browser_run_code` | Variante alternativa pra executar JS |

## Regra anti-laziness (núcleo)

**PROIBIDO pedir ao usuário pra colar JS no console** se a página é acessível ao Playwright MCP.

Auto-policiamento mental antes de pedir output ao usuário:

1. Estou prestes a escrever *"cola isto no console"*, *"roda esse comando e me passa o output"*, *"abre F12 e..."*?
2. A página alvo é acessível por `browser_navigate` (URL pública ou já autenticada no perfil dedicado)?
3. Se sim → **PARAR**, invocar a tool MCP correspondente em vez de pedir ao humano.
4. Se a página exige login que o perfil não tem → escalar pra `browser-actions` (auth assistida), **não** pedir ao humano colar JS.

A regra vale mesmo se o usuário **pedir** explicitamente pra Claude usar "computer use" — não existe; o caminho correto é Playwright MCP.

## Extração dirigida (P16 — anti-inchaço de contexto)

Snapshots e dumps inteiros são o maior custo de contexto do Playwright MCP (medição 2026-07-03, VM2: 240 kB acumulados de `evaluate`+`snapshot` numa sessão; snapshots únicos de até 37 kB). Regras:

1. **`browser_evaluate` seletivo > `browser_snapshot` inteiro.** Se você sabe O QUE procura (um valor, um estado, uma lista), escreva um `evaluate` que retorne SÓ isso (`document.querySelector(...)`, `.map()` dos campos relevantes) em vez de snapshotar a página.
2. **Snapshot só para descobrir estrutura desconhecida** — e no máximo 1× por página/estado; depois disso, navegue por seletores já observados.
3. **`evaluate` que retorna coleção grande:** projete os campos (`{id, status}`) e limite (`.slice(0, 20)`) — nunca devolva objetos DOM inteiros ou arrays sem cap.
4. **Console/network:** filtre na chamada (`browser_console_messages` só errors; `browser_network_requests` do endpoint específico) em vez de despejar tudo.

O mesmo princípio vale para MCPs de documento (Google Drive, Gmail): busca/trecho dirigido > `read_file_content`/thread inteiro (caso medido: 169 kB de docs inteiros numa sessão).

## Padrões comuns

### 4.1 — Ler console (errors/logs)

```
1. browser_navigate(url=<página alvo>)              // ou confirmar aba ativa via browser_tabs
2. browser_wait_for({ time: 2 })                    // dá tempo dos scripts carregarem
3. browser_console_messages()                        // retorna array { type, text, location }
4. (filtrar mentalmente por type==='error' se for caça-bug)
```

### 4.2 — Ler network (XHR/fetch)

```
1. browser_navigate(url=<página alvo>)
2. (executar a ação que dispara o request — click, navegação interna, etc.)
3. browser_network_requests()                        // metadados {url, method, status}
4. (filtrar por padrão de URL: requests.filter(r => r.url.includes('/api/foo')))
```

`browser_network_requests` retorna **metadados**. Se precisa do **body** do request/response, use `browser_evaluate` pra interceptar `fetch`/`XMLHttpRequest` antes da ação:

```js
() => {
  window.__captured = [];
  const orig = window.fetch;
  window.fetch = async (...a) => {
    const r = await orig(...a);
    const c = r.clone();
    window.__captured.push({ url: a[0], status: r.status, body: await c.text() });
    return r;
  };
}
```

Depois da ação: `browser_evaluate(() => window.__captured)`.

### 4.3 — Synthetic click pra observar evento

Use quando precisa observar comportamento de event listener (analytics, GA4, custom handler).

```
1. browser_navigate(url=<página alvo>)
2. browser_evaluate(() => location.hostname)         // pre-check Zona 3 (passo obrigatório)
3. (se hostname bate em blocklist sensível → PARAR, escalar pra browser-actions)
4. (anunciar: "Vou disparar synthetic click em <hostname> pra observar <evento>")
5. browser_evaluate(() => {
     const a = document.createElement('a');
     a.href = 'https://example.com/target';
     a.textContent = 'synthetic';
     document.body.appendChild(a);
     a.click();
     a.remove();
   })
6. browser_console_messages()                        // captura logs do handler
7. browser_network_requests()                        // confirma request analytics se aplicável
```

**Caso real validado** (wikiapp, GA4 `outbound_click_locaweb`, 2026-05-07): a sequência acima substitui o pedido *"cola isto no console e me passa o resultado"*.

### 4.4 — Espera por estado async

Polling simples:

```
1. browser_evaluate(() => window.someAsyncThing.isReady)   // poll inicial
2. browser_wait_for({ time: 3 })                            // aguarda
3. browser_evaluate(() => window.someAsyncThing.isReady)   // re-poll
```

Pra esperas mais sofisticadas, embutir `Promise` com timeout dentro do próprio `browser_evaluate`:

```js
() => new Promise((resolve, reject) => {
  const start = Date.now();
  const tick = () => {
    if (window.foo) resolve(window.foo);
    else if (Date.now() - start > 5000) reject('timeout');
    else setTimeout(tick, 100);
  };
  tick();
})
```

## Critério operacional de delegação pra `browser-actions`

Antes de qualquer `browser_evaluate`/`browser_run_code` que possa mutar estado, executar:

1. **Pre-check de URL.** `browser_evaluate(() => location.hostname)` — se hostname bate em `~/.claude/skills/browser-actions/blocklist.json:sensitive_domains_regex` (`*.stripe.com`, `*.bank*`, `*.itau*`, `*.bb.com.br`, `*.santander*`, etc.) → **PARAR**, escalar pra `browser-actions`.
2. **Detecção sintática de mutação.** O JS contém algum de: `.click(`, `.submit(`, `.dispatchEvent(`, `location.assign|replace|href=`, `fetch(`, `XMLHttpRequest`, `form.requestSubmit(`, `localStorage.setItem`, `sessionStorage.setItem`? → é mutativo.
3. **Decisão.**
   - Mutativo + URL sensível → escalar pra `browser-actions` (auth assistida + blocklist Zona 3 + confirmação humana).
   - Mutativo + URL OK + fim explícito de debug → seguir aqui, **anunciar** ao usuário antes (*"Vou disparar `<X>` em `<hostname>` pra observar `<Y>`"*).
   - Read-only puro (`querySelector`/`textContent`/`getComputedStyle`/leitura de console/network) → seguir sem confirmação.

**[SUPOSIÇÃO]** Detecção sintática (lista de keywords) cobre 90%+ dos casos. JS sofisticado (`Proxy`, decorators, `eval` em string) escapa. Risco aceito — se virar problema, escalar pra `browser-actions` por default.

## Anti-patterns (extraídos de logs reais)

**Errado** — pedir output de leitura simples:
> *"Cola e enter: `mw.loader.getState('ext.popups')`. Me passa o output"*

**Certo:**
> `browser_evaluate(() => mw.loader.getState('ext.popups'))`

---

**Errado** — pedir execução pra observar comportamento:
> *"Roda esse comando, me passa o output, e te digo o próximo passo"*

**Certo:**
> `browser_evaluate` + `browser_console_messages` em sequência

---

**Errado** — pedir abertura manual de DevTools:
> *"F12 → console. Cola isto antes do click..."*

**Certo:**
> `browser_navigate` + `browser_evaluate(<synthetic click>)` + `browser_console_messages`

## Pré-requisitos & troubleshooting

**Pré-requisitos:**
- MCP Playwright registrado e `✓ Connected` (`claude mcp list`).
- Página alvo acessível (URL pública ou já autenticada no perfil dedicado `~/.claude/chrome-profile/`).
- Nenhuma outra sessão Claude Code segurando o lock (`~/.claude/chrome-profile/.lock`).

| Sintoma | Causa provável | Resolução |
|---|---|---|
| `browser_evaluate` retorna `undefined` quando esperava valor | Função async / Promise não resolveu | Embutir Promise no evaluate (Padrão 4.4) ou `browser_wait_for` antes |
| `browser_console_messages` retorna `[]` em página com `console.log` óbvio | Mensagens emitidas antes do MCP attach | Re-navegar (`browser_navigate` re-anexa) + repetir ação |
| `browser_network_requests` falta payload do response | Tool retorna só metadados | Interceptar via `browser_evaluate` que monkey-patcha `fetch`/`XMLHttpRequest` antes da ação (ver Padrão 4.2) |
| Synthetic click não dispara handler | Listener registrado em fase posterior ao DOMContentLoaded | `browser_wait_for` + verificar inspeção; fallback `dispatchEvent(new MouseEvent('click', { bubbles: true }))` |
| Domínio em blocklist | Regex match em `browser-actions/blocklist.json` | Escalar pra `browser-actions` (não tente burlar) |

## Referência rápida

- Skill irmã (ações mutativas): `~/.claude/skills/browser-actions/SKILL.md`.
- Princípio 12 da `CLAUDE.md` (precedência CLI > MCP > API > Playwright MCP).
- Blocklist de domínios sensíveis: `~/.claude/skills/browser-actions/blocklist.json`.
- Perfil dedicado: `~/.claude/chrome-profile/`.
