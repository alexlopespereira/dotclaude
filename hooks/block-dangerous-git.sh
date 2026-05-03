#!/bin/bash
# Git guardrails — secret scan only (Princípio 7 do CLAUDE.md).
# Original (upstream): ~/.claude/skills/git-guardrails-claude-code/scripts/block-dangerous-git.sh
#
# Policy:
#  - NÃO bloqueia operações destrutivas (--force, reset --hard, clean, branch -D, etc.) —
#    Princípio 7 fala só de segredos; ops destrutivas o usuário decide.
#  - Bloqueia git push/commit se o STAGED DIFF contém prováveis segredos
#    (tokens Stripe/GH/Netlify/AWS/Google/Slack, PEM) ou stages arquivos
#    .env / credentials / *.pem / *.key.

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

[ -z "$COMMAND" ] && exit 0

# Strip quoted strings so substrings inside echo/heredoc don't trigger false positives.
STRIPPED=$(printf '%s' "$COMMAND" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")

# --- Secret scan on git push / git commit ---
if printf '%s' "$STRIPPED" | grep -qE 'git +(push|commit)\b'; then
  STAGED=$(git diff --cached 2>/dev/null; git diff 2>/dev/null)
  if [ -n "$STAGED" ]; then
    SECRET_PATTERNS=(
      '(sk|pk)_(test|live)_[A-Za-z0-9]{16,}'
      'gh[ps]_[A-Za-z0-9]{20,}'
      'nfp_[A-Za-z0-9]{20,}'
      'AKIA[0-9A-Z]{16}'
      'ASIA[0-9A-Z]{16}'
      'AIza[0-9A-Za-z_-]{30,}'
      'ya29\.[0-9A-Za-z_-]+'
      'xox[abprs]-[0-9A-Za-z-]{10,}'
      '-----BEGIN ((RSA|DSA|EC|OPENSSH|PGP) )?PRIVATE KEY-----'
    )
    for pat in "${SECRET_PATTERNS[@]}"; do
      if printf '%s' "$STAGED" | grep -qE -- "$pat"; then
        MATCH=$(printf '%s' "$STAGED" | grep -oE -- "$pat" | head -1 | cut -c1-12)
        echo "BLOCKED (secret detected): diff contains pattern matching /$pat/ — preview '${MATCH}…'. Princípio 7 do CLAUDE.md proíbe versionar segredos. Mova para .env, secret manager, ou vars de ambiente, e tente novamente." >&2
        exit 2
      fi
    done

    STAGED_FILES=$(git diff --cached --name-only 2>/dev/null)
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if printf '%s' "$f" | grep -qE '(^|/)(\.env(\..*)?|credentials(\..*)?|secrets?(\..*)?)$|\.(pem|key|p12|pfx)$'; then
        echo "BLOCKED (sensitive file staged): '$f' looks like secrets material. Add to .gitignore and unstage with 'git reset HEAD $f'." >&2
        exit 2
      fi
    done <<< "$STAGED_FILES"
  fi
fi

exit 0
