---
description: Ciclo end-to-end enxuto pra features simples — sem revisão adversária (Fase 2) e sem Codex review no Ralph. Use quando a feature tem escopo único, ≤5 arquivos tocados, sem schema migration/dep/auth, sem custo recorrente. Se mid-Plan algum critério disparar, agente pausa e oferece escalar pra /full-cycle.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(find *), Bash(bash *), Bash(chmod *), Bash(cat *), Bash(jq *), Bash(grep *), Bash(wc *), Bash(git *), Bash(gh *), Bash(ls *), Bash(pwd), Bash(cd *), Bash(echo *), Bash(test *)
argument-hint: [descrição curta da feature simples]
---

Versão enxuta de `/full-cycle` para **features simples**: pula a revisão adversária (Fase 2) e o reviewer dentro do Ralph (Fase 5). Mantém Plan + PRD + implementação Ralph + testes + PR.

**Quando usar:** escopo único (1-3 user stories), ≤5 arquivos, sem schema migration / nova dependência / mudança em auth, sem custo financeiro recorrente. Se algum critério falhar ao fim da Fase 1, o gate E3 pausa e oferece escalar pra `/full-cycle`.

**Modelo trunk-based (Boris Cherny).** O cwd é um slot do pool (`/checkout-use <repo> <slot>` antes). **Não criamos branch** — `main` local, branch efêmera só no push, sync via `/checkout-sync-all`.

**Progressive disclosure.** Instruções detalhadas por fase em `~/.claude/skills/full-cycle/references/`. **ANTES de cada fase, leia APENAS o reference da fase corrente.** Os gates resumidos abaixo valem mesmo sem o reference carregado.

**Protocolo de janela de contexto (obrigatório):** idêntico ao `/full-cycle` — (1) um ciclo por janela: novo ciclo na mesma sessão interativa → `/handoff-continue` + `/clear` primeiro; (2) contexto pesado ao fim da Fase 1.5 → handoff antes de executar; (3) subagents gravam detalhe em arquivo e retornam ≤15 linhas.

## Fases

**Fase 1 — Planejamento** · reference: `fase1-plan.md` — IDÊNTICO ao /full-cycle
Ciclo ReAct para: $ARGUMENTS. Plano em `.claude/plans/<slug>.md` + flag de custo + docs de domínio (termos OBSERVADOS no CONTEXT.md, seção `## ADRs propostos`; biblioteca domain-docs — `~/.claude/skills/domain-docs/SKILL.md`).

**Fase 1.5 — Gate de complexidade (E3)**
Auto-assessment via script determinístico — fonte única dos 6 triggers T1-T6 (>3 fatias, schema migration, nova dependência, auth/permissions, >5 arquivos, custo financeiro):

```bash
bash $HOME/Projects/dotclaude/bin/gate-e3.sh ".claude/plans/<slug>.md" ".claude/plans/<slug>.flags"
```

Contrato (detalhes no header do script): `GATE_E3_CLEAN` + exit 0 → prossiga. `GATE_E3_TRIGGERED` + exit 1 → **PARE** e pergunte ao humano: (1) continuar assim mesmo, (2) escalar pra `/full-cycle` (Plan reusável), ou (3) abortar. Exit 2 → invocação errada, corrija.

*Override auditável* (falso-positivo textual): emita no próprio plano `<!-- gate-e3-override: TN motivo não-vazio -->` — suprime SÓ o trigger citado; motivo obrigatório (fail-closed); **T6 (custo, P11e) NÃO é suprimível**. Use SOMENTE quando o plano apenas MENCIONA termos de auth/custo como prosa sem tocar arquivos de auth/permissões/settings (caso real 2026-07-02: plano citava "auth do Codex" e vocabulário de custo vindos de logs — T4 dispararia por prosa). Confira nas fatias/`touchesFiles` que a superfície real não muda; na dúvida, não emita.

**Fase 4 — Conversão em PRD** · reference: `fase4-prd.md` — IDÊNTICO ao /full-cycle
Materialização de ADRs no início da fase de execução (pós-gate de aprovação da Fase 1.5): `## ADRs propostos` → `docs/adr/` + marcador `<!-- adr-materialized -->`. Plano → `prd.json` (skill `prd`), validação `jq`, gate humano se `hasFinancialCost: true`. **Sem Fase 4.5** (test-spec é do `/full-cycle`).

**Fase 5 — Ralph SEM reviewer (--no-review)** · reference: `exec-simple.md`
`ralph-adversarial.sh --no-review` (não exige `codex`). Stories escaladas → **PARE** (sugira `/reflect --on-failure 5 --quick`).

**Fase 6 — Testes com auto-fix até 3 iterações** · reference: `exec-simple.md`
Único gate pré-PR (sem Fase 5.5 neste modo): suíte completa + Playwright se tocou UI; loop de auto-fix 3×; ainda vermelho → **PARE** (sugira `/reflect --on-failure 6 --quick --from-stdin`). Não abra PR com testes vermelhos.

**Fase 7 — Branch efêmera + Push + PR** · reference: `fase7-8-deliver.md` — IDÊNTICO ao /full-cycle
`/commit-push-pr "<mensagem>"` (auto-merge ON por default). Push rejeitado → **PARE**.

**Fase 8 — Watch de CI + merge + sync** · reference: `fase7-8-deliver.md` — IDÊNTICO ao /full-cycle
`bin/pr-watch.sh` em background; exit codes pelo reference (142 = ainda rodando). Verde → sync (`/checkout-sync-all`; `/force-merge` se auto-merge não pegou). Vermelho → **PARE**.

**Fase 9 — Reflexão DoD (--baseline --quick)** · reference: `fase9-reflect.md`
Subprocess headless em background, non-blocking, modelo padrão configurado (sem `--model`):

```bash
PR_NUMBER=$(gh pr list --state merged --limit 1 --base main --json number --jq .[0].number)
mkdir -p ~/.claude/cache/reflect
claude -p "/reflect $PR_NUMBER --baseline --quick" \
  >> ~/.claude/cache/reflect/fase9-fullcycle-simple.log 2>&1 &
disown
```

## Guardrails

- **Plan completo é obrigatório** — atalhos de planejamento foram intencionalmente NÃO cortados.
- **Gate E3** ao fim da Fase 1 é não-negociável.
- **Princípios 7 (segredos) e 11 (a-e) continuam ativos** mesmo nesse modo "sem interrupção".
- Humano pode interromper via Ctrl-C; qualquer fase falhou → reporte e PARE.
- **Modelo:** `main` local → branch efêmera no push → PR → merge (auto) → sync. Branch protection mantida.
