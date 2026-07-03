# Fase 1 — Planejamento (Agente Planejador)

> Reference do `/full-cycle` e `/full-cycle-simple`. Leia APENAS quando estiver
> iniciando a Fase 1 — não carregue os demais references junto (progressive
> disclosure; ver Protocolo de janela no corpo do comando).

1. Leia `~/.claude/skills/react-feynman/SKILL.md`.
2. Assuma o papel de **Agente Planejador**.
3. Execute o ciclo ReAct completo para o `$ARGUMENTS` do comando.

   **Paralelização do passo Action (Princípio 9).** Quando o passo *Action*
   precisa coletar contexto sobre múltiplas áreas antes de planejar, **dispare
   TODOS os subagents necessários no MESMO bloco de tool_calls** — rodam
   concorrentes e o wall-time fica ≈ ao do mais lento (não a soma). Critério:
   independência ≡ subagent B não consome output de A. Heurística de quando
   vale: tarefa do subagent >5k tokens ou >30s; abaixo disso o overhead de
   reabrir context não compensa.

   - ✅ `Agent(Explore: módulo afetado)` + `Agent(Explore: testes/fixtures relacionados)` + `Agent(Explore: features análogas)` — três investigações independentes, mesmo turn.
   - ✅ `Agent(Plan: arquitetura A)` + `Agent(Plan: arquitetura B)` para pesar duas opções — pareceres independentes, mesmo turn.
   - ❌ `Agent(Explore: módulo X)` → ler resultado → `Agent(Plan: baseado em X)` — segundo precisa do output do primeiro. Sequencial.

   **Retorno enxuto obrigatório (anti-inchaço de contexto).** O texto final de
   cada subagent volta INTEIRO ao contexto da sessão-mãe (em background, via
   task-notification — medição 2026-07-03: notifications de 4–9 kB cada, 46–89 kB
   por sessão). Instrua cada subagent, no próprio prompt, a **gravar o relatório
   completo em arquivo** (ex.: `.claude/cache/explore-<slug>.md` ou o scratchpad)
   **e responder com ≤15 linhas**: conclusões acionáveis + path do arquivo.

4. Produza o plano usando o Template: Plano (4 seções: Problema, Abordagem,
   Fatias, AC + tags `[FATO]`/`[INFERÊNCIA]`/`[SUPOSIÇÃO]` + Perguntas Abertas).
5. Salve o plano em `.claude/plans/<slug>.md` (relativo ao cwd).
6. **Detecção de custo recorrente (Princípio 11 cláusula (e)):** após salvar,
   execute o step shell determinístico abaixo para gerar a flag lida pela skill
   `prd` na Fase 4. **Heurística aplicada por shell, NÃO pelo agente** — evita
   circularidade ("agente decide se o que ele mesmo escreveu contém
   palavras-chave"):
   ```bash
   PLAN_FILE=".claude/plans/<slug>.md"
   FLAGS_FILE=".claude/plans/<slug>.flags"
   if grep -iqE 'subscription|monthly|paid tier|API key|recurring cost|SaaS|R\$[0-9]|\$[0-9]+/(mo|mês)' "$PLAN_FILE"; then
       echo "HAS_FINANCIAL_COST=true" > "$FLAGS_FILE"
   else
       echo "HAS_FINANCIAL_COST=false" > "$FLAGS_FILE"
   fi
   ```
7. **Docs de domínio (modo batch):** ao salvar o plano, escreva os **termos
   OBSERVADOS** no `CONTEXT.md` (criação lazy + anúncio de 1 linha) e inclua a
   seção `## ADRs propostos` com o texto integral de cada ADR que passa no gate
   triplo. Regras na biblioteca `domain-docs`
   (`~/.claude/skills/domain-docs/SKILL.md`) — não duplique o formato. Os ADRs
   materializam no início da fase de execução (Fase 4).
