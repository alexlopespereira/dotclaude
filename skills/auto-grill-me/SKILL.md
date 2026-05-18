---
name: auto-grill-me
description: Interview adversário que classifica perguntas por rubrica quantitativa antes de interromper. Score baixo → assume silenciosamente. Score médio → assume + footnote. Score alto → pergunta. Use quando o usuário menciona "auto grill", "grille com classificação", "plano silencioso", "rubrica de decisão", ou pede grilling sem ser interrompido em tudo. Produz plano em formato /plan com DoD por artefato em .claude/plans/.
argument-hint: "[topic]"
---

# auto-grill-me

Interview the user about a plan or design. For each question in the design tree, **classify before interrupting** using the rubric in [references/RUBRICA.md](references/RUBRICA.md). Walk down each branch resolving dependencies one-by-one. Provide a recommended answer for every Tipo 1 question (verbatim grill-me style).

Topic vem de `$ARGUMENTS` se fornecido; caso contrário, usa o contexto da conversa.

## Per-question protocol

Para cada decisão da árvore de design:

1. **Gerar a próxima pergunta** (ou encerrar se shared understanding alcançado — ver §Stop criterion).
2. **Escolher domínio candidato** (eng / mkt / biz) via heurística de palavras-chave na pergunta. Empate → eng (default). Zero matches → eng + adicionar 1 a G6 (sinal de incerteza no mapping).
3. **Avaliar short-circuits** ([RUBRICA.md §1](references/RUBRICA.md), F1–F8). Se algum disparar, executar ação direta sem score.
4. **Avaliar anti-patterns** ([RUBRICA.md §2](references/RUBRICA.md), 1–10). Se algum disparar, forçar Tipo 2 silencioso (não perguntar).
5. **Calcular score** via critérios genéricos G1–G8 ([§3](references/RUBRICA.md)) + critérios de domínio ([§4](references/RUBRICA.md)), agregando por [§5](references/RUBRICA.md). G6 = verbalized_confidence − 1 (desconto fixo; sem self-consistency na Fatia 1).
6. **Aplicar threshold** ([§6](references/RUBRICA.md)):
   - `score < 35` → **Tipo 2**: assume silenciosamente, **não imprime nada** ao usuário (apenas log).
   - `35 ≤ score ≤ 60` → **Tipo 3**: assume, imprime **uma linha** `▸ assumi: <decisão em 1 frase> (footnote #N)`, armazena footnote completa em buffer (formato [§7](references/RUBRICA.md)).
   - `score > 60` → **Tipo 1**: pergunta ao usuário **uma pergunta por vez** com recomendação explícita (verbatim grill-me style). Aguarda resposta antes de continuar.
7. **Logar a decisão** em `decisions.jsonl` (ver §Audit log).
8. **Se um artefato emergir** ("vamos precisar de um hook", "isso vai virar uma skill"): usar o índice de mapping em [DOD.md](references/DOD.md) para escolher candidato de categoria/tarefa. Rodar meta-classificação via rubrica sobre o mapping (mesmo algoritmo §3–§6 — usar G3/G6 para avaliar confiança no mapping). Gerar DoD da tarefa correspondente e adicioná-lo à seção "Artefatos a produzir" do plano em formação.

## Stop criterion

Encerrar quando **shared understanding** for alcançado (julgamento do agente, mesmo do `grill-me` original):

- Todas as ramificações da árvore foram resolvidas.
- Nenhuma decisão Tipo 1 pendente sem resposta.
- Agente não consegue formular próxima pergunta substantiva (não-redundante).

## Output

Ao encerrar:

1. **Imprimir o buffer de footnotes Tipo 3** consolidado (numerado #1, #2, …) com `▸ assumi: <decisão>` + `alternativas:` + `trade-off:` + `reverter:` quando aplicável.
2. **Persistir o plano** em `.claude/plans/<ISO-timestamp>-<slug>.md` no formato `/plan` ReAct+Feynman (ver [skill react-feynman](../react-feynman/SKILL.md)):
   - `# Plano: <slug>`
   - `## Contexto`
   - `## Árvore de Design (decisões tomadas)` — Thought/Action/Observation por decisão, marcando resolução (Tipo 1/2/3).
   - `## Artefatos a produzir` — cada artefato com Categoria/Tarefa mapeada + DoD em checklist `- [ ]`.
   - `## Perguntas Abertas` — dúvidas residuais + grau de confiança (alta/média/baixa).
   - `## Apêndices` — A) footnotes Tipo 3, B) resumo do audit log da sessão (distribuição Tipo 1/2/3 por domínio), C) confiança geral.
3. **Anunciar o path** + listar próximos comandos sugeridos: `/adversarial-review <plan>`, `/prd-convert`, `/full-cycle`.

Slug = 5–8 palavras derivadas do tópico ou da pergunta-raiz. Criar `.claude/plans/` se não existir.

## Audit log

Append por decisão (Tipo 1/2/3) em `~/.claude/cache/auto-grill/<basename-cwd>-decisions.jsonl`, schema definido em [RUBRICA.md §8](references/RUBRICA.md).

- Criar diretório lazy na primeira escrita.
- Opt-out: env `CLAUDE_AUTO_GRILL_NO_LOG=1` (sem prompt).
- `session_id` = UUID gerado no primeiro turno da sessão; mesmo valor para todas as decisões da sessão.

<!-- FATIA-2: substituir G6 verbalized direto por self-consistency check (3 amostras, ajuste por concordância). Wang et al. ICLR 2023, arXiv:2203.11171. Atualizar §3 da RUBRICA.md em paralelo. -->

## Gotchas

(Preencher após primeiro uso real. DoD Categoria 1 / Tarefa 2 exige "erros reais observados em uso, não inventados".)
