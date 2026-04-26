---
description: Abre 1 janela do terminal com 5 abas (workflow Boris) — uma por slot do pool, opcionalmente com claude --name por slot
allowed-tools: Bash(bash *), Bash(chmod *), Bash(test *), Bash(ls *), Read
argument-hint: <repo> [--slots=1,3] [--claude] [--skip-permissions|--yolo] [--names=feature-a,feature-b,tests,bugfix,docs]
---

Abre uma aba por slot do pool `<repo>`, já com `cd` no diretório certo. Suporta lançar `claude` em cada aba com `--name` próprio (workflow Boris: cada sessão tem identidade visual).

## Parâmetros

- `<repo>` — pool (ex: `horizons`).
- `--slots=1,3` — apenas alguns slots.
- `--claude` — `claude` em cada aba.
- `--skip-permissions` (alias: `--yolo`) — `claude --dangerously-skip-permissions` em cada aba. Implica `--claude`. Combina com `--names`.
- `--names=A,B,C,D,E` — labels por slot (implica `--claude`). Vira `claude --name <label>`.
- `--cmd "..."` — comando custom em cada aba.

## Passos

```bash
SCRIPT="$HOME/Projects/dotclaude/bin/checkout-launch.sh"
test -x "$SCRIPT" || chmod +x "$SCRIPT"
ls -d "$HOME/Projects/checkouts/${REPO}-"* >/dev/null 2>&1 || { echo "Pool não existe — rode /checkout-init."; exit 1; }
bash "$SCRIPT" $ARGUMENTS
```

Reporte o que o script imprimiu.

## Guardrails

- Pool deve existir — script aborta se não.
- Para abas (não janelas) no Terminal.app, exige `AppleWindowTabbingMode=always` + Accessibility para System Events. Script avisa se faltar.
