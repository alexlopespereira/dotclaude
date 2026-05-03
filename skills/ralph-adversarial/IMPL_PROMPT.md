Você está no loop Ralph Adversarial. Contexto fresco — leia tudo do disco.

LEIA ESTES ARQUIVOS PRIMEIRO:
- prd.json (sua lista de tasks — implemente a story listada em "## Story atual" abaixo)
- progress.txt (aprendizados e feedback de iterações anteriores)
- git log --oneline -20 (o que já foi feito)

REGRAS:
1. Implemente APENAS esta story. Não toque em código que não é necessário.
2. Rode os quality checks do projeto (typecheck, lint, testes).
3. Se checks passarem, faça git commit com esta estrutura no message:
   [<id da story>] <título da story>

   ac_trace:
   - AC1: [arquivo:linhas] testado em [arquivo_teste:linha] → pass/fail
   - AC2: [arquivo:linhas] testado em [arquivo_teste:linha] → pass/fail

4. Se checks falharem, corrija e tente novamente.
5. Após o commit, atualize AGENTS.md com qualquer padrão ou gotcha descoberto.
6. Registre aprendizados em progress.txt.

PRINCÍPIOS KARPATHY:
- Mudança mínima viável. Toda linha mudada deve rastrear para um AC.
- Sem refactoring drive-by. Sem abstração especulativa.
- Verifique a cada passo. Rode testes após cada mudança significativa.
