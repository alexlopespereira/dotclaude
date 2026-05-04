#!/usr/bin/env bash
# validate-prd.sh — Schema + dependsOn + cycle + ESCALATED-vs-dep consistency
# check for prd.json. Extends the Fase 1 inline jq one-liner used by
# /prd-convert (US-02).
#
# Usage:
#   validate-prd.sh [--auto-recover] <prd.json>
#
# Exit codes:
#   0 — OK (or warnings only — prd.json untouched)
#   1 — schema invalid, cycle detected, or unresolved dependsOn reference
#   2 — usage / unknown flag
#
# Bash 3.2 compatible (sources lib/dispatch.sh which enforces the same).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./dispatch.sh
. "$SCRIPT_DIR/dispatch.sh"

AUTO_RECOVER=0
PRD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --auto-recover) AUTO_RECOVER=1 ;;
        -h|--help)
            cat <<'USAGE'
Usage: validate-prd.sh [--auto-recover] <prd.json>

  --auto-recover   Revert ESCALATED stories whose blocked_by dep is now passes:true.
                   Without the flag the validator only warns; prd.json is untouched.
USAGE
            exit 0
            ;;
        --*)
            echo "ERROR: unknown flag '$1'" >&2
            exit 2
            ;;
        *)
            if [ -n "$PRD" ]; then
                echo "ERROR: only one prd path expected (got '$PRD' and '$1')" >&2
                exit 2
            fi
            PRD="$1"
            ;;
    esac
    shift
done

if [ -z "$PRD" ]; then
    echo "ERROR: prd path required (see --help)" >&2
    exit 2
fi
if [ ! -f "$PRD" ]; then
    echo "ERROR: prd file not found: $PRD" >&2
    exit 1
fi

# ─── Schema check (extends Fase 1 inline jq with dependsOn typing) ─────────
if ! jq -e '
    (.userStories | type == "array")
    and (.userStories | length > 0)
    and (.userStories | all(
        ((.id // "") != "")
        and ((.title // "") != "")
        and (((.acceptanceCriteria // []) | type == "array"))
        and (((.acceptanceCriteria // []) | length > 0))
        and (((.acceptanceCriteria // []) | all(type == "string" and . != "")))
        and (((.dependsOn // []) | type == "array"))
        and (((.dependsOn // []) | all(type == "string" and . != "")))
    ))
' "$PRD" > /dev/null; then
    echo "ERROR: $PRD failed schema check (missing id/title/acceptanceCriteria or malformed dependsOn)" >&2
    exit 1
fi

# ─── dependsOn references resolve to known story ids ─────────────────────
unresolved=$(jq -r '
    . as $root
    | .userStories[]
    | (.dependsOn // []) as $deps
    | $deps[] as $d
    | select(($root.userStories | map(.id) | index($d)) == null)
    | "\(.id)→\($d)"
' "$PRD")
if [ -n "$unresolved" ]; then
    echo "ERROR: unresolved dependsOn references in $PRD:" >&2
    printf '  %s\n' $unresolved >&2
    exit 1
fi

# ─── Cycle detection (delegates to lib/dispatch.sh DFS) ───────────────────
if ! detect_dependsOn_cycle "$PRD"; then
    exit 1
fi

# ─── ESCALATED-vs-dep-OK consistency (rev3 R12) ───────────────────────────
# A story B is inconsistent when ALL hold:
#   B.passes == "ESCALATED"
#   B.blocked_by is a non-empty string
#   the story whose id == B.blocked_by exists AND has passes == true (literal)
# Output rows: "<B.id>|<dep.id>" — one per inconsistency.
inconsistencies=$(jq -r '
    . as $root
    | .userStories[]
    | select(.passes == "ESCALATED")
    | select((.blocked_by // "") != "")
    | .id as $b
    | .blocked_by as $a
    | ($root.userStories | map(select(.id == $a)) | .[0]) as $dep
    | select($dep != null and $dep.passes == true)
    | "\($b)|\($a)"
' "$PRD")

if [ -z "$inconsistencies" ]; then
    exit 0
fi

if [ "$AUTO_RECOVER" -eq 0 ]; then
    # Warn-only: emit one WARN line per inconsistency, leave prd.json untouched.
    while IFS='|' read -r b a; do
        [ -z "$b" ] && continue
        echo "WARN: $b passes:ESCALATED com blocked_by:$a; $a está OK." >&2
    done <<EOF
$inconsistencies
EOF
    exit 0
fi

# Auto-recover mode: build the list of story ids to revert, then rewrite the
# whole file in one jq pass (so a partial failure cannot leave prd.json half
# patched). Atomic via mktemp_safe + mv.
ids_json="["
first=1
recovered_ids=""
while IFS='|' read -r b a; do
    [ -z "$b" ] && continue
    if [ $first -eq 1 ]; then
        ids_json="$ids_json\"$b\""
        first=0
    else
        ids_json="$ids_json,\"$b\""
    fi
    recovered_ids="$recovered_ids $b"
done <<EOF
$inconsistencies
EOF
ids_json="$ids_json]"

tmp=$(mktemp_safe file validate-prd-recover) || {
    echo "ERROR: could not allocate tmpfile for auto-recover" >&2
    exit 1
}

if ! jq --argjson revert "$ids_json" '
    .userStories |= map(
        if (.id as $i | $revert | index($i)) != null
        then (. + {passes: false}) | del(.escalation_reason)
        else .
        end
    )
' "$PRD" > "$tmp"; then
    rm -f "$tmp"
    echo "ERROR: jq rewrite failed during auto-recover" >&2
    exit 1
fi
mv -f "$tmp" "$PRD"

for id in $recovered_ids; do
    echo "RECOVERED: $id reverted to passes:false" >&2
done
exit 0
