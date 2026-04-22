---
description: Cria um git worktree isolado em ~/Projects/worktrees/ com branch dedicado para trabalhar uma feature
allowed-tools: Bash(git *), Bash(mkdir *), Bash(basename *), Bash(pwd), Bash(ls *), Bash(realpath *), Bash(echo *), Bash(cat *), Bash(test *), Read, Write
argument-hint: <slug> [base-branch]
---

Cria um git worktree isolado para a feature `$ARGUMENTS`.

## Parâmetros

- `<slug>` — identificador curto, kebab-case (ex: `fix-auth-bug`, `add-dark-mode`). Obrigatório.
- `[base-branch]` — branch base. Default: `main`.

Se `$ARGUMENTS` estiver vazio, **PARE** e peça o slug ao usuário.

## Passos

1. **Validar entrada e estado do repo:**
   ```bash
   # Detectar repo root e nome
   REPO_ROOT=$(git rev-parse --show-toplevel)
   REPO_NAME=$(basename "$REPO_ROOT")

   # Primeiro argumento é o slug; segundo opcional é a base
   SLUG="<primeiro token de $ARGUMENTS>"
   BASE="<segundo token, ou 'main' se ausente>"

   # Sanitizar slug: só [a-z0-9-], lowercase
   ```

   Valide:
   - `SLUG` não vazio e matches `^[a-z0-9][a-z0-9-]*$`
   - `git status --porcelain` — se houver mudanças não commitadas no worktree atual, avise e pergunte se deseja prosseguir.
   - `git show-ref --verify --quiet refs/heads/$BASE` — base branch existe localmente.

2. **Preparar paths:**
   ```bash
   WORKTREE_BASE="$HOME/Projects/worktrees"
   WORKTREE_PATH="$WORKTREE_BASE/${REPO_NAME}-${SLUG}"
   mkdir -p "$WORKTREE_BASE"
   ```

   Se `$WORKTREE_PATH` já existir, **PARE** e informe: "Worktree já existe em $WORKTREE_PATH. Use `/delete-worktree` primeiro ou escolha outro slug."

3. **Atualizar base branch:**
   ```bash
   git fetch origin "$BASE" --quiet || true
   # Não mude o branch do worktree atual; apenas garanta que a base remota está atualizada
   ```

4. **Criar worktree:**
   ```bash
   # Se branch local já existe, usa; senão cria a partir de origin/BASE (ou BASE se offline)
   if git show-ref --verify --quiet "refs/heads/$SLUG"; then
     git worktree add "$WORKTREE_PATH" "$SLUG"
   else
     git worktree add "$WORKTREE_PATH" -b "$SLUG" "origin/$BASE" 2>/dev/null \
       || git worktree add "$WORKTREE_PATH" -b "$SLUG" "$BASE"
   fi
   ```

5. **Registrar worktree ativo** (para outros comandos detectarem):
   ```bash
   # Dentro do worktree recém-criado
   echo "$WORKTREE_PATH" > "$WORKTREE_PATH/.claude/.current-worktree" 2>/dev/null || \
     (mkdir -p "$WORKTREE_PATH/.claude" && echo "$WORKTREE_PATH" > "$WORKTREE_PATH/.claude/.current-worktree")
   ```

   Adicione `.claude/.current-worktree` ao `.gitignore` do worktree se ainda não estiver ignorado.

6. **Reportar:**
   ```
   Worktree criado:
     path:   <WORKTREE_PATH>
     branch: <SLUG>
     base:   <BASE>

   Próximos passos:
     - Faça `cd <WORKTREE_PATH>` e trabalhe normalmente. Comandos subsequentes
       (/plan, /full-cycle, /pr) operam no cwd atual.
     - Para remover após merge: /delete-worktree
   ```

## Guardrails

- **NUNCA** force overwrite de worktree existente — exige cleanup explícito.
- **NUNCA** crie worktree a partir de branch com mudanças não commitadas sem avisar.
- O path `~/Projects/worktrees/<repo>-<slug>` é a única convenção aceita — não use outros locais.
