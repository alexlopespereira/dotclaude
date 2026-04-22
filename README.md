# dotclaude

Global commands, skills and protocols for [Claude Code](https://claude.ai/code) that turn your AI assistant into a disciplined engineering partner — one that plans before coding, attacks its own ideas, and never ships unchallenged assumptions.

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

> **Why it matters:** LLMs naturally optimize for "the test passes," not "the test catches defects." Making the failure-first cycle structural — RED before GREEN, hook before commit, subagent after every change — is the only way to keep the suite honest.

### Bonus: LLM Wiki Bootstrap

Docs rot the moment they leave the writer's head. The usual fix — RAG on top of raw source — is stateless: every question re-derives context from scratch and throws the synthesis away. The **LLM Wiki** pattern (inspired by [Karpathy's gist](https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f)) flips this: an agent **writes and maintains a persistent Markdown wiki** as the repo evolves, so each question starts from pre-compiled knowledge — not re-discovered raw files.

`bootstrap/llm-wiki/` is a drop-in template that installs this system in any repo:

```
repo-alvo/
├── src/                              # immutable for the agent
├── wiki/
│   ├── index.md                      # catalog / routing
│   ├── log.md                        # audit log of every intervention
│   ├── entidades/                    # one page per module — the WHAT
│   ├── conceitos/                    # transversal patterns
│   ├── decisoes/                     # ADRs extracted from PRs — the WHY
│   └── contradicoes/                 # open items needing human review
├── AGENTS.md                         # inviolable protocol (6 rules)
├── wiki-lint.py                      # validates frontmatter + staleness via git log
└── .github/workflows/wiki-update.yml # triggers on PR merged
```

The autonomous cycle:

```
PR merged in main
     │
     ▼
GitHub Actions — anthropics/claude-code-action with CLAUDE_CODE_OAUTH_TOKEN
     │
     ▼
Extracts PR context (title, body, reviews, comments, files)
     │
     ▼
Claude Code (Opus 4.7 via subscription) reads AGENTS.md + pr-context.json
     │
     ▼
Updates wiki/entidades/ (what changed), wiki/decisoes/ (why, when ADR heuristics match)
     │
     ▼
python wiki-lint.py --fix
     │
     ▼
Commit wiki/ back to main with [skip-wiki]
```

**The guardrails that prevent the usual failure modes:**

| Failure mode | Mitigation in the bootstrap |
|-------------|----------------------------|
| Agent corrupts source code | `AGENTS.md` rule 1: `src/` is read-only. Workflow commits only `wiki/` paths. |
| Pages lie about the code (staleness) | Every page has YAML frontmatter with `source_files` + `last_verified_commit`. `wiki-lint.py` runs `git diff <sha>..HEAD` on those paths — if they changed and `confidence: high`, CI fails. |
| Agent hallucinates file paths | Lint validates every `source_files` entry exists on disk. |
| Confident fabrication | `confidence: high \| medium \| low` is required. `--fix` mode auto-downgrades stale `high` to `medium`. |
| Knowledge silently deleted | Rule 4: pages are never deleted. Obsolete content is marked `superseded_by:` with the commit SHA that replaced it. |
| Loop of workflow triggering itself | Auto-commit includes `[skip-wiki]` in the title; workflow ignores those PRs. |
| Conflicts in wiki/ block delivery | Agent has authority to resolve `wiki/*` merge conflicts semantically (logged). Conflicts in `src/*` still escalate to human. |

**Uses the Claude Max subscription, not the paid API.** The GitHub Action consumes the OAuth token generated by `claude setup-token` — no `ANTHROPIC_API_KEY` billing. One wiki update per PR is well inside the Max rate limits.

**Install in a target repo:**

```bash
/caminho/para/dotclaude/bootstrap/llm-wiki/install.sh /caminho/do/repo-alvo

# one-time per machine (token is reusable across all your repos):
claude setup-token
gh secret set CLAUDE_CODE_OAUTH_TOKEN

# initial bootstrap (manual, uses your subscription, zero marginal cost):
claude -p "Leia todo src/ e popule wiki/ seguindo AGENTS.md"
python wiki-lint.py
git add AGENTS.md wiki-lint.py .github/workflows/wiki-update.yml wiki/ && git commit -m "feat: install LLM Wiki system"
```

Re-running with `install.sh <repo> --update` overwrites the protocol/lint/workflow files but **never** touches `wiki/` — the content is always repo-specific.

> **Why it matters:** The real risk with AI-generated docs isn't hallucination — it's **staleness**. Without a structural link from each doc back to the source files and the commits that verified them, wikis become fiction in weeks. Making `source_files` + `last_verified_commit` mandatory, and checking them in CI on every PR, is the cheapest way to keep the knowledge base actually true.

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
| `/plan` | Planning | Technical plan with ReAct + Feynman |
| `/adversarial-review` | Review | Red Team attack on an existing plan |
| `/full-planning-cycle` | Planning + Review | Both agents in sequence (no execution) |
| `/full-cycle` | End-to-end delivery | Worktree + plan + review + PRD + Ralph + PR/merge + cleanup |
| `/worktree-start` | Git workflow | Creates isolated git worktree at `~/Projects/worktrees/` |
| `/worktree-cleanup` | Git workflow | Removes worktree after merge (with safety checks) |
| `/adversarial-research` | Research | Deep research with 3 AI providers |
| `/research-status` | Research | Lists all research sessions |
| `/research-synthesize` | Research | Synthesizes a completed research |
| `/pr` | Git workflow | Creates PR, auto-merges, and offers worktree cleanup |
| `/export-report` | Utility | Exports last response as Markdown |
| `/prd-convert` | Implementation | Converts an approved plan into prd.json (Ralph format) |
| `/ralph-adversarial` | Implementation | Runs the Ralph loop with Codex code review |
| `/e2e` | Testing | Generates or runs Playwright E2E tests for a flow |

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

**Purpose:** Runs the complete end-to-end delivery pipeline — creates an isolated git worktree, plans, reviews, converts to PRD, executes Ralph Adversarial, runs tests, opens and merges a PR, and finally removes the worktree. All production work happens in isolation from the main checkout.

**What happens when you run it:**

1. **Phase 0 — Worktree:** derives a slug from the description and creates `~/Projects/worktrees/<repo>-<slug>` with a new branch based on `origin/main`. All subsequent phases operate inside this path
2. **Phase 1 — Planning:** Claude acts as the Planner Agent, executes the full ReAct cycle, and saves a plan to `<worktree>/.claude/plans/<slug>.md`
3. **Phase 2 — Adversarial Review:** Claude switches to the Adversary Agent role, re-reads the plan with fresh eyes, and attacks it. The review is appended to the same file under a `---` separator
4. **Phase 3 — Approval gate:**
   - **APPROVED** → proceeds to PRD
   - **APPROVED WITH CAVEATS** → asks the human whether to proceed
   - **REJECTED** → stops. Worktree is preserved for human review
5. **Phase 4 — PRD conversion:** slices the plan into `<worktree>/prd.json` following the `prd` skill rules
6. **Phase 5 — Ralph Adversarial:** runs the implementation loop (Claude implements, Codex reviews) inside the worktree until all stories pass or the budget is exhausted
7. **Phase 6 — Final tests:** runs the project test suite inside the worktree; fails here stop the flow (no PR opened)
8. **Phase 7 — PR + Merge:** pushes the branch, opens a PR, waits for CI, merges with `--delete-branch`
9. **Phase 8 — Cleanup:** removes the worktree and deletes the local branch. Returns to the main repo

**Guardrails:** No production code is written before adversarial approval. The worktree is **preserved** on any interruption (rejection, escalated stories, P0 findings, failing tests, blocked merge) — it is only removed after Phase 7 succeeds. For planning-only without execution or PR, use `/full-planning-cycle`.

**Example:**
```
> /full-cycle implement real-time notifications with WebSocket

Phase 0 — Worktree
  Created ~/Projects/worktrees/myapp-realtime-notifications-websocket
  Branch: realtime-notifications-websocket (from origin/main)

Phase 1 — Planning (ReAct + Feynman)
  ...
  Plan saved to .claude/plans/realtime-notifications-websocket.md

Phase 2 — Adversarial Review
  Verdict: APPROVED WITH CAVEATS — proceed? y

Phase 4 — PRD with 4 stories
Phase 5 — Ralph: 4/4 passed (Codex verdicts: MERGE MERGE MERGE MERGE)
Phase 6 — Tests green
Phase 7 — PR #128 merged
Phase 8 — Worktree removed, branch deleted. Back on main.
```

---

### `/worktree-start <slug> [base-branch]`

**Purpose:** Creates an isolated git worktree so feature work never pollutes the main checkout.

**What happens when you run it:**

1. Validates the slug (`^[a-z0-9][a-z0-9-]*$`) and that the base branch exists
2. Fetches `origin/<base>` (default `main`) to ensure the worktree starts from the latest remote state
3. Creates `~/Projects/worktrees/<repo-name>-<slug>` with a new branch `<slug>`
4. Reports the path so subsequent work (`cd`, `git -C`, file operations) targets it

**Layout convention:** all worktrees live under `~/Projects/worktrees/` and are named `<repo-name>-<slug>` to disambiguate across repos.

**Guardrails:** refuses to overwrite an existing worktree path (use `/worktree-cleanup` first). Never creates a worktree on top of uncommitted changes in the source branch without warning.

**Example:**
```
> /worktree-start fix-auth-bug

Worktree created:
  path:   /Users/you/Projects/worktrees/myapp-fix-auth-bug
  branch: fix-auth-bug
  base:   main
```

---

### `/worktree-cleanup [path-or-slug] [--force]`

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
> /worktree-cleanup fix-auth-bug

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

### `/pr`

**Purpose:** Creates a Pull Request on GitHub, auto-merges it, and offers to clean up the worktree if you're working inside one — a complete git workflow in one command.

**What happens when you run it:**

1. **Checks state:** `git status` to detect uncommitted changes; detects whether the cwd is inside `~/Projects/worktrees/`
2. **Commits** if needed (following the repo's commit convention)
3. **Creates branch** if currently on `main` (descriptive name based on changes)
4. **Pushes** the branch to origin
5. **Creates the PR** via `gh pr create` with a structured summary
6. **Waits for CI** checks to pass (if configured), otherwise proceeds
7. **Merges** the PR with `--merge --delete-branch`
8. **Returns** to the main repo and pulls latest (resolves the main checkout via `git-common-dir` when called from a worktree)
9. **Offers cleanup** when the run started inside a worktree: prompts before running `git worktree remove` + `git worktree prune` + local-branch delete

**Guardrails:** If merge fails due to branch protection or pending reviews, it reports the status and **stops** — no cleanup is attempted on a failed merge. Never touches the worktree without explicit confirmation.

**Example:**
```
> /pr

Detected worktree: ~/Projects/worktrees/myapp-fix-auth
Created branch: fix-auth
Pushed to origin.
PR #42 created: "Fix auth middleware token expiry handling"
CI checks passed. PR #42 merged. Branch deleted on remote.
Returned to main repo.
Remove worktree ~/Projects/worktrees/myapp-fix-auth? (Y/n) y
Worktree removed. Local branch deleted.
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

### `/ralph-adversarial [max_iterations, default 10]`

**Purpose:** Runs an autonomous implementation loop: Claude Code implements one user story per iteration with a fresh context window, and OpenAI Codex reviews every commit using a strict code-review rubric.

**What happens when you run it:**

1. Verifies prerequisites: `prd.json` at the repo root, `jq`, `claude` CLI, `codex` CLI, and the rubric at `~/.claude/skills/ralph-adversarial/CODE_REVIEW.md`
2. If `prd.json` doesn't exist but an approved plan does, it offers to run `/prd-convert` first
3. Creates (or checks out) the branch declared in `prd.json` → `branchName`
4. Iterates until all stories pass or `max_iterations` is reached:
   - **(A) Claude Code** spawns with a fresh context, reads `prd.json`, `progress.txt`, and recent git history, picks the next pending story (lowest priority number), implements it, runs project quality checks, and commits with an `ac_trace` block in the commit message
   - **(B) Codex** is spawned to review the diff against the rubric in `CODE_REVIEW.md` and produces a JSON verdict: `MERGE`, `REQUEST_CHANGES`, or `BLOCK`
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

**Prerequisites:** OpenAI Codex CLI installed and authenticated (`codex` in PATH), plus `jq`.

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
├── CLAUDE.md                          # Global instructions (ReAct + Feynman protocol)
├── WORKFLOW.md                        # Command reference and workflow guide
├── commands/                          # Slash commands (installed to ~/.claude/commands/)
│   ├── plan.md                        #   /plan
│   ├── adversarial-review.md          #   /adversarial-review
│   ├── full-cycle.md                  #   /full-cycle
│   ├── adversarial-research.md        #   /adversarial-research
│   ├── research-status.md             #   /research-status
│   ├── research-synthesize.md         #   /research-synthesize
│   ├── pr.md                          #   /pr
│   ├── worktree-start.md              #   /worktree-start
│   ├── worktree-cleanup.md            #   /worktree-cleanup
│   ├── export-report.md               #   /export-report
│   ├── prd-convert.md                 #   /prd-convert
│   ├── ralph-adversarial.md           #   /ralph-adversarial
│   └── e2e.md                         #   /e2e
├── agents/                            # Subagents (installed to ~/.claude/agents/)
│   └── test-runner.md                 #   Proactive test runner (read-mostly)
├── skills/                            # Skills (installed to ~/.claude/skills/)
│   ├── react-feynman/SKILL.md         #   ReAct + Feynman templates
│   ├── adversarial-research/          #   Multi-provider research
│   │   ├── SKILL.md
│   │   └── runner.py
│   ├── prd/SKILL.md                   #   Plan → prd.json conversion rules
│   ├── ralph-adversarial/              #   Implementation loop
│   │   ├── SKILL.md
│   │   ├── CODE_REVIEW.md             #   V2 review rubric (used by Codex)
│   │   └── ralph-adversarial.sh       #   Orchestration script
│   └── testing/                       #   TDD + Playwright discipline
│       ├── SKILL.md
│       └── templates/                 #   Bootstrap files for new projects
│           ├── playwright.config.ts
│           ├── mcp.json
│           ├── settings.hooks.json    #   PreToolUse hook (guarded)
│           └── gitignore.testing
├── bootstrap/                         # Drop-in templates (not installed globally)
│   └── llm-wiki/                      #   LLM Wiki system — copy into any target repo
│       ├── AGENTS.md                  #     inviolable protocol
│       ├── wiki-lint.py               #     frontmatter + staleness validator
│       ├── wiki-update.yml            #     GitHub Actions trigger on PR merged
│       ├── wiki/                      #     template (index.md, log.md)
│       ├── install.sh                 #     ./install.sh <target-repo> [--update]
│       └── README.md
└── sync.sh                            # Sync script (repo ↔ ~/.claude/)
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

**Worked example — post-merge Shopify theme push.** The [`horizons`](https://github.com/aeitauser/horizons) Shopify-theme repo has a two-way sync with the Shopify CDN: merging a PR in GitHub does *not* automatically update the theme DB, and the next `shopify[bot]` sync can silently revert the PR (this actually happened — PR #58 was reverted by commit `c5ca2f4`). The fix is a post-merge `shopify theme push --nodelete`, but only when the diff touches files the platform serializes (`config/settings_data.json`, `snippets/*.liquid`, `sections/*.liquid`, `templates/page.*.json`).

That logic is specific to one repo, one theme ID, one store — so it lives in `<horizons>/.claude/commands/pr.md` as an override of `/pr`. The override reuses steps 1–6 verbatim and inserts step 6.5 (the theme push) between "return to main" and "worktree cleanup". The global `/pr` in this repo stays free of Shopify references.

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
| Autonomous loops contaminate the working checkout | `/full-cycle` runs every delivery inside an isolated git worktree; cleanup is gated on successful merge |
| Playwright MCP floods context with a11y trees | CLI-first policy in the `testing` skill; MCP only for explicit cases |
| Docs drift from code as the repo evolves | LLM Wiki Bootstrap: YAML frontmatter ties every page to `source_files` + `last_verified_commit`; CI fails on stale `high`-confidence claims |

## License

MIT
