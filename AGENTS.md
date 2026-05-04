# AGENTS.md — Ralph Fase 2 Conventions & Gotchas

Discovered during implementation; consume on every iteration.

## Repository layout

- Canonical source for skills: `skills/<name>/` in this repo.
- Live runtime location: `~/.claude/skills/<name>/`.
- `sync.sh install` propagates repo → `~/.claude/`. Run after merging skill
  changes if the running loop must see them mid-flight.

## Tests

- TDD harness for `lib/dispatch.sh` lives in `skills/ralph-adversarial/tests/lib/test_dispatch.sh`.
- No `bats` installed; tests are plain bash with an inline assertion harness.
  Run: `bash skills/ralph-adversarial/tests/lib/test_dispatch.sh`.

## Fase 2 dispatch helpers — gotchas

- macOS default shell is bash 3.2 → no associative arrays (`declare -A`),
  no `mapfile`/`readarray`, no `$BASHPID`. All Fase 2 lib code must stay
  3.2-compatible. The PRECONDITION lint (US-01 AC10) enforces this.
- Slot phase tracking is **file-based** (`$slot/.slot-phase`) precisely
  because of the bash 3.2 constraint. Atomic write uses
  `printf > .slot-phase.tmp.$$.$RANDOM` then `mv -f`.
  - `$RANDOM` is added because bash 3.2 subshells inherit the parent's `$$`;
    without it, racing subshells from the same parent would collide on the
    tmpfile name even though their final `mv` would not corrupt the target.
  - `mv` on the same filesystem is atomic on POSIX → readers see either old
    or new contents, never partial.
- `mktemp` template MUST have exactly 8 X's and MUST NOT use `-t`
  (rev5b R28). The lint in `test_dispatch.sh` enforces both. Use the
  `mktemp_safe` helper instead of raw `mktemp` going forward.
- `mktemp_safe` reads its fallback path from `${MKTEMP_SAFE_FALLBACK:-/tmp}`.
  This is intentional: tests exercise the "TMPDIR + fallback both unwritable"
  branch by setting `TMPDIR=$ro_sandbox MKTEMP_SAFE_FALLBACK=$ro_sandbox`
  and asserting `rc=1` plus the `no writable tmpdir found` message — without
  needing root to chmod the real `/tmp`. Production callers leave the env
  var unset and get the `/tmp` default.
- `is_dispatchable` requires dependency `passes == true` (literal). `ESCALATED`
  counts as not-yet-passed and blocks downstream stories.
- Cycle detection (`detect_dependsOn_cycle`) uses iterative DFS over an edge
  list extracted by `jq` — no recursion in jq, no associative arrays.
- `parse_pool_from_pwd` regex: `^.*/checkouts/<repo>-<N>$`. Repo names may
  contain hyphens; only the trailing `-<digits>` is treated as the slot
  number.

## with_validated_slot contract

- `layer_a_validate` is a stub in lib/dispatch.sh (real impl lands in US-04).
- The validator runs in a subshell so `die`/`exit 1` is captured as a non-zero
  rc instead of killing the orchestrator. On failure: phase persisted as
  `layer_a_failed`, callback NOT invoked, function returns 1.
- Callers under `set -e` will see the wrapper's `return 1` propagate as a
  pipeline abort.

## Test harness conventions

- Each AC block is annotated with the AC it covers (greppable for ac_trace).
- Tests do NOT `set -e` so a single failure does not mask later failures.
- Race tests must `bash -c '...'` to fork real processes (bash 3.2 subshells
  share `$$`).

## validate-prd.sh (US-02) gotchas

- Lives next to `dispatch.sh` and sources it for `detect_dependsOn_cycle` /
  `mktemp_safe`. Keep both files in the same `lib/` dir.
- **Default mode is warn-only — must NEVER touch prd.json.** Tests assert
  this with `cmp` against a backup. Auto-recover is opt-in via
  `--auto-recover` and only rewrites when there is at least one
  ESCALATED-vs-dep-OK inconsistency to fix.
- Inconsistency trigger requires **all three**: `passes == "ESCALATED"`
  (string, not bool), `blocked_by` is a non-empty string, and the referenced
  dep has `passes == true` (literal `true`, not `"true"`). If the dep is
  still `passes:false` or `passes:"ESCALATED"`, no action — story stays
  ESCALATED (AC6).
- Schema check intentionally does NOT validate `priority` or `passes` —
  parity with the Fase 1 inline jq. `dependsOn` is optional; when present
  it must be an array of non-empty strings.
- `dependsOn` reference resolution: validator rejects unknown ids before
  cycle detection (so the cycle DFS only sees a closed graph).
- jq rewrite uses a single pass on a temp file then `mv` for atomicity —
  callers under `set -e` either see the full new file or the unchanged
  original. Never partial.

## extract-deps-from-plan.sh (US-02 AC1)

- Two-stage grep: stage 1 anchors on `depende d[aoe]s? +US-XX(...)`; stage 2
  pulls every `US-XX` out of the matched span. Sort -u for stable output.
- Recognises `,` and ` e ` as connectors between IDs; case-insensitive on the
  verb. Does NOT recognise `requer`, `precisa de`, etc. — only the literal
  Portuguese phrase the prd-convert markdown documents.
- Empty input → exit 0 with no output (lets prd-convert pipe arbitrary fatia
  text without an explicit empty-check).

## validate_worker_commits / orch_rebase (US-04) — gotchas

- 3-layer order: **A' (reflog) first**, then A (SHA short-circuit), then B
  (per-commit filename). A' must run *before* A's early-return so the zero-net
  case (commit + reset → HEAD unchanged, AC10) still gets caught.
- Reflog parsing uses `git reflog show --date=unix HEAD` and a POSIX-only
  awk filter (`match($0, /HEAD@\{[0-9]+\}/)` + RSTART/RLENGTH). Do NOT
  use the gawk three-arg `match(s, re, arr)` — macOS BSD awk lacks it.
- `git reflog show` requires `core.logAllRefUpdates=true` on the slot's
  repo; pre-flight check lands in US-05 AC6. The mk_repo helper here forces
  it on for safety.
- Layer B regex anchors the forbidden filenames at the path root:
  `^(progress\.txt|AGENTS\.md)$`. `progress-<id>.txt` and
  `agents-delta-<id>.md` (the contract delta files) MUST be allowed.
- `orch_rebase` is a thin wrapper that calls `assert_layer_a_done` first.
  The real rebase logic lands in US-09; for US-04 the wrapper just enforces
  the invariant. Direct invocation outside `with_validated_slot` dies with
  `INVARIANT VIOLATION` (AC9).
- AC6 enforcement compares `slot == "$ORCH"` only when `ORCH` is non-empty.
  Tests that exercise the negative path explicitly export `ORCH=""` to keep
  the guard quiet on same-slot self-checks.

## die() vs `return 1` (US-04 AC11) — convention

- `lib/dispatch.sh` ships a `die "msg"` helper (= `echo >&2; exit 1`).
- For invariant/precondition failures inside functions called via
  `$(func ...)` (command substitution): use `die`. `return 1` from a
  function inside `$()` does **not** terminate the subshell — execution
  continues past the call, defeating fail-fast.
- For functions called via `( func )` or as a statement (no `$()`),
  either works. The `with_validated_slot` wrapper uses `( layer_a_validate
  ... )` deliberately so both styles in `layer_a_validate` propagate.
- Test fixture in `test_validate_worker_commits.sh` (AC11) exercises both
  patterns side by side so the anti-pattern stays documented and any
  future helper that uses `return` inside a `$()` is caught immediately.

## Mocks (US-03 F3) — fake-claude / fake-codex

- Both live in `tests/mocks/` and are drop-in replacements activated by the
  orchestrator env vars `RALPH_AGENT_BIN` (primary) and `RALPH_REVIEWER_BIN`
  (reviewer). When set, ralph-adversarial.sh routes around the real
  `claude --print …` / `codex exec review …` calls and invokes the mock
  with the prompt as a single positional arg (no flag forwarding).
- `RALPH_AGENT_BIN`/`RALPH_REVIEWER_BIN` also short-circuit the
  `command -v claude|codex` pre-flight checks (`NEEDS_CLAUDE`/`NEEDS_CODEX`),
  so tests do not require the real CLIs to be installed.
- `fake-claude.sh` extracts `STORY_ID` from the prompt by `grep -oE '"id"\s*:\s*"[^"]+"'`
  on the JSON block ralph appends after `## Story atual`. `FAKE_STORY_ID`
  overrides for tests that pass a hand-crafted prompt.
- `FAKE_OUTCOME` matrix is one outcome per US-04/US-09 acceptance pattern:
  `commit`, `noop`, `hang`, `conflict-trivial`, `conflict-overlap`,
  `multi-commit-violation`, `amend-violation`, `commit-then-reset`,
  `git-reset-violation`. Unknown values exit 2.
- `git-reset-violation` requires the test repo to start with ≥ 2 commits so
  `HEAD~1` resolves; the `mk_repo N` helper in test_mocks.sh takes the count.
- `conflict-overlap` is *deterministic per FAKE_STORY_ID* — identical inputs
  produce identical line content, so two parallel workers running the same
  story id genuinely collide on the same row (US-09 F8b).
- `fake-codex.sh` supports `FAKE_VERDICT=MERGE|BLOCK|REQUEST_CHANGES|hang`.
  The `## Verdict: X` line is exactly the format `parse_verdict.sh` (the
  markdown branch, line 36) recognises.
- `FAKE_OUTCOME=hang-with-mcp` runs `bash -c 'sleep 999 & sleep 999 & wait'`.
  The two sleeps appear as `pgrep -P <bash-c-pid>` children — `pgrep -P` on
  the *script* PID returns only the bash-c PID (one child), so the AC6 test
  unwraps one level. `(cmd &)` would subshell-detach and orphan the children
  to PID 1; do not refactor.
- macOS portability: `setsid(1)` does NOT exist as a separate utility on
  Darwin, only as a syscall (exposed via `python3` os.setsid). The
  hang-with-mcp pattern works without any wrapper because the children
  inherit the invoking shell's process group, which is exactly what
  `kill_agent_pg` (orchestrator) targets.

## tests/lib/test_mocks.sh

- `mk_repo N` helper bootstraps an isolated git repo under TMPDIR with N
  empty `--allow-empty` base commits. Use N=2 for `git-reset-violation`
  and `commit-then-reset`.
- The AC1 e2e test exports `RALPH_HANG_TIMEOUT=15` so a stuck mock cannot
  blow the test budget; the mock itself completes in well under 1s.
- AC6 cleanup is best-effort: kill the bash-c grandchildren first (sleeps
  would otherwise outlive the parent shell), then the bash-c, then the
  mock script. Do not rely on `wait` to reap orphaned sleeps.

## --parallel bootstrap (US-05) — gotchas

- Arg parsing in `ralph-adversarial.sh` is a positional consumer with two
  recognized flags: `--parallel` and `--parallel=N`. Anything else flows
  through to `POSITIONAL` (so legacy `bash ralph-adversarial.sh 5` still
  sets `MAX_ITERATIONS=5`). Keep the loop bash 3.2 friendly: `POSITIONAL+=`
  on an indexed array is fine; do not switch to `mapfile`.
- Empty-array expansion: bash 3.2 expands `"${POSITIONAL[@]:-}"` to a single
  empty string, NOT to zero args — so `set -- "${POSITIONAL[@]:-}"` would
  silently inject `''` as `$1` and break `MAX_ITERATIONS=${1:-10}`. Branch on
  `${#POSITIONAL[@]}` instead (see ralph-adversarial.sh:24-28). Do NOT
  "simplify" the branch back to `:-`.
- Pool detection runs **before** the prereq block (jq, prd.json, claude/codex
  CLI checks). This lets AC1 (cwd outside pool) fail with the parallel-mode
  usage message even when the cwd has no `prd.json`. Don't reorder.
- `POOL_BASE="$(dirname "$PWD")"` works because `parse_pool_from_pwd` already
  validated that `$PWD` ends in `/checkouts/<repo>-<N>`. The dirname is
  therefore always `<...>/checkouts`. Do not switch to `~/Projects/checkouts`
  hardcoded — tests synthesize pools under `/tmp/.../checkouts`.
- Preflight gates (`preflight_slot`) test reflog setting + git ≥ 2.9 via two
  overrideable shims (`git_version_for_slot`, `git_reflog_setting_for_slot`)
  so unit tests can stub without touching PATH or installing fake binaries.
  Same pattern as `layer_a_validate` (US-04 AC11).
- `version_ge` strips non-numeric suffixes per component (`2.39.5-rc1` →
  `2.39.5`) and pads missing components to 0 (`2.9` ≡ `2.9.0`). Tests cover
  major-dominates-lexical (`1.99 < 2.0`) and Apple's `git --version` triple.
- `count_pool_slots` prefers the `slots=N` field in `<base>/.<repo>.pool`
  but falls back to `ls -d <base>/<repo>-[0-9]*` when the file is missing
  OR malformed (`slots=oops`). The fallback handles pools created before
  the metadata file existed and pools where the file was hand-edited.
- `run_serial`/`run_parallel` are functions wrapping the existing `while`
  loop. The dispatch is a single `if PARALLEL_MODE` at the bottom of the
  script. The loop's `continue`/`exit 0` semantics are preserved because
  `while` lives inside the function and `exit 0` exits the whole script.
- E2E tests in `tests/lib/test_bootstrap.sh` use a `mk_pool` helper that
  builds the full `/checkouts/<repo>-N` layout under a `mktemp -d` base.
  The orchestrator slot gets a minimal "all stories already passing"
  `prd.json` so the serial loop returns "TODAS COMPLETAS" immediately —
  proving `run_parallel` → `run_serial` without needing real claude/codex.
- The bootstrap test wires `RALPH_AGENT_BIN` and `RALPH_REVIEWER_BIN` to
  the existing fakes from US-03 so the prereq block's `command -v claude`
  / `command -v codex` checks are skipped (`NEEDS_*` flags both false).

## run_parallel dispatcher (US-06) — gotchas

- `run_parallel` is now real: each tick runs `poll_workers_tick` →
  `dispatch_workers_tick` → `sleep $RALPH_POLL_INTERVAL`. State lives in
  `workers.txt` (single line per worker, format `slot:pid:story_id:started_at`).
  Tests can override the path via `RALPH_WORKERS_FILE` to inspect
  mid-run snapshots.
- Mutations to `workers.txt` always go via `mktemp_safe file` + `mv`. The
  orchestrator is the only writer; workers do not touch the file.
- `dispatch_one` uses `( cd "$slot" && exec "${SETSID_CMD[@]}" agent ... ) &`.
  The `exec` is required so `$!` is the agent (PG leader), not the wrapping
  subshell — otherwise `kill_agent_pg` cannot find the right PGID and
  `kill -- -$pgid` becomes a no-op or, worse, kills the wrong group.
- Slate cleanup before dispatch: `slate_cleanup_for_retry` runs
  `git rm --ignore-unmatch -q -- progress-<id>.txt agents-delta-<id>.md`
  AND a defensive `rm -f` for any untracked leftover. Both are needed —
  `git rm` alone leaves untracked copies in place; `rm -f` alone leaves
  the index dirty if the previous attempt staged-and-committed the file.
- **Backgrounded bash + SIGINT trap is broken by design.** A non-interactive
  bash launched with `&` inherits `SIGINT` set to `SIG_IGN` from the parent;
  the script's `trap '...' INT` cannot override `SIG_IGN`. So in tests we
  send `SIGTERM` (the trap covers both) instead of `SIGINT`. In production
  the user runs the orchestrator in the foreground where Ctrl-C delivers
  SIGINT normally and the trap fires. Do not "fix" this by sending SIGINT
  in tests — it is silently dropped, the orchestrator keeps running, and
  the test hangs at `wait $ORCH_PID` until something else kills the script.
- Trap order: `EXIT` runs `parallel_cleanup`; `INT`/`TERM` log a `TRAP_*`
  event then run `parallel_cleanup` then `exit 130`/`143`. The cleanup
  itself is idempotent via `PARALLEL_CLEANUP_DONE` so the EXIT pass after
  the explicit signal handler is a no-op.
- Loop exit conditions: pending=0 (all merged or escalated) OR active=0
  AND nothing dispatchable (stalemate). `RALPH_MAX_TICKS` is a 1000-tick
  safety net; not exercised in normal runs.
- `next_dispatchable_excluding` is the parallel-mode replacement for the
  serial path's "pick the lowest-priority pending story" pattern. Excluded
  IDs come from `workers.txt` so the same story never gets dispatched
  twice in parallel.

## Mocks (US-06 follow-ups)

- `fake-claude.sh` accepts `FAKE_OUTCOME_MAP` and `FAKE_DELAY_MAP` —
  files mapping `STORY_ID:VALUE`. When set and the resolved STORY_ID has
  a row, those values override `FAKE_OUTCOME`/`FAKE_DELAY`. This lets a
  single orchestrator run exercise multiple outcomes (3 commit + 1 noop +
  1 hang + 1 conflict-trivial) with one mock binary.
- `delta-commit` is the contract-compliant outcome: writes to
  `progress-<id>.txt` and `agents-delta-<id>.md` only and commits them.
  Used to seed the slate-cleanup retry scenario (US-06 AC6 unit setup).

## Review queue + drainer (US-07) — gotchas

- State files: `review-queue.txt` (FIFO of `slot:story_id:committed_at`) and
  `review-state.txt` (single line `pid:slot:story_id:started_at:logfile`).
  Tests can override paths via `RALPH_REVIEW_QUEUE_FILE` and
  `RALPH_REVIEW_STATE_FILE` to inspect mid-run snapshots.
- Tick order in `run_parallel` is fixed: `poll_workers_tick` →
  `poll_review_tick` → `dispatch_workers_tick`. The worker→review handoff
  happens in the same tick (commit detected → enqueue → drainer picks up
  on next iteration), so latency is bounded by `RALPH_POLL_INTERVAL`.
- `handle_finished_worker` no longer runs the review inline; it just logs
  `COMMIT` + `REVIEW_ENQUEUE`. The drainer is the single place that spawns
  reviews — that's what enforces serialization (single-active invariant).
- Slot freeing (AC3): `poll_workers_tick` rebuilds workers.txt without
  the finished row before calling `handle_finished_worker`, so the slot
  is already gone from workers.txt when the review enqueues. The
  dispatcher treats the slot as free even while the review runs in it
  — `collect_in_flight` includes review-state's story id (so the same
  story isn't dispatched twice), but does NOT include the slot id
  (so slot reuse is allowed; AC8 porcelain check guards against codex
  trampling on a concurrent worker's WT).
- Hang detection (AC4): `RALPH_REVIEW_TIMEOUT` defaults to 600s. Tests
  override to 5–10s. On timeout, `kill_agent_pg` SIGTERMs the entire
  PG, then SIGKILL after 2s; finalize then logs `REVIEW_BLOCK reason=REVIEW_HANG`.
- PG hang propagation (AC5): the PG kill is what cleans up codex's MCP
  children. Cannot use `pgrep -f 'sleep 999'` system-wide as the only
  liveness signal in tests — it picks up all sleep-999 processes from
  any prior or concurrent test run. Use `pgrep -P $REVIEW_PID` for a
  scoped check, OR drain with `pkill -f 'sleep 999'` between AC blocks.
- `collect_in_flight` (story-id union) covers the dependsOn block (AC6):
  while A is in queue/state, A.passes is still false in prd.json, so
  any B with `dependsOn:[A]` fails `is_dispatchable`. No extra logic
  needed — the existing dispatchability check inherits the property.
- AC7 race-safe prd.json writes: `finalize_review` and `handle_failed_worker`
  both write through `mktemp_safe file ralph-prd` + `mv`. Even when
  poll_workers and poll_review fire updates in the same tick, the writes
  are sequential within a single bash process — but the tmp+mv pattern
  defends against partial-write if a future change parallelises the
  ticks (e.g., putting them in subshells).
- AC8 dirty-worktree: `launch_review` snapshots `git status --porcelain`
  before exec; `finalize_review` re-snapshots and flips the verdict to
  BLOCK with `REVIEW_DIRTY_WORKTREE` if they differ — UNLESS the reason
  is `REVIEW_HANG` (a killed review may legitimately leave half-written
  artifacts that we don't want to relabel). Test mocks of dirty-worktree
  must produce a UNIQUE filename per invocation (`$$` suffix); a fixed
  filename causes BEFORE_iter2 == AFTER_iter2 (stray persisted from
  iter1, both snapshots list it once) and the violation goes undetected
  on retry, masking the test.

## Mocks (US-07) — fake-codex follow-ups

- New env vars (REVIEW-prefixed to avoid clashing with fake-claude when
  the orchestrator exports both in the same shell scope):
  `FAKE_REVIEW_OUTCOME`, `FAKE_REVIEW_DELAY`, `FAKE_REVIEW_DELAY_MAP`.
  Legacy `FAKE_OUTCOME`/`FAKE_DELAY` still work as fallback (US-03
  test_mocks.sh:246 calls fake-codex.sh standalone with FAKE_OUTCOME=hang-with-mcp;
  that path stays green).
- `FAKE_VERDICT_MAP` (file with STORY_ID:VERDICT lines) lets a single
  orchestrator run alternate MERGE/BLOCK/REQUEST_CHANGES across reviews
  (AC1). The story id is extracted from the prompt (`grep -oE 'US-...'`).
- `FAKE_REVIEW_OUTCOME=dirty-worktree` writes a unique-per-invocation
  stray file (`.ralph-codex-stray.$$`) in the cwd then prints MERGE.
  Unique filename is required; see "AC8" gotcha above.
- DO NOT set `FAKE_OUTCOME=hang-with-mcp` or `FAKE_DELAY_MAP=...` in a
  test that also exports `RALPH_AGENT_BIN=fake-claude.sh` — fake-claude
  reads the same env names and will either error (`unknown FAKE_OUTCOME`)
  or hang on its own. Always use the `FAKE_REVIEW_*` variants when the
  orchestrator is running both mocks in one process.

## Fase 1 exit-code catalog + set-e sentinel (US-08) — gotchas

- **Decisão #13 / rev5b R25:** `set -euo pipefail` é aplicado SOMENTE dentro
  do corpo de `run_parallel()`, nunca como diretiva global no topo do script.
  `run_serial` é o legado da Fase 1 e contém dezenas de comandos cujo exit
  non-zero é semanticamente válido (`kill -0`, `grep` no-match em pipeline,
  `var=$(git log)` em repo sem HEAD, etc.). Aplicar `set -e` global quebra
  a Fase 1 inteira sem benefício.
- O catálogo formal vive em `tests/fase1-exit-codes.md`. Toda edição futura
  do script que toque `run_parallel` deve consultá-lo: as linhas marcadas
  classe (b) e (c) que são chamadas a partir de `run_parallel` (transitivamente
  via helpers) PRECISAM ser refatoradas antes de `set -e` rodar nelas. A
  linha 122 (`pgid=$(ps … | tr …)` em `kill_agent_pg`), 353 (`count=$(grep …
  | tail | cut)` em `get_retry_count`) e 419 (`mktemp -t` direto) são as
  três principais que F8 vai mexer.
- Sentinela: `tests/lib/test_set_e_sentinel.sh` (21 assertions) prova que
  patchar `set -euo pipefail` como 1ª linha de `run_parallel()` não toca
  o caminho serial. Funciona porque (a) o patch é injetado in-place via
  awk anchored em `^run_parallel\(\) \{$`, (b) a cópia patchada vive ao
  lado do original (`$SKILL_DIR/.ralph-adversarial.sentinel.$$.sh`) para
  que `SCRIPT_DIR=$(cd $(dirname $BASH_SOURCE) && pwd)` resolva a `lib/`,
  parse-verdict.sh, IMPL_PROMPT.md e CODE_REVIEW.md corretamente — uma
  cópia em `/tmp` falharia em todos os `source` do bootstrap.
- Anti-padrão crítico para F8: `local var=$(cmd)`. O exit code de `cmd`
  é mascarado pelo sucesso de `local`, então `set -e` não dispara nem
  mesmo quando `cmd` falha. Toda captura nova em `run_parallel` deve usar
  `local var; var=$(cmd)` (declaração separada de atribuição) para que
  `set -e` veja o exit real. Esse padrão já está documentado em US-09 AC
  "declaração separada"; o catálogo F8h é a fundação que justifica.
- A sentinela NÃO valida que o caminho parallel sobrevive `set -e` —
  isso é responsabilidade explícita de US-09 / F8 quando ele aplicar a
  diretiva e refatorar as capturas (b)/(c). F8h só prova que o serial
  permanece intocado, removendo o risco "F8 quebra Fase 1" do escopo.

## merge_and_push_story (US-09 F8) — gotchas

- `set -euo pipefail` is the **first line of `run_parallel()` body** (line
  immediately after `{`). It is NOT global — the existing `set -e` on line
  6 of ralph-adversarial.sh stays as-is, since `run_serial` cannot
  tolerate `-u`/`pipefail` (catalog: `tests/fase1-exit-codes.md`). The
  sentinel test (`test_set_e_sentinel.sh`) is now idempotent: re-injecting
  via awk is a no-op when the directive is already present.
- `merge_and_push_story` lives in `lib/dispatch.sh` and is the **only**
  function allowed to use `head_before_merge`. The lint check2 enforces
  the whitelist at function-body granularity (awk tracks the enclosing
  `name() {…}` block; comments are skipped).
- **Why `head_before_merge` (local var), not `ORIG_HEAD`:** `git rebase`
  resets `ORIG_HEAD` to the *start* of the rebase (= the merge commit) before
  it can fail. So after a failed rebase + `--abort`, `ORIG_HEAD` points at
  the merge commit, not the pre-merge HEAD. A `git reset --hard ORIG_HEAD`
  in this state leaves HEAD on the "merge X" commit (wrong). The captured
  local variable is unaffected by intermediate ops. AC F8f locks this in
  with a regression test that runs both code paths and asserts divergence.
- **Separate declaration from assignment** is a hard rule for any new
  capture in `run_parallel`'s reachable code: `local var; var=$(cmd)` —
  NOT `local var=$(cmd)`. The latter masks `cmd`'s exit code with `local`'s
  success, defeating `set -e`. Catalog ref: `tests/fase1-exit-codes.md`
  rev5b R25.
- Push 403 → `exit 7` (NOT `return`). Auth failures are fatal for the
  orchestrator; the spec is explicit. Detection: stderr contains "403" or
  "forbidden" (case-insensitive). Test uses a `pre-receive` hook in the
  bare origin that prints `remote: 403 Forbidden` and exits non-zero.
- Default `git rebase` flattens merge commits. After a successful upstream
  rebase, the "merge US-X" commit message disappears — the worker's
  original commit is replayed as a flat patch. Tests verify the *content*
  lands in origin (work.txt:N) rather than asserting the merge commit
  message is preserved. `--rebase-merges` would preserve it but requires
  git ≥ 2.18; our preflight only requires 2.9.
- The merge function takes 5 args: `orch_slot worker_ref story_id
  remote_name [other_story_id]`. `worker_ref` is anything `git fetch`
  accepts (path or remote+branch). `other_story_id` is for the
  `REBASE_CONFLICT_AGAINST:<id>` reason string (omit → bare
  `REBASE_CONFLICT`).
- **`git rebase HEAD FETCH_HEAD` detaches HEAD.** Two-arg rebase
  (`rebase <upstream> <branch>`) checks out `<branch>` first, so HEAD
  becomes detached on the rebased commit. `git reset --hard $sha`
  preserves detachment. The post-rebase `git push HEAD:main` then
  updates origin/main but leaves the **local** `main` ref pointing at
  the pre-merge commit — the next iteration sees a stale local main.
  Mitigation: `git checkout -q main` after the rebase (success path)
  AND after `rebase --abort` (failure path), since `--abort` from a
  two-arg rebase leaves HEAD at `FETCH_HEAD`, not at the original
  branch. Regression: `test_merge_and_push.sh` AC F8a-rebase /
  F8a-rebase-fail use a PATH-shimmed `git` wrapper that fails the
  first `merge --no-ff … FETCH_HEAD` to force the rebase path; with
  disjoint-line workers (F8a setup) the direct merge succeeds and
  the bug is invisible without the shim.

## Lint expansion (US-09 AC F8g) — `tests/lib/lint-f8.sh`

- 5 checks, all return 0 violations on clean code:
  1. uppercase `HEAD_BEFORE_MERGE` (must stay lowercase; the var is local).
  2. `head_before_merge` outside `merge_and_push_story` body in dispatch.sh
     OR anywhere in ralph-adversarial.sh (whitelist enforcement).
  3. `git reflog --since=…` filtering on HEAD (broken — use
     `--date=unix` + epoch range; US-04 Camada A').
  4. `mktemp -t prefix` direct call (use `mktemp_safe`).
  5. mktemp template with fewer than 8 X's (rev5b R28).
- Comments (lines starting with `#`) are skipped in checks 2, 3, 4, 5.
  Check 1 is case-sensitive AND independent of comments — the uppercase
  form is forbidden everywhere because it has no legitimate use.
- Mutation tests live in `test_lint_f8.sh`. Each mutation copies the real
  files to a tmpdir, appends a single violation, and runs the lint via
  `LINT_F8_TARGETS=…` env var (so the lint targets the patched copies).
- BSD awk lacks `\<`/`\>` word boundaries — check2's awk uses explicit
  `(^|[^a-zA-Z0-9_])head_before_merge([^a-zA-Z0-9_]|$)` instead. Same
  portability pattern used in `validate_worker_commits` reflog parsing.
- The lint runner uses **process substitution** `< <(...)` rather than
  `|` to keep the `while read` loop in the parent shell so the
  `VIOLATIONS` counter increments stick. Pipe → subshell → counter lost
  is a bash 3.2 footgun documented elsewhere in this file.

## set -euo pipefail in run_parallel — refactors required

- `kill_agent_pg` line 124: `pgid=$(ps … | tr …)` was unsafe under
  pipefail because ps exits non-zero when the pid already died. Fix:
  trailing `|| true` on the pipeline. Comment cites
  `tests/fase1-exit-codes.md` line 122 class (b).
- `get_retry_count` line 359: `count=$(grep … | tail | cut)` was unsafe
  under pipefail because `grep` no-match exits 1. Fix: trailing `|| true`
  on the pipeline. Comment cites the same catalog line 353.
- `RETRY_FILE` (line 351) and `LOGFILE` (line 427) switched from
  `mktemp -t prefix.XXXXXX` to `mktemp_safe file <label>` — primarily
  for the lint check4/check5, secondarily because the catalog flagged
  them as class (c) candidates for F8 refactor.

## integrate_delta_files (US-10 F9) — gotchas

- **`commit --amend --no-edit --allow-empty` is mandatory, not paranoia.**
  When all delta files are 0-byte (AC4) the central files don't change,
  so the staged index delta after `git rm` is non-empty (rm IS a
  change), but `--allow-empty` is still cheap insurance for the future
  case where someone calls `integrate_delta_files` on a slot where the
  worker never produced ANY delta and the helper short-circuits before
  the rm — at which point amend with no index change requires the flag.
- **Single-line collapse for progress.txt entries.** Existing
  progress.txt rows are one line each (`<ts> | LEARNING | <id> |
  <text>`); the integrator collapses multi-line worker deltas via
  `tr '\n' ' ' | sed 's/  */ /g'` so the central log stays greppable.
  Workers that need structured prose write it into agents-delta-<id>.md
  (appended verbatim under a Markdown section header) instead of
  progress-<id>.txt.
- **AC4 skip rule uses `grep -q '[^[:space:]]'`, not `[ -s file ]`.**
  `[ -s ]` only catches 0-byte files; a worker that emits a lone `\n`
  or `   \n` would still trip `[ -s ]`. The grep covers 0-byte and
  whitespace-only in one predicate. Fixture `printf '\n   \n\t\n' >
  delta` enforces this in `test_integrate_delta.sh` AC4b.
- **`git rm --ignore-unmatch` AND `rm -f`.** Same defense-in-depth as
  `slate_cleanup_for_retry` (US-06). `git rm` only touches the index;
  an untracked stray would survive into the next iteration. In US-10
  the file is always tracked (the merge brought it in), but the
  `rm -f` keeps the helper symmetric with US-06.
- **Integration runs AFTER merge, BEFORE push.** The wiring in
  `merge_and_push_story` puts the call after the if/else merge block
  and before `[ -z "$remote_name" ] && return 0`. This covers BOTH
  merge paths: (a) direct `git merge --no-ff FETCH_HEAD` success and
  (b) the conflict-rebase path that re-merges `$rebased_sha`. The
  upstream-rebase-after-push-reject path then flattens the merge
  commit, but the integration changes ride inside its diff, so the
  rebased flat commit still carries the central-file mutations.
- **Same commit ≡ amend, not separate trailing commit.** Story spec:
  "git rm dos arquivos delta no mesmo commit". `commit --amend` keeps
  the merge commit's parents (preserving merge topology) while folding
  the rm + central-file appends into it. A separate trailing commit
  would double the commit count per story and force AC1 assertions to
  look beyond HEAD~1.
- **`git add -- progress.txt AGENTS.md` swallows errors with
  `|| true`.** If the central files don't exist yet (first-ever
  integration in a fresh repo), `git add` fails and the helper would
  abort under `set -e` (the caller `merge_and_push_story` runs under
  `set -euo pipefail` in run_parallel). The helper is best-effort on
  staging; the `commit --amend` itself is the only failure-bearing
  step that propagates.

## smoke.sh + per-story refs/ralph capture (US-11 F10) — gotchas

- **Slot reuse contamination is the bug F10 was built to expose.** With
  `RALPH_PARALLEL_N=2` and 3 stories on a 3-slot pool, the dispatcher
  re-uses a freed slot for the next pending story before the prior story's
  review finishes. The reused slot's HEAD then carries BOTH commits
  (story-N + story-N+2 stacked on main). A naive `git fetch <slot_path>`
  in `merge_and_push_story` would pull both into orch's main while
  `integrate_delta_files` only cleans the current story's deltas → AC4
  strays. Mitigation in `handle_finished_worker`:
  `git -C $orch_slot fetch $slot_path "+HEAD:refs/ralph/$story_id"`
  immediately after COMMIT, capturing the worker's exact SHA into orch's
  local refs BEFORE the slot can be reused. `finalize_review` then prefers
  this captured ref via `merge_and_push_story`'s new 6th arg
  (`worker_branch`). The ref is deleted post-merge (AC3 "branches
  efêmeras ralph/<story> deletadas após merge").
- **`merge_and_push_story` 6th arg `worker_branch` is opt-in.** When set,
  `git fetch $worker_ref $worker_branch` writes that specific refspec to
  FETCH_HEAD; when empty, behaviour is identical to US-09 (fetch worker's
  default HEAD). All existing `test_merge_and_push.sh` callers use ≤5 args
  and stay on the legacy path. Production / smoke pass the 6th arg with
  `refs/ralph/$story_id`.
- **`finalize_review` MERGE wiring is gated by `origin` remote presence.**
  `git -C $orch_slot remote get-url origin` succeeds → call
  `merge_and_push_story` (production / smoke). Fails → fall back to the
  pre-US-11 prd.json-only flip (preserves US-06/US-07 mk_pool tests which
  init each slot independently with no shared origin → would error
  "refusing to merge unrelated histories" if merge ran unconditionally).
  This is auto-detection, not an env flag — production setups via
  /checkout-init always have origin and always merge; legacy isolated
  test pools always skip and stay on the flip path.
- **`cleanup_smoke` whitelist regex is the safety net for `rm -rf $SMOKE`.**
  `^(/tmp/ralph-smoke\.|/private/var/folders/[^/]+/[^/]+/T/ralph-smoke\.|/var/folders/[^/]+/[^/]+/T/ralph-smoke\.)`
  covers Linux `/tmp/` and macOS `TMPDIR` under `/var/folders/<a>/<b>/T/`
  (also surfaced as `/private/var/folders/...`). Three rejection paths
  exit 8: SMOKE='/' (root), SMOKE='/tmp/something-else' (wrong prefix),
  any other non-matching path. SMOKE='' is a silent no-op (return 0,
  not exit) so the trap fires harmlessly when `mktemp_safe` failed
  before SMOKE was assigned. Tests in `test_smoke.sh` AC8a/b/c lock all
  three branches.
- **AC9 trap test sends SIGTERM, not SIGINT.** Same gotcha as US-06:
  bash backgrounded inherits SIGINT=SIG_IGN. The smoke's trap covers
  both INT/TERM with the SAME handler body, so SIGTERM exercises the
  same cleanup path and leaves exit code 143. The test's subshell uses
  `exec bash $SMOKE_SCRIPT` so `$!` is the smoke PID directly — without
  `exec`, `$!` is the wrapping subshell and SIGTERM kills only the
  wrapper, leaving the orphaned smoke + sandbox behind (silent failure
  observed during initial AC9 implementation).
- **`smoke.sh` is dual-mode (CLI + sourceable).** The tail guard
  `if [ "${BASH_SOURCE[0]}" = "${0}" ]; then run_smoke "$@"; fi` lets
  tests `. smoke.sh` to load `cleanup_smoke` / `provision_sandbox`
  WITHOUT executing `run_smoke`. AC8 tests rely on this — sourcing the
  script and invoking only `cleanup_smoke` in a subshell so its
  `exit 8` is captured as a non-zero rc by the test harness.
- **AC10 SMOKE_VIOLATIONS line is observational, not pass/fail.** The
  count of stray `progress-*.txt` / `agents-delta-*.md` files in the
  orch slot after smoke completes is data for human review (validates
  the SUPOSIÇÕES rev5 about parallel claude / single-instance Codex /
  delta-file contract). With contract-compliant mocks (delta-commit) +
  per-story ref capture wired, expected value is 0; non-zero with real
  binaries would denote a worker contract violation worth investigating.
- **`SMOKE_VIOLATIONS` is the bottleneck for ALL e2e smoke assertions.**
  The single line emitted at the end of `run_smoke` carries
  `delta_strays=N stray_refs=N passes=K/T rc=N`. Tests assert against
  these substrings (AC4 `delta_strays=0`, AC3 `stray_refs=0`, AC5
  `passes=3/3`) instead of trying to read the sandbox post-cleanup
  (impossible — `trap EXIT` already nuked it). When adding a new
  observation, append a `key=value` token to the same line so existing
  asserts keep matching. NEVER reformat the line as multi-line or
  quote-wrap values — `assert_contains` is substring-based.
- **`ac_trace` lines must point to ASSERTION lines, not section headers
  or comment blocks.** US-11 review caught `ac_trace test_smoke.sh:213-216`
  pointing at the e2e section comment instead of the actual `assert_*`
  call (which lived in a different range). Reviewer flagged it as
  partial coverage. Discipline: when writing `ac_trace`, jump to the
  exact `assert_eq` / `assert_contains` line that exercises the AC, not
  the comment that documents the section.

## Test harness — count_lines vs grep -c (US-06 follow-up)

- `grep -c PATTERN file` exits 1 when there are zero matches but still
  prints `0`. Combined with `|| echo 0`, the captured value becomes the
  two-line string `"0\n0"` — which `[ "$n" -ge 2 ]` rejects with
  "integer expression expected", and `[ -ge ]` then evaluates false in a
  way that LOOKS like the loop's wait condition is never reached.
  Fix: use `grep PATTERN file | wc -l | tr -d ' '` (always one integer)
  via the `count_lines` helper. Documented because this same trap
  surfaced twice during US-06 debugging.
