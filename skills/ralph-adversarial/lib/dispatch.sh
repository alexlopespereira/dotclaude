#!/usr/bin/env bash
# lib/dispatch.sh — Pure helpers for Ralph parallel dispatch (Fase 2 US-01).
#
# Bash 3.2 compatible (rev5b R27): no associative arrays, no mapfile.
# Slot phase tracking is file-based (atomic write via .tmp.$$ + mv).
#
# Sourced by tests and by the Fase 2 dispatcher; safe to source repeatedly.
# Functions return non-zero on failure; never call `exit` directly except in
# `assert_layer_a_done` (an explicit invariant violation guard).

# AC10 (rev5 PRECONDITION): bash 3.2 is sufficient because we use file-based
# slot phase storage. Only print a soft warning for very old shells.
if [ -z "${BASH_VERSINFO+x}" ]; then
    echo "WARN: lib/dispatch.sh expects BASH; functions may misbehave under sh." >&2
fi

# ─── is_dispatchable ───────────────────────────────────────────────────────
# Args: story_id  prd_path
# Returns 0 when:
#   - the story exists and has passes:false, AND
#   - every dependsOn entry (if any) has passes:true (literal true, not ESCALATED).
# Returns 1 otherwise.
is_dispatchable() {
    local story_id="$1"
    local prd_path="$2"

    local self_passes
    self_passes=$(jq -r --arg id "$story_id" \
        '.userStories[] | select(.id == $id) | .passes' "$prd_path")

    [ "$self_passes" = "false" ] || return 1

    local deps
    deps=$(jq -r --arg id "$story_id" \
        '.userStories[] | select(.id == $id) | (.dependsOn // [])[]' "$prd_path")

    [ -z "$deps" ] && return 0

    local dep dep_passes
    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        dep_passes=$(jq -r --arg id "$dep" \
            '.userStories[] | select(.id == $id) | .passes' "$prd_path")
        [ "$dep_passes" = "true" ] || return 1
    done <<< "$deps"

    return 0
}

# ─── compute_cap ───────────────────────────────────────────────────────────
# Args: parallel_n  slots_avail  dispatchable_count
# Prints min(parallel_n, slots_avail, dispatchable_count) on stdout.
# slots_avail <= 0 → prints 0 and emits a WARN to stderr (pool too small).
compute_cap() {
    local parallel_n="$1"
    local slots_avail="$2"
    local dispatchable="$3"

    if [ "$slots_avail" -le 0 ]; then
        echo "WARN: pool too small for parallel dispatch (slots_avail=$slots_avail)" >&2
        echo 0
        return 0
    fi

    local cap="$parallel_n"
    [ "$slots_avail" -lt "$cap" ] && cap="$slots_avail"
    [ "$dispatchable" -lt "$cap" ] && cap="$dispatchable"
    [ "$cap" -lt 0 ] && cap=0
    echo "$cap"
}

# ─── parse_pool_from_pwd ───────────────────────────────────────────────────
# Args: pwd
# Matches ^.*/checkouts/<repo>-<N>$ where N is digits.
# On match: prints "<repo> <N>" on stdout, returns 0.
# Otherwise: returns 1 with error on stderr.
parse_pool_from_pwd() {
    local pwd_arg="$1"
    if [[ "$pwd_arg" =~ ^.*/checkouts/([^/]+)-([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
        return 0
    fi
    echo "ERROR: pwd '$pwd_arg' does not match pool pattern .../checkouts/<repo>-<N>" >&2
    return 1
}

# ─── read_workers_file ─────────────────────────────────────────────────────
# Args: path
# Parses lines of format "slot:pid:story_id:started_at" and prints valid ones.
# Malformed lines are silently skipped. Missing file → no output, return 0.
read_workers_file() {
    local path="$1"
    [ -f "$path" ] || return 0

    local line
    while IFS= read -r line; do
        # 4 colon-separated fields; pid and started_at must be numeric.
        if [[ "$line" =~ ^[^:]+:[0-9]+:[^:]+:[0-9]+$ ]]; then
            echo "$line"
        fi
    done < "$path"
}

# ─── next_dispatchable ─────────────────────────────────────────────────────
# Args: prd_path
# Prints the id of the highest-priority dispatchable story (priority=1 ranks
# first; sort_by(.priority) ascending). Empty when no story is dispatchable.
# Returns 0 always (caller decides what empty means).
next_dispatchable() {
    local prd_path="$1"

    local ids
    ids=$(jq -r '[.userStories[]] | sort_by(.priority) | .[].id' "$prd_path")

    local id
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        if is_dispatchable "$id" "$prd_path"; then
            echo "$id"
            return 0
        fi
    done <<< "$ids"
    return 0
}

# ─── detect_dependsOn_cycle ────────────────────────────────────────────────
# Args: prd_path
# Performs DFS over the dependsOn graph. Returns 0 when no cycle exists.
# On cycle: prints "ciclo detectado: A → B → A" to stderr and returns 1.
detect_dependsOn_cycle() {
    local prd_path="$1"

    local nodes
    nodes=$(jq -r '.userStories[].id' "$prd_path")
    local edges
    edges=$(jq -r '.userStories[] | . as $s | (.dependsOn // [])[] | "\($s.id) \(.)"' "$prd_path")

    # Reset shared DFS state for this invocation.
    _DFS_VISITED=""

    local node
    while IFS= read -r node; do
        [ -z "$node" ] && continue
        case " $_DFS_VISITED " in *" $node "*) continue ;; esac
        _DFS_PATH=""
        if _dfs_cycle "$node" "$edges"; then
            return 1
        fi
    done <<< "$nodes"
    return 0
}

# Internal: iterative-friendly recursive helper. Uses globals _DFS_PATH (current
# DFS stack as space-separated ids) and _DFS_VISITED (fully-explored set).
# Returns 0 when a cycle is detected (and prints it to stderr); 1 otherwise.
_dfs_cycle() {
    local node="$1"
    local edges="$2"

    case " $_DFS_PATH " in
        *" $node "*)
            local cycle="" found=0 p
            for p in $_DFS_PATH; do
                if [ "$p" = "$node" ]; then found=1; fi
                if [ $found -eq 1 ]; then
                    if [ -z "$cycle" ]; then
                        cycle="$p"
                    else
                        cycle="$cycle → $p"
                    fi
                fi
            done
            cycle="$cycle → $node"
            echo "ciclo detectado: $cycle" >&2
            return 0
            ;;
    esac

    case " $_DFS_VISITED " in *" $node "*) return 1 ;; esac

    _DFS_PATH="$_DFS_PATH $node"

    local src dep
    while IFS=' ' read -r src dep; do
        [ "$src" = "$node" ] || continue
        [ -z "$dep" ] && continue
        if _dfs_cycle "$dep" "$edges"; then
            return 0
        fi
    done <<< "$edges"

    _DFS_VISITED="$_DFS_VISITED $node"
    _DFS_PATH="${_DFS_PATH% $node}"
    return 1
}

# ─── mktemp_safe (rev5b R28) ───────────────────────────────────────────────
# Args: type label
#   type: "file" | "dir"
#   label: prefix (e.g., "ralph-iter")
# Constraints: never use `-t`; template has exactly 8 X's.
# TMPDIR handling: trailing slash stripped; if TMPDIR is unset/unwritable/not a
# directory, fall back to ${MKTEMP_SAFE_FALLBACK:-/tmp} with a warning. If both
# fail, return 1. The fallback is injectable (env var) so tests can exercise the
# "both unwritable" branch deterministically without needing to chmod real /tmp.
mktemp_safe() {
    local type="$1"
    local label="$2"

    local fallback="${MKTEMP_SAFE_FALLBACK:-/tmp}"
    fallback="${fallback%/}"
    [ -z "$fallback" ] && fallback="/tmp"

    local tmp_root="${TMPDIR:-$fallback}"
    tmp_root="${tmp_root%/}"
    [ -z "$tmp_root" ] && tmp_root="$fallback"

    if [ ! -d "$tmp_root" ] || [ ! -w "$tmp_root" ]; then
        echo "WARN: TMPDIR='${TMPDIR:-}' not usable; falling back to $fallback" >&2
        tmp_root="$fallback"
    fi

    if [ ! -d "$tmp_root" ] || [ ! -w "$tmp_root" ]; then
        echo "ERROR: no writable tmpdir found (tried TMPDIR and $fallback)" >&2
        return 1
    fi

    local template="$tmp_root/${label}.XXXXXXXX"  # exactly 8 X's
    case "$type" in
        file) mktemp "$template" ;;
        dir)  mktemp -d "$template" ;;
        *)
            echo "ERROR: mktemp_safe type must be 'file' or 'dir' (got '$type')" >&2
            return 1
            ;;
    esac
}

# ─── set_slot_phase / get_slot_phase (rev5b R27, file-based atomic) ────────
# Args: slot_dir  phase
# Writes phase to $slot_dir/.slot-phase via tmp file + mv (atomic on POSIX).
# Tmp suffix uses $$ so concurrent set_slot_phase calls do not collide.
set_slot_phase() {
    local slot_dir="$1"
    local phase="$2"
    # Suffix uses $$.$RANDOM to disambiguate concurrent writers from the SAME
    # parent shell (bash 3.2 lacks $BASHPID, so subshells share $$). $$ alone
    # suffices for separate worker processes; $RANDOM closes the same-shell
    # racing-subshell hole.
    local tmp="$slot_dir/.slot-phase.tmp.$$.$RANDOM"
    printf '%s\n' "$phase" > "$tmp"
    mv -f "$tmp" "$slot_dir/.slot-phase"
}

# Args: slot_dir
# Prints the slot's current phase, or "uninit" if no .slot-phase file exists.
get_slot_phase() {
    local slot_dir="$1"
    if [ -f "$slot_dir/.slot-phase" ]; then
        head -1 "$slot_dir/.slot-phase"
    else
        echo "uninit"
    fi
}

# ─── die (US-04 AC11) ──────────────────────────────────────────────────────
# Convention: invariant/precondition violations call die so they propagate
# even from inside a `$(...)` command substitution (subshell exits, the
# captured rc is non-zero). `return 1` from a function does NOT terminate
# the enclosing subshell — execution would continue past the call,
# defeating fail-fast semantics. See test_validate_worker_commits.sh AC11
# for the documented anti-pattern vs canonical fixture.
die() {
    echo "$*" >&2
    exit 1
}

# ─── layer_a_validate (default stub) ───────────────────────────────────────
# Real validator lands in US-04 (3-layer post-validation). Default is a
# permissive stub so US-01 tests can override per-case via redefinition.
# CONVENTION (AC11): when overriding, signal failure via `die "..."` (which
# expands to exit 1) — never `return 1`. Inside `( layer_a_validate ... )`
# both behave the same, but `$(layer_a_validate ...)` (command substitution)
# only fast-aborts on `exit`. Tests document both behaviours.
layer_a_validate() {
    return 0
}

# ─── with_validated_slot (rev5b R27) ───────────────────────────────────────
# Args: slot_dir  callback...
# Runs layer_a_validate. On success: marks phase=in_progress, runs callback,
# marks phase=completed (or callback_failed). On validate failure: persists
# phase=layer_a_failed, returns 1 WITHOUT invoking callback.
#
# The validator is wrapped in a subshell so a `die`/`exit 1` inside it bubbles
# up as the subshell's non-zero rc; we then persist failure state and return 1
# so callers under `set -e` get an immediate pipeline abort.
with_validated_slot() {
    local slot_dir="$1"; shift

    if ! ( layer_a_validate "$slot_dir" ); then
        set_slot_phase "$slot_dir" "layer_a_failed"
        return 1
    fi

    set_slot_phase "$slot_dir" "in_progress"
    "$@"
    local rc=$?
    if [ $rc -eq 0 ]; then
        set_slot_phase "$slot_dir" "completed"
    else
        set_slot_phase "$slot_dir" "callback_failed"
    fi
    return $rc
}

# ─── assert_layer_a_done ───────────────────────────────────────────────────
# Args: slot_dir
# Invariant guard for orch_rebase (US-04 AC9): refuses to proceed if Layer A
# has not been completed for this slot. Phase must be in_progress or completed.
# Anything else (uninit / layer_a_failed / callback_failed) → exit 1.
assert_layer_a_done() {
    local slot_dir="$1"
    local phase
    phase=$(get_slot_phase "$slot_dir")
    case "$phase" in
        in_progress|completed) return 0 ;;
        *)
            echo "INVARIANT VIOLATION: orch_rebase on slot=$slot_dir in phase=$phase (Layer A not done)" >&2
            exit 1
            ;;
    esac
}

# ─── validate_worker_commits (US-04 — 3-layer post-validation) ─────────────
# Args: slot  head_before  head_after  iter_start  worker_finished
#   slot            : path to the worker slot (must NOT equal $ORCH)
#   head_before     : SHA of HEAD before the worker iteration started
#   head_after      : SHA of HEAD after the worker finished
#   iter_start      : unix epoch when the iteration started (reflog low bound)
#   worker_finished : unix epoch when the worker finished (reflog high bound)
#
# Three layers, run in order:
#   Layer A' (reflog) — `git reflog show --date=unix HEAD` filtered by epoch
#       range. Detects history rewrites that the SHA/DAG comparison cannot
#       see: `commit (amend):` (AC3) and `reset:` (AC8/AC10). Catches the
#       zero-net case (head_before == head_after but reflog shows commit
#       then reset, AC10). On hit → HISTORY_REWRITE_DETECTED.
#   Layer A  (SHA)    — primary determinism check. If head_before ==
#       head_after, no commits were added; return 0 (Layer A' already
#       cleared the rewrite case).
#   Layer B  (filename) — iterate every commit in `head_before..head_after`
#       and reject if any touches a top-level forbidden delta (progress.txt
#       or AGENTS.md). Per-commit iteration matters for AC2/AC4 where only
#       one commit in the range is dirty.
#
# Returns 0 when all layers pass; non-zero otherwise (with reason on stderr).
# AC6: rejects slot == "$ORCH" up-front.
validate_worker_commits() {
    local slot="$1"
    local head_before="$2"
    local head_after="$3"
    local iter_start="$4"
    local worker_finished="$5"

    if [ -n "${ORCH:-}" ] && [ "$slot" = "$ORCH" ]; then
        echo "ERROR: slot inválido — não pode ser orquestrador" >&2
        return 1
    fi

    # Layer A': reflog inspection. POSIX awk extracts HEAD@{<epoch>} and
    # filters to entries whose timestamp lies in [iter_start, worker_finished].
    # macOS ships BSD awk; we rely only on POSIX match()/RSTART/RLENGTH.
    local reflog_window
    reflog_window=$(git -C "$slot" reflog show --date=unix HEAD 2>/dev/null \
        | awk -v lo="$iter_start" -v hi="$worker_finished" '
            {
                if (match($0, /HEAD@\{[0-9]+\}/)) {
                    ts = substr($0, RSTART+6, RLENGTH-7) + 0
                    if (ts >= lo && ts <= hi) print
                }
            }')

    if printf '%s\n' "$reflog_window" | grep -qE 'commit \(amend\)'; then
        echo "HISTORY_REWRITE_DETECTED: amend entry in reflog ($slot)" >&2
        return 1
    fi
    if printf '%s\n' "$reflog_window" | grep -qE '(^|[[:space:]])reset:'; then
        echo "HISTORY_REWRITE_DETECTED: reset entry in reflog ($slot)" >&2
        return 1
    fi

    # Layer A: SHA comparison. Equal → no DAG growth, nothing for Layer B.
    if [ "$head_before" = "$head_after" ]; then
        return 0
    fi

    # Layer B: per-commit filename inspection. --reverse so iteration order
    # matches authoring order, but rejection on first hit is sufficient.
    local commits sha touched
    commits=$(git -C "$slot" rev-list --reverse "${head_before}..${head_after}" 2>/dev/null)
    while IFS= read -r sha; do
        [ -z "$sha" ] && continue
        touched=$(git -C "$slot" show --name-only --pretty=format: "$sha" \
            | grep -E '^(progress\.txt|AGENTS\.md)$' || true)
        if [ -n "$touched" ]; then
            echo "FORBIDDEN_DELTA in $sha: $touched" >&2
            return 1
        fi
    done <<< "$commits"

    return 0
}

# ─── orch_rebase (US-04 AC9) ───────────────────────────────────────────────
# Args: slot
# Real rebase logic lands in US-09 (F8); here it is just the invariant guard
# wrapper. Calling orch_rebase directly without going through
# with_validated_slot must die with INVARIANT VIOLATION (Layer A not done).
orch_rebase() {
    local slot="$1"
    assert_layer_a_done "$slot"
    return 0
}

# ─── version_ge (US-05 AC7) ────────────────────────────────────────────────
# Args: a  b
# Returns 0 when dotted version a >= b, 1 otherwise. Strips non-numeric
# suffix from each component (e.g. "2.39.5-rc1" → 2.39.5). Missing
# components default to 0. Three components compared: major, minor, patch.
version_ge() {
    local a="$1" b="$2"
    local a_maj a_min a_pat _rest_a
    local b_maj b_min b_pat _rest_b
    IFS='.' read -r a_maj a_min a_pat _rest_a <<< "$a"
    IFS='.' read -r b_maj b_min b_pat _rest_b <<< "$b"
    # Strip non-numeric suffix from each component (trailing -rc1, etc.).
    a_maj="${a_maj%%[!0-9]*}"; a_min="${a_min%%[!0-9]*}"; a_pat="${a_pat%%[!0-9]*}"
    b_maj="${b_maj%%[!0-9]*}"; b_min="${b_min%%[!0-9]*}"; b_pat="${b_pat%%[!0-9]*}"
    a_maj="${a_maj:-0}"; a_min="${a_min:-0}"; a_pat="${a_pat:-0}"
    b_maj="${b_maj:-0}"; b_min="${b_min:-0}"; b_pat="${b_pat:-0}"

    if [ "$a_maj" -ne "$b_maj" ]; then [ "$a_maj" -gt "$b_maj" ]; return; fi
    if [ "$a_min" -ne "$b_min" ]; then [ "$a_min" -gt "$b_min" ]; return; fi
    [ "$a_pat" -ge "$b_pat" ]
}

# ─── git_version_for_slot / git_reflog_setting_for_slot (overrideable) ─────
# Indirection lets tests stub the underlying git lookups without touching
# PATH or installing fake binaries. Same redefinition pattern used by
# layer_a_validate (US-04 AC11).
git_version_for_slot() {
    git -C "$1" --version 2>/dev/null | awk '{print $3}'
}

git_reflog_setting_for_slot() {
    git -C "$1" config --get core.logAllRefUpdates 2>/dev/null
}

# ─── preflight_slot (US-05 AC6, AC7) ───────────────────────────────────────
# Args: slot_path
# Validates that a slot is acceptable for parallel dispatch:
#   AC6: core.logAllRefUpdates must NOT be 'false' (Camada A' needs reflog).
#        Empty/unset → ok (git's default is true unless explicitly disabled).
#   AC7: git --version must be >= 2.9 (reflog --date=unix requires 2.9+).
# Returns 0 on pass; 1 with diagnostic on stderr otherwise.
preflight_slot() {
    local slot_path="$1"
    local reflog_setting git_ver
    reflog_setting=$(git_reflog_setting_for_slot "$slot_path")
    if [ "$reflog_setting" = "false" ]; then
        echo "ERRO: $slot_path com core.logAllRefUpdates=false." >&2
        echo "  Camada A' de pós-validação requer reflog ativo." >&2
        echo "  Corrija com: git -C $slot_path config core.logAllRefUpdates true" >&2
        return 1
    fi
    git_ver=$(git_version_for_slot "$slot_path")
    if [ -z "$git_ver" ]; then
        echo "ERRO: $slot_path — não foi possível ler 'git --version'." >&2
        return 1
    fi
    if ! version_ge "$git_ver" "2.9"; then
        echo "ERRO: $slot_path tem git $git_ver (requer >= 2.9)." >&2
        echo "  git reflog show --date=unix exige git 2.9+ para Camada A'." >&2
        return 1
    fi
    return 0
}

# ─── count_pool_slots (US-05) ──────────────────────────────────────────────
# Args: pool_base  repo
# Reads ${pool_base}/.${repo}.pool (slots=N field) when present and valid;
# falls back to counting ${repo}-<N> directories under pool_base. Always
# prints an integer (0 when neither source yields a count).
count_pool_slots() {
    local pool_base="$1" repo="$2"
    local pool_file="$pool_base/.${repo}.pool"
    if [ -f "$pool_file" ]; then
        local n
        n=$(grep '^slots=' "$pool_file" | head -1 | cut -d= -f2)
        if [[ "$n" =~ ^[0-9]+$ ]]; then
            echo "$n"
            return 0
        fi
    fi
    ls -d "$pool_base/${repo}-"[0-9]* 2>/dev/null | wc -l | tr -d ' '
}

# ─── log_event (US-06) ─────────────────────────────────────────────────────
# Args: category  story_id  detail
# Writes a one-line structured event to stderr in the existing progress.txt
# format ("<iso8601> | <CATEGORY> | <story> | <detail>") so callers may also
# tee it to progress.txt. Categories are fixed strings used in tests; new
# values must be added to the AGENTS.md vocabulary list to stay greppable.
log_event() {
    local category="$1"
    local story_id="$2"
    local detail="$3"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    printf '%s | %s | %s | %s\n' "$ts" "$category" "$story_id" "$detail" >&2
}

# ─── ensure_slot_excludes_deltas (Plano B follow-up) ───────────────────────
# Args: slot_path
# Appends delta-file patterns to slot's .git/info/exclude so `git add .`
# never accidentally stages them. Defense-in-depth backstop for the new
# worker contract: delta files MUST stay untracked. Idempotent: skips
# append if patterns already present. Best-effort.
ensure_slot_excludes_deltas() {
    local slot_path="$1"
    local exclude_file="$slot_path/.git/info/exclude"
    [ ! -f "$exclude_file" ] && return 0
    if grep -qE '^progress-\*\.txt$' "$exclude_file" 2>/dev/null; then
        return 0
    fi
    {
        echo ""
        echo "# Ralph Adversarial — delta files are framework-managed, never committed"
        echo "progress-*.txt"
        echo "agents-delta-*.md"
    } >> "$exclude_file" 2>/dev/null || true
    return 0
}

# ─── stash_worker_deltas (Plano B follow-up) ───────────────────────────────
# Args: worker_slot orch_slot story_id
# Captures worker's UNTRACKED delta files (progress-<id>.txt and
# agents-delta-<id>.md) into orch's stash dir BEFORE the slot can be
# reused. Removes them from the worker WT so the next dispatch starts
# clean. Stash dir layout: $orch_slot/.ralph/delta-stash/<story>/.
# integrate_delta_files reads from this dir at MERGE time, so the worker
# never has to commit its delta files (they don't pollute the SHA the
# reviewer sees, nor git history).
# Returns: always 0 (best-effort; missing files are not an error).
stash_worker_deltas() {
    local worker_slot="$1"
    local orch_slot="$2"
    local story_id="$3"

    local progress_path="$worker_slot/progress-${story_id}.txt"
    local agents_path="$worker_slot/agents-delta-${story_id}.md"

    if [ ! -f "$progress_path" ] && [ ! -f "$agents_path" ]; then
        return 0
    fi

    local stash_dir="$orch_slot/.ralph/delta-stash/$story_id"
    mkdir -p "$stash_dir" 2>/dev/null || return 0

    if [ -f "$progress_path" ]; then
        cp -f "$progress_path" "$stash_dir/progress-${story_id}.txt" 2>/dev/null || true
        rm -f "$progress_path" 2>/dev/null || true
    fi
    if [ -f "$agents_path" ]; then
        cp -f "$agents_path" "$stash_dir/agents-delta-${story_id}.md" 2>/dev/null || true
        rm -f "$agents_path" 2>/dev/null || true
    fi
    return 0
}

# ─── slate_cleanup_for_retry (US-06 AC5/AC6) ───────────────────────────────
# Args: slot  story_id
# Pre-condition for re-dispatch: remove the worker's delta files from the
# slot's index/working tree so a retry starts with a clean slate. Uses
# `git rm --ignore-unmatch` so the call is idempotent — exits 0 whether the
# files were tracked or absent.
#
# AC5: noop iteration produced no deltas → cleanup must NOT abort.
# AC6: previous attempt produced deltas → cleanup removes them.
slate_cleanup_for_retry() {
    local slot="$1"
    local story_id="$2"
    git -C "$slot" rm --ignore-unmatch -q -- \
        "progress-${story_id}.txt" "agents-delta-${story_id}.md" >/dev/null 2>&1 || true
    # Defense-in-depth: also remove untracked copies left in the working
    # tree. `git rm` only touches the index, so a stale untracked file
    # would survive and contaminate the retry.
    rm -f "$slot/progress-${story_id}.txt" "$slot/agents-delta-${story_id}.md" 2>/dev/null || true
    return 0
}

# ─── workers.txt helpers (US-06) ───────────────────────────────────────────
# Format: one record per line, "slot:pid:story_id:started_at" where slot
# is the basename of the slot dir (matches read_workers_file's regex).
# Mutations always go via tmp + mv so concurrent readers (tests) never see
# a partial line.
write_worker_record() {
    local workers_file="$1"
    local slot="$2"
    local pid="$3"
    local story_id="$4"
    local started_at="$5"
    printf '%s:%s:%s:%s\n' "$slot" "$pid" "$story_id" "$started_at" >> "$workers_file"
}

remove_worker_record() {
    local workers_file="$1"
    local pid="$2"
    [ -f "$workers_file" ] || return 0
    local tmp
    tmp=$(mktemp_safe file ralph-wk-rm) || return 1
    grep -v ":${pid}:" "$workers_file" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$workers_file"
}

# ─── dispatch helpers (US-06) ──────────────────────────────────────────────
# Args: prd_path
# Counts dispatchable stories (passes:false + deps satisfied). Used to size
# compute_cap when there are fewer pending stories than slots.
count_dispatchable() {
    local prd_path="$1"
    local ids n
    ids=$(jq -r '[.userStories[]] | sort_by(.priority) | .[].id' "$prd_path")
    n=0
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        if is_dispatchable "$id" "$prd_path"; then
            n=$((n + 1))
        fi
    done <<< "$ids"
    echo "$n"
}

# ─── touchesFiles disjunction gate (US-04) ─────────────────────────────────
# Conservative literal-prefix algorithm specified in skills/prd/SKILL.md
# ("Algoritmo de interseção de touchesFiles"). Glob matching is deliberately
# NOT used: it is cheap, deterministic, and only ever errs toward declaring
# a FALSE intersection (which serializes — safe), never a false disjunction
# (which would corrupt via concurrent edits to the same file).

# Args: glob
# Prints the literal prefix: the substring up to (exclusive) the first glob
# metacharacter (* ? [). No metacharacter → the whole string. The bracket
# class [*?[] matches any of those three chars; %% strips it and everything
# after. Verified under bash 3.2.
touches_literal_prefix() {
    printf '%s\n' "${1%%[*?[]*}"
}

# Args: a  b  (two literal prefixes)
# Returns 0 when one prefix is a string-prefix of the other (SKILL.md step 2).
# Prefixes are metachar-free, but $b is quoted so any stray char stays literal.
prefixes_intersect() {
    local a="$1" b="$2"
    case "$a" in "$b"*) return 0 ;; esac
    case "$b" in "$a"*) return 0 ;; esac
    return 1
}

# Args: story_id  prd_path
# Prints each touchesFiles entry on its own line (nothing when absent/empty).
touches_files_for() {
    jq -r --arg id "$1" \
        '.userStories[] | select(.id == $id) | (.touchesFiles // [])[]' "$2"
}

# Args: id_a  id_b  prd_path
# Returns 0 when stories A and B have intersecting touchesFiles (SKILL.md
# step 3 — any pair of prefixes intersects). If EITHER story lacks the field
# (absent OR empty array), returns 1 (no restriction — pre-US-04 behavior).
stories_touch_intersect() {
    local id_a="$1" id_b="$2" prd_path="$3"
    local files_a files_b
    files_a=$(touches_files_for "$id_a" "$prd_path")
    files_b=$(touches_files_for "$id_b" "$prd_path")
    [ -z "$files_a" ] && return 1
    [ -z "$files_b" ] && return 1

    local ga gb pa pb
    while IFS= read -r ga; do
        [ -z "$ga" ] && continue
        pa=$(touches_literal_prefix "$ga")
        while IFS= read -r gb; do
            [ -z "$gb" ] && continue
            pb=$(touches_literal_prefix "$gb")
            if prefixes_intersect "$pa" "$pb"; then
                return 0
            fi
        done <<< "$files_b"
    done <<< "$files_a"
    return 1
}

# Args: candidate_id  in_flight_ids (space-separated)  prd_path
# Returns 0 when the candidate's touchesFiles intersect ANY in-flight story's
# touchesFiles (→ must serialize). Returns 1 when there is no conflict.
candidate_touch_conflicts() {
    local candidate="$1" in_flight="$2" prd_path="$3"
    local other
    for other in $in_flight; do
        [ -z "$other" ] && continue
        [ "$other" = "$candidate" ] && continue
        if stories_touch_intersect "$candidate" "$other" "$prd_path"; then
            return 0
        fi
    done
    return 1
}

# Args: prd_path  excluded_ids (space-separated)
# Like next_dispatchable but skips ids already in flight on a worker. The
# orchestrator calls this with the current set of in-flight story_ids so the
# same story is never dispatched twice in parallel.
#
# US-04: the excluded set IS the in-flight set, so it doubles as the input
# to the touchesFiles disjunction gate — a candidate whose touchesFiles
# intersect any in-flight story is skipped (serialized) even when its
# dependsOn are satisfied. Field absent on either side → no extra restriction.
next_dispatchable_excluding() {
    local prd_path="$1"
    local excluded="$2"
    local ids id
    ids=$(jq -r '[.userStories[]] | sort_by(.priority) | .[].id' "$prd_path")
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        case " $excluded " in *" $id "*) continue ;; esac
        if is_dispatchable "$id" "$prd_path"; then
            if candidate_touch_conflicts "$id" "$excluded" "$prd_path"; then
                continue
            fi
            echo "$id"
            return 0
        fi
    done <<< "$ids"
    return 0
}

# ─── review queue + state helpers (US-07) ──────────────────────────────────
# review-queue.txt: FIFO of stories awaiting review.
#   line format: "<slot_basename>:<story_id>:<committed_at_epoch>"
# review-state.txt: at most ONE active review at a time (single line).
#   line format: "<pid>:<slot_basename>:<story_id>:<started_at_epoch>:<logfile>"
#   The logfile field carries the path captured stdout/stderr; the porcelain
#   snapshot taken before launch is stashed at "<logfile>.porcelain.before".
#
# The single-line invariant on review-state.txt is what AC2 (serialization)
# asserts. mktemp_safe + mv guarantees readers never observe a partial line.

# Append a queue entry. Caller must already have the queue file initialized
# (`: > "$queue_file"`); we don't create it here so that the absence of the
# file would surface a missing-init bug instead of being silently created.
enqueue_review() {
    local queue_file="$1" slot="$2" story_id="$3" committed_at="$4"
    printf '%s:%s:%s\n' "$slot" "$story_id" "$committed_at" >> "$queue_file"
}

# Pop the head line (FIFO). Prints the line on stdout and rewrites the file
# without it via mktemp_safe + mv (atomic). Returns 1 when the queue is
# empty so callers can `if pop_review_queue ...` without a separate check.
pop_review_queue() {
    local queue_file="$1"
    [ -s "$queue_file" ] || return 1
    local head_line
    head_line=$(head -1 "$queue_file")
    [ -z "$head_line" ] && return 1
    local tmp
    tmp=$(mktemp_safe file ralph-rq) || return 1
    tail -n +2 "$queue_file" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$queue_file"
    printf '%s\n' "$head_line"
    return 0
}

# Print review-state.txt content (or nothing when no active review).
read_review_state() {
    local state_file="$1"
    [ -f "$state_file" ] || return 0
    head -1 "$state_file" 2>/dev/null
}

# Atomic write of the single-line review-state record.
write_review_state() {
    local state_file="$1" pid="$2" slot="$3" story_id="$4" started_at="$5" logfile="$6"
    local tmp
    tmp=$(mktemp_safe file ralph-rs) || return 1
    printf '%s:%s:%s:%s:%s\n' "$pid" "$slot" "$story_id" "$started_at" "$logfile" > "$tmp"
    mv -f "$tmp" "$state_file"
}

# Truncate review-state.txt — single-writer (the orchestrator), so a plain
# `: >` is sufficient; readers see either the previous line or the empty
# file, never a partial mid-write state.
clear_review_state() {
    local state_file="$1"
    : > "$state_file"
}

# Args: workers_file  queue_file  state_file
# Print every story_id currently "in flight" — implementation worker, queued
# review, or active review. Used by next_dispatchable_excluding so the same
# story is never dispatched twice across the worker/review pipelines, and so
# stories whose dep is in review (passes:false) stay blocked correctly.
collect_in_flight() {
    local workers_file="$1" queue_file="$2" state_file="$3"
    [ -f "$workers_file" ] && awk -F: 'NF>=4 {printf "%s ", $3}' "$workers_file" 2>/dev/null
    [ -f "$queue_file"   ] && awk -F: 'NF>=3 {printf "%s ", $2}' "$queue_file"   2>/dev/null
    [ -f "$state_file"   ] && awk -F: 'NF>=4 {printf "%s ", $3}' "$state_file"   2>/dev/null
}

# ─── integrate_delta_files (US-10 F9) ──────────────────────────────────────
# Args: orch_slot story_id
# Reads progress-<story>.txt and agents-delta-<story>.md from the
# orchestrator's working tree (placed there by the just-finished merge),
# appends non-empty content to the central progress.txt and AGENTS.md with
# a "<ts> | LEARNING | <story_id>" prefix, then `git rm`s the delta files
# and folds everything into the merge commit via `git commit --amend
# --no-edit`. Skip rules:
#   • file does not exist        → silently skip (no work to do).
#   • file empty (0 bytes) or
#     contains only whitespace   → skip the central-file append; still
#                                   `git rm` the placeholder so AC1 holds
#                                   (no progress-*.txt left in main).
#
# The "same commit" requirement (story description + AC1) is enforced via
# `commit --amend --no-edit`: integration changes ride inside the merge
# commit instead of producing a separate trailing commit. `--allow-empty`
# is used so the amend never fails if every delta turned out to be empty
# (the rm-only path).
#
# Returns 0 on success or no-op; 1 only when the amend itself fails (very
# unlikely — would indicate the working tree was concurrently dirtied).
integrate_delta_files() {
    local orch_slot="$1"
    local story_id="$2"
    # Optional 3rd arg lets callers point at a non-default stash path; the
    # default path is what stash_worker_deltas writes (handle_finished_worker
    # at COMMIT time). Empty string disables stash hydration entirely (used
    # by legacy tests that pre-place deltas in orch WT directly).
    local stash_dir
    if [ "$#" -ge 3 ]; then
        stash_dir="$3"
    else
        stash_dir="$orch_slot/.ralph/delta-stash/$story_id"
    fi

    local progress_delta="progress-${story_id}.txt"
    local agents_delta="agents-delta-${story_id}.md"
    local progress_central="progress.txt"
    local agents_central="AGENTS.md"

    local progress_path="$orch_slot/$progress_delta"
    local agents_path="$orch_slot/$agents_delta"

    # Hydrate from stash (Plano B follow-up: worker no longer commits
    # delta files; they live in $stash_dir, captured at COMMIT time).
    # Backward compatibility: when stash_dir is empty or missing, fall
    # back to reading from orch WT (legacy tests rely on this — the
    # worker_commit helper stages deltas directly).
    if [ -n "$stash_dir" ] && [ -d "$stash_dir" ]; then
        if [ -f "$stash_dir/$progress_delta" ]; then
            cp -f "$stash_dir/$progress_delta" "$progress_path" 2>/dev/null || true
        fi
        if [ -f "$stash_dir/$agents_delta" ]; then
            cp -f "$stash_dir/$agents_delta" "$agents_path" 2>/dev/null || true
        fi
    fi

    local has_progress=0 has_agents=0
    [ -f "$progress_path" ] && has_progress=1
    [ -f "$agents_path"   ] && has_agents=1

    # Nothing to integrate — true no-op for stories that did not produce
    # delta files (covers all existing US-09 merge tests).
    if [ "$has_progress" = "0" ] && [ "$has_agents" = "0" ]; then
        return 0
    fi

    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")

    # Append progress delta (if non-whitespace) to central progress.txt.
    # Multi-line content collapses to single-line via `tr` to match the
    # existing "<ts> | <CAT> | <id> | <text>" format used elsewhere in
    # progress.txt.
    if [ "$has_progress" = "1" ] \
        && grep -q '[^[:space:]]' "$progress_path" 2>/dev/null; then
        local progress_text
        progress_text=$(tr '\n' ' ' < "$progress_path" | sed 's/  */ /g; s/ *$//')
        printf '%s | LEARNING | %s | %s\n' "$ts" "$story_id" "$progress_text" \
            >> "$orch_slot/$progress_central"
    fi

    # Append agents delta (if non-whitespace) to central AGENTS.md as a
    # Markdown section. Content is preserved multi-line because AGENTS.md
    # is structured prose, not log lines.
    if [ "$has_agents" = "1" ] \
        && grep -q '[^[:space:]]' "$agents_path" 2>/dev/null; then
        {
            printf '\n## %s | LEARNING | %s\n\n' "$ts" "$story_id"
            cat "$agents_path"
            printf '\n'
        } >> "$orch_slot/$agents_central"
    fi

    # Always remove the delta placeholders — even when empty — so AC1
    # (no progress-*.txt in main) holds for every story. With the new
    # contract, deltas are usually untracked (rm-from-WT only); the
    # `git rm --ignore-unmatch` line stays as a no-op for legacy callers
    # whose worker did stage them.
    git -C "$orch_slot" rm --ignore-unmatch -q -- \
        "$progress_delta" "$agents_delta" >/dev/null 2>&1 || true
    rm -f "$progress_path" "$agents_path" 2>/dev/null || true

    # Remove the consumed stash dir (and an empty parent) regardless of
    # whether content was integrated. Best-effort: rmdir is silent on
    # non-empty parents.
    if [ -n "$stash_dir" ] && [ -d "$stash_dir" ]; then
        rm -rf "$stash_dir" 2>/dev/null || true
        rmdir "$orch_slot/.ralph/delta-stash" 2>/dev/null || true
        rmdir "$orch_slot/.ralph" 2>/dev/null || true
    fi

    # Stage central files (new content) so amend folds them in alongside
    # the staged rm.
    git -C "$orch_slot" add -- "$progress_central" "$agents_central" \
        >/dev/null 2>&1 || true

    if ! git -C "$orch_slot" commit --amend --no-edit --allow-empty \
            >/dev/null 2>&1; then
        echo "INTEGRATE_DELTA_AMEND_FAILED: $story_id" >&2
        return 1
    fi
    return 0
}

# ─── merge_and_push_story (US-09 F8) ───────────────────────────────────────
# Args: orch_slot worker_ref story_id remote_name [other_story_id]
#   orch_slot       : path to the orchestrator's slot (where the merge runs)
#   worker_ref      : ref to merge from (worker slot path or remote+branch);
#                     anything `git fetch` accepts. Resulting commit lands
#                     under FETCH_HEAD.
#   story_id        : story id (used in the merge commit message + reasoning)
#   remote_name     : remote to push to (typically "origin"); empty → skip push
#   other_story_id  : optional other story id for REBASE_CONFLICT_AGAINST
#
# Behaviour:
#   1. Capture head_before_merge BEFORE the merge using `local x; x=$(...)`
#      separate-decl-then-assign so set -e propagates rev-parse failures.
#      (`local x=$(...)` would mask the rc via `local`'s success.)
#   2. git fetch worker_ref → FETCH_HEAD; git merge --no-ff FETCH_HEAD.
#   3. On merge conflict: abort, rebase the fetched commit onto current HEAD,
#      then reset to head_before_merge and merge --no-ff the rebased SHA so
#      the result is still a --no-ff merge commit. If the inner rebase fails,
#      reset --hard $head_before_merge and return REBASE_CONFLICT.
#   4. Push to remote. Push reject → fetch + rebase remote/main + retry push.
#      If that rebase fails, reset --hard $head_before_merge and return
#      UPSTREAM_DRIFT_CONFLICT.
#   5. Push fails with HTTP 403 in stderr → AUTH_FORBIDDEN + exit 7 (per
#      spec, exit not return — auth failures are fatal for the orchestrator).
#
# CRITICAL: $head_before_merge is captured in a local variable BEFORE merge,
# NOT via ORIG_HEAD. Intermediate `git rebase` resets ORIG_HEAD to the merge
# commit, so a `git reset --hard ORIG_HEAD` after a failed rebase would leave
# HEAD pointing at the merge commit (wrong) instead of the pre-merge state
# (right). See test_merge_and_push.sh AC F8f for the regression that walks
# both code paths and asserts the divergence empirically.
#
# CRITICAL #2: `git rebase HEAD FETCH_HEAD` (two-arg form) checks out
# FETCH_HEAD first → HEAD becomes DETACHED. `git reset --hard` preserves the
# detachment, and a follow-up `git push HEAD:main` updates origin/main but
# leaves local main untouched (next iteration sees stale main). After ANY
# `rebase HEAD FETCH_HEAD` (success OR failure path), we must explicitly
# `git checkout -q main` to reattach. `rebase --abort` does NOT help here
# because it restores HEAD to "FETCH_HEAD" (still detached, since that was
# the original ref the two-arg form checked out).
#
# Forbidden: ORIG_HEAD, `git reflog --since=<x> -- HEAD` (lint enforces).
merge_and_push_story() {
    local orch_slot="$1"
    local worker_ref="$2"
    local story_id="$3"
    local remote_name="${4:-}"
    local other_story_id="${5:-}"
    # US-11 F10: optional 6th arg lets callers fetch a SPECIFIC ref from
    # worker_ref (e.g. `refs/ralph/<story>` captured pre-slot-reuse). Empty
    # → preserves US-09 behavior of fetching worker's default HEAD.
    local worker_branch="${6:-}"

    # Separate declaration from assignment (US-09 set -e gotcha): combining
    # `local var=$(cmd)` would mask cmd's exit code with `local`'s success.
    local head_before_merge
    head_before_merge=$(git -C "$orch_slot" rev-parse HEAD)

    local fetch_rc=0
    if [ -n "$worker_branch" ]; then
        git -C "$orch_slot" fetch "$worker_ref" "$worker_branch" 2>/dev/null || fetch_rc=$?
    else
        git -C "$orch_slot" fetch "$worker_ref" 2>/dev/null || fetch_rc=$?
    fi
    if [ "$fetch_rc" -ne 0 ]; then
        echo "MERGE_FETCH_FAILED: $worker_ref${worker_branch:+ $worker_branch}" >&2
        return 1
    fi

    local merge_msg="merge $story_id"
    if git -C "$orch_slot" merge --no-ff -m "$merge_msg" FETCH_HEAD >/dev/null 2>&1; then
        :  # direct merge succeeded
    else
        # Conflict: abort the merge, rebase fetched commit onto current HEAD,
        # then reset and re-merge --no-ff the rebased commit.
        git -C "$orch_slot" merge --abort 2>/dev/null || true

        if git -C "$orch_slot" rebase HEAD FETCH_HEAD >/dev/null 2>&1; then
            local rebased_sha
            rebased_sha=$(git -C "$orch_slot" rev-parse HEAD)
            # Two-arg rebase detached HEAD onto FETCH_HEAD; reattach to main
            # before reset so subsequent push HEAD:main also moves local main.
            git -C "$orch_slot" checkout -q main >/dev/null 2>&1
            git -C "$orch_slot" reset --hard "$head_before_merge" >/dev/null 2>&1
            if git -C "$orch_slot" merge --no-ff -m "$merge_msg" "$rebased_sha" >/dev/null 2>&1; then
                :  # retry after rebase succeeded
            else
                git -C "$orch_slot" merge --abort 2>/dev/null || true
                git -C "$orch_slot" reset --hard "$head_before_merge" >/dev/null 2>&1
                if [ -n "$other_story_id" ]; then
                    echo "REBASE_CONFLICT_AGAINST:$other_story_id" >&2
                else
                    echo "REBASE_CONFLICT" >&2
                fi
                return 2
            fi
        else
            # rebase --abort leaves HEAD at FETCH_HEAD (detached); reattach
            # explicitly so the slot is usable for the next dispatch.
            git -C "$orch_slot" rebase --abort 2>/dev/null || true
            git -C "$orch_slot" checkout -q main >/dev/null 2>&1
            git -C "$orch_slot" reset --hard "$head_before_merge" >/dev/null 2>&1
            if [ -n "$other_story_id" ]; then
                echo "REBASE_CONFLICT_AGAINST:$other_story_id" >&2
            else
                echo "REBASE_CONFLICT" >&2
            fi
            return 2
        fi
    fi

    # US-10 F9: integrate the worker's progress-/agents-delta files into the
    # central progress.txt and AGENTS.md, then `git rm` the deltas. This is
    # folded into the merge commit via `commit --amend --no-edit`, so the
    # subsequent push carries one merge commit (no trailing integration
    # commit) and main never retains progress-*.txt placeholders.
    integrate_delta_files "$orch_slot" "$story_id"

    [ -z "$remote_name" ] && return 0

    local push_err push_rc
    push_err=$(git -C "$orch_slot" push "$remote_name" HEAD:main 2>&1) && push_rc=0 || push_rc=$?

    if [ "$push_rc" -eq 0 ]; then
        return 0
    fi

    case "$push_err" in
        *403*|*"forbidden"*|*"Forbidden"*)
            echo "AUTH_FORBIDDEN: $push_err" >&2
            exit 7
            ;;
    esac

    # Push reject: fetch upstream + rebase + retry.
    git -C "$orch_slot" fetch "$remote_name" 2>/dev/null || true
    if git -C "$orch_slot" rebase "${remote_name}/main" >/dev/null 2>&1; then
        push_err=$(git -C "$orch_slot" push "$remote_name" HEAD:main 2>&1) && push_rc=0 || push_rc=$?
        if [ "$push_rc" -eq 0 ]; then
            return 0
        fi
        case "$push_err" in
            *403*|*"forbidden"*|*"Forbidden"*)
                echo "AUTH_FORBIDDEN: $push_err" >&2
                exit 7
                ;;
        esac
        # Still rejected — fall through to upstream-drift handling.
    else
        git -C "$orch_slot" rebase --abort 2>/dev/null || true
    fi

    git -C "$orch_slot" reset --hard "$head_before_merge" >/dev/null 2>&1
    echo "UPSTREAM_DRIFT_CONFLICT" >&2
    return 3
}
