---
description: Mergea um PR aberto agora (modo soft default, --wait aguarda CI, --admin bypassa proteção). Auto-sync do pool Boris após merge.
allowed-tools: Bash(bash *), Bash(gh *), Bash(git *), Bash(jq *), Bash(test *), Bash(chmod *), Read
argument-hint: [PR-num|branch-name] [--wait] [--admin] [--merge-method=squash|merge|rebase] [--wait-timeout=Nm] [--no-sync]
---

Mergea um PR aberto agora, sem esperar `--auto`. Cobre o caso onde `gh pr merge --auto` não funciona (repo sem `allow_auto_merge` ligado) ou onde você quer mergear imediatamente em repo solo. Após merge bem-sucedido, dispara `/sync` para atualizar todos os slots do pool Boris.

## Modos

- **soft (default):** `gh pr merge <num> --squash --delete-branch`. Mergeia agora se o GitHub permitir (CI satisfeito ou ausente, branch sem proteção ou proteção atendida).
- **`--wait`:** aguarda CI passar (`gh pr checks --watch` com timeout default 30min, override `--wait-timeout=Nm`), então mergeia soft. Se PR não tem checks, pula wait e mergeia direto. Se algum check falha, aborta sem mergear.
- **`--admin`:** `gh pr merge <num> --admin --squash --delete-branch`. **Bypassa branch protection e CI obrigatório.** Sempre exige confirmação humana (mesmo dentro de slash compostos).

## Como o comando descobre o PR alvo

1. **Argumento explícito** (`/force-merge 42` ou `/force-merge feat/foo`) — usa esse número/branch direto.
2. **Sem argumento** — `gh pr list --author @me --state open` filtrando `isDraft=false`:
   - 1 candidato → auto-seleciona e mostra qual.
   - 0 candidatos → erro: passe um número.
   - >1 candidatos → erro listando todos: passe explicitamente.

## Procedimento

Você deve seguir esta sequência ao executar `/force-merge`:

### Passo 1 — Resolver alvo e validar estado

Invoque `bin/force-merge.sh` em modo "dry-detect" (sem flag de execução):

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/force-merge.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
```

Mas o script atual é always-execute. Para "dry-detect" use `gh` diretamente:

```bash
# Se o usuário passou ARG numérico, é o PR_NUM.
# Se passou nome de branch, resolva: gh pr list --head "$ARG" --state open --json number --jq '.[0].number // empty'
# Se sem ARG, auto-detect:
gh pr list --author @me --state open --json number,title,headRefName,isDraft \
  | jq '[.[] | select(.isDraft == false)]'
```

### Passo 2 — Apresentar proposta ao usuário

Mostre no chat **exatamente** este formato (preenchendo os valores reais):

```
PR alvo:    #<NUM>  '<TÍTULO>'
Branch:     <HEAD_REF>  →  <BASE_REF>
Modo:       <soft | wait | admin>
Proteção:   <não-protegida | protegida>
Auto-sync:  <sim | não (--no-sync)>
```

### Passo 3 — Decidir se precisa confirmação

Aplica esta tabela:

| modo | proteção | composto? | confirma? |
|------|----------|-----------|-----------|
| soft | não      | qualquer  | **não** — execute direto |
| soft | sim      | qualquer  | **sim** |
| wait | qualquer | sim (`FORCE_MERGE_NESTED=1`) | **não** (composto pode pular) |
| wait | qualquer | não       | **sim** |
| admin | qualquer | qualquer | **sim, sempre** |

Para confirmar: pergunte literalmente no chat **`Mergear? [y/N]`** e aguarde resposta. Trate qualquer coisa diferente de `y`/`yes`/`s`/`sim` como negativa → aborte.

### Passo 4 — Executar

Quando confirmação foi obtida (ou não era necessária), invoque o script com flag inline `FORCE_MERGE_CONFIRMED=1` repassando os args do usuário:

```bash
FORCE_MERGE_CONFIRMED=1 bash "$HOME/Projects/dotclaude/bin/force-merge.sh" $ARGS
```

Se o usuário passou `--no-sync`, `--admin`, `--wait`, `--merge-method=...`, `--wait-timeout=...`, repasse tudo.

### Passo 5 — Reportar resultado

O script imprime mensagens claras (`✓ PR #N mergeado`, `aviso: cwd fora do pool`, etc). Repasse a saída sem reescrever. Se sucesso, lembre que `/sync` foi disparado automaticamente (a menos que `--no-sync`).

## Edge cases (o script trata; relate ao usuário)

- **PR já MERGED** (`exit 0`): "PR já estava mergeado — sync rodado mesmo assim."
- **PR CLOSED sem merge** (`exit 1`): "PR foi fechado sem merge. Reabrir manualmente se quiser."
- **PR é draft** (`exit 1`): "PR é draft. Converta com `gh pr ready <num>` e tente novamente."
- **Sem PRs abertos** (`exit 1`): "nenhum PR seu aberto — passe número se quer mergear PR de outro autor."
- **Múltiplos PRs ambíguos** (`exit 1`): mostra a lista, pede para passar o número.
- **Auto-sync fora do pool**: mensagem "cwd fora do pool Boris — sync pulado", mas merge OK.
- **Combinação `--wait --admin`** (`exit 2`): mutuamente exclusivas; o script recusa.

## Compostos (Princípio 11)

Quando `/force-merge` é invocado dentro de outro slash command composto (ex: futuro Ralph step), o agente seta `FORCE_MERGE_NESTED=1` antes do script. Isso permite que `--wait` pule a confirmação (a invocação composta já é o gate). **`--admin` sempre confirma**, mesmo nested — bypass de proteção é classe destrutiva (Princípio 11(a)).

## Guardrails

- **NUNCA** pule confirmação de `--admin` (mesmo nested).
- **NUNCA** execute o script sem confirmação humana quando a tabela do Passo 3 exige.
- Se `gh` não está autenticado, reporte e pare — não tente reauth.
- Se `bin/force-merge.sh` retornar `rc=3` (falta confirmação), foi bug do markdown — você esqueceu de setar `FORCE_MERGE_CONFIRMED=1` após confirmar.
