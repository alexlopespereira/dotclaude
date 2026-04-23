#!/bin/bash
# detect-quota.sh — detecta erros de quota/rate-limit em output do Codex CLI.
# Uso:
#   source detect-quota.sh && is_codex_quota_error "$output" && echo "quota"
#   echo "$output" | bash detect-quota.sh   # exit 0 se quota, 1 caso contrário
#
# Retorna exit 0 se a saída parece um erro de quota/rate-limit da OpenAI
# (sinal para o loop Ralph cair no fallback Claude Sonnet). Caso contrário
# retorna exit 1 — tratado como erro genérico de execução do Codex.

is_codex_quota_error() {
    local input
    if [ $# -gt 0 ]; then
        input="$*"
    else
        input=$(cat)
    fi

    # Padrões observados quando a OpenAI responde com limite atingido.
    # Note: o "429" exige fronteira não-numérica para não casar em "1429".
    echo "$input" | grep -qiE '(exceeded[[:space:]]+your[[:space:]]+current[[:space:]]+quota|insufficient[_-]?quota|rate[[:space:]_-]?limit(ed|[_-]?exceeded)?|([^0-9]|^)429([^0-9]|$)|too[[:space:]]+many[[:space:]]+requests|usage[[:space:]_-]?limit|plan[[:space:]]+limit|(monthly|daily|weekly)[[:space:]]+limit|quota[[:space:][:alpha:]]{0,40}(exceeded|reached|exhausted)|(exceeded|reached|exhausted|hit)[[:space:][:alnum:]]{0,30}quota)'
}

# Execução direta (não-sourced): parseia stdin ou args.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if is_codex_quota_error "$@"; then
        echo "QUOTA_ERROR"
        exit 0
    else
        echo "NO_QUOTA_ERROR"
        exit 1
    fi
fi
