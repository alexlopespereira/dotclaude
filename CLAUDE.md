# CLAUDE.md — dotclaude (stub de projeto)

> **Este arquivo é um stub intencional.** Os Princípios globais (ReAct+Feynman,
> autonomia, supply-chain, etc.) **não** são repetidos aqui: eles já entram em
> toda sessão via `~/.claude/CLAUDE.md` (config global). Duplicá-los neste arquivo
> dobrava ~6k tokens de baseline em cada sessão *deste* repo (o global E o de
> projeto carregam juntos quando o cwd é o dotclaude). A fonte-da-verdade do
> conteúdo global vive em **`CLAUDE.global.md`** e é instalada em
> `~/.claude/CLAUDE.md` por `./sync.sh install`.

## O que é este repo

dotclaude é o **dotfiles do `~/.claude/`**: CLAUDE.global.md, `commands/`,
`skills/`, `agents/`, `hooks/`, `bin/`, `WORKFLOW.md`. O repo é a fonte-da-verdade;
`~/.claude/` é o alvo instalado. Sincronização nos dois sentidos via `./sync.sh`:

- `./sync.sh install` — repo → `~/.claude/` (após `git pull`; renomeia
  `CLAUDE.global.md` → `~/.claude/CLAUDE.md`). Rodado a cada SessionStart nas VMs.
- `./sync.sh backup` — `~/.claude/` → repo (antes de commitar edits feitos no host).
- `./sync.sh status` — diff entre repo e `~/.claude/`.

## Trabalhando aqui

- **Editou um Princípio / a config global?** Edite `CLAUDE.global.md` (não este
  stub). Rode `./sync.sh install` para refletir em `~/.claude/CLAUDE.md`.
- **TDD obrigatório.** Suíte: `bash bin/tests/run-all.sh` (un teste por arquivo em
  `bin/tests/`). Nada de implementar antes do teste vermelho.
- **Propagação multi-máquina:** mudanças aqui chegam ao host + VMs via
  `git pull` + `sync.sh install`. Preserve histórico em renames (`git mv`) para a
  detecção de stale do `sync.sh` continuar reconhecendo cópias antigas como
  seguras de sobrescrever.

## Referências

- Conteúdo global completo: `CLAUDE.global.md`
- Guia do repo: `README.md` · Mapa tático: `WORKFLOW.md`
- Skills/comandos: `skills/`, `commands/`
