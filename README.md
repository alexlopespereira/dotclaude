# dotclaude

![tests](https://github.com/alexlopespereira/dotclaude/actions/workflows/tests.yml/badge.svg)

Global commands, skills and protocols for [Claude Code](https://claude.ai/code) that turn your AI assistant into a disciplined engineering partner — one that plans before coding, attacks its own ideas, and never ships unchallenged assumptions.

## Document Hierarchy & Language Convention

Five root documents, in descending order of authority — when two disagree, the higher one wins:

- **`CLAUDE.md`** — *normative*. The protocol Claude must follow (principles + available skills); overrides default model behavior.
- **`README.md`** — *the guide*. Human-facing overview of every command, skill, and the rationale behind them (this file).
- **`WORKFLOW.md`** — *tactical map*. The condensed how-to for the multi-agent flow.
- **`AGENTS.md`** — *implementation notes*. Patterns and gotchas discovered while building the harness.
- **`CONTEXT.md`** — *glossary*. Domain terms and operating model, kept by the planning skills per [ADR 0003](docs/adr/0003-planning-skills-write-domain-docs.md).

**Language rule (D6):** command and skill *names* are English `kebab-case` (stable identifiers across the harness); the *body* and frontmatter *descriptions* are free Brazilian Portuguese.

## The Problem

LLMs are confident by default. They produce plausible-sounding plans, skip over assumptions, and rarely question their own reasoning. When you use an AI coding assistant without structure, you get fast output — but not necessarily *good* output. Bugs hide behind fluent explanations. Architectural flaws get buried under confident prose.

**dotclaude** fixes this by embedding three proven reasoning disciplines directly into your Claude Code workflow:

## The Three Pillars

### 1. ReAct — Reasoning + Acting

Instead of jumping straight to a solution, Claude follows a strict **Thought → Action → Observation** loop for every non-trivial decision:

```
Thought #1: I need to understand how auth tokens are stored before proposing a migration.
Action #1:  Read src/auth/token-store.ts
Observation #1: Tokens are stored in localStorage with no expiry. The refresh logic is in a separate module.
```

This cycle repeats until Claude has enough evidence to make a grounded recommendation — or explicitly declares that the information is insufficient. No more "let me just assume X and move on."

**UI work gets a specific corollary:** when a task changes the user interface (layout, styling, copy, interaction), the plan must cite elements *actually observed* in the current state — not imagined ones. Preferred tool is Playwright (screenshot + DOM snapshot) when a dev server exists; acceptable fallbacks are user-provided screenshots, `curl`/fetch of the rendered HTML, static markup/template inspection, or a detailed description from the user. A UI plan with zero observation of the current state is incomplete by policy.

> **Why it matters:** [Yao et al. (2023)](https://arxiv.org/abs/2210.03629) showed that ReAct reduces hallucination and error propagation in LLM reasoning by forcing the model to interleave reasoning with real-world observations rather than chain-of-thought in a vacuum.

### 2. The Feynman Method — Intellectual Honesty

Richard Feynman's core insight was simple: **if you can't explain the mechanism in plain language, you don't actually understand it.** dotclaude enforces this in two ways:

**Epistemic markers** — every technical claim must be classified:

| Marker | Meaning |
|--------|---------|
| `[FACT]` | Verified or verifiable right now (e.g., "The API returns 404" — after testing) |
| `[INFERENCE]` | Logical conclusion from facts, but could be wrong |
| `[ASSUMPTION]` | Adopted without verification — **must** be validated before implementation |

**The Feynman Test** — if Claude names a pattern without explaining its mechanism, it's a violation:

- **Fail:** "We should use the Strategy pattern here."
- **Pass:** "We'll extract the calculation into a separate interface so we can swap implementations at runtime without changing the consumer. This works because the caller depends on the abstraction, not the concrete implementation."

> **Why it matters:** Most LLM planning failures aren't wrong answers — they're unexamined assumptions. Feynman markers make uncertainty visible instead of hiding it behind confident language.

### 3. Adversarial Review — Red Team Your Own Plans

Every plan produced by the Planner Agent gets attacked by an Adversary Agent before any production code is written. The adversary's job is to **find flaws, not confirm the plan:**

```
┌─────────────────┐        ┌─────────────────┐
│  PLANNER AGENT  │───────▶│ ADVERSARY AGENT  │
│  (Claude Code)  │        │  (Red Team)      │
│                 │◀───────│                  │
│  Produces plan  │ review │  Attacks plan    │
│  with ReAct +   │        │  Refutes assump. │
│  Feynman markers│        │  Tests Feynman   │
└─────────────────┘        └─────────────────┘
         │                          │
         └──── Max 3 cycles ────────┘
                     │
              Human has final say
```

The adversary specifically:
- Tries to **refute** every `[ASSUMPTION]`
- Finds **scenarios where the plan fails**
- Catches **Feynman violations** (naming without explaining)
- Asks **questions the planner should have asked**
- Gives a verdict: **APPROVED**, **APPROVED WITH CAVEATS**, or **REJECTED**

The full cycle (`/full-cycle`) runs both agents in sequence. For external validation, the plan can also be reviewed by OpenAI Codex as an independent adversary — a different model from a different provider, eliminating correlated bias.

> **Why it matters:** Self-review doesn't work — the same model that produced a flawed plan will approve it. Adversarial review forces genuine challenge. Cross-provider review (Claude vs. Codex) eliminates the shared blind spots that same-model review preserves.

### Bonus: Adversarial Deep Research (3 Providers)

For research tasks that demand high reliability, `/adversarial-research` orchestrates three independent AI providers in an adversarial pipeline:

```
   TOPIC
     │
     ▼
  GEMINI DEEP RESEARCH ──── Elaborates (80-160 web searches)
     │
     ▼
  PERPLEXITY SONAR DR ───── Fact-checks claims, finds counter-evidence
     │
     ▼
  OPENAI + WEB SEARCH ───── Reviews logic, methodology, and bias
     │
     ▼
  All three disagree? ──── Gemini corrects → reviewers re-check (max 3 cycles)
     │
     ▼
  SYNTHESIS with confidence map
```

Each provider has a structural advantage at its role: Gemini excels at broad research, Perplexity at citation verification, and OpenAI at logical reasoning. Using three different providers prevents correlated hallucination.

### Bonus: Ralph Adversarial Implementation Loop

Once a plan is approved by `/full-cycle`, the `/ralph-adversarial` loop carries it to production code without sacrificing rigor. It's the [Ralph pattern](https://ghuntley.com/ralph/) — one story per iteration with a fresh context window — extended with **cross-agent code review**: Claude Code implements, Codex reviews.

```
  APPROVED PLAN (.claude/plans/*.md)
          │
          ▼
   /prd-convert ─── Slices the plan into user stories with testable AC
          │
          ▼
    prd.json (root of repo)
          │
          ▼
   /ralph-adversarial ─── bash loop: one story per iteration
          │
          ▼
    ┌──────────────────────────────────┐
    │ Fresh Claude Code context        │
    │   reads prd.json + progress.txt  │
    │   implements 1 story             │
    │   runs checks + commits ac_trace │
    └──────────────────────────────────┘
          │
          ▼
    ┌──────────────────────────────────┐
    │ Codex reviews the diff           │
    │   applies CODE_REVIEW.md rubric  │
    │   verdict: MERGE / BLOCK / CHANGES │
    └──────────────────────────────────┘
          │
          ▼
    Passed? → next story   Failed? → feedback to progress.txt, retry
    2 consecutive failures on same story → escalate to human
```

The review rubric (in `skills/ralph-adversarial/CODE_REVIEW.md`) enforces six dimensions — AC compliance, correctness, security, reliability, maintainability (with Karpathy's simplicity and surgical-change principles), and testing — with P0–P3 severity and explicit block rules. State lives on disk (prd.json, progress.txt, git history) so each iteration starts fresh.

> **Why it matters:** A planner LLM reviewing its own code has the same blind spots that produced the code. Using a different provider (Codex) as the reviewer is the cheapest form of cross-model adversarial review for implementation — the same principle as the research loop, applied to patches.

#### Parallel mode — story-level DAG (`--parallel[=N]`)

From a Boris pool slot, `/ralph-adversarial --parallel` turns the loop into an orchestrator: sibling slots become workers, each implementing a **different story concurrently** (default cap 4). The dispatcher honors the DAG declared in `prd.json`:

- **`dependsOn`** — a story only dispatches when every dependency is `passes: true` (an `ESCALATED` dependency blocks it).
- **`touchesFiles`** — glob estimates declared by the planner; two stories co-dispatch only when their file sets are **disjoint** (literal-prefix intersection — conservative on purpose: a false positive serializes, never corrupts).

Both fields are generated by the `prd` skill at plan-conversion time. Serial mode also gained an incident-driven guardrail: a **clean-tree preflight** aborts before any mutation when the tree has dirt outside the framework-file allowlist (`prd.json`, `progress*.{txt,jsonl}`, `.claude/`, `graphify-out/` — override with `--allow-dirty`), and the HANG-path `git stash` uses pathspec excludes. A hung worker can no longer sweep your uncommitted WIP into a stash.

### Bonus: Testing for Agentic Coding

Agents ship code that passes its own tests — but its own tests are precisely the ones the agent wrote. Without discipline, the suite becomes a coat of paint: green, pretty, and useless. The `testing` skill plus the `/e2e` command and `test-runner` subagent wire this discipline into the harness:

```
  BEFORE CODE             DURING CODE              BEFORE COMMIT
  ───────────             ───────────              ─────────────
  TDD RED                 test-runner subagent     PreToolUse hook
  fails for right reason  runs after changes       blocks if playwright.config.*
  (not syntax error)      repairs selector drift   exists AND tests fail
        │                        │                        │
        ▼                        ▼                        ▼
  Implementation            Cross-cuts target       exit 2 → deterministic
  writes minimum code       specs via --reporter    block; stderr surfaces
  to turn it GREEN          line --last-failed      to the model
```

The central rule: **a test must be able to fail for a real defect**. If it can't, delete it. The skill codifies six more:

- Strong assertions (`toEqual(expected)` > `toBeTruthy()`)
- No magic literals, no `.skip` / `.only` / `@ignore` to hide failures
- Bug fix always ships with the regression test that failed before the fix
- Prefer Playwright CLI over MCP (it avoids dumping tool schemas and a11y trees into context)
- `getByRole` / `getByTestId` selectors only — never CSS descendants
- Watch for **agent cheating**: a test edited in the same commit as the feature, with no change to the expected assertion, is a red flag

The test-runner subagent is read-mostly: it edits `tests/**` and `playwright.config.ts`, never product code. If a previously-green test fails after a change, it escalates instead of "fixing" it.

Bootstrap templates live in `skills/testing/templates/` — `playwright.config.ts` (agent-aware reporter, maxFailures, trace-on-first-retry), `mcp.json` (token-efficient MCP settings), `settings.hooks.json` (pre-commit hook with `playwright.config.*` guard so projects without Playwright aren't blocked), and `gitignore.testing`.

The harness's own test suite — **35 suites under `bin/tests/`** (stubs + call-log, capture-proof assertions) — runs locally via `bin/tests/run-all.sh` and in CI on every PR and push to `main` (`.github/workflows/tests.yml`, macOS runner on purpose: the suites use BSD idioms like `stat -f` and `date -v`, and the hooks under test run primarily on a macOS laptop).

> **Why it matters:** LLMs naturally optimize for "the test passes," not "the test catches defects." Making the failure-first cycle structural — RED before GREEN, hook before commit, subagent after every change — is the only way to keep the suite honest.

### Bonus: Knowledge Graph via Graphify

Docs rot the moment they leave the writer's head, and ad-hoc RAG over raw source is stateless — every question re-derives context from scratch. The pragmatic fix is to keep a **persistent, code-derived map of the repo** that the agent consults before any `Glob`/`Grep`/`Read`. We use [Graphify](https://github.com/safishamsi/graphify) (PyPI: `graphifyy`) for that — it produces `graphify-out/{graph.json, graph.html, GRAPH_REPORT.md}` per repo, kept fresh by AST-only git hooks (zero LLM cost on rebuild).

This replaced our previous in-house solution (`bootstrap/llm-wiki/`, deleted on 2026-05-07). Full migration record in `docs/adr/0001-adopt-graphify-sunset-llm-wiki.md`; glossary and operating model in `CONTEXT.md`.

**Bootstrap a target repo (after 1× per-machine `uv tool install graphifyy && graphify install`):**

```bash
cd /path/to/target-repo
/graphify-init                    # build + claude install + git hooks + .gitignore/.gitattributes + commit
```

What `/graphify-init` does (two stages — see `commands/graphify-init.md`):
- **Stage 1 (agent):** `/graphify .` skill — initial build via Claude Code subagents (zero API cost). The slash command is served by the installed skill (`~/.claude/skills/graphify/SKILL.md`); it is *not* a CLI subcommand.
- **Stage 2 (script `bin/graphify-init.sh`):** `graphify claude install` — writes `.claude/settings.json` PreToolUse hook so the agent is told about the graph before any file scan.
- `graphify hook install` — git `post-commit` + `post-checkout` hooks (AST-only, zero LLM).
- `.gitignore` ← `manifest.json`, `cost.json`, `cache/` (per upstream README:185–190).
- `.gitattributes` ← `graphify-out/graph.json merge=theirs` (so concurrent slots don't fight over a JSON blob).
- Local commit only — no push (`/commit-push-pr` does that explicitly).

**Boris workflow integration:** `/checkout-init <repo>` installs Graphify hooks in all 5 slots automatically (when CLI is present); `/sync` regenerates `graphify-out/` per slot after pull to realign the graph with the working tree (compensating for `merge=theirs`).

**Expected dirt in `graphify-out/` (by design — ADR 0001 Errata 2026-05-12):** the `post-commit`/`post-checkout` hooks regenerate `graphify-out/{.graphify_root, GRAPH_REPORT.md, graph.json, graph.html}` in the background, and part of the output is per-slot (absolute path, cwd basename) or non-deterministic (clustering community IDs). Handle it as derived files, never as user work-in-progress: don't commit the dirt in isolation, don't `git stash` it (pop conflicts across slots); before any command that performs an internal checkout (`gh pr merge --delete-branch`, `git rebase`, `git switch`) — or whenever git fails with `"would be overwritten by checkout"` citing `graphify-out/` — discard with `git checkout -- graphify-out/` and re-run. Canonical pattern: `bin/checkout-sync-all.sh:49-56`.

> **Why it matters:** the previous wiki-based system relied on a per-PR LLM call via GitHub Actions to keep docs fresh — that costs money, has lag, and breaks when the action token rotates. AST-derived knowledge graphs cost nothing per rebuild and stay in sync with code by construction. The trade-off is that the artifact (`graph.json`) is binary-shaped JSON in PR diffs; we accept that explicitly in the ADR.

### Bonus: Context Threshold Notification

Long sessions silently approach the context limit until autocompact fires — usually mid-task, at the worst possible moment. Claude Code has no native setting to alert at a custom threshold, so dotclaude ships a `Stop` hook that emits a macOS notification when the session crosses **128K tokens**, giving you a heads-up to `/compact` or `/clear` before the harness compresses on its own.

**How it works:**

1. After every Claude turn, the `Stop` hook runs `~/.claude/hooks/context-threshold-notify.py`
2. The script reads the session transcript JSONL, finds the most recent `assistant` message with a `usage` block, and sums `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`
3. If the total ≥ 128K, it fires `osascript display notification` with a system sound — once per session, flagged in `~/.claude/cache/context-notify/<session_id>.flag`

**Configuration:**

- **Threshold:** edit `THRESHOLD = 128_000` at the top of `hooks/context-threshold-notify.py`
- **Reset within a session** (e.g. to test): delete `~/.claude/cache/context-notify/<session_id>.flag`
- Wired in `~/.claude/settings.json` under `"hooks": {"Stop": [...]}`; requires `"disableAllHooks": false`

**Install** is automatic — `./sync.sh install` copies `hooks/` to `~/.claude/hooks/`. After installing, add the hook block to `~/.claude/settings.json`:

```json
"hooks": {
  "Stop": [
    {
      "matcher": "",
      "hooks": [
        { "type": "command", "command": "/Users/<you>/.claude/hooks/context-threshold-notify.py" }
      ]
    }
  ]
},
"disableAllHooks": false
```

Restart Claude Code after editing `settings.json` — hooks are read at session startup.

> **Why it matters:** Autocompact mid-task forces Claude to compress mid-thought. A nudge at 128K — well before the limit — lets you choose how to free context (compact, clear, split into a subagent) instead of having the harness make that choice for you.

### Bonus: Plan Alignment — Grilling & Hierarchical Systems Thinking

Before a plan is worth reviewing, it has to target the right problem. Three modes front-load that alignment, all reachable from `/plan`:

- **`grill-me`** (`/plan --grill`) — an adversarial interview that asks **one question at a time**, resolving each branch of the decision tree until planner and human share the same mental model. **`grill-with-docs`** is a superset that maintains a domain glossary (`CONTEXT.md`) and ADRs (`docs/adr/`) as it goes.
- **`auto-grill-me`** (`/plan --auto-grill`) — same idea, but a rubric **scores each candidate question** before interrupting: low score → assume silently, medium → assume + footnote, high → actually ask. It emits a plan with a **Definition of Done per artifact**.
- **`/plan --hst`** — Hierarchical Systems Thinking: six top-down phases with a persisted **System Intent** stored once per project/feature tier and reused on later plans, so scope isn't re-litigated every time.
- **`zoom-out`** — maps the modules/callers of an unfamiliar area using the domain's own vocabulary before any plan is written; invoked by `/plan` and `/techdebt` whenever code context is shallow.

> **Why it matters:** the most expensive bug is solving the wrong problem precisely. Alignment-first planning makes the human resolve ambiguity before any code — and the rubric in `auto-grill-me` keeps that from devolving into twenty questions.

### Bonus: Definition of Done & the TDD Chain

A plan's acceptance criteria are only as good as the tests that prove them. dotclaude closes the loop from DoD → test → review → retrospective:

- **`/test-spec`** turns each Definition of Done into Gherkin-lite specs (Given/When/Then), appended to the plan or to `skills/testing/references/TEST-PATTERNS.md`. `/full-cycle` auto-invokes it (Phase 4.5) so specs exist *before* implementation.
- **TDD-chain traceability** — every spec bullet carries an ID (`[bN]`) that threads through the test, the commit, and the review, so you can audit which DoD a given test defends.
- **`/reflect`** is post-merge supervision that classifies how well the DoD applied to a merged PR. Modes: `--baseline` (immediate compliance), `--retro` (full retrospective after D+7), `--on-failure` (audit at a stop gate), `--learn` (an LLM consumes the per-story TDD-chain bundle and proposes DoD / TEST-PATTERNS improvements). `/full-cycle` runs it as Phase 9.
- **Cross-machine telemetry** — DoD/test-spec usage is logged per-machine to `~/.claude/telemetry/*.jsonl`. A Stop hook (`hooks/sync-telemetry-log.sh`) copies each machine's log into the repo's `telemetry/` and stages it, so the next commit carries it — git is the transport/backup across machines (plan M8 / Adv #1). `bin/lib/usage-fold.sh` folds the logs for `/reflect --learn`, reading **only** the local `~/.claude/telemetry/` and never the repo copy. That is why `telemetry/` is versioned on purpose and *not* gitignored.

> **Why it matters:** "negative-branch" criteria — the cases a feature must *reject* — are the ones agents quietly skip. Materialising DoDs into specs, threading IDs through the chain, and reflecting after merge keeps the suite from going vacuous.

### Bonus: The `/ship` Delivery Pipeline

`/ship` is the last mile — runnable standalone or as the final phase of `/full-cycle*`:

```
  PRE-MERGE TESTS ──► PR ──► AUTO-MERGE ──► DEPLOY ──► POST-MERGE E2E
  loop 3× auto-fix          (or soft        (if          against the real
                             force-merge     ship.json    URL, loop 3×
                             on unprotected) configures)  hotfix per pass
```

Per-repo config lives in `.claude/ship.json` (cascade: config > auto-detect > CLI flag). On an unprotected repo it merges directly; on a protected one it waits for CI/reviews. **`/force-merge`** covers the cases where `gh pr merge --auto` never fires — a repo without `allow_auto_merge`, a solo repo, or reviews that never arrive.

> **Why it matters:** "tests pass locally" and "the deployed thing works" are different claims. Running E2E against the real URL *after* merge closes that gap, and the hotfix loop turns a post-deploy failure into another iteration instead of a fire drill.

### Bonus: Headless Operations — Morning Autopilot, Retro Drainer, Backlog Dispatcher

Three scripts turn idle time (overnight, login) into harness throughput, all sharing the same battle-tested patterns (append-only jsonl state + dedup markers, `timeout → gtimeout → warning` fallback chain, `claude` resolution with `~/.local/bin` fallback):

- **`bin/auto-morning.sh`** — a macOS LaunchAgent wrapper that runs at login: opens the VM work sessions (`vm-morning.sh`), then non-blocking drains the queues below (`--max 2 || true` each).
- **`bin/reflect-retro-due.sh`** — finds D+7 retrospectives that came due in `~/.claude/cache/reflect/reminders.jsonl`, resolves the matching checkout, and runs `claude -p "/reflect <pr> --retro"` headless — model pinned via `--model` (default `claude-fable-5`). Dedup via `retro_done` markers; ≥3 failed attempts = permanent skip.
- **`bin/backlog-dispatch.sh`** — a cross-repo work queue (`~/.claude/cache/backlog/<repo>.jsonl`). Each eligible item is dispatched as a headless `/full-cycle-simple` into a **free pool slot** (clean + on `main`), guarded by an atomic `mkdir` lock. Two hard rules: items flagged `human_gate` (financial cost, Zone-3, destructive) are **never** auto-dispatched — they're listed for the human instead; and the generated prompt instructs the cycle to **stop at an open PR, no auto-merge** — nothing merges while you sleep.
- **`bin/parallelism-report.sh`** — measures adherence to Principle 9 (parallel tool-use) across all transcripts, grouping `tool_use` blocks by API `message.id` (parallel calls share an id but occupy separate jsonl lines — naive line counting reads a false 0%). Fleet baseline at adoption: **14%** of API messages carry ≥2 tool calls.

> **Why it matters:** the human was the fleet's dispatcher — five checkout slots and two VMs sat idle unless someone typed into them. Queues with human-gates keep the judgment calls human while the mechanical backlog drains itself.

### Bonus: VM Fleet — Provisioning, Doctor, OAuth Tunnel

Long-running autonomous Claude sessions live on UTM VMs, not the laptop. The repo versions everything needed to stand one up:

- **`bin/vm-provision.sh`** — two-phase provisioning (user phase batched over SSH; root phase via `ssh -t` because sudo needs a real tty): Docker, Playwright deps (`--no-sandbox` baked in for Ubuntu 24.04 AppArmor), `python-is-python3`, per-repo Chrome profiles, MCP config fixes.
- **`systemd/claude-code.service` + `claude-sessions.sh`** — the VM session service, captured verbatim from production VMs (UTF-8 locale fix included — systemd units don't inherit `LANG`).
- **`bin/vm-doctor.sh`** — sanitizes orphan systemd units and stale state after upgrades.
- **`bin/vm-oauth.sh <1|2> <port>`** — `ssh -L` tunnel so the `claude` OAuth callback printed *inside* the VM can be completed by the browser on the Mac (the VM's `localhost` isn't yours).
- **`vm1.sh` / `vm2.sh` / `vm-paste.sh`** — terminal launchers (SSH + Claude in the right slot, X11 via XQuartz) and a clipboard bridge that scp's Mac screenshots into the VM and puts the remote path back on your clipboard.
- **Auto-sync** — a `SessionStart` hook (`.vm-profile`-gated) pulls `dotclaude` and re-installs on every session start, so VMs track `main` without manual syncs.

> **Why it matters:** autonomous loops are exactly the workloads you don't want sharing a filesystem with your laptop's credentials and WIP. VMs give cheap blast-radius isolation; versioned provisioning makes them reproducible instead of artisanal.

### Bonus: Supply-Chain Hygiene (Shai-Hulud defense)

Attacks like Shai-Hulud (TanStack, 2026 — 169 packages / 373 malicious versions) run their payload in install-time lifecycle hooks (`preinstall`/`prepare`), stealing GitHub/npm/AWS tokens the moment `npm install` fires — and they arrive through *transitive* deps, so the victim never installs the malicious package directly. A global `PreToolUse` hook (`hooks/supply-chain-guard.sh`, Principle 13) enforces fail-closed defense in depth:

| Layer | Rule |
|-------|------|
| **Cooldown** | Any package (root **or transitive**, resolved via `--dry-run`) published < **14 days** ago is blocked |
| **`--ignore-scripts`** | Mandatory on npm/pnpm/yarn/bun — kills the lifecycle-hook execution vector |
| **Git-url deps** | `github:user/repo`, `git+https://…`, `user/repo` shorthand are blocked (second-wave vector that dodges the cooldown) |
| **Lockfile** | `npm install` with a lockfile present is steered to `npm ci` / `--frozen-lockfile` |

Bypass is **granular by design** — four separate env flags (`CLAUDE_SC_BYPASS_*`) each require `CLAUDE_SC_REASON`. Every decision (allow/block/bypass) is logged to `~/.claude/cache/supply-chain/audit.jsonl`; **`/supply-chain-audit`** renders it human-readable. Full rationale in `docs/adr/0002-supply-chain-cooldown-gate.md`.

> **Why it matters:** the window between a malicious publish and public detection has been < 7 days in every historical case; a 14-day cooldown sidesteps the whole class without blocking month-old bugfixes. A monolithic bypass doesn't exist on purpose — defense in depth needs surgical exceptions.

### Bonus: Safety Rails & Session Continuity

A few smaller guardrails round out the harness:

- **Git secret-scan** (`hooks/block-dangerous-git.sh`, skill `git-guardrails-claude-code`) — a `PreToolUse` hook that blocks `commit`/`push` when the staged diff contains secrets (Stripe/GH/Netlify/AWS/Google/Slack keys, `.pem`/`.key`, `.env`/`credentials` files). Scoped to secrets only — destructive ops are *not* pre-blocked (Principle 7).
- **Browser-as-agent** (skills `browser-actions` / `browser-inspect`, Principle 12) — when an external action falls through the precedence ladder (domain CLI → domain MCP → direct API → Playwright MCP), the browser is the last resort: it announces every open, runs a cookie pre-check, asks you to log in via chat, and applies a "Zone 3" blocklist of irreversible actions. `browser-inspect` is the anti-laziness rule — if a page is reachable by Playwright, the agent reads the console/network itself instead of asking you to paste it.
- **`/handoff-continue`** — distills the current session into a handoff doc + a pending pointer, and lazy-installs a `SessionStart` hook so the next session **has the handoff as silent context**. It prints the handoff and asks you to `/clear` — it never clears for you. After `/clear` the session opens blank: the handoff is injected as an invisible system reminder and **does not auto-start the work** (no Claude Code hook can trigger an assistant turn) — type `continuar` (or any message) to resume from the "Próximo passo".
- **Branch protection on `main`** — the `main` branch requires the `bin-tests` status check (the job id in `.github/workflows/tests.yml`) to pass before merge, with **0 required approvals** (solo repo — the Boris auto-merge workflow must not deadlock) and `strict=false`. `allow_auto_merge` stays enabled so `/commit-push-pr` and `/ship` merge automatically once `bin-tests` is green. Because the config lives on GitHub (not in the repo), `bin/verify-branch-protection.sh` encodes these invariants as a versioned drift-check — run it to confirm the live config still matches, or catch a silent change (a `tests`-vs-`bin-tests` rename, a re-enabled review requirement, `allow_auto_merge` turned off). Revert in one line: `gh api -X DELETE repos/alexlopespereira/dotclaude/branches/main/protection`.

> **Why it matters:** the failure modes here aren't reasoning errors — they're a leaked token, an irreversible click, or a lost thread after compaction. Each rail makes the dangerous path the explicit one.

## Installation

```bash
git clone https://github.com/alexlopespereira/dotclaude.git
cd dotclaude
chmod +x sync.sh
./sync.sh install
```

This copies everything to `~/.claude/`, making all commands and skills globally available in any project.

## Commands

After installation, these slash commands are available in any Claude Code project:

| Command | Category | What it does |
|---------|----------|-------------|
| `/plan` | Planning | Technical plan with ReAct + Feynman. Flags: `--grill` (alignment interview), `--auto-grill` (rubric-scored interview), `--hst` (Hierarchical Systems Thinking) |
| `/adversarial-review` | Review | Red Team attack on an existing plan |
| `/full-planning-cycle` | Planning + Review | Both agents in sequence (no execution) |
| `/full-cycle` | End-to-end delivery | Plan + review + test-spec + PRD + Ralph + code-review + tests + PR + reflect |
| `/full-cycle-simple` | End-to-end delivery | Same pipeline for **simple** features (≤5 files, no migration/dep/auth/cost) — skips adversarial review + Codex reviewer |
| `/ship` | Delivery | Pre-merge tests → PR → auto-merge → deploy → post-merge E2E against the real URL |
| `/reflect` | Review / Quality | Post-merge Definition-of-Done supervision (`--baseline` / `--retro` / `--on-failure` / `--learn`) |
| `/test-spec` | Testing | Generates Gherkin-lite test specs from DoDs (TDD bake-in) |
| `/e2e` | Testing | Generates or runs Playwright E2E tests for a flow |
| `/diagnose` | Debugging | Disciplined 6-phase diagnosis loop (feedback loop → reproduce → fix → regression) |
| `/techdebt` | Code quality | Analyses diff for tech debt, produces P0/P1/P2 cleanup plan |
| `/adversarial-research` | Research | Deep research with 3 AI providers |
| `/research-status` | Research | Lists all research sessions |
| `/research-synthesize` | Research | Synthesizes a completed research |
| `/checkout-init` | Parallel workflow (Boris) | Provisions 5 parallel checkouts at `~/Projects/checkouts/<repo>-{1..5}` |
| `/checkout-launch` | Parallel workflow (Boris) | Opens 1 terminal window with 5 tabs (one per slot) |
| `/checkout-use` | Parallel workflow (Boris) | Prepares a slot — updates `main`, **does not create branch** |
| `/checkout-status` | Parallel workflow (Boris) | Shows state of all slots (branch, dirty, ahead/behind, label) |
| `/checkout-sync-all` | Parallel workflow (Boris) | Pulls `origin/main` in all slots, prunes merged branches |
| `/sync` | Parallel workflow (Boris) | Shortcut to `/checkout-sync-all` (auto-detects pool from cwd) |
| `/morning` | Parallel workflow (Boris) | Daily routine — sync-all + launch tabs |
| `/commit-push-pr` | Git workflow | Creates ephemeral branch, commits, pushes, opens PR (auto-merge default; soft-merge on unprotected repos) |
| `/force-merge` | Git workflow | Merges an open PR now (soft / `--wait` / `--admin`), then syncs the pool |
| `/create-worktree` *(legacy)* | Git workflow | Creates isolated git worktree at `~/Projects/worktrees/` |
| `/delete-worktree` *(legacy)* | Git workflow | Removes worktree after merge (with safety checks) |
| `/prd-convert` | Implementation | Converts an approved plan into prd.json (Ralph format) |
| `/ralph-adversarial` | Implementation | Runs the Ralph loop with Codex code review (`--parallel[=N]` dispatches stories concurrently across pool slots) |
| `/graphify-init` | Knowledge graph | Bootstraps Graphify in a repo (build + hooks + .gitignore + local commit) |
| `/supply-chain-audit` | Security | Inspects the supply-chain-guard audit log (decisions, bypasses, cache stats) |
| `/browser-status` | Browser | Lists cookies in the dedicated Chrome profile (read-only) |
| `/browser-logout-all` | Browser | Clears all cookies in the dedicated Chrome profile (destructive) |
| `/handoff-continue` | Utility | Distills session context into a handoff doc + pending pointer for clean resume |
| `/export-report` | Utility | Exports last response as Markdown |

---

### `/plan [problem description]`

**Purpose:** Produces a complete technical plan using the ReAct + Feynman protocol.

**What happens when you run it:**

1. Claude assumes the role of **Planner Agent**
2. Reads the ReAct + Feynman skill templates
3. Executes the ReAct cycle — iterating Thought/Action/Observation until it has enough evidence
4. Produces a structured plan with: Context, Technical Decisions table, Assumptions to Validate, Open Questions, and Next Slice
5. Every claim is classified as `[FACT]`, `[INFERENCE]`, or `[ASSUMPTION]`
6. The Feynman Test is applied: mechanisms are explained, not just pattern names

**Output format:**

```markdown
## Plan: [Title]
**Overall Confidence:** [HIGH / MEDIUM / LOW] — [one-line justification]

### Context and Objective
### ReAct Cycle (Thought/Action/Observation iterations)
### Technical Decisions
| # | Decision | Alternatives | Justification (mechanism, not name) |
### Assumptions to Validate
- [ ] [ASSUMPTION] ...
### Open Questions
### Next Slice (smallest implementable increment)
```

**Example:**
```
> /plan migrate the database from MySQL 5.7 to PostgreSQL 16
```

---

### `/adversarial-review [path to plan or "last plan"]`

**Purpose:** Performs a Red Team review of an existing plan. Claude switches from Planner to Adversary — its goal becomes **finding flaws**, not confirming the plan.

**What happens when you run it:**

1. Claude assumes the role of **Adversary Reviewer Agent**
2. Loads the plan specified (a file path, or "last plan" to find the most recent one in `.claude/plans/`)
3. For each technical decision in the plan:
   - Applies ReAct to reason about the decision and test contrary hypotheses
   - Tries to **refute** each listed `[ASSUMPTION]`
   - Applies the Feynman Test — flags any pattern named without explaining its mechanism
4. Produces a structured adversarial review with a verdict

**Output format:**

```markdown
## Adversarial Review: [Plan Title]
**Verdict:** [APPROVED / APPROVED WITH CAVEATS / REJECTED]

### Flaws Found
| # | Type | Description | Severity | Suggestion |
| 1 | [Logic / Assumption / Gap / Risk] | ... | [Critical / High / Medium / Low] | ... |

### Refuted Assumptions
### Feynman Test (violations found)
### Questions the Planner Should Have Asked
### Recommendation (specific changes needed)
```

**Example:**
```
> /adversarial-review .claude/plans/migrate-mysql-to-postgres.md
```

---

### `/full-cycle [problem description]`

**Purpose:** Runs the complete end-to-end delivery pipeline in the current working directory — plans, reviews, generates test specs, converts to PRD, executes Ralph Adversarial, runs a local code review, runs tests, opens and merges a PR, optionally ships, and reflects on DoD compliance.

**Isolation management is explicit and user-owned.** This command does **not** create or release slots/worktrees. Choose your isolation model before invoking:

- **Recommended (Boris parallel checkouts):** run `/checkout-use <repo> <slot>` and `cd` into `~/Projects/checkouts/<repo>-<slot>`. After PR merges, run `/sync` (or `/checkout-sync-all <repo>`) to update all slots.
- **Legacy (worktree):** `/create-worktree <slug>` then `cd` into the worktree. After merge, `/delete-worktree`.
- **None:** run directly in the main checkout.

**What happens when you run it:**

1. **Phase 1 — Planning:** Claude acts as the Planner Agent, executes the full ReAct cycle, and saves a plan to `.claude/plans/<slug>.md`
2. **Phase 2 — Adversarial Review:** Claude switches to the Adversary Agent role, re-reads the plan with fresh eyes, and attacks it. The review is appended to the same file under a `---` separator
3. **Phase 3 — Approval gate:**
   - **APPROVED** → proceeds to PRD
   - **APPROVED WITH CAVEATS** → asks the human whether to proceed
   - **REJECTED** → stops
4. **Phase 4 — PRD conversion:** slices the plan into `prd.json` following the `prd` skill rules
5. **Phase 4.5 — Test specs:** auto-invokes `/test-spec` to materialise Gherkin-lite specs from the plan's DoDs *before* implementation
6. **Phase 5 — Ralph Adversarial:** runs the implementation loop (Claude implements, Codex reviews) until all stories pass or the budget is exhausted
7. **Phase 5.5 — Local code review:** auto-invokes the native `/code-review` on the accumulated diff — running **concurrently** with Phase 6
8. **Phase 6 — Final tests:** the project suite runs **in background, in parallel with Phase 5.5**; both join (must be green) before any PR. If the auto-fix loop commits after the review ran, the review re-covers the delta
9. **Phase 7 — PR + Merge:** pushes the branch, opens a PR; CI is watched via a **background task** so the session stays free for the next item
10. **Phase 8 — Ship (optional):** when `.claude/ship.json` exists, hands off to `/ship` for deploy + post-merge E2E against the real URL
11. **Phase 9 — Reflect:** a headless subprocess pinned to `claude-fable-5` runs `/reflect` (`--learn` when the cycle ran anomalous — escalations, repeated review blocks, auto-fix triggered — `--baseline` otherwise), non-blocking

**Guardrails:** No production code is written before adversarial approval. Internal phase transitions don't ask for confirmation — the slash command *is* the high-level gate, and you interrupt with Ctrl-C (Principle 11); the exceptions that always re-confirm are destructive commands, paid external domains, and any `prd.json` flagged `hasFinancialCost: true`. The command stops and escalates on any interruption (rejection, escalated stories, P0 findings, failing tests, blocked merge). For planning-only without execution or PR, use `/full-planning-cycle`. For **simple** features (≤5 files, no migration/dep/auth/cost), use `/full-cycle-simple`, which skips Phase 2 and the Codex reviewer.

**Example:**
```
> /checkout-use myapp 3              # prepare slot 3 (updates main, no branch)
> cd ~/Projects/checkouts/myapp-3
> /full-cycle implement real-time notifications with WebSocket

Phase 1 — Planning (ReAct + Feynman)
  ...
  Plan saved to .claude/plans/realtime-notifications-websocket.md

Phase 2 — Adversarial Review
  Verdict: APPROVED WITH CAVEATS — proceed? y

Phase 4   — PRD with 4 stories
Phase 4.5 — Test specs generated for 4 stories
Phase 5   — Ralph: 4/4 passed (Codex verdicts: MERGE MERGE MERGE MERGE)
Phase 6   — Tests green
Phase 7   — PR #128 merged
Phase 9   — Reflect: DoD baseline recorded

> /sync                              # propagate merged main to all slots
```

---

### `/create-worktree <slug> [base-branch]`

**Purpose:** Creates an isolated git worktree so feature work never pollutes the main checkout.

**What happens when you run it:**

1. Validates the slug (`^[a-z0-9][a-z0-9-]*$`) and that the base branch exists
2. Fetches `origin/<base>` (default `main`) to ensure the worktree starts from the latest remote state
3. Creates `~/Projects/worktrees/<repo-name>-<slug>` with a new branch `<slug>`
4. Reports the path so subsequent work (`cd`, `git -C`, file operations) targets it

**Layout convention:** all worktrees live under `~/Projects/worktrees/` and are named `<repo-name>-<slug>` to disambiguate across repos.

**Guardrails:** refuses to overwrite an existing worktree path (use `/delete-worktree` first). Never creates a worktree on top of uncommitted changes in the source branch without warning.

**Example:**
```
> /create-worktree fix-auth-bug

Worktree created:
  path:   /Users/you/Projects/worktrees/myapp-fix-auth-bug
  branch: fix-auth-bug
  base:   main
```

---

### `/delete-worktree [path-or-slug] [--force]`

**Purpose:** Removes a worktree after the work has been merged. Runs safety checks before deleting anything.

**What happens when you run it:**

1. Resolves the target — explicit path, slug (mapped to `~/Projects/worktrees/<repo>-<slug>`), or the current working directory if it's inside `~/Projects/worktrees/`
2. Verifies the path is a real worktree via `git worktree list` — refuses to touch the main repo
3. **Safety checks** (skipped only with `--force`):
   - No uncommitted changes in the worktree
   - Branch is merged — verified via `gh pr list --state all` (preferred) or `git merge-base --is-ancestor` as fallback
4. Runs `git worktree remove` + `git worktree prune`
5. Deletes the local branch with `git branch -d` (safe delete — refuses unmerged work)

**Guardrails:** never deletes the main repository. Never force-deletes a branch that wasn't merged, even with `--force` — the flag only bypasses the safety checks, not the branch-safety of `git branch -d`.

**Example:**
```
> /delete-worktree fix-auth-bug

Worktree removed:
  path:   /Users/you/Projects/worktrees/myapp-fix-auth-bug
  branch: fix-auth-bug (local deleted)
  merged: true
```

---

### `/adversarial-research [topic in natural language]`

**Purpose:** Conducts deep research on any topic using three independent AI providers in an adversarial pipeline, producing a high-reliability report with a confidence map.

**What happens when you run it:**

1. **Verifies** that all 3 API keys are set (`GEMINI_API_KEY`, `PERPLEXITY_API_KEY`, `OPENAI_API_KEY`)
2. **Gemini Deep Research** (Elaborator): conducts 80–160 autonomous web searches and produces a comprehensive report (V1)
3. **Perplexity Sonar DR** (Fact-Checker): independently verifies every factual claim, checks citations, finds counter-evidence, flags fabricated data
4. **OpenAI + Web Search** (Logic Reviewer): analyzes internal consistency, methodology, logical gaps, biases, and conclusion robustness
5. **Iteration:** if the logic reviewer rejects the report, Gemini corrects it incorporating both reviews, and the reviewers re-check (max 3 cycles)
6. **Claude synthesizes** the final report with a confidence map per section

**Artifacts produced** (saved to `.claude/research/[timestamp]_[topic]/`):

| File | Content |
|------|---------|
| `meta.json` | Topic, providers, timestamps, cycle count |
| `report-v1.md` ... `report-v3.md` | Gemini's report versions |
| `factcheck-1.md` ... `factcheck-3.md` | Perplexity's fact-check reviews |
| `logic-review-1.md` ... `logic-review-3.md` | OpenAI's logic reviews |
| `synthesis.md` | Final synthesis with confidence map |

**Output — Synthesis format:**

```markdown
# Synthesis: [Topic]
**Date / Cycles / Final Verdict**
**Providers:** Gemini (elaborator) | Perplexity (fact-check) | OpenAI (logic)

## Executive Summary
## Confidence Map
| Section | Facts (Perplexity) | Logic (OpenAI) | Overall Confidence |
## Unverified Claims
## Relevant Counter-Evidence
## Corrections V1 → Vfinal
## Recommendations for Manual Investigation
```

**Example:**
```
> /adversarial-research impact of microservices migration on team velocity in companies with fewer than 50 engineers
```

**Cost per session (2 cycles):** ~$1.50–4.50

---

### `/research-status`

**Purpose:** Lists all adversarial research sessions conducted in the current project, showing which ones are complete and which are pending synthesis.

**What happens when you run it:**

1. Scans `.claude/research/` for research directories
2. Reads `meta.json` from each one (topic, date, cycle count, providers)
3. Checks if `synthesis.md` exists (completed) or not (pending)
4. Produces a summary table

**Output:**

```
| #  | Date       | Topic                            | Cycles | Status    |
|----|------------|----------------------------------|--------|-----------|
| 1  | 2026-04-10 | Impact of LLMs on education      | 2      | Completed |
| 2  | 2026-04-15 | Microservices vs monolith         | 3      | Pending   |

Research #2 is pending synthesis. Run /research-synthesize to generate it.
```

---

### `/research-synthesize [path or "last"]`

**Purpose:** Generates the final synthesis report for an adversarial research session that has completed all provider cycles but hasn't been synthesized yet.

**What happens when you run it:**

1. If argument is `"last"` or `"última"`: picks the most recent directory in `.claude/research/`
2. Reads all artifacts: `meta.json`, all `report-v*.md`, `factcheck-*.md`, `logic-review-*.md`
3. Produces the final synthesis with confidence map, corrections applied, and recommendations
4. Saves as `synthesis.md` in the research directory

**Example:**
```
> /research-synthesize last
```

---

### `/commit-push-pr ["msg"] [--branch=...] [--type=...] [--no-pr] [--draft] [--no-auto-merge] [--merge-method=squash|merge|rebase]`

**Purpose:** Packages your work into an ephemeral branch, opens a PR to `main`, and (by default) enables auto-merge so GitHub squash-merges when CI passes. Replaces the old `/pr`.

**Workflow model (Boris Cherny + branch protection):**
- Work happens on `main` **local** inside each parallel checkout slot.
- This command creates a branch only at push time, derived from the commit message (e.g. `feat: dark mode` → `feat/dark-mode`).
- Branch protection on `origin/main` is preserved — nothing pushes to `main` directly.
- After PR merges (auto or manual), `/sync` propagates the new `main` to all slots and prunes merged branches.

**Arguments are optional.** When run as `/commit-push-pr` with no args, Claude infers a Conventional Commits message + branch name from the diff, recent commits, and conversation context, then asks for confirmation.

**What happens:**

1. **Inference (if no message provided):** Reads `git status`, `git diff`, `git log`, conversation context. Proposes message + branch + PR mode (ready/draft/no-pr based on heuristic).
2. **Creates branch** from main local at HEAD. If commits were already on local main, moves them to the new branch and resets main to `origin/main`.
3. **Pushes** the branch to origin.
4. **Creates the PR** via `gh pr create` (base: `main`, head: new branch).
5. **Enables auto-merge** with `gh pr merge --auto --squash --delete-branch` (skipped on `--draft` or `--no-auto-merge`).
6. **Resets** local `main` so the slot is clean for the next task.

**Defaults:**
- Type when no Conventional Commits prefix: `chore`.
- PR mode: `ready` (sugestões `draft` / `no-pr` aparecem na proposta quando heurística sugere).
- Auto-merge: **on** (squash + delete-branch).

**Guardrails:**
- Never force-pushes to `main`.
- Never bypasses branch protection (`--admin` etc.).
- Aborts if diff contains likely secret files (`.env*`, `*.pem`, `credentials*`).
- If `git push` is rejected by server hook, reports server message verbatim — no bypass attempt.

**Example:**
```
> /commit-push-pr

Mensagem proposta:
  feat: add dark mode toggle in settings page
Branch proposta: feat/add-dark-mode-toggle
Tipo: feat | Arquivos: 3 | Linhas: +47 -12
PR mode sugerido: ready (não-draft)
  → Confirmar tudo? (y / n / editar / draft / no-pr)
> y

✓ PR aberto: https://github.com/owner/repo/pull/142
✓ Auto-merge (squash) habilitado — PR mergeará quando CI passar.
```

---

### `/export-report`

**Purpose:** Exports Claude's last response as a standalone Markdown file — useful for preserving research results, plans, or analysis outside the conversation context.

**What happens when you run it:**

1. Identifies the last response in the conversation (immediately before this command)
2. Creates a file named `report-YYYY-MM-DD-HHmmss.md` in the current working directory
3. Content includes: H1 title (inferred from the response topic), export timestamp, and the **complete** response with all original formatting preserved (tables, code blocks, lists)
4. Reports the full path of the created file

**Guarantees:** No content is summarized, altered, or omitted. The export is an exact copy.

**Example:**
```
> /export-report

Exported to: /Users/you/project/report-2026-04-16-143022.md
```

---

### `/prd-convert [plan path or "last"]`

**Purpose:** Converts an approved plan (from `.claude/plans/`) into a `prd.json` file — the machine-readable task list consumed by the Ralph loop.

**What happens when you run it:**

1. Reads the `prd` skill (`skills/prd/SKILL.md`)
2. Locates the plan — either the path you pass or the most recent file in `.claude/plans/` when you pass `last`
3. Slices the plan into user stories following these rules:
   - **One slice of the plan = one user story**
   - **Each story is completable in a single context window** (rule of thumb: ≤5 files and ≤200 lines of new code — otherwise split)
   - **Acceptance criteria must be testable** — no "works correctly" — verifiable conditions only
   - **Each [ASSUMPTION] in the plan becomes a validation AC** (e.g., "Validate that X is true before implementing")
   - **Priority follows plan order** (the "Next Slice" is priority 1)
4. Writes `prd.json` at the repo root, preserving `sourcePlan` for traceability
5. Shows the result and asks whether you want to adjust any story before running the Ralph loop

**Output format (prd.json):**
```json
{
  "projectName": "...",
  "branchName": "feat/...",
  "sourcePlan": ".claude/plans/....md",
  "userStories": [
    {
      "id": "US-01",
      "title": "...",
      "description": "...",
      "acceptanceCriteria": ["AC1: ...", "AC2: ..."],
      "priority": 1,
      "passes": false
    }
  ]
}
```

**Example:**
```
> /prd-convert last
```

---

### `/e2e <route or flow description>`

**Purpose:** Generates or runs a Playwright E2E test for a specific route or user flow.

**What happens when you run it:**

1. Runs a preflight that shows `git status`, existing specs in `tests/e2e/`, and the `playwright.config.ts` header
2. Discovers any existing specs that already cover the described flow
3. Plans coverage as an explicit checklist: **happy path + 2 error cases + 1 edge case**
4. Writes a new spec at `tests/e2e/<slug>.spec.ts` using `data-testid` or role selectors, `test.describe` per flow, `test.step` per action, and web-first assertions
5. Runs it targeted: `npx playwright test tests/e2e/<slug>.spec.ts --reporter=line`
6. **Repair loop (max 3):** on failure, reads the trace + screenshot in `test-results/`. If a selector is wrong, uses `playwright mcp browser_snapshot` to fix it. Re-runs. Never uses `--update-snapshots` without permission.
7. Reports a PASS/FAIL table and the list of files touched

**Restrictions:**
- Does not start the dev server — assumes `localhost:3000` is already live
- Does not commit — the human reviews first

**Example:**
```
> /e2e checkout with invalid CEP
```

---

### `/ralph-adversarial [--parallel[=N]] [max_iterations, default 10]`

**Purpose:** Runs an autonomous implementation loop: Claude Code implements one user story per iteration with a fresh context window, and OpenAI Codex reviews every commit using a strict code-review rubric.

**What happens when you run it:**

1. Verifies prerequisites: `prd.json` at the repo root, `jq`, `claude` CLI, and the rubric at `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md`. `codex` CLI is optional — if absent, or if it hits quota/rate-limit mid-run, the loop falls back to a second `claude --model sonnet` instance acting as reviewer with the same rubric.
2. If `prd.json` doesn't exist but an approved plan does, it offers to run `/prd-convert` first
3. Creates (or checks out) the branch declared in `prd.json` → `branchName`
4. Iterates until all stories pass or `max_iterations` is reached:
   - **(A) Claude Code** spawns with a fresh context, reads `prd.json`, `progress.txt`, and recent git history, picks the next pending story (lowest priority number), implements it, runs project quality checks, and commits with an `ac_trace` block in the commit message
   - **(B) Reviewer** is spawned to review the diff against the rubric in `CODE_REVIEW.md` and produces a verdict: `MERGE`, `REQUEST_CHANGES`, or `BLOCK`. The reviewer is Codex by default; when Codex is unavailable (missing binary or quota error), a `claude --model sonnet` instance takes over for the rest of the run, and the switch is logged in `progress.txt` as `CODEX_QUOTA`.
   - **(C) Verdict handling:**
     - `MERGE` → story marked `passes: true`, next iteration
     - `BLOCK` / `REQUEST_CHANGES` → review saved to `.claude/research/review-*.txt`, feedback appended to `progress.txt`, story retried
     - 2 consecutive failures on the same story → escalate to human (`passes: "ESCALATED"`)

**The review rubric enforces 6 dimensions:**

| Dimension | Checks |
|-----------|--------|
| `AC_COMPLIANCE` | Every acceptance criterion maps to code + test. Missing impl = P0. Missing test = P1. |
| `CORRECTNESS` | Edge cases, off-by-one, null/undefined, silent type coercion |
| `SECURITY` | Injection, hardcoded secrets, missing authn/authz, input validation, PII in logs |
| `RELIABILITY` | Error handling, race conditions, resource cleanup, dependency failure behavior |
| `MAINTAINABILITY` | Karpathy principles: no speculative abstraction, every line traces to an AC |
| `TESTING` | Positive + at least one negative case per new behavior; existing tests still valid |

**Severity:** P0 blocks merge; P1 requests changes; P2/P3 are informational.

**Memory between iterations lives on disk:**
- `prd.json` — which stories are pending vs done
- `progress.txt` — accumulated feedback, gotchas, lessons
- git history — what's already been implemented
- `AGENTS.md` — conventions discovered during implementation

**Prerequisites:** `jq` and the Claude Code CLI. OpenAI Codex CLI (`codex` in PATH) is recommended for cross-provider review, but optional — if it's missing or hits a quota/rate-limit error, the loop automatically falls back to `claude --model sonnet` as the reviewer and continues.

**Example:**
```
> /ralph-adversarial 15

RALPH ADVERSARIAL LOOP
Project:    payment-refactor
Branch:     feat/payment-refactor
Iterations: max 15
Rubric:     ~/.claude/skills/ralph-adversarial/CODE_REVIEW.md

--- Iteration 1/15 ---
Story: US-01 - Add idempotency key to charge endpoint
[A] Claude Code — Implementing...
  Commit: [US-01] Add idempotency key to charge endpoint
[B] Codex — Reviewing code...
  Verdict: MERGE
  Story US-01 APPROVED
```

## Project Structure

```
dotclaude/
├── CLAUDE.md                          # Global protocol (15 principles: ReAct + Feynman + guardrails)
├── WORKFLOW.md                        # Integrated workflow guide
├── CONTEXT.md                         # Domain glossary + consolidated decisions
├── README.md
├── sync.sh                            # Sync repo ↔ ~/.claude/ (install / backup / status)
├── commands/                          # Slash commands → ~/.claude/commands/
│   ├── plan.md  adversarial-review.md  full-planning-cycle.md
│   ├── full-cycle.md  full-cycle-simple.md  ship.md  force-merge.md
│   ├── reflect.md  test-spec.md  e2e.md  diagnose.md  techdebt.md
│   ├── adversarial-research.md  research-status.md  research-synthesize.md
│   ├── checkout-init.md  checkout-launch.md  checkout-use.md
│   ├── checkout-status.md  checkout-sync-all.md  sync.md  morning.md
│   ├── commit-push-pr.md  commit-push-pr-push.md  create-worktree.md  delete-worktree.md
│   ├── prd-convert.md  ralph-adversarial.md  graphify-init.md
│   ├── supply-chain-audit.md  browser-status.md  browser-logout-all.md
│   └── handoff-continue.md  export-report.md
├── skills/                            # Skills → ~/.claude/skills/
│   ├── react-feynman/                 #   ReAct + Feynman templates
│   ├── grill-me/  grill-with-docs/  auto-grill-me/  zoom-out/   # alignment + exploration
│   ├── adversarial-research/          #   multi-provider research (SKILL.md + runner.py)
│   ├── prd/  ralph-adversarial/       #   plan→prd + impl loop (+ CODE_REVIEW.md rubric)
│   ├── testing/                       #   TDD + Playwright (SKILL.md, templates/, references/)
│   ├── diagnose/                      #   6-phase diagnosis protocol
│   ├── browser-actions/  browser-inspect/   # browser-as-agent (Principle 12)
│   ├── supply-chain-guard/            #   Shai-Hulud defense (Principle 13)
│   └── git-guardrails-claude-code/    #   secret-scan git hook
├── bin/                               # Implementation scripts behind the commands
│   ├── checkout-*.sh  sync.sh  morning.sh  commit-push-pr.sh
│   ├── ship.sh  force-merge.sh  graphify-init.sh  reflect-learn-bundle.sh
│   ├── reflect-retro-due.sh  backlog-dispatch.sh  parallelism-report.sh
│   ├── vm-provision.sh  vm-doctor.sh  vm-oauth.sh  claude-yolo
│   ├── dod-usage-migrate.sh  browser-*.sh  auto-morning*.sh
│   └── lib/  tests/                   #   shared libs + 35 test suites (run-all.sh → CI)
├── systemd/                           # VM session service (unit + launcher), captured verbatim
├── .github/workflows/
│   └── tests.yml                      # CI: full bin/tests suite on macos-latest (every PR + main)
├── hooks/                             # Hooks → ~/.claude/hooks/
│   ├── context-threshold-notify.py    #   Stop: macOS notification at 128K tokens
│   ├── stop-notify.sh  session-start-sync.sh  handoff-resume.sh
│   ├── block-dangerous-git.sh         #   PreToolUse: git secret-scan
│   ├── block-browser-mutations.sh     #   PreToolUse: browser Zone-3 blocklist
│   ├── supply-chain-guard.sh          #   PreToolUse: install-command gate
│   └── sync-telemetry-log.sh          #   DoD/test-spec telemetry append-log
├── agents/
│   └── test-runner.md                 #   Proactive test runner (read-mostly)
└── docs/adr/                          # Architecture Decision Records
    ├── 0001-adopt-graphify-sunset-llm-wiki.md
    └── 0002-supply-chain-cooldown-gate.md
```

## Syncing Changes

```bash
# Check differences between repo and ~/.claude/
./sync.sh status

# After editing commands/skills in ~/.claude/, back up to the repo
./sync.sh backup
git add -A && git commit -m "Update commands/skills" && git push

# After git pull (changes from another machine), install to ~/.claude/
./sync.sh install
```

## Project-Specific Command Overrides

The commands shipped by dotclaude are deliberately generic — they have to work across any stack, any repo, any objective. When a specific project needs extra steps that don't belong in the global flow, the right move is a **local override**, not a branch in the global command.

Claude Code resolves slash commands in this order:

```
<repo>/.claude/commands/<name>.md   ← project override (wins)
~/.claude/commands/<name>.md         ← global (dotclaude)
```

Any `<name>.md` placed under a project's `.claude/commands/` replaces the global one while you're inside that repo. The global stays clean and portable.

**Worked example — post-merge Shopify theme push.** The [`storefront`](https://github.com/acme-org/storefront) Shopify-theme repo has a two-way sync with the Shopify CDN: merging a PR in GitHub does *not* automatically update the theme DB, and the next `shopify[bot]` sync can silently revert the PR (this actually happened — PR #58 was reverted by commit `c5ca2f4`). The fix is a post-merge `shopify theme push --nodelete`, but only when the diff touches files the platform serializes (`config/settings_data.json`, `snippets/*.liquid`, `sections/*.liquid`, `templates/page.*.json`).

That logic is specific to one repo, one theme ID, one store — so it lives in `<storefront>/.claude/commands/commit-push-pr.md` as an override of `/commit-push-pr`. The override reuses the global steps verbatim and inserts the theme push after the merge step. The global `/commit-push-pr` in this repo stays free of Shopify references.

**Rule of thumb:** if extra steps reference hardcoded IDs, specific domains, or platform integrations that only exist in one repo, override locally. If they're about how Claude should reason (planning discipline, review rigor, testing), they belong in the global command or in `CLAUDE.md`.

## Prerequisites for Adversarial Research

The `/adversarial-research` command requires API keys from three providers as environment variables:

```bash
export GEMINI_API_KEY="..."
export PERPLEXITY_API_KEY="..."
export OPENAI_API_KEY="..."
```

And Python dependencies:
```bash
pip install google-genai openai requests
```

Estimated cost per research session (2 cycles): **~$1.50–4.50**

## Philosophy

This toolkit is built on a simple conviction: **an AI that challenges its own reasoning produces better work than one that doesn't.** The cost of structured planning and adversarial review is minutes. The cost of an unexamined assumption that makes it to production is days.

The protocols here aren't arbitrary ceremony — each one addresses a specific, documented failure mode of LLM-assisted development:

| Failure mode | Mitigation |
|-------------|------------|
| LLM acts on unverified assumptions | Feynman epistemic markers make assumptions visible |
| LLM chains reasoning without grounding | ReAct forces observation between reasoning steps |
| Self-review misses own blind spots | Adversarial review from a separate agent role |
| Same-provider bias in review | Cross-provider research (Gemini + Perplexity + OpenAI) |
| Plans skip straight to code | No production code before adversarial approval |
| Complexity hides behind jargon | Feynman Test: explain mechanism, not just name the pattern |
| Self-review of own code misses introduced bugs | Ralph loop: Claude implements, Codex (different provider) reviews each commit |
| Long implementations drift from the plan | Fresh context per story + `ac_trace` in every commit forces traceability |
| Agents pass their own tests (which they wrote) | TDD RED-before-GREEN + pre-commit hook + test-runner subagent |
| Autonomous loops contaminate the working checkout | Boris parallel checkouts — 5 slots on `main` local, ephemeral branch only at push (`/create-worktree` remains as a legacy isolation fallback) |
| Playwright MCP floods context with a11y trees | CLI-first policy in the `testing` skill; MCP only for explicit cases |
| Docs drift from code as the repo evolves | Graphify AST-derived knowledge graph (`graphify-out/`), refreshed by zero-LLM git hooks |
| Agents write green-but-vacuous tests | DoD → `/test-spec` Gherkin specs → `[bN]` TDD-chain IDs → `/reflect` retrospective |
| A poisoned dependency runs code at install time | Supply-chain guard: 14-day publish cooldown + `--ignore-scripts` + git-url block, fail-closed (Principle 13) |
| Secrets slip into a commit | `block-dangerous-git.sh` secret-scan blocks `commit`/`push` on detected keys / `.env` |
| Irreversible action via browser automation | Browser-as-agent precedence ladder + Zone-3 blocklist (Principle 12) |
| Context lost after compaction or `/clear` | `/handoff-continue` distills a handoff doc + `SessionStart` hook that injects it as silent context (type `continuar` after `/clear` to resume — it never auto-starts) |
| Long sessions hit autocompact mid-task | `Stop` hook fires a macOS notification at 128K tokens (configurable) before the harness compresses |
| A hung worker's `git stash -u` sweeps user WIP | Ralph serial preflight requires a clean tree (framework files excluded, `--allow-dirty` to override); HANG-path stash uses pathspec excludes |
| Independent stories execute serially | `/ralph-adversarial --parallel` — `dependsOn` DAG + `touchesFiles` disjunction gate dispatch stories across pool slots concurrently |
| Parallel tool-use is enabled but never exercised | `bin/parallelism-report.sh` measures Principle 9 adherence per project, grouping `tool_use` by API `message.id` (naive line counting reads a false 0%) |
| The backlog waits for a human dispatcher | `bin/backlog-dispatch.sh` drains a per-repo queue into free slots headless; cost/Zone-3 items stay human-gated; PRs stop open — nothing auto-merges overnight |

## License

MIT
