---
name: adversarial-research
description: Deep research adversarial com três provedores. Gemini Deep Research elabora e corrige. Perplexity Sonar DR faz fact-checking com citações. OpenAI (Responses API + web search) faz revisão adversária de lógica e metodologia. Use para pesquisas que exigem alta confiabilidade.
---

# Skill: Adversarial Deep Research (3 provedores)

## Arquitetura

TEMA DE PESQUISA
       |
       v
  GEMINI DEEP RESEARCH (Elaborador)
  Interactions API | ~80-160 buscas | Produz V1
       |
       v
  PERPLEXITY SONAR DR (Revisor de Fatos)
  Verifica citações, busca contra-evidências, identifica fabricações
       |
       v
  OPENAI + WEB SEARCH (Revisor de Lógica)
  Responses API | Analisa consistência, metodologia, lacunas, vieses
       |
       v
  MERGE dos dois pareceres
       |
       v
  Aprovado? --Sim--> Claude Code sintetiza relatório final
       |
      Não
       |
       v
  GEMINI corrige V2 com base nos dois pareceres --> volta aos revisores (máx 3 ciclos)

## Provedores

### 1. Gemini Deep Research — Elaborador + Corretor
- API: Interactions API (generativelanguage.googleapis.com/v1beta/interactions)
- Agent: deep-research-pro-preview-12-2025
- Assíncrono (background=True, polling)
- 80-160 buscas autônomas por tarefa

### 2. Perplexity Sonar Deep Research — Revisor de Fatos
- API: api.perplexity.ai/v1/sonar
- Model: sonar-deep-research
- Foco: verificação de claims, URLs, dados quantitativos, citações
- Força: 96% acurácia em citações, busca multi-step

### 3. OpenAI — Revisor Adversário de Lógica
- API: api.openai.com/v1/responses (Responses API)
- Model: gpt-4o (default, custo-efetivo) ou gpt-4.1
- Tool: web_search_preview (busca web quando necessário)
- Foco: consistência interna, metodologia, lacunas, vieses, conclusões

### Por que dois revisores separados?
- Perplexity é MELHOR em fact-checking (busca nativa otimizada para citações)
- OpenAI é MELHOR em raciocínio adversário (lógica, metodologia, vieses)
- Revisores de provedores diferentes evitam viés correlacionado
- Custo combinado menor que Claude Opus para o mesmo resultado

## Custos estimados por pesquisa completa (2 ciclos)
- Gemini: ~$1.00-3.00 (2 chamadas)
- Perplexity: ~$0.30-1.00 (2 chamadas, ~30 buscas cada)
- OpenAI: ~$0.10-0.50 (2 chamadas gpt-4o + web search)
- Total: ~$1.50-4.50
