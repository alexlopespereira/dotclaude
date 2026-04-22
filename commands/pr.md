Crie um Pull Request e faça merge automaticamente. Siga estes passos na ordem:

1. **Verificar estado do branch:**
   - Rode `git status` para ver mudanças pendentes.
   - Se houver mudanças não commitadas, faça commit primeiro (siga o padrão de commits do repo).
   - Identifique o branch atual. Se estiver em `main`, crie um novo branch com nome descritivo baseado nas mudanças.
   - **Detecte se o cwd está dentro de `~/Projects/worktrees/`** — guarde o path em `WORKTREE_PATH` (usado apenas para `cd` de volta ao repo principal na etapa 6).

2. **Push para o remote:**
   - Rode `git push -u origin <branch>` para enviar o branch.

3. **Criar o PR:**
   - Use `gh pr create` com título curto (<70 chars) e body com resumo das mudanças.
   - O body deve seguir o formato:
     ```
     ## Summary
     - <bullets descrevendo as mudanças>

     🤖 Generated with [Claude Code](https://claude.ai/code)
     ```

4. **Aguardar checks (se houver):**
   - Rode `gh pr checks <pr-number> --watch` para aguardar CI.
   - Se não houver checks configurados, prossiga direto.

5. **Merge do PR:**
   - Rode `gh pr merge <pr-number> --merge --delete-branch` para fazer merge e deletar o branch remoto.
   - Se o merge falhar por proteção de branch ou reviews pendentes, informe o usuário e **PARE**.

6. **Voltar para o repo principal e atualizar:**
   - Se estava em worktree: `cd` para o repo principal — `MAIN_ROOT=$(git -C "$WORKTREE_PATH" rev-parse --path-format=absolute --git-common-dir | xargs dirname)`. Então `cd "$MAIN_ROOT" && git checkout main && git pull`.
   - Se não estava em worktree: `git checkout main && git pull`.

7. **Reportar resultado:**
   - Mostre o link do PR merged.
   - Se o merge aconteceu a partir de um worktree, lembre o usuário: "Worktree em `$WORKTREE_PATH` preservado. Para remover manualmente: `/delete-worktree`."

## Guardrails

- **NUNCA** delete branch local se o merge falhou — o trabalho ainda é necessário.
- **NUNCA** remova worktree automaticamente — gestão de worktree é explícita e fica com o usuário (`/delete-worktree`).
