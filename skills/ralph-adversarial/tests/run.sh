#!/bin/bash
# Test runner for parse-verdict.sh.
# Iterates over fixtures/, pipes each into parse_verdict, compares output
# against the expected verdict encoded in the filename.
#
# Filename convention:
#   json-merge.txt             → expect MERGE
#   md-inline-block.txt        → expect BLOCK
#   md-standalone-request-changes.txt → expect REQUEST_CHANGES
#   unknown.txt                → expect UNKNOWN
#   guard-false-positive.txt   → expect BLOCK (guards against matching
#                                 "approved by security" outside verdict line)
#
# Exit status = number of failing tests.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$SCRIPT_DIR/../parse-verdict.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# shellcheck source=../parse-verdict.sh
source "$PARSER"

expected_for() {
    local name="$1"
    case "$name" in
        *merge.txt)           echo MERGE ;;
        *block.txt)           echo BLOCK ;;
        *request-changes.txt) echo REQUEST_CHANGES ;;
        unknown.txt)          echo UNKNOWN ;;
        guard-*.txt)          echo BLOCK ;;
        *)                    echo "UNMAPPED_${name}" ;;
    esac
}

pass=0
fail=0
failures=()

for fixture in "$FIXTURES_DIR"/*.txt; do
    name=$(basename "$fixture")
    expected=$(expected_for "$name")
    got=$(parse_verdict "$(cat "$fixture")")

    if [ "$got" = "$expected" ]; then
        printf "  PASS  %-40s → %s\n" "$name" "$got"
        pass=$((pass + 1))
    else
        printf "  FAIL  %-40s expected=%s got=%s\n" "$name" "$expected" "$got"
        fail=$((fail + 1))
        failures+=("$name (expected=$expected got=$got)")
    fi
done

echo
echo "---"
echo "Pass: $pass  Fail: $fail"
if [ "$fail" -gt 0 ]; then
    echo "Failures:"
    for f in "${failures[@]}"; do
        echo "  - $f"
    done
fi

exit "$fail"