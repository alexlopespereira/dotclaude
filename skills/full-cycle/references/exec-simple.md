# Fases 5 e 6 — Execução Ralph sem reviewer + testes (/full-cycle-simple)

> Reference do `/full-cycle-simple`. Leia APENAS ao iniciar a Fase 5. O
> `/full-cycle` usa `exec-full.md`.

## Fase 5 — Execução Ralph SEM reviewer (--no-review)

1. Leia `~/.claude/skills/ralph-adversarial/SKILL.md`.
2. Verifique pré-requisitos: `jq` e o CLI do PRIMARY_AGENT (default `claude`).
   - **Não exige `codex`** porque `--no-review` desliga o reviewer.
3. Execute no cwd atual com a flag `--no-review`:
   ```bash
   chmod +x ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   PRIMARY_AGENT="${PRIMARY_AGENT:-claude}" \
     bash ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh --no-review
   ```
4. Após conclusão, apresente resumo: stories completas/pendentes/escaladas,
   progress.txt.

**Gate:** Se houver stories escaladas (max retries por FALHA_COMMIT/HANG),
**PARE** e escale para humano. NÃO prossiga para testes/PR.

**Antes de escalar para humano:** sugira `/reflect --on-failure 5 --quick
--context-file <path-com-findings-P0>`. Modo `--quick` mantém o espírito enxuto
do `/full-cycle-simple` (camadas 1+2 apenas; sem fetch de PR comments).

## Fase 6 — Testes (suite + Playwright se UI) com auto-fix até 3 iterações

**Divergência vs `/full-cycle` (paralelismo 5.5 ∥ 6).** O `/full-cycle-simple`
**não tem Fase 5.5** (`/code-review` é pulado neste modo enxuto), então não há
review concorrente, não há join de dois veredictos, e a regra de re-review
pós-auto-fix é **N/A**. Aqui a suíte de testes é o **único gate pré-PR** e roda
em foreground com o loop de auto-fix abaixo. O watch de CI em background
(Fase 8) é idêntico ao `/full-cycle`.

Antes de abrir PR:

1. **Detecte se a feature tocou UI:**
   `git diff origin/main..HEAD --name-only | grep -iE '\.(tsx?|jsx?|vue|svelte|html|css|scss)$'`.
   Se houver match, é UI.
2. **Se UI:** gere/rode teste Playwright cobrindo o critério de aceitação
   principal. Use `/e2e <fluxo>` se já existir base, senão crie em
   `tests/e2e/<slug>.spec.ts` seguindo a convenção do projeto. Detalhes em
   `~/.claude/skills/testing/SKILL.md`.
3. **Sempre:** rode a suite completa do projeto (detecte runner via
   `package.json scripts.test`, `pytest.ini`, `go test`, `cargo test`, etc.).
4. **Loop de auto-fix (até 3 iterações):**
   - Iteração 1: rodar testes. Se passou, prossegue Fase 7.
   - Se falhou: agente lê output, faz Edit nos arquivos relevantes (código de
     produção OU teste, conforme análise), commita o fix, re-roda.
   - Iteração 2: se passou, prossegue. Se falhou, repete.
   - Iteração 3: última tentativa. Se ainda falhar, **PARE** e escale para
     humano com: resumo dos 3 fixes tentados, output do teste falhante,
     hipótese atual sobre o bug.
   Não abra PR com testes vermelhos.

**Antes de escalar para humano:** sugira `/reflect --on-failure 6 --quick
--from-stdin` (alimentado por output do test runner).
