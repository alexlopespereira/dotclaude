---
description: Cria branch efêmera, commita, pusha e abre PR. Argumentos opcionais — Claude infere mensagem e branch do contexto se você não passar.
allowed-tools: Bash(bash *), Bash(chmod *), Bash(test *), Bash(git *), Bash(gh *), Read, Glob, Grep
argument-hint: ["mensagem"] [--branch=NAME] [--type=...] [--no-pr] [--draft] [--no-auto-merge] [--merge-method=squash|merge|rebase]
---

Empacota o trabalho do slot atual em uma branch efêmera e abre PR para `main`. **Todos os argumentos são opcionais.** Se você não passar nada, Claude infere mensagem e nome de branch a partir do contexto e propõe antes de executar.

## Modo de operação

### A) Sem argumentos (`/commit-push-pr`)

Claude **infere** mensagem e branch a partir de:

1. **Diff atual:**
   ```bash
   git status --short
   git diff --stat
   git diff --no-color | head -200   # primeiras 200 linhas do diff bruto
   ```

2. **Commits ahead de `origin/main`** (se trabalho já foi commitado em main local):
   ```bash
   git log --oneline origin/main..HEAD
   git log -p origin/main..HEAD | head -300
   ```

3. **Estilo de commits do repo:**
   ```bash
   git log --oneline -20
   ```

4. **Contexto da conversa atual** — o que foi discutido/implementado nesta sessão.

A partir disso, **gera duas coisas**:

- **Mensagem em Conventional Commits.** Tipo correto (`feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `perf`). Subject em imperativo, foco no **porquê**, ≤72 chars na 1ª linha. Body opcional se a mudança merecer explicação.
- **Nome da branch.** Default é deixar o script auto-gerar do prefixo + slug da mensagem (`feat/add-dark-mode`). Override só se Claude tiver um nome semanticamente melhor (ex: contexto da conversa indica o nome ideal).

**Apresentar proposta ao usuário** no formato (com sugestão de PR mode baseada em heurística):

```
Mensagem proposta:
  feat: add dark mode toggle in settings page

Branch proposta: feat/add-dark-mode-toggle
Tipo: feat | Arquivos: 3 | Linhas: +47 -12

PR mode sugerido: ready (não-draft)
  → Confirmar tudo? (y / n / editar / draft / no-pr)
```

**Heurística para sugerir PR mode:**

- **`draft`** quando: muitos arquivos (>10), mudança grande (>300 linhas), tipo é `feat` em domínio crítico, mensagem do usuário ou contexto da sessão sugere "WIP/incompleto", ou a sessão envolveu spike/exploração.
- **`no-pr`** quando: trabalho é manifestamente experimental e o usuário sinalizou que só quer salvar progresso (ex: nome do slot é "spike" ou label do `.slot-info` é "experiment"), ou é commit em branch já-existente que não quer abrir PR ainda.
- **`ready`** (default): qualquer outro caso.

**Respostas aceitas:**

- `y` ou enter → executa exatamente como proposto.
- `n` → aborta sem fazer nada.
- `editar` ou `e` → reabre proposta para ajuste (mensagem, branch, tipo).
- `draft` → mantém msg/branch propostas, mas adiciona `--draft`.
- `no-pr` → mantém msg/branch, mas adiciona `--no-pr` (apenas push, sem PR).

Apresente a heurística por trás da sugestão em uma linha curta logo após a proposta (ex: "sugerindo `draft` porque diff tem 412 linhas em 14 arquivos"). Mantém o usuário no controle sem forçar leitura de docs.

### B) Com mensagem (`/commit-push-pr "feat: ..."`)

Use a mensagem do usuário diretamente. Não infera, não pergunte. Branch ainda é auto-gerada (a menos que `--branch=` seja passado).

### C) Com flags adicionais

Repasse para o script:
- `--branch=NAME` força nome de branch.
- `--type=feat|fix|chore|refactor|docs|test|perf` força tipo (override do detectado). **Default quando nada indica: `chore`.**
- `--no-pr` só pusha, sem PR.
- `--draft` abre PR como draft (auto-merge é desabilitado em drafts automaticamente).
- `--no-auto-merge` abre PR sem habilitar auto-merge.
- `--merge-method=squash|merge|rebase` método do auto-merge (default: `squash`).

**Auto-merge é DEFAULT.** Após criar o PR, o script roda `gh pr merge --auto --squash --delete-branch` — o GitHub mergeia automaticamente quando CI e reviews exigidos passarem. Para desligar pontualmente: `--no-auto-merge`.

## Passos finais (em qualquer modo)

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/commit-push-pr.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
bash "$SCRIPT" "$MSG" $EXTRA_FLAGS
```

Após sucesso, reporte o link do PR e instrua:
```
PR aberto: <URL>
Após review/merge no GitHub, rode: /checkout-sync-all <repo>
```

## Guardrails

- **Modo A (inferência)** exige confirmação explícita antes de commitar — você não vai criar PR baseado num palpite.
- **NUNCA** commite arquivos suspeitos de segredo (`.env*`, `*.pem`, `credentials*`, `*.key`). Se aparecerem no diff, liste e pergunte se entram antes de prosseguir.
- **NUNCA** force-push em `main`.
- **NUNCA** pule branch protection com `--admin`.
- Se `git push` for rejeitado por hook do servidor, reporte a mensagem original; não tente bypass.
- Se a inferência ficar fraca (diff muito grande/heterogêneo), **pare** e peça ao usuário para passar a mensagem explicitamente em vez de chutar.
