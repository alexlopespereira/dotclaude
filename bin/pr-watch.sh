#!/usr/bin/env bash
# pr-watch.sh — observa o CI de um PR sem corrida com o auto-merge.
#
# O QUE FAZ: resolve o número do PR por precedência
#   arg explícito  >  $(git rev-parse --git-dir)/CPP_LAST_PR  >  gh pr view --json number
# e consulta o state ANTES de watchar (com retry: falha transiente do gh não é
# veredicto — 3 tentativas, depois exit 3 DEDICADO, ≠2 de invocação inválida):
#   MERGED → mensagem + exit 0 (nada a aguardar — auto-merge já pegou; se o
#            número veio de CPP_LAST_PR, o arquivo é CONSUMIDO/removido para
#            nunca responder por um ciclo futuro);
#   CLOSED → mensagem + exit 1 (não haverá CI; arquivo consumido idem);
#   OPEN   → se o PR não tem checks configurados → mensagem + exit 0 (paridade
#            com ship.sh; `gh pr checks --watch` sai ≠0 em repo sem CI);
#            senão gh pr checks <n> --watch com teto via perl alarm (idioma de
#            ship.sh; SIGALRM → exit 142 = timeout, CI ainda rodando — NÃO é
#            CI vermelho), exit do watch propagado.
#
# POR QUE EXISTE: o snippet inline da Fase 8 de /full-cycle{,-simple} resolvia o
# PR pela BRANCH ATUAL (`gh pr view --json number`) — quando o auto-merge mergeava
# e deletava a branch antes do watch começar, a resolução falhava (corrida real
# do PR #86). CPP_LAST_PR é gravado pelo commit-push-pr.sh no momento do create,
# então sobrevive ao delete da branch; e o pre-check de state transforma "já
# mergeou" em saída feliz em vez de erro.
#
# Uso:
#   pr-watch.sh [--timeout=<segundos>] [<pr-number>]
#
# Env (seams de teste, padrão vm-doctor):
#   PRWATCH_GH          — binário gh (default: gh)
#   PRWATCH_TIMEOUT     — teto do watch em segundos (default: 1800; a flag
#                         --timeout vence a env — convenção CLI flag > env var)
#   PRWATCH_RETRY_DELAY — pausa entre retries do pre-check de state (default 2s)

set -u

GH="${PRWATCH_GH:-gh}"
TIMEOUT="${PRWATCH_TIMEOUT:-1800}"
RETRY_DELAY="${PRWATCH_RETRY_DELAY:-2}"

usage() {
  echo "Uso: pr-watch.sh [--timeout=<segundos>] [<pr-number>]" >&2
  echo "  Sem número, resolve via .git/CPP_LAST_PR e, em fallback, gh pr view --json number." >&2
  echo "  Exit: 0 CI verde/mergeado/sem checks · 1 CI vermelho/CLOSED · 2 invocação inválida" >&2
  echo "        3 state irresolúvel (erro transiente do gh — re-tente) · 142 timeout do watch" >&2
}

PR_NUM=""
for arg in "$@"; do
  case "$arg" in
    --timeout=*)
      TIMEOUT="${arg#--timeout=}"
      case "$TIMEOUT" in *[!0-9]*|"") echo "ERRO: --timeout '$TIMEOUT' não é numérico." >&2; usage; exit 2 ;; esac ;;
    --*)
      echo "ERRO: flag desconhecida '$arg'." >&2; usage; exit 2 ;;
    *)
      if [ -n "$PR_NUM" ]; then echo "ERRO: mais de um número de PR." >&2; usage; exit 2; fi
      PR_NUM="$arg"
      case "$PR_NUM" in
        *[!0-9]*) echo "ERRO: PR '$PR_NUM' não é numérico." >&2; usage; exit 2 ;;
      esac ;;
  esac
done

# Precedência 2: CPP_LAST_PR (gravado pelo commit-push-pr.sh no create).
# Conteúdo não-numérico (corrompido) é descartado — cai no fallback.
# PR_SRC=file marca a origem: estado terminal consome o arquivo (ciclo de vida
# do code-review 2026-07-02 — stale numérico tornava o fallback inalcançável).
PR_SRC="arg"
CPP_FILE=""
if [ -z "$PR_NUM" ]; then
  GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo "")
  if [ -n "$GIT_DIR" ] && [ -f "$GIT_DIR/CPP_LAST_PR" ]; then
    PR_NUM=$(cat "$GIT_DIR/CPP_LAST_PR" 2>/dev/null || echo "")
    case "$PR_NUM" in *[!0-9]*|"") PR_NUM="" ;; *) PR_SRC="file"; CPP_FILE="$GIT_DIR/CPP_LAST_PR" ;; esac
  fi
fi

# Precedência 3: PR da branch atual (comportamento antigo — só como último recurso).
if [ -z "$PR_NUM" ]; then
  PR_NUM=$("$GH" pr view --json number --jq .number 2>/dev/null || echo "")
  case "$PR_NUM" in *[!0-9]*|"") PR_NUM="" ;; esac
fi

if [ -z "$PR_NUM" ]; then
  echo "ERRO: PR irresolúvel — sem arg, sem CPP_LAST_PR e sem PR na branch atual." >&2
  usage
  exit 2
fi

# Consome o CPP_LAST_PR quando o PR resolvido POR ELE atinge estado terminal —
# o arquivo é um handoff one-shot do create pro watch, nunca fonte perene.
consume_cpp_file() {
  [ "$PR_SRC" = "file" ] && [ -n "$CPP_FILE" ] && rm -f "$CPP_FILE"
}

# Pre-check de state com retry: falha do comando/output vazio é transiente
# (rede, 5xx, auth hiccup) — 3 tentativas antes do exit 3 dedicado. State
# retornado com sucesso mas não-reconhecido continua exit 2 (contrato).
STATE=""
attempt=1
while [ "$attempt" -le 3 ]; do
  STATE=$("$GH" pr view "$PR_NUM" --json state --jq .state 2>/dev/null) || STATE=""
  [ -n "$STATE" ] && break
  attempt=$((attempt+1))
  [ "$attempt" -le 3 ] && sleep "$RETRY_DELAY"
done
if [ -z "$STATE" ]; then
  echo "ERRO: state do PR #$PR_NUM irresolúvel após 3 tentativas (erro transiente do gh? re-tente)." >&2
  exit 3
fi
case "$STATE" in
  MERGED)
    echo "PR #$PR_NUM já mergeado — nada a watchar."
    consume_cpp_file
    exit 0 ;;
  CLOSED)
    echo "PR #$PR_NUM está CLOSED — não haverá CI." >&2
    consume_cpp_file
    exit 1 ;;
  OPEN) ;;
  *)
    echo "ERRO: state desconhecido '$STATE' para o PR #$PR_NUM." >&2
    exit 2 ;;
esac

# Zero-checks: PR sem CI configurado não é falha — `gh pr checks --watch` sai
# ≠0 nesse caso e viraria falso "CI vermelho". No gh real (verificado ao vivo,
# 2.87.3) o probe `--json name` sai ≠0 com "no checks reported" no stderr e
# stdout VAZIO — a detecção primária é pela mensagem; o ramo via `length==0`
# fica como defesa caso versões futuras passem a emitir `[]`. Outros erros do
# probe (transiente) → fail-open pro watch (comportamento pré-existente).
CHECKS_RC=0
CHECKS_OUT=$("$GH" pr checks "$PR_NUM" --json name 2>&1) || CHECKS_RC=$?
if [ "$CHECKS_RC" -ne 0 ]; then
  case "$CHECKS_OUT" in
    *"no checks reported"*)
      echo "PR #$PR_NUM sem checks configurados — sem CI pra aguardar."
      exit 0 ;;
  esac
else
  CHECKS_COUNT=$(printf '%s' "$CHECKS_OUT" | jq 'length' 2>/dev/null) || CHECKS_COUNT=""
  if [ "$CHECKS_COUNT" = "0" ]; then
    echo "PR #$PR_NUM sem checks configurados — sem CI pra aguardar."
    exit 0
  fi
fi

echo "→ Aguardando CI do PR #$PR_NUM (timeout ${TIMEOUT}s)..."
WATCH_RC=0
perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" "$GH" pr checks "$PR_NUM" --watch || WATCH_RC=$?
if [ "$WATCH_RC" = "142" ]; then
  echo "ERRO: timeout (${TIMEOUT}s) aguardando CI do PR #$PR_NUM — CI ainda rodando, NÃO é veredicto vermelho." >&2
fi
exit "$WATCH_RC"
