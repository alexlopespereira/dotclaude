---
description: Converte um plano aprovado (.claude/plans/) em prd.json para o loop Ralph
allowed-tools: Read, Write, Bash(cat *), Bash(ls *), Bash(find *), Bash(bash *), Bash(~/.claude/skills/ralph-adversarial/lib/*)
argument-hint: [caminho do plano ou "último"]
---

Converte um plano em prd.json para execução no Ralph Adversarial.

1. Leia `~/.claude/skills/prd/SKILL.md`.

2. Localize o plano:
   - Se "$ARGUMENTS" for "último"/"last": mais recente em .claude/plans/
   - Senão: use o caminho fornecido.

3. Leia o plano completo.

3.5. **Gate de veredito adversário (backstop — rode ANTES de gerar qualquer story):**
   ```bash
   bash ~/.claude/skills/ralph-adversarial/lib/plan-verdict-gate.sh <caminho-do-plano>
   ```
   O gate recusa converter um plano cujo CORPO ainda não reflete o veredito
   adversário final (o parecer no rodapé não reescreve o corpo; prd-convert lê o
   corpo). Exit != 0 → **PARE**: REPROVADO escala para humano; APROVADO COM
   RESSALVAS sem `<!-- plan-reconciled -->` exige reconciliar o corpo primeiro
   (remover/corrigir cada finding Crítica/Alta) e re-stampar. Só prossiga com
   exit 0. Ver skill `prd` seção "Gate de veredito".

4. Converta seguindo as regras da skill prd:
   - 1 fatia = 1 user story
   - AC testáveis (não "funciona corretamente")
   - [SUPOSIÇÕES] do plano viram AC de validação
   - Stories pequenas o bastante para 1 context window

5. **Detecte dependências entre fatias (US-02 AC1).** Para cada fatia, examine
   o texto da fatia (descrição, ReAct, ACs) procurando frases tipo
   `depende de US-XX`, `depende das US-XX, US-YY`, `depende dos US-XX e US-YY`
   (caso-insensitivo no verbo). Use o helper para extrair os IDs:

   ```bash
   bash ~/.claude/skills/ralph-adversarial/lib/extract-deps-from-plan.sh < <(printf '%s\n' "<texto da fatia>")
   ```

   Cada US-ID retornado vira uma entrada em `dependsOn` da story correspondente.
   Stories sem nenhuma menção ficam **sem o campo** `dependsOn` (compat Fase 1
   — US-02 AC3). Não invente deps que não estão escritas no plano.

6. Salve como `prd.json` na raiz do repositório.

7. **Valide automaticamente** (Princípio 11 substitui o gate humano de "ajustar story?"):
   ```bash
   bash ~/.claude/skills/ralph-adversarial/lib/validate-prd.sh prd.json
   ```

   O validador (US-02) faz:
   - Schema check (id, title, acceptanceCriteria não-vazio, dependsOn array de strings se presente).
   - dependsOn referencia stories existentes (sem id órfão).
   - Detecção de ciclos via DFS (mensagem `ciclo detectado: ...`).
   - Inconsistência ESCALATED-vs-dep-OK em modo warn-only por default.
     Para destravar em batch, rode com `--auto-recover` (reverte
     `passes: "ESCALATED"` → `passes: false`, remove `escalation_reason`).

   - Exit 0: imprima resumo do prd.json gerado (story count, priorities) e
     termine. Humano interrompe via Ctrl-C se quiser ajustar manualmente
     antes de invocar `/ralph-adversarial`.
   - Exit != 0: **PARE** com a mensagem de erro do validador (schema, ciclo
     ou dep não-resolvida). NÃO prossiga.
