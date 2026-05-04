#!/usr/bin/env bash
# tests/mocks/fake-codex.sh — drop-in replacement for `codex exec review`
# in tests (US-03 F3). Reads behaviour from env vars; ignores positional
# args (real codex receives `exec review --commit HEAD --full-auto`,
# but ralph-adversarial.sh routes around all that when
# RALPH_REVIEWER_BIN is set).
#
# Env vars (REVIEW-prefixed take precedence over legacy ones; the
# REVIEW prefix exists because the orchestrator exports both fake-claude
# and fake-codex env in the same scope, and the legacy FAKE_OUTCOME /
# FAKE_DELAY / FAKE_DELAY_MAP would otherwise be read by fake-claude too):
#
#   FAKE_VERDICT             MERGE | BLOCK | REQUEST_CHANGES | hang   (default MERGE)
#   FAKE_REVIEW_DELAY        integer seconds before output            (default $FAKE_DELAY → 0)
#   FAKE_REVIEW_OUTCOME      hang-with-mcp / dirty-worktree (defaults
#                            to legacy FAKE_OUTCOME for back-compat
#                            with US-03 test_mocks.sh).
#                              hang-with-mcp  → spawn 2 sleep children and wait
#                              dirty-worktree → drop stray untracked file in cwd
#                                               then emit MERGE (US-07 AC8 trigger)
#   FAKE_VERDICT_MAP         optional path to a STORY_ID:VERDICT map (one line
#                            per story). Overrides FAKE_VERDICT when matched.
#                            Lets US-07 AC1 alternate verdicts across reviews.
#   FAKE_REVIEW_DELAY_MAP    optional STORY_ID:DELAY map; overrides
#                            FAKE_REVIEW_DELAY/FAKE_DELAY when matched.
#                            Used by AC4 to make a single review hang.
#   FAKE_STORY_ID            override for the id extracted from the prompt.
#
# Output: a stub review followed by a single "## Verdict: <X>" line that
# parse_verdict.sh can match.

set -e

PROMPT="${1:-}"
VERDICT="${FAKE_VERDICT:-MERGE}"
DELAY="${FAKE_REVIEW_DELAY:-${FAKE_DELAY:-0}}"
OUTCOME="${FAKE_REVIEW_OUTCOME:-${FAKE_OUTCOME:-}}"

# Pull "US-XX" out of the prompt (ralph passes "review HEAD for US-XX").
# Falls back to FAKE_STORY_ID then a literal placeholder.
STORY_ID="${FAKE_STORY_ID:-}"
if [ -z "$STORY_ID" ]; then
    STORY_ID=$(printf '%s\n' "$PROMPT" \
        | grep -oE 'US-[A-Za-z0-9_-]+' \
        | head -1)
fi
[ -z "$STORY_ID" ] && STORY_ID="US-FAKE"

# Per-story overrides (US-07 AC1, AC4).
if [ -n "${FAKE_VERDICT_MAP:-}" ] && [ -f "$FAKE_VERDICT_MAP" ]; then
    mapped=$(grep "^${STORY_ID}:" "$FAKE_VERDICT_MAP" | head -1 | cut -d: -f2-)
    [ -n "$mapped" ] && VERDICT="$mapped"
fi
if [ -n "${FAKE_REVIEW_DELAY_MAP:-}" ] && [ -f "$FAKE_REVIEW_DELAY_MAP" ]; then
    mapped_delay=$(grep "^${STORY_ID}:" "$FAKE_REVIEW_DELAY_MAP" | head -1 | cut -d: -f2-)
    [ -n "$mapped_delay" ] && DELAY="$mapped_delay"
fi

if [ "$OUTCOME" = "hang-with-mcp" ]; then
    # AC6 (US-03)/AC5 (US-07): emulate codex + 2 MCP server children.
    #
    # Pattern is `bash -c 'sleep 999 & sleep 999 & wait'` — two direct
    # background sleeps then wait for both. Validated empirically:
    # `pgrep -P <bash-c-pid>` returns exactly 2 PIDs.
    #
    # Do NOT use `(cmd &)` (subshell-detach) — that orphans the children
    # to PID 1, defeating the orchestrator's `kill -- -$PGID`.
    #
    # macOS portability: setsid(1) does NOT exist as a separate utility
    # on Darwin (only the syscall does, exposed by Python or coreutils).
    # The pattern here works without any setsid wrapper because the
    # children inherit the invoking shell's process group, which is
    # exactly what kill_agent_pg targets.
    bash -c 'sleep 999 & sleep 999 & wait'
    exit 0
fi

if [ "$OUTCOME" = "dirty-worktree" ]; then
    # US-07 AC8: codex sujou o working tree. Trigger porcelain divergence
    # by dropping an untracked file in cwd; do NOT git-add it. The mock
    # still emits a MERGE so the only signal the orchestrator can use to
    # reject is the porcelain BEFORE/AFTER comparison.
    #
    # Filename is unique per invocation ($$) so the BEFORE snapshot of a
    # retry iteration (which still carries the prior stray file as an
    # untracked entry) differs from AFTER (now also lists the new stray).
    # A fixed filename would produce identical porcelain on retries and
    # mask the violation on iteration 2+.
    printf 'codex artifact\n' > ".ralph-codex-stray.$$"
    cat <<EOF
Mock codex review for HEAD (with side-effect).

## Verdict: MERGE
EOF
    exit 0
fi

[ "$DELAY" -gt 0 ] 2>/dev/null && sleep "$DELAY"

if [ "$VERDICT" = "hang" ]; then
    sleep 999
    exit 0
fi

cat <<EOF
Mock codex review for HEAD.

No findings. (FAKE_VERDICT=$VERDICT story=$STORY_ID)

## Verdict: $VERDICT
EOF

exit 0
