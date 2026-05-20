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

    # 3. Codex 0.120+ review mode (`codex exec review --commit ... --full-auto`):
    #    output é markdown sem linha "Verdict:". Inferir pelos findings.
    #    Convenção da rubrica CODE_REVIEW.md: P0/P1/P2 são bloqueantes; P3 é nit.
    #    Falhas técnicas do binário (codex_exec_failed) já caem na regra 1 (JSON sentinel).
    if echo "$input" | grep -qE '^[[:space:]]*[-*][[:space:]]*\[P[012]\]'; then
        echo "REQUEST_CHANGES"; return 0
    fi
    # Codex emitiu review (marcador "Full review comments" ou "Review complete")
    # sem nenhum P0/P1/P2 → MERGE. Apenas P3 (nit) ainda merge.
    # Phrasings observadas em smoke test 2026-05-03 (US-05 AC7):
    #   - "do not introduce any functional or maintainability issues"
    #   - "does not introduce an identifiable functional or maintainability issue"
    if echo "$input" | grep -qiE '(full[[:space:]]+review[[:space:]]+comments|review[[:space:]]+complete|no[[:space:]]+(blocking[[:space:]]+)?(issues|findings)|no[[:space:]]+[a-z, ]*(issues|findings|problems|bugs)[[:space:]]+(were[[:space:]]+|was[[:space:]]+)?found|(did[[:space:]]+not|didn'\''t)[[:space:]]+find[[:space:]]+any[[:space:]]+(introduced[[:space:]]+)?[a-z, ]*(issues|problems|bugs)|(do|does)[[:space:]]+not[[:space:]]+introduce[[:space:]]+(an[[:space:]]+|any[[:space:]]+)?[a-z, ]*(issue|issues|problem|problems|bug|bugs))'; then
        echo "MERGE"; return 0
    fi

    # 4. Heading standalone "## Verdict" seguido de linha de conteúdo.
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

# emit_progress_event — dual-output writer para progress.txt + progress.jsonl.
#
# Uso:
#   emit_progress_event <event> <story_id> <verdict|""> <evidences_newline_sep>
#
# Escreve uma linha humano-legível em progress.txt (pipe-concat das evidences,
# formato compat com ralph-adversarial.sh) E uma linha JSON em progress.jsonl
# com evidences como ARRAY de strings.
#
# Schema progress.jsonl:
#   {"ts": "ISO-8601", "event": "...", "story_id": "...",
#    "evidences": [...], "verdict": "..." | null}
#
# Evidences ausentes → array vazio. Verdict vazio → null.
emit_progress_event() {
    local event="$1" story_id="$2" verdict="$3" evidences_raw="${4:-}"
    local ts evidences_concat evidences_json
    ts=$(date -Iseconds)

    # progress.txt: pipe-concat compat (mesmo formato de ralph-adversarial.sh:706)
    if [ -n "$evidences_raw" ]; then
        evidences_concat=$(printf '%s' "$evidences_raw" | tr '\n' '|' | sed 's/|$//')
    else
        evidences_concat=""
    fi
    echo "${ts} | ${event} | ${story_id} | ${evidences_concat}" >> progress.txt

    # progress.jsonl: schema estruturado, evidences como array (não concat).
    if [ -n "$evidences_raw" ]; then
        evidences_json=$(printf '%s' "$evidences_raw" | jq -R . | jq -s .)
    else
        evidences_json='[]'
    fi
    jq -nc \
        --arg ts "$ts" \
        --arg event "$event" \
        --arg story_id "$story_id" \
        --argjson evidences "$evidences_json" \
        --arg verdict "$verdict" \
        '{ts: $ts, event: $event, story_id: $story_id, evidences: $evidences, verdict: (if $verdict == "" then null else $verdict end)}' \
        >> progress.jsonl
}

# Execução direta (não-sourced): parseia stdin ou args.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    parse_verdict "$@"
fi
