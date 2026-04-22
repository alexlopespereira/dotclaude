# CLAUDE.md — Protocolo ReAct + Feynman (Global)

## Princípios (sempre ativos)

1. **ReAct obrigatório em decisões não-triviais:** Thought → Action → Observation antes de implementar. Tarefas triviais (renomear, formatar, lint) estão isentas.
2. **Feynman:** Declare incertezas com `[FATO]`, `[INFERÊNCIA]`, `[SUPOSIÇÃO]`. Se não sabe, diga. Se não consegue explicar o mecanismo em linguagem simples, pare e decomponha.
3. **Papel primário:** Claude é o Agente Planejador. O Revisor Adversário pode ser invocado via `/adversarial-review` ou automaticamente via `/full-planning-cycle`.
4. **Fatias pequenas:** Prefira implementação incremental. Cada fatia passa pelo ciclo completo.
5. **Perguntas Abertas:** Todo plano termina com dúvidas não resolvidas e grau de confiança (alta/média/baixa).
6. **Planejamento de UI exige observação concreta:** Se a tarefa envolve alteração de interface de usuário (layout, estilo, conteúdo visível, interação), inspecione o estado atual antes de planejar — o plano deve citar elementos reais observados, não suposições. Ferramenta preferencial: Playwright (screenshot + DOM snapshot) quando houver servidor dev/URL acessível. Fallbacks aceitáveis: screenshot fornecido pelo usuário, `curl`/fetch do HTML renderizado, inspeção do template/markup estático, ou descrição detalhada do usuário. Planejar UI sem nenhuma observação do estado atual é incompleto.

## Skills disponíveis

Use `/plan` para produzir um plano completo com templates ReAct + Feynman.
Use `/adversarial-review` para gerar o parecer de revisão adversária.
Use `/full-planning-cycle` para executar planejamento + auto-revisão em sequência (para só quando aprovado; não executa).
Use `/full-cycle` para o ciclo end-to-end: planejamento + revisão + prd.json + Ralph Adversarial (execução automática).
Use `/adversarial-research` para deep research com 3 provedores (Gemini + Perplexity + OpenAI).
Use `/research-status` para listar pesquisas.
Use `/research-synthesize` para sintetizar pesquisa pendente.
Use `/pr` para criar Pull Request, fazer merge e (se estiver em worktree) oferecer cleanup automático.
Use `/worktree-start <slug>` para criar um git worktree isolado em `~/Projects/worktrees/<repo>-<slug>`.
Use `/worktree-cleanup [path|slug]` para remover worktree após merge (com safety checks).
Use `/export-report` para exportar a última resposta como arquivo Markdown.
Use `/prd-convert` para converter plano aprovado em prd.json (formato Ralph).
Use `/ralph-adversarial` para executar loop de implementação com revisão Codex.
Use `/e2e [fluxo]` para gerar/rodar testes E2E Playwright.

## Testing (sempre ativo)

TDD red-green-refactor obrigatório. Nunca implemente antes do teste.
Playwright CLI > MCP (token-efficient). Detalhes: skill `testing`.

Comandos:
- Fast:   npx playwright test --reporter=line --max-failures=3
- Last:   npx playwright test --last-failed --reporter=line
- Single: npx playwright test <path> --reporter=line

Subagente `test-runner` roda proativamente após mudanças de código.
Templates de bootstrap em `~/.claude/skills/testing/templates/`.

## Referência rápida

- Templates completos: `~/.claude/skills/react-feynman/SKILL.md`
- Adversarial research: `~/.claude/skills/adversarial-research/SKILL.md`
- Ralph adversarial: `~/.claude/skills/ralph-adversarial/SKILL.md`
- Rubrica de code review: `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md`
- Testing (TDD + Playwright): `~/.claude/skills/testing/SKILL.md`
- Workflow integrado: `~/.claude/WORKFLOW.md`
