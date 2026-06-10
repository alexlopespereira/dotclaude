---
description: Alias do typo de /commit-push-pr — cria branch efêmera, commita, pusha e abre PR. Argumentos opcionais; Claude infere mensagem e branch do contexto se você não passar.
allowed-tools: Bash(bash *), Bash(chmod *), Bash(test *), Bash(git *), Bash(gh *), Read, Glob, Grep
argument-hint: ["mensagem"] [--branch=NAME] [--type=...] [--no-pr] [--draft] [--no-auto-merge] [--merge-method=squash|merge|rebase]
---

**Alias do typo de `/commit-push-pr`** (dedo escorregou no `-push` final). Segue exatamente os MESMOS passos: empacota o trabalho do slot em branch efêmera e abre PR para `main`, com auto-merge default.

Execute o mesmo fluxo de `/commit-push-pr` — inferência de mensagem/branch quando sem args, repasse de flags — terminando em:

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/commit-push-pr.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
bash "$SCRIPT" $ARGUMENTS
```
