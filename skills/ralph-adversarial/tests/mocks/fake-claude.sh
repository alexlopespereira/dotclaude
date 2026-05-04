#!/usr/bin/env bash
# tests/mocks/fake-claude.sh — drop-in replacement for `claude` in tests
# (US-03 F3). Behaviour controlled by env vars; reads the prompt from $1
# only to extract STORY_ID. The real claude flags (--print etc.) are
# never seen here because ralph-adversarial.sh strips them whenever
# RALPH_AGENT_BIN is set (see launch_agent_pgrouped).
#
# Env vars:
#   FAKE_OUTCOME   one of: commit | noop | hang | conflict-trivial |
#                  conflict-overlap | multi-commit-violation |
#                  amend-violation | commit-then-reset |
#                  git-reset-violation | delta-commit | delta-untracked
#                  (default: commit)
#   FAKE_OUTCOME_MAP  optional path to a file mapping STORY_ID:OUTCOME (one
#                  per line). When set and the resolved STORY_ID has a row,
#                  it overrides FAKE_OUTCOME. Used by US-06 parallel tests
#                  to assign a different outcome per dispatched story.
#   FAKE_DELAY     integer seconds to sleep before acting (default 0)
#   FAKE_DELAY_MAP optional STORY_ID:DELAY map; same semantics as
#                  FAKE_OUTCOME_MAP but for FAKE_DELAY.
#   FAKE_STORY_ID  override for the id extracted from the prompt
#   FAKE_FILE      filename for conflict-* outcomes (default work.txt)
#   FAKE_LINE      line number written by conflict-overlap (default 1)
#
# Exit codes:
#   0 normal
#   2 unknown FAKE_OUTCOME

set -e

PROMPT="${1:-}"
OUTCOME="${FAKE_OUTCOME:-commit}"
DELAY="${FAKE_DELAY:-0}"
SHARED_FILE="${FAKE_FILE:-work.txt}"
OVERLAP_LINE="${FAKE_LINE:-1}"

# Pull "id": "US-XX" out of the JSON block ralph-adversarial.sh appends
# after "## Story atual". Falls back to FAKE_STORY_ID then a literal
# placeholder so the mock never crashes on missing input.
STORY_ID="${FAKE_STORY_ID:-}"
if [ -z "$STORY_ID" ]; then
    STORY_ID=$(printf '%s\n' "$PROMPT" \
        | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -1 \
        | sed -E 's/.*"([^"]+)"$/\1/')
fi
[ -z "$STORY_ID" ] && STORY_ID="US-FAKE"

# US-06: optional per-story map override for OUTCOME and DELAY.
if [ -n "${FAKE_OUTCOME_MAP:-}" ] && [ -f "$FAKE_OUTCOME_MAP" ]; then
    mapped=$(grep "^${STORY_ID}:" "$FAKE_OUTCOME_MAP" | head -1 | cut -d: -f2-)
    [ -n "$mapped" ] && OUTCOME="$mapped"
fi
if [ -n "${FAKE_DELAY_MAP:-}" ] && [ -f "$FAKE_DELAY_MAP" ]; then
    mapped_delay=$(grep "^${STORY_ID}:" "$FAKE_DELAY_MAP" | head -1 | cut -d: -f2-)
    [ -n "$mapped_delay" ] && DELAY="$mapped_delay"
fi

[ "$DELAY" -gt 0 ] 2>/dev/null && sleep "$DELAY"

# Local git identity — repo under test may not have one configured.
git config user.email >/dev/null 2>&1 || git config user.email "fake-claude@test.local"
git config user.name  >/dev/null 2>&1 || git config user.name  "fake-claude"

case "$OUTCOME" in
    commit)
        # Touches progress.txt — intentional violation seed for US-04 AC1
        # (Camada B detects the forbidden delta).
        printf 'fake commit by %s\n' "$STORY_ID" >> progress.txt
        git add progress.txt
        git commit -m "[$STORY_ID] fake commit" --quiet
        ;;

    noop)
        # No commit, no edits — exercises FALHA_COMMIT path in orchestrator.
        :
        ;;

    hang)
        # Block forever; the orchestrator's wait_with_timeout must kill us.
        sleep 999
        ;;

    conflict-trivial)
        # Append a uniquely-tagged line — two workers running this from
        # different stories edit different rows, so a 3-way merge resolves
        # cleanly (US-09 F8a).
        printf '%s line for %s\n' "$(date +%s)" "$STORY_ID" >> "$SHARED_FILE"
        git add "$SHARED_FILE"
        git commit -m "[$STORY_ID] conflict-trivial" --quiet
        ;;

    conflict-overlap)
        # Rewrite the same line regardless of story id; two workers
        # produce a textual conflict on the exact same row (US-09 F8b).
        # Use awk to overwrite line $OVERLAP_LINE in place; create file
        # with a sentinel row if missing.
        if [ ! -f "$SHARED_FILE" ]; then
            : > "$SHARED_FILE"
            i=0
            while [ "$i" -lt "$OVERLAP_LINE" ]; do
                printf 'placeholder\n' >> "$SHARED_FILE"
                i=$((i + 1))
            done
        fi
        awk -v ln="$OVERLAP_LINE" -v new="overlap from $STORY_ID" \
            'NR == ln { print new; next } { print }' \
            "$SHARED_FILE" > "$SHARED_FILE.tmp"
        mv "$SHARED_FILE.tmp" "$SHARED_FILE"
        git add "$SHARED_FILE"
        git commit -m "[$STORY_ID] conflict-overlap" --quiet
        ;;

    multi-commit-violation)
        # Two-commit sequence used by US-04 AC2 to verify that Camada B
        # iterates per-commit (the second commit alone is clean — only
        # commit-1 touches progress.txt).
        printf 'violation\n' >> progress.txt
        printf 'first slice\n' >> work.txt
        git add progress.txt work.txt
        git commit -m "[$STORY_ID] commit-1 violation (touches progress.txt)" --quiet

        printf 'second slice\n' >> work.txt
        git add work.txt
        git commit -m "[$STORY_ID] commit-2 clean" --quiet
        ;;

    amend-violation)
        # US-04 AC3: history-rewrite that hides the forbidden delta from
        # rev-list. Stage progress.txt + work.txt, commit, then `git rm`
        # progress.txt and amend. Post-amend SHA's tree no longer
        # contains progress.txt; only the reflog ('commit (amend):')
        # remembers the original.
        printf 'history-rewrite\n' >> progress.txt
        printf 'kept content\n'    >> work.txt
        git add progress.txt work.txt
        git commit -m "[$STORY_ID] commit-1 (will be amended)" --quiet

        git rm --quiet progress.txt
        git commit --amend --no-edit --quiet
        ;;

    commit-then-reset)
        # US-04 AC10 zero-net: HEAD_BEFORE == HEAD_AFTER after the
        # commit+reset cycle, so SHA-only Camada A misses the violation.
        # Camada A' (reflog) catches the 'commit:' + 'reset:' pair.
        printf 'transient\n' >> progress.txt
        git add progress.txt
        git commit -m "[$STORY_ID] transient commit (about to be reset)" --quiet
        git reset --hard HEAD~1 --quiet
        ;;

    git-reset-violation)
        # US-04 AC8: move HEAD without --hard so working tree stays
        # dirty. Reflog gains a 'reset:' entry. Caller must seed the
        # repo with at least one extra commit beyond the orchestrator's
        # initial branch tip so HEAD~1 resolves.
        git reset HEAD~1 >/dev/null
        ;;

    delta-commit)
        # US-06 AC6 (legacy): contract-compliant worker per the OLD contract
        # — deltas were committed alongside the implementation. Kept for
        # backward-compat with tests that pre-date the unstaged-deltas
        # refactor; new tests should use delta-untracked. -f forces the add
        # past the .git/info/exclude patterns added by ensure_slot_excludes_deltas.
        printf 'delta entry from %s\n' "$STORY_ID" > "progress-${STORY_ID}.txt"
        printf '## Notes from %s\n' "$STORY_ID"   > "agents-delta-${STORY_ID}.md"
        git add -f "progress-${STORY_ID}.txt" "agents-delta-${STORY_ID}.md"
        git commit -m "[$STORY_ID] delta-commit (contract-compliant)" --quiet
        ;;

    delta-untracked)
        # New worker contract (Plano B follow-up): deltas are written to
        # the WT but NEVER staged/committed. The orchestrator's
        # stash_worker_deltas hook captures them at COMMIT time. The mock
        # commits a work-<id>.txt file (PRD-scope simulation) so the COMMIT
        # event fires; deltas remain as untracked files for the orchestrator
        # to stash.
        printf 'delta entry from %s\n' "$STORY_ID" > "progress-${STORY_ID}.txt"
        printf '## Notes from %s\n' "$STORY_ID"   > "agents-delta-${STORY_ID}.md"
        printf 'work for %s\n' "$STORY_ID" > "work-${STORY_ID}.txt"
        git add "work-${STORY_ID}.txt"
        git commit -m "[$STORY_ID] delta-untracked (new contract)" --quiet
        ;;

    *)
        echo "ERROR: fake-claude.sh: unknown FAKE_OUTCOME='$OUTCOME'" >&2
        exit 2
        ;;
esac

exit 0
