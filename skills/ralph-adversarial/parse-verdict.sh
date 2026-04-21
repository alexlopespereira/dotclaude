#!/bin/bash
# parse-verdict.sh — extrai veredicto de reviews Codex.
# Aceita JSON clássico (Codex <0.120) e markdown moderno.
# Uso:
#   source parse-verdict.sh  && parse_verdict "$review_text"
#   echo "$review_text" | bash parse-verdict.sh
# Imprime: MERGE | BLOCK | REQUEST_CHANGES | UNKNOWN

parse_verdict() {
    local input
    if [ $# -gt 0 ]; then
        input="$*"
    else
        input=$(cat)
    fi

    # 1. JSON clássico (compat Codex <0.120)
    if echo "$input" | grep -qiE '"verdict"[[:space:]]*:[[:space:]]*"MERGE"'; then
        echo "MERGE"; return 0
    fi
    if echo "$input" | grep -qiE '"verdict"[[:space:]]*:[[:space:]]*"BLOCK"'; then
        echo "BLOCK"; return 0
    fi
    if echo "$input" | grep -qiE '"verdict"[[:space:]]*:[[:space:]]*"REQUEST_CHANGES"'; then
        echo "REQUEST_CHANGES"; return 0
    fi

    # 2. Linha "Verdict:/Veredicto:/Decision:" (heading ou inline, com ou sem bold)
    #    Exemplos reconhecidos:
    #      ## Verdict: MERGE
    #      **Verdict:** APPROVE
    #      Veredicto: BLOCK
    #      Final Verdict: request changes
    local verdict_line
    verdict_line=$(echo "$input" \
        | grep -iE '^[[:space:]]*#{0,6}[[:space:]]*\**[[:space:]]*(final[[:space:]]+)?(verdict|veredicto|decision|decisão|recommendation|recomendação)[[:space:]]*\**[[:space:]]*:' \
        | head -3 \
        | tr '[:upper:]' '[:lower:]')

    # Ordem importa: BLOCK e REQUEST_CHANGES antes de MERGE.
    # Caso contrário "do not merge" casa "merge" e devolve MERGE errado.
    if [ -n "$verdict_line" ]; then
        if echo "$verdict_line" | grep -qE '(request[_[:space:]]?changes|needs[_[:space:]]?changes|changes[_[:space:]]?(required|requested))'; then
            echo "REQUEST_CHANGES"; return 0
        fi
        if echo "$verdict_line" | grep -qE '(block|do[[:space:]]?not[[:space:]]?merge|must[[:space:]]?not[[:space:]]?merge)'; then
            echo "BLOCK"; return 0
        fi
        if echo "$verdict_line" | grep -qE '(merge|approve|approved|lgtm|ship[[:space:]]?it)'; then
            echo "MERGE"; return 0
        fi
    fi

    # 3. Heading standalone "## Verdict" seguido de linha de conteúdo.
    #    Ex:
    #      ## Verdict
    #      LGTM — merge.
    local after_heading
    after_heading=$(echo "$input" \
        | awk 'tolower($0) ~ /^[[:space:]]*#{1,6}[[:space:]]*(final[[:space:]]+)?(verdict|veredicto|decision|recommendation)[[:space:]]*$/ {found=1; next} found && NF {print; found=0}' \
        | head -3 \
        | tr '[:upper:]' '[:lower:]')

    # Ordem importa: BLOCK e REQUEST_CHANGES antes de MERGE.
    if [ -n "$after_heading" ]; then
        if echo "$after_heading" | grep -qE '(request[_[:space:]]?changes|needs[_[:space:]]?changes|changes[_[:space:]]?(required|requested))'; then
            echo "REQUEST_CHANGES"; return 0
        fi
        if echo "$after_heading" | grep -qE '(block|do[[:space:]]?not[[:space:]]?merge|must[[:space:]]?not[[:space:]]?merge)'; then
            echo "BLOCK"; return 0
        fi
        if echo "$after_heading" | grep -qE '(merge|approve|approved|lgtm|ship[[:space:]]?it|looks[[:space:]]?good)'; then
            echo "MERGE"; return 0
        fi
    fi

    echo "UNKNOWN"
    return 0
}

# Execução direta (não-sourced): parseia stdin ou args.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    parse_verdict "$@"
fi
