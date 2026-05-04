#!/usr/bin/env bash
# extract-deps-from-plan.sh — Extract "depende de US-XX" mentions from text.
#
# Usage: extract-deps-from-plan.sh < plan.md
#        echo "Esta fatia depende de US-01" | extract-deps-from-plan.sh
#
# Outputs unique US-IDs (one per line, sorted).
# Recognized phrasings (case-insensitive on the verb):
#   "depende de US-XX"
#   "depende das US-XX, US-YY"
#   "depende dos US-XX e US-YY"
#
# Used by /prd-convert to populate dependsOn for fatias that declare deps in
# prose (US-02 AC1).

set -u

input=$(cat)
[ -z "$input" ] && exit 0

# Two-stage grep: (1) match the full "depende d[ea]s? <ids>" phrase to anchor
# the context; (2) pull every US-XX out of the matched span. sort -u keeps the
# output stable across input order.
printf '%s\n' "$input" \
    | grep -oEi 'depende d[aoe]s?[[:space:]]+US-[A-Za-z0-9]+([[:space:]]*(,|e)[[:space:]]+US-[A-Za-z0-9]+)*' \
    | grep -oE 'US-[A-Za-z0-9]+' \
    | sort -u
