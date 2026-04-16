Crie um Pull Request e faça merge automaticamente. Siga estes passos na ordem:

1. **Verificar estado do branch:**
   - Rode `git status` para ver mudanças pendentes.
   - Se houver mudanças não commitadas, faça commit primeiro (siga o padrão de commits do repo).
   - Identifique o branch atual. Se estiver em `main`, crie um novo branch com nome descritivo baseado nas mudanças.

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
   - Se o merge falhar por proteção de branch ou reviews pendentes, informe o usuário.

6. **Voltar para main:**
   - Rode `git checkout main && git pull` para atualizar o branch local.

7. **Reportar resultado:**
   - Mostre o link do PR merged.
