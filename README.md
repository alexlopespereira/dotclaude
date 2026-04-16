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

The full cycle (`/ciclo-completo`) runs both agents in sequence. For external validation, the plan can also be reviewed by OpenAI Codex as an independent adversary — a different model from a different provider, eliminating correlated bias.

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
| `/planejar` | Planning | Technical plan with ReAct + Feynman |
| `/revisar-adversario` | Review | Red Team attack on an existing plan |
| `/ciclo-completo` | Planning + Review | Both agents in sequence |
| `/adversarial-research` | Research | Deep research with 3 AI providers |
| `/research-status` | Research | Lists all research sessions |
| `/research-synthesize` | Research | Synthesizes a completed research |
| `/pr` | Git workflow | Creates PR and auto-merges |
| `/export-report` | Utility | Exports last response as Markdown |

---

### `/planejar [problem description]`

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
> /planejar migrate the database from MySQL 5.7 to PostgreSQL 16
```

---

### `/revisar-adversario [path to plan or "last plan"]`

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
> /revisar-adversario .claude/plans/migrate-mysql-to-postgres.md
```

---

### `/ciclo-completo [problem description]`

**Purpose:** Runs the full pipeline — planning followed by adversarial self-review — in a single command. This is the recommended way to start any non-trivial task.

**What happens when you run it:**

1. **Phase 1 — Planning:** Claude acts as the Planner Agent, executes the full ReAct cycle, and produces a plan. The plan is saved to `.claude/plans/[slug].md`
2. **Phase 2 — Adversarial Review:** Claude switches to the Adversary Agent role, re-reads the plan with fresh eyes, and attacks it. The review is appended to the same file under a `---` separator
3. **Phase 3 — Synthesis:**
   - If **APPROVED** or **APPROVED WITH CAVEATS**: lists immediate actions for the next implementation slice
   - If **REJECTED**: highlights the 3 most critical issues and escalates to the human. Does **not** attempt to auto-fix — the human decides

**Guardrails:** Maximum 3 review cycles. After 3, the divergence is escalated to the human with a summary. No production code is written before approval.

**Example:**
```
> /ciclo-completo implement real-time notifications with WebSocket

Phase 1 — Planning (ReAct + Feynman)
  Thought #1: I need to understand the current notification system...
  Action #1: Read src/notifications/...
  ...
  Plan produced with 3 [ASSUMPTIONS] flagged.
  Saved to .claude/plans/real-time-notifications-websocket.md

Phase 2 — Adversarial Review
  [ASSUMPTION] "Redis Pub/Sub is available" → REFUTED: staging uses in-memory store.
  Feynman violation: "Use the Observer pattern" without explaining the mechanism.
  Verdict: APPROVED WITH CAVEATS — 2 items need revision.

Phase 3 — Synthesis
  Next slice: implement WebSocket handshake + heartbeat (no business logic yet).
  Human decides whether to proceed.
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

**Purpose:** Creates a Pull Request on GitHub and auto-merges it — a complete git workflow in one command.

**What happens when you run it:**

1. **Checks state:** `git status` to detect uncommitted changes
2. **Commits** if needed (following the repo's commit convention)
3. **Creates branch** if currently on `main` (descriptive name based on changes)
4. **Pushes** the branch to origin
5. **Creates the PR** via `gh pr create` with a structured summary
6. **Waits for CI** checks to pass (if configured), otherwise proceeds
7. **Merges** the PR with `--merge --delete-branch`
8. **Returns to main** and pulls latest

**Guardrails:** If merge fails due to branch protection or pending reviews, it reports the status instead of forcing. The human decides next steps.

**Example:**
```
> /pr

Created branch: fix/update-auth-middleware
Pushed to origin.
PR #42 created: "Fix auth middleware token expiry handling"
CI checks passed.
PR #42 merged. Branch deleted.
Returned to main.
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

## Project Structure

```
dotclaude/
├── CLAUDE.md                          # Global instructions (ReAct + Feynman protocol)
├── WORKFLOW.md                        # Command reference and workflow guide
├── commands/                          # Slash commands (installed to ~/.claude/commands/)
│   ├── planejar.md                    #   /planejar
│   ├── revisar-adversario.md          #   /revisar-adversario
│   ├── ciclo-completo.md              #   /ciclo-completo
│   ├── adversarial-research.md        #   /adversarial-research
│   ├── research-status.md             #   /research-status
│   ├── research-synthesize.md         #   /research-synthesize
│   ├── pr.md                          #   /pr
│   └── export-report.md              #   /export-report
├── skills/                            # Skills (installed to ~/.claude/skills/)
│   ├── react-feynman/SKILL.md         #   ReAct + Feynman templates
│   └── adversarial-research/          #   Multi-provider research
│       ├── SKILL.md
│       └── runner.py
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

## License

MIT
