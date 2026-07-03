---
description: Ciclo end-to-end — planejamento + revisão adversária + PRD + Ralph + PR/merge
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(find *), Bash(bash *), Bash(chmod *), Bash(cat *), Bash(jq *), Bash(git *), Bash(gh *), Bash(ls *), Bash(pwd), Bash(cd *), Bash(echo *), Bash(test *)
argument-hint: [descrição do problema ou feature]
---

Executa o ciclo completo de entrega no cwd atual: planejamento → revisão adversária → PRD → Ralph → commit + push em main.

**Modelo trunk-based (Boris Cherny).** O cwd é um slot do pool de checkouts (`/checkout-use <repo> <slot>` antes de invocar). **Não criamos branch** — trabalho em `main` local, branch efêmera só no push, e propagação aos outros slots via `/checkout-sync-all`. Para apenas planejar (sem executar/merge), use `/full-planning-cycle`.

**Progressive disclosure.** As instruções detalhadas de cada fase vivem em `~/.claude/skills/full-cycle/references/`. **ANTES de iniciar cada fase, leia (Read) APENAS o reference da fase corrente** — nunca todos de uma vez. Os gates resumidos abaixo valem mesmo sem o reference carregado.

## Protocolo de janela de contexto (obrigatório)

Sessões-maratona são a causa nº 1 de contexto 400k+ (medição 2026-07-03: sessões de 360–1846 mensagens chegando a 994k). Regras:

1. **Um ciclo por janela.** Ao concluir a Fase 8, o ciclo terminou. Novo `/full-cycle` na mesma sessão interativa → PRIMEIRO rode `/handoff-continue` e peça `/clear`.
2. **Checkpoint pós-Fase 3.** O estado do ciclo vive em disco (plano + `.flags` + prd.json + progress.txt) — a execução não depende da memória da janela. Se o contexto já está pesado ao fim da Fase 3 (aviso de contexto do harness, ou planejamento longo com muitos subagents), rode `/handoff-continue "executar Fases 4–8 do plano <path>"` e peça `/clear` em vez de seguir na mesma janela. Em sessão headless (`claude -p`) siga direto — cada `-p` já é janela nova.
3. **Subagents retornam enxuto (Princípio 9).** O texto final de cada subagent volta INTEIRO ao contexto da sessão-mãe — instrua cada um a gravar o relatório em arquivo e responder ≤15 linhas (conclusões + path).

## Fases

**Fase 1 — Planejamento** · reference: `fase1-plan.md`
Papel Agente Planejador; ciclo ReAct para: $ARGUMENTS. Salva plano em `.claude/plans/<slug>.md` + flag de custo (`.flags`, heurística por shell) + docs de domínio (termos OBSERVADOS no CONTEXT.md e seção `## ADRs propostos`; regras na biblioteca domain-docs — `~/.claude/skills/domain-docs/SKILL.md`).

**Fase 2 — Revisão Adversária** · reference: `fase2-3-adversarial.md`
Papel Agente Revisor; refutações paralelas; parecer anexado ao plano sob `---`.

**Fase 3 — Gate de Aprovação** · reference: `fase2-3-adversarial.md`
REPROVADO → **PARE**, escale (sugira `/reflect --on-failure 3`). APROVADO COM RESSALVAS → registre ressalvas como ACs e prossiga (Princípio 11). APROVADO → prossiga. Depois aplique o item 2 do Protocolo de janela.

**Fase 4 — Conversão em PRD** · reference: `fase4-prd.md`
Materialização de ADRs no início da fase de execução (pós-gate de aprovação): seção `## ADRs propostos` → `docs/adr/` + marcador `<!-- adr-materialized -->` no plano. Converte plano → `prd.json` (skill `prd`), valida com `jq`, gate humano se `hasFinancialCost: true` (Princípio 11e).

**Fase 4.5 — Test specs (TDD bake-in)** · reference: `fase4-prd.md`
`claude -p "/test-spec <plan>"` como subprocess headless — anexa `## Test Specs` ao plano. Best-effort: falha NÃO interrompe o pipeline.

**Fase 5 — Execução Ralph Adversarial** · reference: `exec-full.md`
`ralph-adversarial.sh` (papéis via `PRIMARY_AGENT`/`REVIEWER_AGENT`). Stories escaladas ou P0 não resolvidos → **PARE**, escale (sugira `/reflect --on-failure 5`).

**Fase 5.5 — Code review holístico ∥ Fase 6 testes** · reference: `exec-full.md`
Suíte de testes em background (`run_in_background`) ∥ `claude -p "/code-review high"` como subprocess. Marque `REVIEW_BASE_SHA` antes. P0 → **PARE**; P1/P2 → registre em progress.txt e siga.

**Fase 6 — Join** · reference: `exec-full.md`
PR só abre com suíte verde **e** review sem P0. Suíte vermelha → **PARE** (sugira `/reflect --on-failure 6 --from-stdin`). Fix-commits pós-`REVIEW_BASE_SHA` → re-review do delta ou registrar `CODE_REVIEW_VALID_UNTIL`.

**Fase 7 — Branch efêmera + Push + PR** · reference: `fase7-8-deliver.md`
`/commit-push-pr "<mensagem>"`. Push rejeitado por proteção → **PARE**, não tente bypass.

**Fase 8 — Watch de CI + merge + sync** · reference: `fase7-8-deliver.md`
`bin/pr-watch.sh` em background; interprete exit codes pelo reference (142 = ainda rodando, NÃO é vermelho). CI verde → merge (se preciso `/force-merge`) + `/checkout-sync-all`. CI vermelho → **PARE**.

**Fase 9 — Reflexão sobre DoD** · reference: `fase9-reflect.md`
Compute `NEED_LEARN`/`REFLECT_MODE` pela heurística do reference e dispare como subprocess em background — non-blocking, usa o modelo padrão configurado (sem `--model`):

```bash
PR_NUMBER=$(gh pr list --state merged --limit 1 --base main --json number --jq .[0].number)
mkdir -p ~/.claude/cache/reflect
REFLECT_NESTED=1 REFLECT_LEARN_GATE=$([ "$NEED_LEARN" = "true" ] && echo 1 || echo 0) \
  claude -p "/reflect $PR_NUMBER $REFLECT_MODE" \
  >> ~/.claude/cache/reflect/fase9-fullcycle.log 2>&1 &
disown
```

## Guardrails

- Nenhum código de produção é escrito antes do veredicto APROVADO.
- Humano pode interromper em qualquer fase.
- Se qualquer fase falhar, reporte o status e PARE — não improvise.
- **Modelo:** trabalho em `main` local → branch efêmera no push → PR → merge → sync. Branch protection mantida.
