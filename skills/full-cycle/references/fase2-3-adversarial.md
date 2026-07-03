# Fases 2–3 — Revisão Adversária + Gate de Aprovação (/full-cycle)

> Reference do `/full-cycle` (o `/full-cycle-simple` pula estas fases). Leia
> APENAS ao iniciar a Fase 2.

## Fase 2 — Revisão Adversária (Agente Revisor)

1. Troque para o papel de **Agente Revisor Adversário**.
2. Releia o plano com olhos frescos.
3. Para cada decisão, tente refutar. Aplique Teste Feynman.

   **Paralelização de refutações (Princípio 9).** O Revisor normalmente ataca o
   plano por várias frentes ortogonais — checar se uma SUPOSIÇÃO bate com o
   código real, procurar anti-patterns similares no histórico, stress-testar
   contra edge cases conhecidos, validar dependências externas. Dispare **todos
   os subagents adversários no MESMO turn** quando as investigações forem
   independentes — cada um devolve um finding que o Revisor consolida no
   parecer. Mesma regra de independência e de **retorno enxuto** da Fase 1
   (detalhe em arquivo, resposta ≤15 linhas).

   - ✅ `Agent(Explore: a SUPOSIÇÃO "API X é idempotente" bate com a implementação?)` + `Agent(Explore: histórico de bugs no módulo Y)` + `Agent(Explore: cobertura de teste do caso Z)` — três refutações ortogonais, mesmo turn.
   - ❌ Esperar resposta de uma para decidir a próxima — anula o ganho.

4. Produza o parecer usando o Template: Revisão Adversária.
5. Adicione o parecer ao mesmo arquivo do plano, sob `---` separador.

## Fase 3 — Gate de Aprovação

**Se REPROVADO:**
- Destaque os 3 pontos mais críticos.
- **PARE AQUI** — escale para o humano. NÃO prossiga para PRD/Ralph/PR.
- **Antes de escalar para humano:** sugira `/reflect --on-failure 3 --context-file <path-do-parecer>` para entender qual critério DoD teria evitado a reprovação.

**Se APROVADO COM RESSALVAS:**
- Liste as ressalvas bloqueantes (severidade Crítica/Alta) — recomendar correção durante implementação como ACs adicionais.
- Prossiga automaticamente para Fase 4 (Princípio 11: transição interna não pede confirmação). Humano interrompe via Ctrl-C se quiser revisar antes.

**Se APROVADO:** prossiga para Fase 4.
