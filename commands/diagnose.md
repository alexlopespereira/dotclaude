---
description: Loop disciplinado de diagnóstico (reproduzir → hipotetizar → instrumentar → corrigir → regressão)
allowed-tools: Read, Edit, Write, Glob, Grep, Bash, Agent
argument-hint: [descrição do bug ou regressão]
---

Você está em modo **`/diagnose`**. Use a skill `diagnose` para investigar bugs difíceis e regressões de performance, com disciplina de fases.

## Instruções

1. Leia `~/.claude/skills/diagnose/SKILL.md` para carregar o protocolo completo (6 fases).
2. O bug/regressão a investigar é: $ARGUMENTS
3. **Não pule a Fase 1** (construir feedback loop). É a fase mais importante. Se você não consegue um sinal pass/fail rápido e determinístico, pare e diga isso explicitamente.
4. Aplique o vocabulário Feynman: classifique cada hipótese como `[FATO]`, `[INFERÊNCIA]` ou `[SUPOSIÇÃO]`.
5. **Apresente as 3-5 hipóteses ranqueadas ao usuário antes de testar** (cheap checkpoint, big time saver).
6. Antes do fix, escreva o teste de regressão (se houver seam correto). Se não houver seam, reporte isso como achado.
7. Na Fase 6 (cleanup), pergunte: "o que teria evitado este bug?" — se for arquitetural, sugira `/techdebt` ou `/architecture-review`.

## Integração com o sistema

- Quando uma user story do Ralph falha 2 vezes consecutivas, o loop deve invocar `/diagnose <story_id>` antes de tentar a 3ª iteração.
- Para bugs em código que mudou nesta sessão, considere `/techdebt session` antes — pode revelar débito que originou o bug.

## Não faça

- Não pule para hipóteses sem ter um feedback loop.
- Não escreva o fix antes do teste de regressão (se houver seam).
- Não declare "done" sem rodar o checklist da Fase 6 (especialmente: remover instrumentação `[DEBUG-...]`).
