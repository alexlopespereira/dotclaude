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

CONTRATO DE WORKER PARALELO (Fase 2 — não-negociável):
1. Delta files: escreva aprendizados APENAS em progress-<id>.txt e agents-delta-<id>.md
   no slot do worker. Esses arquivos devem permanecer UNTRACKED — NÃO faça `git add`
   neles, NÃO os inclua no commit. O orquestrador captura via filesystem após seu
   commit (stash em $ORCH/.ralph/delta-stash/<id>/) e integra ao progress.txt /
   AGENTS.md central no momento do merge. Para garantir que `git add .` (amplo) não
   os pegue acidentalmente, o pool já tem `.git/info/exclude` configurado para
   ignorá-los. NUNCA edite progress.txt ou AGENTS.md diretamente.

   Implicação prática: se o PRD da story restringe escopo (ex: "não tocar fora de
   scripts/"), os delta files na raiz NÃO violam o escopo — eles são protocolo
   do framework, não conteúdo do produto. Stage só os arquivos da implementação.
2. No push: faça git commit local. NÃO rode git push — o orquestrador serializa o push
   após review.
3. No history rewrite: NÃO use git commit --amend, git rebase -i, git reset (--hard ou
   não), git revert sobre seu próprio commit, nem qualquer operação que reescreva o DAG
   ou mexa o reflog do slot. Cada commit é imutável a partir do momento que existe.
   Detecção: o orquestrador roda pós-validação 3-camadas (SHA + reflog + filename).
   Violar qualquer uma faz o veredicto virar BLOCK automaticamente.
