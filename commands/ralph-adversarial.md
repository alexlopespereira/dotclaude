---
description: Executa o loop Ralph Adversarial — Claude implementa stories do prd.json, Codex revisa cada commit usando a rubrica V2
allowed-tools: Read, Write, Bash(bash *), Bash(chmod *), Bash(cat *), Bash(jq *), Bash(git *)
argument-hint: [max_iterations, default 10]
---

Executa o loop de implementação Ralph Adversarial.

1. Leia `~/.claude/skills/ralph-adversarial/SKILL.md`.

2. Verifique pré-requisitos:
   - `prd.json` existe na raiz do projeto atual?
   - `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md` existe?
   - `jq`, `claude`, `codex` estão disponíveis?

3. Se `prd.json` NÃO existir:
   - Verifique se há plano aprovado em `.claude/plans/`
   - Se sim, ofereça: "Encontrei o plano [nome]. Deseja convertê-lo em prd.json?"
   - Se o usuário concordar, use a skill `prd` para converter.

4. Execute:
   ```bash
   chmod +x ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh
   bash ~/.claude/skills/ralph-adversarial/ralph-adversarial.sh $ARGUMENTS
   ```

5. Após conclusão, apresente resumo:
   - Stories completas vs pendentes vs escaladas
   - Findings P0/P1 encontrados pelo Codex
   - Conteúdo do progress.txt (aprendizados acumulados)
