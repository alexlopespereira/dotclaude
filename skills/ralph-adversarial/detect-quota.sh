#!/bin/bash
# detect-quota.sh — detecta Codex inutilizável por causa externa ao código
# revisado: quota/rate-limit OU auth morta (token expirado/revogado, 401).
# (O filename preserva o nome histórico; o contrato completo é "fallback".)
# Uso:
#   source detect-quota.sh && is_codex_fallback_error "$output" && echo "fallback"
#   echo "$output" | bash detect-quota.sh   # exit 0 se quota/auth, 1 caso contrário
#
# Retorna exit 0 se a saída parece um erro de quota/rate-limit da OpenAI
# ou de autenticação morta do Codex — ambos sinalizam para o loop Ralph
# cair no fallback Claude Sonnet. Caso contrário retorna exit 1 — tratado
# como erro genérico de execução do Codex.

is_codex_fallback_error() {
    local input
    if [ $# -gt 0 ]; then
        input="$*"
    else
        input=$(cat)
    fi

    # Padrões observados quando a OpenAI responde com limite atingido.
    # Note: o "429" exige fronteira não-numérica para não casar em "1429".
    if echo "$input" | grep -qiE '(exceeded[[:space:]]+your[[:space:]]+current[[:space:]]+quota|insufficient[_-]?quota|rate[[:space:]_-]?limit(ed|[_-]?exceeded)?|([^0-9]|^)429([^0-9]|$)|too[[:space:]]+many[[:space:]]+requests|usage[[:space:]_-]?limit|plan[[:space:]]+limit|(monthly|daily|weekly)[[:space:]]+limit|quota[[:space:][:alpha:]]{0,40}(exceeded|reached|exhausted)|(exceeded|reached|exhausted|hit)[[:space:][:alnum:]]{0,30}quota)'; then
        return 0
    fi

    # Padrões de auth morta do Codex (token expirado/revogado, 401 da API).
    # Estritos por design: "token_expired" só na forma underscore (código de
    # erro literal, não prosa); "401 unauthorized" exige o par adjacente com
    # fronteira não-numérica à esquerda para não casar em "1401" nem em
    # número de linha de review ("api.ts:401 returns Unauthorized").
    echo "$input" | grep -qiE '(token_expired|refresh[[:space:]]+token[[:space:]]+(was[[:space:]]+)?already[[:space:]]+used|([^0-9]|^)401[[:space:]]+unauthorized)'
}

# Alias de compatibilidade — nome antigo, de quando o detector só cobria
# quota. Consumidores novos devem usar is_codex_fallback_error.
is_codex_quota_error() {
    is_codex_fallback_error "$@"
}

# Execução direta (não-sourced): parseia stdin ou args.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if is_codex_fallback_error "$@"; then
        echo "FALLBACK_ERROR"
        exit 0
    else
        echo "NO_FALLBACK_ERROR"
        exit 1
    fi
fi
