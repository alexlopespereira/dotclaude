#!/bin/sh
# Uma sessao tmux por repo (slot-1) com Claude interativo, SEM Telegram.
# Acessar:  tmux attach -t <repo>     (ex.: tmux attach -t etl-crm)
# Auto-descobre os slots *-1 em ~/Projects/checkouts.
export PATH=/home/dev/.bun/bin:/home/dev/.local/bin:/usr/local/bin:/usr/bin:/bin
# Locale UTF-8: o systemd unit NAO herda LANG/LC_* (so define TERM/HOME/PATH),
# entao sem isto o Claude e o codex que ele spawna rodam em C/POSIX e corrompem
# acentuacao PT-BR. -e em new-session garante o locale mesmo com tmux server stale.
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
CLAUDE=/home/dev/.local/bin/claude
for d in /home/dev/Projects/checkouts/*-1; do
  [ -d "$d" ] || continue
  name=$(basename "$d"); name=${name%-1}
  tmux has-session -t "$name" 2>/dev/null && continue
  tmux new-session -d -s "$name" -e LANG=en_US.UTF-8 -e LC_ALL=en_US.UTF-8 -c "$d" "$CLAUDE --dangerously-skip-permissions"
done
