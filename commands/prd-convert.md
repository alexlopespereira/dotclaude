---
description: Converte um plano aprovado (.claude/plans/) em prd.json para o loop Ralph
allowed-tools: Read, Write, Bash(cat *), Bash(ls *), Bash(find *)
argument-hint: [caminho do plano ou "último"]
---

Converte um plano em prd.json para execução no Ralph Adversarial.

1. Leia `~/.claude/skills/prd/SKILL.md`.

2. Localize o plano:
   - Se "$ARGUMENTS" for "último"/"last": mais recente em .claude/plans/
   - Senão: use o caminho fornecido.

3. Leia o plano completo.

4. Converta seguindo as regras da skill prd:
   - 1 fatia = 1 user story
   - AC testáveis (não "funciona corretamente")
   - [SUPOSIÇÕES] do plano viram AC de validação
   - Stories pequenas o bastante para 1 context window

5. Salve como `prd.json` na raiz do repositório.

6. Mostre o resultado ao usuário e pergunte se quer ajustar alguma story antes de executar o Ralph.
