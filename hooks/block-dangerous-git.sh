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
#
# Fail-closed (ressalva R3 / US-02): no contrato PreToolUse só exit 2 BLOQUEIA
# — exit 1 e exit 0 liberam. Logo qualquer erro interno (dep ausente, parse
# falho, comando inesperado) tem de virar exit 2, nunca exit 1 silencioso.
# `set -e` sozinho é insuficiente (sai com o rc do comando, tipicamente 1);
# por isso `trap ... exit 2 ERR` converte qualquer falha em bloqueio.

set -u
# shellcheck disable=SC2154  # rc é atribuído (rc=$?) no início da própria string do trap
trap 'rc=$?; echo "BLOCKED (hook error): block-dangerous-git.sh falhou internamente (rc=$rc) — fail-closed por segurança (Princípio 7). Verifique dependências (jq, git) e o ambiente, depois tente de novo." >&2; exit 2' ERR

# Dependências obrigatórias. Seams BDG_JQ/BDG_GIT permitem o teste apontar o
# binário para um caminho inexistente/stub e provar o fail-closed (→ exit 2).
JQ_BIN="${BDG_JQ:-jq}"
GIT_BIN="${BDG_GIT:-git}"
if ! command -v "$JQ_BIN" >/dev/null 2>&1; then
  echo "BLOCKED (dependency missing): jq não encontrado ('$JQ_BIN') — block-dangerous-git.sh precisa de jq para parsear o input do hook. Instale jq (brew install jq) e tente de novo. Fail-closed por segurança." >&2
  exit 2
fi
if ! command -v "$GIT_BIN" >/dev/null 2>&1; then
  echo "BLOCKED (dependency missing): git não encontrado ('$GIT_BIN') — block-dangerous-git.sh precisa de git para inspecionar o diff staged. Fail-closed por segurança." >&2
  exit 2
fi

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | "$JQ_BIN" -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then exit 0; fi

# Strip quoted strings so substrings inside echo/heredoc don't trigger false positives.
STRIPPED=$(printf '%s' "$COMMAND" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")

# --- Secret scan on git push / git commit ---
if printf '%s' "$STRIPPED" | grep -qE 'git +(push|commit)\b'; then
  # Fora de repo git: nada a escanear — o próprio git falhará o comando do
  # usuário ('not a git repository'). Allow deliberado, não fail-open.
  if ! "$GIT_BIN" rev-parse --git-dir >/dev/null 2>&1; then
    exit 0
  fi
  # DENTRO de repo, falha de git diff (index.lock, corrupção) NÃO pode virar
  # scan pulado: o trap ERR não herda em command substitution (sem set -E) e
  # `|| true` mascarava o rc — P0 do code-review Fase 5.5. rc explícito → exit 2.
  if ! STAGED_CACHED=$("$GIT_BIN" diff --cached 2>/dev/null); then
    echo "BLOCKED (hook error): 'git diff --cached' falhou — impossível escanear o staged diff por segredos. Fail-closed por segurança (Princípio 7). Verifique o estado do repo (index.lock?) e tente de novo." >&2
    exit 2
  fi
  if ! STAGED_WT=$("$GIT_BIN" diff 2>/dev/null); then
    echo "BLOCKED (hook error): 'git diff' falhou — impossível escanear o working tree por segredos. Fail-closed por segurança (Princípio 7). Verifique o estado do repo e tente de novo." >&2
    exit 2
  fi
  STAGED="${STAGED_CACHED}
${STAGED_WT}"
  if [ -n "${STAGED//[[:space:]]/}" ]; then
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
        MATCH=$(printf '%s' "$STAGED" | grep -oE -- "$pat" | head -1 | cut -c1-12) || true
        echo "BLOCKED (secret detected): diff contains pattern matching /$pat/ — preview '${MATCH}…'. Princípio 7 do CLAUDE.md proíbe versionar segredos. Mova para .env, secret manager, ou vars de ambiente, e tente novamente." >&2
        exit 2
      fi
    done

    if ! STAGED_FILES=$("$GIT_BIN" diff --cached --name-only 2>/dev/null); then
      echo "BLOCKED (hook error): 'git diff --cached --name-only' falhou — impossível listar arquivos staged. Fail-closed por segurança (Princípio 7)." >&2
      exit 2
    fi
    while IFS= read -r f; do
      if [ -z "$f" ]; then continue; fi
      if printf '%s' "$f" | grep -qE '(^|/)(\.env(\..*)?|credentials(\..*)?|secrets?(\..*)?)$|\.(pem|key|p12|pfx)$' \
         && ! printf '%s' "$f" | grep -qE '\.(example|sample|template|tmpl)(\..*)?$'; then
        echo "BLOCKED (sensitive file staged): '$f' looks like secrets material. Add to .gitignore and unstage with 'git reset HEAD $f'." >&2
        exit 2
      fi
    done <<< "$STAGED_FILES"
  fi
fi

exit 0
