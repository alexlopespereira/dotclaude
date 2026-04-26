---
description: Analisa o código mudado nesta sessão atrás de tech debt e propõe plano de limpeza
allowed-tools: Read, Bash(git *), Bash(grep *), Bash(find *), Glob, Grep
argument-hint: [escopo: "session" | "branch" | "<path>"]
---

Analisa o código em busca de **tech debt** acumulado e propõe plano de limpeza priorizado.

## Escopo

- `$ARGUMENTS` vazio ou `session` → `git diff` desde o último commit ou desde o início da sessão (use `git diff` + arquivos modificados).
- `branch` → `git diff origin/main...HEAD` (mudanças vs main).
- `<path>` → analisa apenas o path indicado (arquivo ou diretório).

## Passos

1. **Coletar escopo:**
   ```bash
   case "$ARGUMENTS" in
     ""|session) FILES=$(git diff --name-only HEAD ; git diff --cached --name-only ; git ls-files -o --exclude-standard) ;;
     branch) FILES=$(git diff --name-only origin/main...HEAD) ;;
     *) FILES="$ARGUMENTS" ;;
   esac
   ```

2. **Para cada arquivo no escopo, identificar:**
   - **Código duplicado** — funções/blocos quase idênticos.
   - **Abstrações desnecessárias** — wrappers que só repassam, classes com 1 método.
   - **Variáveis/imports não utilizados.**
   - **Dead code** — branches inalcançáveis, funções nunca chamadas.
   - **Comentários TODO/FIXME** ainda relevantes.
   - **Magic numbers/strings** que mereceriam constantes.
   - **Funções gigantes** (>50 linhas, mais de 1 responsabilidade).
   - **Try/catch genéricos** que engolem erros.
   - **Acoplamento alto** — módulo importando muitos outros sem necessidade.

3. **Priorizar findings:**
   - **P0 (corrigir já)** — bugs latentes, vazamentos, segurança.
   - **P1 (próxima sessão)** — duplicação clara, dead code grande.
   - **P2 (eventual)** — estilo, comentários, magic numbers.

4. **Produzir relatório no formato:**

   ```markdown
   ## Tech Debt — escopo: <escopo>

   ### P0 — Crítico (N findings)
   - [path:linha] Descrição. Plano: <ação concreta>.

   ### P1 — Alto (N findings)
   - …

   ### P2 — Baixo (N findings)
   - …

   ## Plano de limpeza recomendado
   1. Comece por P0 (estimativa: X min).
   2. Faça P1 em sessão dedicada.
   3. P2 só se sobrar tempo.

   ## Próximos passos
   - `/full-cycle "limpar tech debt P0"` para o ciclo completo.
   - Ou aplique fixes pontuais e use `/commit-push-pr "tech debt cleanup"`.
   ```

## Guardrails

- **NÃO implemente nada** — esta skill é só análise + plano. O usuário decide o que executar.
- Se não há findings, diga isso explicitamente e pare. Não invente débito.
- Use `[FATO]/[INFERÊNCIA]/[SUPOSIÇÃO]` quando a severidade não for óbvia.
