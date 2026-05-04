#!/usr/bin/env bash
# tests/lib/lint-f8.sh — multi-check lint introduced by US-09 / F8 (AC F8g).
#
# Each check inspects ralph-adversarial.sh + lib/dispatch.sh for a forbidden
# pattern that previous loops have encoded as gotchas. A clean code base
# returns 0 violations across all 5 checks. Mutation tests in
# test_lint_f8.sh inject one violation per check and assert detection.
#
# Usage: lint-f8.sh [--quiet]
#   When run with --quiet, only the violation count + per-check tally is
#   printed; otherwise each violation is emitted with file:line:context.
#
# Exit codes:
#   0 → no violations
#   1 → at least one violation found
#
# The 5 checks (rev5 R20+R22+R23):
#   1. uppercase HEAD_BEFORE_MERGE used as a name (must stay lowercase).
#   2. head_before_merge referenced outside the whitelist of functions
#      (only merge_and_push_story is allowed to define/use it).
#   3. `git reflog --since=…` filtering on HEAD (broken by design — reflog
#      timestamps are local-clock unreliable; use --date=unix + epoch range).
#   4. `mktemp -t prefix` direct call (must use mktemp_safe).
#   5. mktemp template with fewer than 8 X's (forbidden by rev5b R28).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

# Files in scope. Tests/mocks are excluded — they may legitimately contain
# pattern-matching strings inside heredocs / fixtures.
TARGET_FILES=(
    "$SKILL_DIR/ralph-adversarial.sh"
    "$SKILL_DIR/lib/dispatch.sh"
)

# Override target list via env for mutation tests (so they can lint a
# patched copy in /tmp without touching the real files).
if [ -n "${LINT_F8_TARGETS:-}" ]; then
    # shellcheck disable=SC2206
    TARGET_FILES=( ${LINT_F8_TARGETS} )
fi

VIOLATIONS=0
report() {
    local check="$1" file="$2" line="$3" context="$4"
    VIOLATIONS=$((VIOLATIONS + 1))
    [ "$QUIET" -eq 1 ] && return 0
    printf '%s: %s:%s: %s\n' "$check" "$file" "$line" "$context"
}

# ─── Check 1: uppercase HEAD_BEFORE_MERGE used as a name ──────────────────
# Pattern: word boundary + HEAD_BEFORE_MERGE + word boundary, anywhere
# (assignment, expansion, comparison). The lowercase head_before_merge is
# the canonical form (Check 2 enforces its scope).
check_uppercase_head_before_merge() {
    local f
    for f in "${TARGET_FILES[@]}"; do
        [ -f "$f" ] || continue
        while IFS=: read -r line ctx; do
            [ -z "$line" ] && continue
            report "check1_uppercase_HEAD_BEFORE_MERGE" "$f" "$line" "$ctx"
        done < <(grep -nE '\bHEAD_BEFORE_MERGE\b' "$f" 2>/dev/null || true)
    done
}

# ─── Check 2: head_before_merge outside whitelist ─────────────────────────
# Whitelist: lines inside the merge_and_push_story function body OR in
# explanatory comments at the top of dispatch.sh. The simplest enforcement
# is "appears only in dispatch.sh; if anywhere else, violation".
# Within dispatch.sh we further require the surrounding awk window to land
# inside merge_and_push_story.
check_head_before_merge_scope() {
    local f
    for f in "${TARGET_FILES[@]}"; do
        [ -f "$f" ] || continue
        # Outside dispatch.sh: any reference is a violation.
        if [ "$(basename "$f")" != "dispatch.sh" ]; then
            while IFS=: read -r line ctx; do
                [ -z "$line" ] && continue
                report "check2_head_before_merge_outside_dispatch" "$f" "$line" "$ctx"
            done < <(grep -nE '\bhead_before_merge\b' "$f" 2>/dev/null || true)
            continue
        fi

        # Within dispatch.sh: track the enclosing top-level `name() {` block
        # and only allow the identifier inside merge_and_push_story. Uses
        # explicit non-word character context (BSD awk lacks `\<`/`\>`).
        # Comment lines (starting with `#`, possibly indented) are skipped:
        # the function's docstring legitimately discusses the rule.
        # Process substitution keeps the `while` in the parent shell so
        # VIOLATIONS increments stick.
        while IFS=: read -r line ctx; do
            [ -z "$line" ] && continue
            report "check2_head_before_merge_outside_whitelist" "$f" "$line" "$ctx"
        done < <(awk '
            /^[[:space:]]*#/ { next }
            /^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{$/ {
                fn = $0
                sub(/\(\) \{$/, "", fn)
                next
            }
            /^\}$/ { fn = ""; next }
            /(^|[^a-zA-Z0-9_])head_before_merge([^a-zA-Z0-9_]|$)/ {
                if (fn != "merge_and_push_story") {
                    printf "%d:%s\n", NR, $0
                }
            }
        ' "$f" 2>/dev/null || true)
    done
}

# ─── Check 3: `git reflog --since=…` against HEAD ─────────────────────────
# Pattern: literal `git reflog` followed by `--since=` with `HEAD` somewhere
# on the same line. --since on reflog uses the local clock and the entries'
# committer time, neither of which is reliable for our window logic; we use
# `git reflog show --date=unix HEAD` + epoch filter (US-04).
check_reflog_since_head() {
    local f
    for f in "${TARGET_FILES[@]}"; do
        [ -f "$f" ] || continue
        # Skip pure comment lines — they document the forbidden pattern.
        while IFS=: read -r line ctx; do
            [ -z "$line" ] && continue
            report "check3_reflog_since_head" "$f" "$line" "$ctx"
        done < <(grep -vnE '^[[:space:]]*#' "$f" 2>/dev/null \
            | grep -E ':[[:space:]]*[^#]*git[[:space:]]+reflog[[:space:]].*--since=.*HEAD' \
            | sed -E 's/^([0-9]+):[^:]*:/\1:/' || true)
    done
}

# ─── Check 4: mktemp -t prefix ────────────────────────────────────────────
# Direct `mktemp -t …` is forbidden (rev5b R28); use mktemp_safe.
# Comments (lines starting with #) are skipped — they document the rule.
check_mktemp_dash_t() {
    local f
    for f in "${TARGET_FILES[@]}"; do
        [ -f "$f" ] || continue
        while IFS=: read -r line ctx; do
            [ -z "$line" ] && continue
            report "check4_mktemp_dash_t" "$f" "$line" "$ctx"
        done < <(grep -vnE '^[[:space:]]*#' "$f" 2>/dev/null \
            | grep -E ':[[:space:]]*[^#]*\bmktemp[[:space:]]+-t[[:space:]]' \
            | sed -E 's/^([0-9]+):[^:]*:/\1:/' || true)
    done
}

# ─── Check 5: mktemp template with fewer than 8 X's ───────────────────────
# Match `mktemp` followed (possibly via flags) by a template ending in
# 1-7 X's at the path tail (XXXXXXXX = 8). Comments excluded — they
# legitimately discuss the rule.
check_mktemp_template_too_short() {
    local f
    for f in "${TARGET_FILES[@]}"; do
        [ -f "$f" ] || continue
        # The pattern looks for `mktemp` + non-newline chars + `.X{1,7}`
        # at end of token (followed by a non-X char OR end of token).
        while IFS=: read -r line ctx; do
            [ -z "$line" ] && continue
            report "check5_mktemp_template_short" "$f" "$line" "$ctx"
        done < <(grep -vnE '^[[:space:]]*#' "$f" 2>/dev/null \
            | grep -E '\bmktemp[[:space:]][^|;&]*\.X{1,7}([^X]|$)' \
            | grep -vE '\.X{8,}' \
            | sed -E 's/^([0-9]+):[^:]*:/\1:/' || true)
    done
}

# ─── Run all checks ───────────────────────────────────────────────────────

check_uppercase_head_before_merge
check_head_before_merge_scope
check_reflog_since_head
check_mktemp_dash_t
check_mktemp_template_too_short

if [ "$QUIET" -eq 1 ]; then
    echo "lint-f8 violations: $VIOLATIONS"
fi
[ "$VIOLATIONS" -eq 0 ] && exit 0 || exit 1
