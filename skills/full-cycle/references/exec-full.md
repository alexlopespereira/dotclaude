# Fases 5, 5.5 e 6 — Execução Ralph + code-review ∥ testes (/full-cycle)

> Reference do `/full-cycle`. Leia APENAS ao iniciar a Fase 5. O
> `/full-cycle-simple` usa `exec-simple.md`.

## Fase 5 — Execução Ralph Adversarial

1. Leia `~/.claude/skills/ralph-adversarial/SKILL.md`.
2. Verifique pré-requisitos: `jq`, `CODE_REVIEW.md`, e os CLIs necessários
   conforme os papéis:
   - Default: `claude` implementa, `codex` revisa → ambos precisam existir.
   - Se `PRIMARY_AGENT` / `REVIEWER_AGENT` estiverem definidos no ambiente,
     valide apenas os CLIs escolhidos.
3. Execute no cwd atual, **propagando as env vars de papéis** se definidas:
   ```bash
   chmod +x ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   PRIMARY_AGENT="${PRIMARY_AGENT:-claude}" REVIEWER_AGENT="${REVIEWER_AGENT:-codex}" \
     bash ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   ```
   Para inverter os papéis, o usuário lança o Claude Code com as vars no shell:
   `PRIMARY_AGENT=codex REVIEWER_AGENT=claude claude` — depois invoca `/full-cycle`.
4. Após conclusão, apresente resumo: stories completas/pendentes/escaladas,
   findings P0/P1, progress.txt.

**Gate:** Se houver stories escaladas ou findings P0 não resolvidos, **PARE** e
escale para humano. NÃO prossiga para PR.

**Antes de escalar para humano:** sugira `/reflect --on-failure 5 --context-file
<path-com-findings-P0>` para entender qual critério DoD teria capturado os
findings P0 antes do Ralph escalar.

## Fase 5.5 — Code review holístico pós-Ralph ∥ suíte de testes (Fase 6)

Após Ralph completar (Fase 5 verde), rode um code review holístico para captar
simplificações/reuse que o reviewer iteração-por-iteração não vê. Complementa
(não substitui) o adversarial do Ralph: o Codex revisa cada commit isoladamente;
este review olha o diff agregado.

**Paralelização Fase 5.5 ∥ Fase 6 (Princípio 9 + `run_in_background`).** A suíte
de testes (Fase 6) e o code review são independentes — rodam **concorrentes**.
**Antes** do review, dispare a suíte de testes do projeto em background via Bash
`run_in_background: true` (detecte o runner: `package.json scripts.test`,
pytest, go test, `bin/tests/...`). O **join explícito** (aguardar AMBOS verdes)
acontece na Fase 6, antes da Fase 7: o PR **só abre** com code-review sem P0
**e** suíte verde.

```bash
# 1. Marque o SHA coberto pelo review (consumido pela regra de re-review da Fase 6)
REVIEW_BASE_SHA=$(git rev-parse HEAD)
echo "REVIEW_BASE_SHA=$REVIEW_BASE_SHA" >> progress.txt

# 2. Suíte em background (run_in_background: true) — NÃO bloqueia a sessão.

# 3. Code review via subprocess headless (anti-inchaço: o corpo do /code-review
#    e o processo de análise ficam FORA da janela da sessão-mãe).
mkdir -p .claude/cache
claude -p "/code-review high" > .claude/cache/code-review-${REVIEW_BASE_SHA:0:8}.log 2>&1
```

Leia o log do review, transcreva os findings num bloco `## Code review findings`
no `progress.txt` (cwd atual). Princípio 11 aplica — transição interna não pede
confirmação humana.

**Gate:**
- **Findings P0 (crítico / segurança / correctness):** PARE — não prossiga para
  Fase 6. Sugira `/reflect --on-failure 5.5 --context-file <path-com-findings-P0>`
  antes de escalar pra humano.
- **Findings P1/P2 (simplificação / dead code / nits):** registre no
  `progress.txt` e prossiga para Fase 6. Humano decide no review do PR.

**Escopo do review.** No modelo Boris (Fase 5 já commitou em `main` local), o
alvo é `git diff origin/main..HEAD` — se a primeira execução mostrar escopo
errado, ajuste com argumento/flag de range na próxima iteração.

**Non-blocking se indisponível.** Se `/code-review` não existir (Claude Code
< v2.1.146) ou o subprocess falhar, registre o aviso e prossiga para Fase 6 —
é layer adicional de qualidade, não gate hard.

## Fase 6 — Join: suíte de testes + code-review

Ponto de junção do paralelismo da Fase 5.5. O PR só abre com **ambos verdes**.
Aguarde a task de testes em background concluir — o `run_in_background`
re-invoca a sessão na conclusão; leia o `TaskOutput` e confirme o exit code.

Se a suíte falhar, **PARE** e escale — não abra PR com testes vermelhos.
**Antes de escalar:** sugira `/reflect --on-failure 6 --from-stdin` (alimentado
por output do test runner).

**Re-review do parecer após auto-fix (gotcha do paralelismo 5.5 ∥ 6).** O review
analisou o diff em `REVIEW_BASE_SHA`. Se a suíte falhou e foram commitadas
correções **depois** desse SHA, esses fix-commits **não foram revisados**. Antes
da Fase 7, escolha:
- **(a) Re-review do delta:** re-rode o review restrito a
  `git diff $REVIEW_BASE_SHA..HEAD`. Use quando o delta tem lógica nova/não-trivial.
- **(b) Registrar SHA coberto:** delta trivial (ajuste de teste, typo,
  formatação) → registre em `progress.txt` a linha
  `CODE_REVIEW_VALID_UNTIL=<REVIEW_BASE_SHA>` + o range não-revisado
  (`$REVIEW_BASE_SHA..HEAD`).

Sem fix-commits após `REVIEW_BASE_SHA` (suíte passou de primeira), o parecer
cobre todo o diff e nenhuma das duas é necessária.
