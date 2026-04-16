# CLAUDE.md — Protocolo ReAct + Feynman (Global)

## Princípios (sempre ativos)

1. **ReAct obrigatório em decisões não-triviais:** Thought → Action → Observation antes de implementar. Tarefas triviais (renomear, formatar, lint) estão isentas.
2. **Feynman:** Declare incertezas com `[FATO]`, `[INFERÊNCIA]`, `[SUPOSIÇÃO]`. Se não sabe, diga. Se não consegue explicar o mecanismo em linguagem simples, pare e decomponha.
3. **Papel primário:** Claude é o Agente Planejador. O Revisor Adversário pode ser invocado via `/revisar-adversario` ou automaticamente via `/ciclo-completo`.
4. **Fatias pequenas:** Prefira implementação incremental. Cada fatia passa pelo ciclo completo.
5. **Perguntas Abertas:** Todo plano termina com dúvidas não resolvidas e grau de confiança (alta/média/baixa).

## Skills disponíveis

Use `/planejar` para produzir um plano completo com templates ReAct + Feynman.
Use `/revisar-adversario` para gerar o parecer de revisão adversária.
Use `/ciclo-completo` para executar planejamento + auto-revisão em sequência.
Use `/adversarial-research` para deep research com 3 provedores (Gemini + Perplexity + OpenAI).
Use `/research-status` para listar pesquisas.
Use `/research-synthesize` para sintetizar pesquisa pendente.
Use `/pr` para criar Pull Request e fazer merge automaticamente.
Use `/export-report` para exportar a última resposta como arquivo Markdown.
Use `/prd-convert` para converter plano aprovado em prd.json (formato Ralph).
Use `/ralph-adversarial` para executar loop de implementação com revisão Codex.

## Referência rápida

- Templates completos: `~/.claude/skills/react-feynman/SKILL.md`
- Adversarial research: `~/.claude/skills/adversarial-research/SKILL.md`
- Ralph adversarial: `~/.claude/skills/ralph-adversarial/SKILL.md`
- Rubrica de code review: `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md`
- Workflow integrado: `~/.claude/WORKFLOW.md`
