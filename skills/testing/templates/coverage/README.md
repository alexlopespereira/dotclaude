# Coverage templates (per language)

Provisioned by `/coverage-init` (`bin/coverage-init.sh`). One config file per
language is copied into the target project root so that the local coverage tool
emits an **lcov** report that `skills/ralph-adversarial/lib/coverage-gate.sh`
can consume in both `--report` (advisory) and `--gate` (CI block) modes.

| Language | Template            | Copied to        | Tool                         |
|----------|---------------------|------------------|------------------------------|
| Python   | `python/.coveragerc`| `.coveragerc`    | `coverage.py --branch`       |
| JS/TS    | `js/.c8rc.json`     | `.c8rc.json`     | `c8 >= 9` (V8 line+branch)   |
| bash     | `bash/.simplecov`   | `.simplecov`     | `bashcov` (line-only) / `kcov` |
| Liquid   | `liquid/.c8rc.json` | `.c8rc.json`     | `liquid.js` harness + `c8`   |

## Notes

- **bash is line-only.** SimpleCov branch coverage is Ruby-only, so the bash
  report declares `branch=n/a` (NOT 0%) — see `coverage-gate.sh` §R3-gaps / AC9.
  `kcov` is the Linux-CI fallback; it is fragile on macOS hosts, so the host run
  records whether `kcov` is available and degrades to `bashcov` line-only.
- **Thresholds live in the gate, not the tool config.** `c8`/`coverage.py` are
  configured to *emit lcov*, not to self-fail; the 100%-of-diff authority is
  `coverage-gate.sh --gate` (via `diff-cover --fail-under=100`) plus the ratchet.
- The CI workflow template (`coverage-ci.yml`) is produced by US-03 and copied by
  `/coverage-init` when present.
