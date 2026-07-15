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
# Segredos da VM ficam em ~/Projects/.env (nao versionado). O gh so le GH_TOKEN/
# GITHUB_TOKEN, entao carregamos o .env e mapeamos GH_PAT_TOKEN -> GH_TOKEN
# DENTRO do shell que o tmux spawna: o valor e lido do arquivo em runtime (nunca
# passa por argv/ps) e sobrevive a tmux server stale (nao depende de heranca de env).
ENV_FILE=/home/dev/Projects/.env
LOAD_ENV="set -a; [ -f $ENV_FILE ] && . $ENV_FILE; set +a; export GH_TOKEN=\"\$GH_PAT_TOKEN\";"
for d in /home/dev/Projects/checkouts/*-1; do
  [ -d "$d" ] || continue
  name=$(basename "$d"); name=${name%-1}
  tmux has-session -t "$name" 2>/dev/null && continue
  tmux new-session -d -s "$name" -e LANG=en_US.UTF-8 -e LC_ALL=en_US.UTF-8 -c "$d" \
    "sh -c '$LOAD_ENV exec $CLAUDE --dangerously-skip-permissions'"
done
