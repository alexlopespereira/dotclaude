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

| Command | What it does |
|---------|-------------|
| `/planejar [problem]` | Produces a technical plan using the full ReAct + Feynman protocol |
| `/revisar-adversario [plan]` | Red Team review of an existing plan |
| `/ciclo-completo [problem]` | Plans + self-reviews in sequence (both agents) |
| `/adversarial-research [topic]` | Deep research with 3 providers (Gemini + Perplexity + OpenAI) |
| `/research-status` | Lists all research sessions and their status |
| `/research-synthesize [path]` | Synthesizes final report from completed research |
| `/pr` | Creates a Pull Request and auto-merges |
| `/export-report` | Exports the last response as a Markdown file |

### Example: Full Cycle

```
> /ciclo-completo migrate authentication from JWT to session-based tokens

Phase 1 — Planning (ReAct + Feynman)
  Thought #1: I need to understand the current JWT implementation...
  Action #1: Read src/auth/...
  ...
  Plan produced with 3 [ASSUMPTIONS] flagged.

Phase 2 — Adversarial Review
  [ASSUMPTION] "Redis is available in all environments" → REFUTED: staging uses in-memory store.
  Feynman violation: "Use the Adapter pattern" without explaining the mechanism.
  Verdict: APPROVED WITH CAVEATS — 2 items need revision.

Phase 3 — Synthesis
  Immediate actions for next slice listed.
  Human decides whether to proceed.
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
