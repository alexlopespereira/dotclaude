#!/usr/bin/env node
// secret-capture-driver.mjs — driver Playwright local do bin/secret-capture.sh.
//
// O QUE FAZ: abre o perfil Chrome dedicado do slot
// (~/.claude/chrome-profile-<slot>) com launchPersistentContext, navega até
// --url, extrai o valor por --selector (CSS) ou --prefix-regex, e o devolve
// SÓ pelo arquivo --out (modo 0600, criado pelo wrapper e destruído por ele
// após a leitura). Nunca stdout (persistido no transcript), nunca argv, e
// NUNCA tira screenshot — a página pode expor o valor em claro.
//
// LOCK: replica o protocolo do wrapper-launch.sh (mkdir <profile>/.lock +
// arquivo pid): dono vivo → aborta com mensagem em vez de disputar o
// user-data-dir com o MCP; órfão (liveness via kill 0 falha) → limpa e
// readquire.
//
// PLAYWRIGHT: resolvido de --pw-root, senão auto-busca nos checkouts
// conhecidos do storefront (decisão #4 do plano R9: dotclaude fica shell-puro,
// sem dependência nova; `npx` on-demand esbarra no cooldown supply-chain).
//
// Exit: 0 ok; 2 uso; 3 playwright não resolvido; 4 lock ocupado; 5 extração.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';

const err = (msg) => process.stderr.write(`secret-capture-driver: ${msg}\n`);
const die = (msg, rc) => { err(msg); process.exit(rc); };

const opt = { url: '', selector: '', prefixRegex: '', slot: '', pwRoot: '', out: '' };
{
  const argv = process.argv.slice(2);
  const take = (flag, i) => {
    if (i + 1 >= argv.length) die(`faltando valor para ${flag}`, 2);
    return argv[i + 1];
  };
  for (let i = 0; i < argv.length; i += 2) {
    const a = argv[i];
    if (a === '--url') opt.url = take(a, i);
    else if (a === '--selector') opt.selector = take(a, i);
    else if (a === '--prefix-regex') opt.prefixRegex = take(a, i);
    else if (a === '--slot') opt.slot = take(a, i);
    else if (a === '--pw-root') opt.pwRoot = take(a, i);
    else if (a === '--out') opt.out = take(a, i);
    else die(`opção desconhecida: ${a}`, 2);
  }
}
if (!opt.url || !opt.out) die('exige --url e --out', 2);
if (!opt.selector === !opt.prefixRegex) die('exige exatamente um de --selector | --prefix-regex', 2);

// --pw-root explícito, senão auto-busca nos checkouts conhecidos do storefront
// (pool Boris storefront-1..5 + repo direto). Falha aponta o fallback --pw-root.
function resolvePlaywright() {
  const home = os.homedir();
  const roots = opt.pwRoot
    ? [opt.pwRoot]
    : [1, 2, 3, 4, 5]
        .map((n) => path.join(home, 'Projects', 'checkouts', `storefront-${n}`))
        .concat([path.join(home, 'Projects', 'shopify', 'storefront')]);
  for (const root of roots) {
    try {
      return createRequire(path.join(root, 'package.json'))('playwright');
    } catch { /* tenta o próximo */ }
  }
  die(`playwright não resolvido em: ${roots.join(', ')} — passe --pw-root DIR (raiz com node_modules/playwright)`, 3);
}

// mesma resolução do wrapper-launch.sh: --slot > $CLAUDE_SLOT_NAME >
// basename(cwd) padrão <repo>-<N> > "default"
function resolveSlot() {
  if (opt.slot) return opt.slot;
  if (process.env.CLAUDE_SLOT_NAME) return process.env.CLAUDE_SLOT_NAME;
  const base = path.basename(process.cwd());
  return /^[a-z0-9-]+-[1-5]$/.test(base) ? base : 'default';
}

// liveness: sinal 0 não entrega sinal, só testa existência (kill -0 do bash);
// EPERM = processo vivo de outro dono
const pidAlive = (pid) => {
  try { process.kill(pid, 0); return true; }
  catch (e) { return e.code === 'EPERM'; }
};

// protocolo do wrapper-launch.sh: mkdir .lock + pid; dono vivo → aborta;
// órfão → limpa e readquire (best-effort, mesma ressalva de race do wrapper)
function acquireLock(lockDir) {
  const pidFile = path.join(lockDir, 'pid');
  try {
    fs.mkdirSync(lockDir);
  } catch {
    let owner = NaN;
    try { owner = parseInt(fs.readFileSync(pidFile, 'utf8').trim(), 10); } catch { /* sem pid = órfão */ }
    if (Number.isFinite(owner) && pidAlive(owner)) {
      die(`perfil em uso pela sessão ${owner} (lock ${lockDir}) — feche o browser dessa sessão ou use --slot`, 4);
    }
    fs.rmSync(lockDir, { recursive: true, force: true });
    fs.mkdirSync(lockDir);
  }
  fs.writeFileSync(pidFile, `${process.pid}\n`);
}

const pw = resolvePlaywright();
const slot = resolveSlot();
const profileDir = path.join(os.homedir(), '.claude', `chrome-profile-${slot}`);
fs.mkdirSync(profileDir, { recursive: true });
const lockDir = path.join(profileDir, '.lock');
acquireLock(lockDir);
const releaseLock = () => { try { fs.rmSync(lockDir, { recursive: true, force: true }); } catch { /* best-effort */ } };
process.on('exit', releaseLock);
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => process.exit(1));

let rc = 0;
let context;
try {
  err(`abrindo perfil ${profileDir} → ${opt.url}`);
  context = await pw.chromium.launchPersistentContext(profileDir, { headless: false });
  const page = context.pages()[0] ?? await context.newPage();
  await page.goto(opt.url, { waitUntil: 'domcontentloaded' });

  let value = '';
  if (opt.selector) {
    const el = page.locator(opt.selector).first();
    await el.waitFor({ state: 'visible', timeout: 120_000 });
    value = (await el.inputValue().catch(() => '')) || (await el.textContent()) || '';
  } else {
    // regex de prefixo: casa prefixo + resto sem whitespace no texto da página
    // (polling: dá tempo do humano clicar em "reveal"/gerar a chave).
    // O evaluate fica em try/catch PRÓPRIO: clicar em "Generate" navega a
    // página e destrói o execution context mid-evaluate — sem o catch, um
    // throw transiente abortava a captura inteira (rc 5) dentro do budget
    // (finding do code-review R9); o próximo poll re-tenta na página nova.
    const re = new RegExp(`${opt.prefixRegex}\\S+`);
    for (let tries = 0; tries < 120 && !value; tries++) {
      try {
        const text = await page.evaluate(() => document.body.innerText);
        value = text.match(re)?.[0] ?? '';
      } catch {
        // navegação/reload em curso — transiente, re-tenta no próximo tick
      }
      if (!value) await page.waitForTimeout(1000);
    }
  }
  value = value.trim();
  if (!value) {
    err('nenhum valor extraído (seletor/regex não casou dentro do timeout)');
    rc = 5;
  } else {
    // o valor sai SÓ por aqui: arquivo 0600 lido e destruído pelo wrapper
    fs.writeFileSync(opt.out, value, { mode: 0o600 });
    fs.chmodSync(opt.out, 0o600);
    err('valor extraído e entregue ao wrapper (report mascarado)');
  }
} catch (e) {
  err(`falha na captura: ${e.message}`);
  rc = 5;
} finally {
  if (context) await context.close().catch(() => {});
}
process.exit(rc);
