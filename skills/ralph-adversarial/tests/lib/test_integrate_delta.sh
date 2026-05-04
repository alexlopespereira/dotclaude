#!/usr/bin/env bash
# tests/lib/test_integrate_delta.sh — US-10 / F9 coverage for integrate_delta_files.
#
# AC1: after MERGE, progress-<story>.txt e agents-delta-<story>.md NÃO existem
#      em main (`git ls-tree HEAD progress-*.txt` empty).
# AC2: conteúdo dos deltas aparece em progress.txt e AGENTS.md central com
#      prefixo de timestamp + 'LEARNING | <story>'.
# AC3: em REQUEST_CHANGES/ESCALATED (não invocação), deltas continuam acessíveis
#      via `git show ralph/<story>:progress-<story>.txt` (branch worker preservada).
# AC4: delta vazio (0 bytes) ou só whitespace → integração pula `cat >> AGENTS.md`,
#      faz só git rm; AGENTS.md / progress.txt central inalterados.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
LIB_DIR="$SKILL_DIR/lib"

# shellcheck source=../../lib/dispatch.sh
source "$LIB_DIR/dispatch.sh"

PASS=0
FAIL=0
FAILED=""

_pass() { PASS=$((PASS + 1)); }
_fail() { FAIL=$((FAIL + 1)); FAILED="${FAILED}
  ✗ $1"; }

assert_eq() {
    local got="$1" want="$2" msg="$3"
    if [ "$got" = "$want" ]; then _pass
    else _fail "$msg :: want='$want' got='$got'"; fi
}
assert_rc() {
    local rc="$1" want="$2" msg="$3"
    if [ "$rc" = "$want" ]; then _pass
    else _fail "$msg :: expected rc=$want got rc=$rc"; fi
}
assert_contains() {
    local hay="$1" needle="$2" msg="$3"
    case "$hay" in
        *"$needle"*) _pass ;;
        *) _fail "$msg :: '$needle' not found in '$hay'" ;;
    esac
}

# mk_world — bare origin + orch clone + worker-A clone, with central
# progress.txt and AGENTS.md seeded so we can assert append behaviour.
mk_world() {
    local base
    base=$(mktemp_safe dir ralph-int)
    (
        cd "$base"
        git init --bare --quiet origin.git
        git clone --quiet origin.git seed
        cd seed
        git config user.email t@t.local
        git config user.name  t
        echo "central progress baseline" > progress.txt
        printf '# AGENTS.md\n\nbaseline section\n' > AGENTS.md
        echo "baseline work" > work.txt
        git add . && git commit -qm baseline
        git push --quiet origin master:main 2>/dev/null \
            || git push --quiet origin HEAD:main
    ) >/dev/null 2>&1
    git clone --quiet "$base/origin.git" "$base/orch"     >/dev/null 2>&1
    git clone --quiet "$base/origin.git" "$base/worker-A" >/dev/null 2>&1
    for d in orch worker-A; do
        ( cd "$base/$d" \
            && git config user.email t@t.local \
            && git config user.name  t \
            && git checkout -q main 2>/dev/null ) || true
    done
    rm -rf "$base/seed"
    echo "$base"
}

# worker_commit — worker creates a commit on branch ralph/<story> with the
# given delta contents. Empty content → 0-byte file. The branch name mirrors
# what the orchestrator will look up via `git show ralph/<story>:...` (AC3).
worker_commit() {
    local slot="$1" story_id="$2" progress_content="$3" agents_content="$4"
    git -C "$slot" checkout -qb "ralph/${story_id}"
    echo "work for ${story_id}" >> "$slot/work.txt"
    if [ -n "$progress_content" ]; then
        printf '%s\n' "$progress_content" > "$slot/progress-${story_id}.txt"
    else
        : > "$slot/progress-${story_id}.txt"
    fi
    if [ -n "$agents_content" ]; then
        printf '%s\n' "$agents_content" > "$slot/agents-delta-${story_id}.md"
    else
        : > "$slot/agents-delta-${story_id}.md"
    fi
    git -C "$slot" add .
    git -C "$slot" commit -qm "[${story_id}] worker"
}

# ─── AC1 + AC2: full merge with non-empty deltas ──────────────────────────

W=$(mk_world)
worker_commit "$W/worker-A" "US-X" \
    "delta progress for US-X" \
    "delta agents content for US-X"

merge_and_push_story "$W/orch" "$W/worker-A" "US-X" origin
rc=$?
assert_rc "$rc" 0 "AC1 merge_and_push rc=0 with deltas"

# AC1: delta files NOT in HEAD tree on orch.
ls_main=$(git -C "$W/orch" ls-tree -r HEAD --name-only \
    | grep -E '^(progress-US-X\.txt|agents-delta-US-X\.md)$' || true)
assert_eq "$ls_main" "" "AC1 delta files removed from main HEAD tree"

# AC1 corollary: the spec wording — `git ls-tree HEAD progress-*.txt` empty.
ls_glob=$(git -C "$W/orch" ls-tree -r HEAD --name-only \
    | grep -E '^progress-[A-Za-z0-9_-]+\.txt$' || true)
assert_eq "$ls_glob" "" "AC1 no progress-*.txt files in HEAD"

# AC2: central progress.txt has timestamp + LEARNING | <story> prefix + content.
progress_after=$(cat "$W/orch/progress.txt")
assert_contains "$progress_after" "LEARNING | US-X" "AC2 progress.txt has LEARNING|US-X prefix"
assert_contains "$progress_after" "delta progress for US-X" "AC2 progress.txt has delta content"
# ISO-8601 UTC marker (year + Z) signals the timestamp prefix is present.
assert_contains "$progress_after" "Z | LEARNING | US-X" "AC2 progress.txt entry has ts | LEARNING | <id> shape"

# AC2: central AGENTS.md has timestamp + LEARNING | <story> prefix + content.
agents_after=$(cat "$W/orch/AGENTS.md")
assert_contains "$agents_after" "LEARNING | US-X" "AC2 AGENTS.md has LEARNING|US-X prefix"
assert_contains "$agents_after" "delta agents content for US-X" "AC2 AGENTS.md has delta content"

# Origin received the amended merge (push happened after integration).
origin_ls=$(git -C "$W/origin.git" ls-tree -r main --name-only \
    | grep -E '^(progress-US-X\.txt|agents-delta-US-X\.md)$' || true)
assert_eq "$origin_ls" "" "AC1 origin main also lacks delta files (push of integrated merge)"
origin_progress=$(git -C "$W/origin.git" show "main:progress.txt" 2>/dev/null)
assert_contains "$origin_progress" "delta progress for US-X" "AC2 origin main has integrated progress content"

rm -rf "$W"

# ─── AC3: BLOCK / REQUEST_CHANGES → no integration → ralph/<story> retains deltas ─

W=$(mk_world)
worker_commit "$W/worker-A" "US-Y" "Y progress content" "Y agents content"

# Simulate REQUEST_CHANGES verdict: the orchestrator does NOT invoke
# merge_and_push_story, so the worker branch keeps its delta files intact.
content_p=$(git -C "$W/worker-A" show "ralph/US-Y:progress-US-Y.txt" 2>/dev/null)
assert_contains "$content_p" "Y progress content" "AC3 ralph/US-Y retains progress delta on BLOCK"

content_a=$(git -C "$W/worker-A" show "ralph/US-Y:agents-delta-US-Y.md" 2>/dev/null)
assert_contains "$content_a" "Y agents content" "AC3 ralph/US-Y retains agents delta on BLOCK"

# Central files on orch must be byte-identical to the seeded baseline (no
# implicit integration leaked in).
orch_progress_before=$(git -C "$W/orch" show "HEAD:progress.txt")
orch_progress_now=$(cat "$W/orch/progress.txt")
assert_eq "$orch_progress_now" "$orch_progress_before" "AC3 orch progress.txt unchanged on BLOCK"
orch_agents_before=$(git -C "$W/orch" show "HEAD:AGENTS.md")
orch_agents_now=$(cat "$W/orch/AGENTS.md")
assert_eq "$orch_agents_now" "$orch_agents_before" "AC3 orch AGENTS.md unchanged on BLOCK"

rm -rf "$W"

# ─── AC4: empty (0-byte) deltas → only git rm; AGENTS.md unchanged ────────

W=$(mk_world)
agents_seed=$(cat "$W/orch/AGENTS.md")
progress_seed=$(cat "$W/orch/progress.txt")

worker_commit "$W/worker-A" "US-Z" "" ""   # both deltas are 0 bytes

merge_and_push_story "$W/orch" "$W/worker-A" "US-Z" origin
rc=$?
assert_rc "$rc" 0 "AC4 merge with empty deltas rc=0"

agents_after=$(cat "$W/orch/AGENTS.md")
assert_eq "$agents_after" "$agents_seed" "AC4 AGENTS.md unchanged for empty agents-delta"

progress_after=$(cat "$W/orch/progress.txt")
assert_eq "$progress_after" "$progress_seed" "AC4 progress.txt unchanged for empty progress-delta"

# Even when empty, delta files are removed from main (AC1 still applies).
ls_main=$(git -C "$W/orch" ls-tree -r HEAD --name-only \
    | grep -E '^(progress-US-Z\.txt|agents-delta-US-Z\.md)$' || true)
assert_eq "$ls_main" "" "AC4 empty delta files still removed from main tree"

rm -rf "$W"

# ─── AC4b: whitespace-only deltas → also skip append (`grep -q '[^[:space:]]'`) ─

W=$(mk_world)
agents_seed=$(cat "$W/orch/AGENTS.md")
progress_seed=$(cat "$W/orch/progress.txt")

git -C "$W/worker-A" checkout -qb "ralph/US-WS"
echo "ws change" >> "$W/worker-A/work.txt"
printf '\n   \n\t\n' > "$W/worker-A/progress-US-WS.txt"
printf '\n' > "$W/worker-A/agents-delta-US-WS.md"
git -C "$W/worker-A" add .
git -C "$W/worker-A" commit -qm "[US-WS] worker — whitespace deltas"

merge_and_push_story "$W/orch" "$W/worker-A" "US-WS" origin
rc=$?
assert_rc "$rc" 0 "AC4b merge with whitespace-only deltas rc=0"

agents_after=$(cat "$W/orch/AGENTS.md")
assert_eq "$agents_after" "$agents_seed" "AC4b AGENTS.md unchanged for whitespace-only agents-delta"

progress_after=$(cat "$W/orch/progress.txt")
assert_eq "$progress_after" "$progress_seed" "AC4b progress.txt unchanged for whitespace-only progress-delta"

ls_main=$(git -C "$W/orch" ls-tree -r HEAD --name-only \
    | grep -E '^(progress-US-WS\.txt|agents-delta-US-WS\.md)$' || true)
assert_eq "$ls_main" "" "AC4b whitespace-only deltas still removed from main tree"

rm -rf "$W"

# ─── AC2-extra: only one delta non-empty → only that central file mutates ─

W=$(mk_world)
agents_seed=$(cat "$W/orch/AGENTS.md")

worker_commit "$W/worker-A" "US-P" "progress only delta" ""

merge_and_push_story "$W/orch" "$W/worker-A" "US-P" origin
rc=$?
assert_rc "$rc" 0 "AC2-extra merge with only-progress delta rc=0"

# Progress.txt mutated.
progress_after=$(cat "$W/orch/progress.txt")
assert_contains "$progress_after" "progress only delta" "AC2-extra progress.txt got the non-empty delta"
assert_contains "$progress_after" "LEARNING | US-P" "AC2-extra progress.txt has LEARNING|US-P prefix"

# AGENTS.md untouched (empty agents delta did not append).
agents_after=$(cat "$W/orch/AGENTS.md")
assert_eq "$agents_after" "$agents_seed" "AC2-extra AGENTS.md unchanged when agents-delta is empty"

# Both delta files still removed from main.
ls_main=$(git -C "$W/orch" ls-tree -r HEAD --name-only \
    | grep -E '^(progress-US-P\.txt|agents-delta-US-P\.md)$' || true)
assert_eq "$ls_main" "" "AC2-extra delta files removed from main tree"

rm -rf "$W"

# ─── Report ───────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────────────"
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '%s\n' "$FAILED"
    exit 1
fi
exit 0
