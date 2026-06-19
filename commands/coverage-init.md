---
description: Provisiona um projeto como coverage-ready — detecta a linguagem dominante, copia o template de config de cobertura, cria .coverage-baseline.json e (quando existe) o workflow de CI. Idempotente. Use ao tornar um repo pronto para o Objetivo de cobertura 100% por ciclo, antes do coverage-gate entrar em vigor.
argument-hint: "[--target <dir>] [--lang python|js|ts|bash|liquid]"
allowed-tools: Bash(bash *), Bash(chmod *), Bash(test *), Bash(ls *), Bash(cat *), Bash(npm install *), Bash(pip install *), Bash(gem install *), Read
---

# /coverage-init — provisiona toolchain + config + baseline de cobertura

Torna o projeto-alvo **coverage-ready**: detecta a linguagem dominante (contagem
de extensões, vendor dirs podados), copia o template de config correspondente
(`skills/testing/templates/coverage/<lang>/`), cria um `.coverage-baseline.json`
inicial e — quando o template de CI (US-03) existe — copia `coverage-ci.yml`.
**Idempotente**: a 2ª execução converge ao mesmo estado (não duplica config nem
sobrescreve um baseline já ratcheted).

## Passos

1. **Localizar o script:**
   ```bash
   SCRIPT="$HOME/Projects/dotclaude/bin/coverage-init.sh"
   test -x "$SCRIPT" || chmod +x "$SCRIPT"
   ```

2. **Provisionar** (alvo = `$ARGUMENTS` ou cwd):

   !`SCRIPT="$HOME/Projects/dotclaude/bin/coverage-init.sh"; test -x "$SCRIPT" || chmod +x "$SCRIPT"; "$SCRIPT" $ARGUMENTS`

   O script imprime a linguagem detectada, qual config foi copiada, o estado do
   probe de `kcov` (bash) e o `total` do baseline.

3. **Instalar a toolchain da linguagem detectada.** O script provisiona *config*;
   a instalação das ferramentas passa por aqui e **pelo supply-chain-guard**
   (hook `PreToolUse`). Por linguagem:
   - **Python:** `pip install coverage diff-cover` (coverage.py `--branch`).
   - **JS/TS:** `npm install --save-dev --ignore-scripts c8` (c8 ≥ 9).
   - **bash:** `gem install simplecov simplecov-lcov bashcov` (+ `kcov` no CI Linux;
     frágil em macOS — o probe registra). diff-cover via `pip install diff-cover`.
   - **Liquid:** `npm install --save-dev --ignore-scripts c8 liquidjs` (harness
     `liquid.js` + `c8`).

   **AC5 — supply-chain.** O install de `liquid.js`/`c8`/etc. é interceptado pelo
   `supply-chain-guard`. Se o **cooldown de 14 dias** falso-positivar num pacote
   legítimo, use **bypass granular** com motivo — **NUNCA** wrapper/subshell
   (um `bash -c "…"` ou `eval $(…)` escapa do gate e é proibido pelo Princípio 13):
   ```bash
   CLAUDE_SC_BYPASS_COOLDOWN=1 CLAUDE_SC_REASON="liquidjs/c8: pacote maduro, falso-positivo de cooldown" \
     npm install --save-dev --ignore-scripts c8 liquidjs
   ```
   `--ignore-scripts` é mandatório (Princípio 13b). Cada decisão é auditada em
   `~/.claude/cache/supply-chain/audit.jsonl`.

4. **Conferir o resultado** (verify-before-handoff, Princípio 14):
   ```bash
   ls -a <target>/.coveragerc <target>/.c8rc.json <target>/.simplecov 2>/dev/null
   cat <target>/.coverage-baseline.json
   ```
   Confirme que a config e o baseline existem antes de reportar concluído.

## Notas

- **Baseline (AC4).** `init` **não** roda a suíte do alvo (efeito colateral pesado
  num projeto arbitrário). O total medido entra via seam
  `COVERAGE_INIT_MEASURED_TOTAL` quando você já mediu; sem ele, o baseline começa
  em `0` com nota e o ratchet sobe via CI (`coverage-gate.sh --gate`).
- **kcov em macOS (AC7).** O probe registra se `kcov` roda no host; quando ausente,
  a cobertura de bash cai em `bashcov` line-only (`branch=n/a`, NÃO 0%).
- **CI.** O `coverage-ci.yml` é produzido por US-03; `/coverage-init` o copia
  quando presente, senão pula com aviso.
- **Paths com espaço (limitação real).** O parser do *script* é space-safe
  (`--target "${2:-}"`), MAS o `!`-bloco acima expande `$ARGUMENTS` **sem aspas**
  e o bash re-divide a string num único re-parse — então `/coverage-init --target
  "/caminho com espaços"` **quebra** (o `--target` recebe `"/caminho` e `com`/`espaços"`
  viram argumentos inesperados → exit 2). `$ARGUMENTS` é deixado sem aspas de
  propósito para suportar múltiplas flags (`--target X --lang py`), e os dois
  requisitos colidem. Workaround para alvo com espaço: rode o script direto —
  `bin/coverage-init.sh --target "/caminho com espaços"` (a quotagem da Bash tool
  sobrevive) — **ou** `cd` no alvo e rode `/coverage-init` sem `--target` (usa o cwd).
