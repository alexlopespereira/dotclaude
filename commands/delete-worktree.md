---
description: Remove git worktree em ~/Projects/worktrees/ após merge, verifica segurança e deleta o branch local
allowed-tools: Bash(git *), Bash(gh *), Bash(basename *), Bash(pwd), Bash(ls *), Bash(rm *), Bash(realpath *), Bash(echo *), Bash(cat *), Bash(test *), Read
argument-hint: [path-ou-slug] [--force]
---

Remove o worktree indicado (ou detecta automaticamente pelo cwd atual), após verificar que as mudanças foram merged.

## Parâmetros

- `[path-ou-slug]` — caminho absoluto do worktree **ou** slug (ex: `fix-auth-bug`). Se ausente, detecta do cwd.
- `--force` — pula checks de segurança (branch não merged, mudanças não commitadas). Use com cuidado.

## Passos

1. **Detectar worktree alvo:**
   ```bash
   # Ordem de resolução:
   # a) Se $ARGUMENTS tem um path absoluto existente → usa
   # b) Se tem slug → monta ~/Projects/worktrees/$(basename <main-repo>)-<slug>
   # c) Se vazio → usa cwd se estiver dentro de ~/Projects/worktrees/
   ```

   Se não conseguir detectar, **PARE** e peça o slug/path.

2. **Validar que é um worktree válido:**
   ```bash
   # Deve aparecer em `git worktree list`
   git worktree list --porcelain | grep -q "^worktree $TARGET_PATH$"
   ```

   Se NÃO for worktree listado, **PARE** com erro claro.

   **NUNCA** remova o worktree principal (main repo). Verifique:
   ```bash
   MAIN_ROOT=$(git -C "$TARGET_PATH" rev-parse --path-format=absolute --git-common-dir)
   # Se $TARGET_PATH == parent do common-dir → é o main repo, abortar.
   ```

3. **Safety checks (pular se `--force`):**

   a) **Mudanças não commitadas:**
   ```bash
   if [ -n "$(git -C "$TARGET_PATH" status --porcelain)" ]; then
     echo "ERRO: worktree tem mudanças não commitadas. Commit/stash ou use --force."
     exit 1
   fi
   ```

   b) **Branch merged:**
   ```bash
   BRANCH=$(git -C "$TARGET_PATH" rev-parse --abbrev-ref HEAD)

   # Tentar via gh primeiro (mais confiável se há PR)
   PR_STATE=$(gh pr list --head "$BRANCH" --state all --json state,mergedAt --limit 1 2>/dev/null | jq -r '.[0].state // "NONE"')

   if [ "$PR_STATE" = "MERGED" ]; then
     MERGED=true
   elif git merge-base --is-ancestor "$BRANCH" origin/main 2>/dev/null; then
     MERGED=true
   else
     MERGED=false
   fi

   if [ "$MERGED" != "true" ]; then
     echo "ERRO: branch '$BRANCH' não foi merged em main. Use --force para remover mesmo assim."
     exit 1
   fi
   ```

4. **Remover worktree:**
   ```bash
   git worktree remove "$TARGET_PATH"
   git worktree prune
   ```

   Se `--force` foi passado e `remove` falhar (ex: untracked files), use `git worktree remove --force "$TARGET_PATH"`.

5. **Deletar branch local** (se merged):
   ```bash
   if [ "$MERGED" = "true" ]; then
     git branch -d "$BRANCH" 2>/dev/null || true
   fi
   ```

   **NÃO** faça `git push --delete origin $BRANCH` — `gh pr merge --delete-branch` já cuida disso.

6. **Reportar:**
   ```
   Worktree removido:
     path:   <TARGET_PATH>
     branch: <BRANCH> (local deletado)
     merged: <true|false>
   ```

## Guardrails

- **NUNCA** remova o repo principal.
- **NUNCA** force cleanup sem `--force` explícito do usuário.
- **NUNCA** delete branch local se `--force` foi usado mas o branch não estava merged — pode haver trabalho não publicado.
- Se `gh` não estiver disponível ou `origin/main` não existir, caia para `git merge-base --is-ancestor` como fallback.
