#!/usr/bin/env bash
# coverage-gate.sh — single coverage tool with two authorities (US-01).
#
# O QUE FAZ
#   Mede cobertura de linha+branch do código de um ciclo e a reporta/bloqueia.
#   Um único script, dois modos com autoridades diferentes (decisão R2 do plano
#   "Objetivo de cobertura 100% por ciclo"):
#
#     --report  (Ralph/loop)  ADVISORY. Roda a suíte com cobertura, computa o
#               diff-coverage vs origin/main e escreve um bloco lido pelo Codex
#               em progress.txt. EXIT 0 SEMPRE — nunca bloqueia o veredicto
#               binário do loop. Se `git fetch` falhar, emite COVERAGE_REPORT_
#               SKIPPED e sai 0 (nunca computa diff contra base velha).
#
#     --gate    (CI)          BLOQUEIO DURO. diff-cover --fail-under=100 no patch
#               + ratchet (cobertura total não pode cair além de ε, lendo
#               .coverage-baseline.json) + checagem conservadora de pragma novo
#               sem justificativa. EXIT != 0 reprova o job. NUNCA auto-commita o
#               baseline (decisão: baseline é atualizado pelo commit do autor).
#
# QUANDO USAR
#   --report: invocado pelo loop Ralph após a implementação de uma story.
#   --gate:   invocado pelo workflow de CI (US-03), required check.
#
# FLUXO PONTA-A-PONTA (--report)
#   pré: estar num checkout git do projeto-alvo; rede p/ `git fetch`.
#   chamada: coverage-gate.sh --report --lang <lang> [--test-cmd ...]
#   encerra: exit 0; bloco coverage-gate em progress.txt.
#
# DEPS (todas injetáveis via seam env var COVERAGE_GATE_<DEP> — pattern vm-doctor)
#   git, diff-cover, coverage, c8, bashcov, kcov. jq/awk são deps base (como nos
#   scripts irmãos validate-prd.sh), usados diretamente.
#
# PER-LINGUAGEM
#   python      coverage run --branch  → coverage lcov   (line+branch)
#   js|ts|liquid c8 --reporter=lcovonly                   (line+branch via V8)
#   bash        bashcov (line-only; branch=n/a — §R3-gaps) | kcov (fallback)
#
# [SUPOSIÇÃO validada] bashcov entrega LINE coverage, não branch (SimpleCov
#   branch é Ruby-only). O relatório declara branch=n/a quando o lcov não tem
#   registros BRF (branches found) — regra GERAL, não hardcode p/ bash: se um
#   bashcov futuro emitir BRF>0, o branch% real aparece automaticamente (AC9).
#
# NOTA pragma: o --gate faz uma checagem CONSERVADORA (marcador no fim da linha,
#   sem texto após = violação). A política rica de pragma (P1) mora na dimensão
#   COVERAGE do Codex (US-05); aqui é só um backstop determinístico.

set -u

# ─── usage / die ───────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'USAGE'
Usage: coverage-gate.sh (--report|--gate) --lang <python|js|ts|bash|liquid> [opts]

Modes (exactly one required):
  --report            Advisory: write coverage block to progress.txt, exit 0 always.
  --gate              CI gate: diff-cover --fail-under=100 + ratchet + pragma; exit!=0 on fail.

Options:
  --lang <lang>       Language: python|js|ts|bash|liquid (required).
  --test-cmd <cmd>    Test command run under coverage (per-lang default otherwise).
  --report-dir <dir>  Where lcov report is written (default: a fresh temp dir).
  --progress-file <p> Progress file for --report (default: progress.txt).
  --baseline <p>      Ratchet baseline JSON for --gate (default: .coverage-baseline.json).
  --epsilon <n>       Ratchet tolerance, 0..100 (default: 0.5).
  --base <ref>        Compare branch (default: origin/main).
  --bash-tool <t>     bashcov|kcov|auto for --lang bash (default: auto).
  -h, --help          Show this help.
USAGE
}
die_usage() { [ -n "${1:-}" ] && echo "ERROR: $1" >&2; usage; exit 2; }

# ─── dep resolution: seam override > PATH > ~/.local/bin (cat-9-base b5/b8) ──
# rc=127 (binary absent) must never be read as a configuration state: a missing
# dep returns 1 from resolve_dep so callers branch explicitly.
resolve_dep() {
    # $1 = seam override (may be empty), $2 = default bin name
    local override="$1" bin="$2" cand p
    for cand in "$override" "$bin"; do
        [ -z "$cand" ] && continue
        if [ -x "$cand" ]; then printf '%s' "$cand"; return 0; fi
        if p=$(command -v "$cand" 2>/dev/null); then printf '%s' "$p"; return 0; fi
    done
    if [ -x "$HOME/.local/bin/$bin" ]; then printf '%s' "$HOME/.local/bin/$bin"; return 0; fi
    return 1
}

# ─── numeric validation: form AND range BEFORE arithmetic (cat-9-base b4) ────
# A giant value must fail validation here, never reach awk/comparison as a
# "happy path".
is_num_in_range() {
    # $1 = value, $2 = max (inclusive). Form: integer or decimal, no sign.
    local v="$1" max="$2"
    case "$v" in
        ''|*[!0-9.]*) return 1 ;;          # only digits and dot
    esac
    # exactly zero or one dot
    case "$v" in *.*.*) return 1 ;; esac
    case "$v" in .|*.) return 1 ;; esac    # reject "." and trailing dot
    # range check via awk (string-safe, no bash integer overflow). LC_ALL=C
    # forces a '.' decimal separator so comma-decimal locales cannot corrupt it.
    LC_ALL=C awk -v x="$v" -v m="$max" 'BEGIN{ exit !(x+0 >= 0 && x+0 <= m) }'
}

# ─── lcov parser: echoes "line_pct branch_pct"; branch_pct may be "n/a" ──────
parse_lcov() {
    # $1 = lcov path. Aggregates LF/LH/BRF/BRH across all records.
    [ -f "$1" ] || { echo "0.00 n/a"; return 0; }
    # LC_ALL=C: '.' decimal separator regardless of host locale.
    LC_ALL=C awk '
        /^LF:/  { lf  += substr($0,4) }
        /^LH:/  { lh  += substr($0,4) }
        /^BRF:/ { brf += substr($0,5) }
        /^BRH:/ { brh += substr($0,5) }
        END {
            lp = (lf > 0) ? (lh/lf)*100 : 0
            if (brf > 0) printf "%.2f %.2f\n", lp, (brh/brf)*100
            else         printf "%.2f n/a\n", lp
        }
    ' "$1"
}

# ─── idempotent progress block writer (cat-9-base b7) ────────────────────────
write_progress_block() {
    # $1 = progress file; remaining args = body lines. Replaces any existing
    # coverage-gate block (begin..end) so re-runs converge to one block.
    local pf="$1"; shift
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/covgate-prog.XXXXXXXX") || return 1
    if [ -f "$pf" ]; then
        awk '
            /<!-- coverage-gate:begin -->/ { skip=1 }
            skip==0 { print }
            /<!-- coverage-gate:end -->/   { skip=0 }
        ' "$pf" > "$tmp"
    fi
    {
        printf '%s\n' '<!-- coverage-gate:begin -->'
        local line
        for line in "$@"; do printf '%s\n' "$line"; done
        printf '%s\n' '<!-- coverage-gate:end -->'
    } >> "$tmp"
    mv -f "$tmp" "$pf"
}

# ─── default test command per language ──────────────────────────────────────
default_test_cmd() {
    case "$1" in
        python)        echo "-m pytest" ;;   # carries -m so a non-module --test-cmd works
        js|ts|liquid)  echo "npm test" ;;
        bash)          echo "bin/tests/run-all.sh" ;;
        *)             echo "" ;;
    esac
}

# ─── produce lcov report for $COV_LANG into a known path; echoes the path ────────
# Returns 1 (and prints nothing) when the required coverage tool is unavailable.
# Side effect: writes the TEST RUNNER's exit code to "$rd/.runner-rc" so the
# caller can tell a failing suite apart from a passing one. produce_report runs
# in a command-substitution subshell, so this filesystem seam (not a global var)
# is the only reliable way to surface the runner rc — a global would be lost.
# Rationale: `>/dev/null 2>&1 || true` must NOT swallow a non-zero runner; a
# stale/partial lcov that still satisfies diff-cover/ratchet would otherwise let
# --gate pass on a red suite.
produce_report() {
    local rd="$1" lcov bin bin2 found
    mkdir -p "$rd"
    case "$COV_LANG" in
        python)
            bin=$(resolve_dep "${COVERAGE_GATE_COVERAGE:-}" coverage) || return 1
            lcov="$rd/lcov.info"
            # -m is carried by TEST_CMD (default "-m pytest"); a script/pipeline
            # --test-cmd is therefore not force-wrapped in -m (P2 fix).
            # shellcheck disable=SC2086  # TEST_CMD is intentionally word-split
            "$bin" run --branch $TEST_CMD >/dev/null 2>&1; printf '%s' "$?" > "$rd/.runner-rc"
            "$bin" lcov -o "$lcov" >/dev/null 2>&1 || true
            printf '%s' "$lcov"
            ;;
        js|ts|liquid)
            bin=$(resolve_dep "${COVERAGE_GATE_C8:-}" c8) || return 1
            lcov="$rd/lcov.info"
            # shellcheck disable=SC2086  # TEST_CMD is intentionally word-split
            "$bin" --reporter=lcovonly --report-dir="$rd" -- $TEST_CMD >/dev/null 2>&1; printf '%s' "$?" > "$rd/.runner-rc"
            printf '%s' "$lcov"
            ;;
        bash)
            lcov="$rd/lcov.info"
            if [ "$BASH_TOOL" != "kcov" ] && bin=$(resolve_dep "${COVERAGE_GATE_BASHCOV:-}" bashcov); then
                # bashcov writes ./coverage/lcov.info (CWD-relative SimpleCov).
                # Relocate to the ABSOLUTE $rd so the returned path is CWD-
                # independent (P1-4: relative path was the vacuous-pass vector).
                # shellcheck disable=SC2086  # TEST_CMD is intentionally word-split
                "$bin" -- $TEST_CMD >/dev/null 2>&1; printf '%s' "$?" > "$rd/.runner-rc"
                [ -f coverage/lcov.info ] && cp coverage/lcov.info "$lcov"
            elif bin2=$(resolve_dep "${COVERAGE_GATE_KCOV:-}" kcov); then
                # kcov fallback (Linux CI). kcov writes a merged lcov tree under
                # the out dir; locate any *.info and normalize to $rd/lcov.info.
                # Best-effort path — the --gate non-empty-lcov guard catches a miss.
                # shellcheck disable=SC2086  # TEST_CMD is intentionally word-split
                "$bin2" --output-interface=lcov "$rd/kcov-out" $TEST_CMD >/dev/null 2>&1; printf '%s' "$?" > "$rd/.runner-rc"
                found=$(find "$rd/kcov-out" -name '*.info' 2>/dev/null | head -1)
                [ -n "$found" ] && cp "$found" "$lcov"
            else
                return 1
            fi
            printf '%s' "$lcov"
            ;;
        *)
            return 1
            ;;
    esac
}

# ─── conservative new-pragma check (gate backstop) ───────────────────────────
# A coverage pragma marker at end-of-line (no justification text after it) on an
# ADDED diff line is a violation. Markers ending in block-comment syntax (c8) are
# intentionally not matched here (handled by Codex COVERAGE dimension, US-05).
pragma_violations() {
    local git_bin diff
    git_bin=$(resolve_dep "${COVERAGE_GATE_GIT:-}" git) || return 0
    diff=$("$git_bin" diff "${BASE_REF}...HEAD" 2>/dev/null) || return 0
    printf '%s\n' "$diff" \
        | grep -E '^\+' \
        | grep -Ei '(pragma:[[:space:]]*no[[:space:]]+cover|:nocov:)[[:space:]]*$' || true
}

# ─── arg parse ──────────────────────────────────────────────────────────────
MODE=""
COV_LANG=""
TEST_CMD=""
REPORT_DIR=""
PROGRESS_FILE="progress.txt"
BASELINE_FILE=".coverage-baseline.json"
EPSILON="0.5"
BASE_REF="origin/main"
BASH_TOOL="auto"

while [ $# -gt 0 ]; do
    case "$1" in
        --report) [ -n "$MODE" ] && die_usage "modes are mutually exclusive"; MODE="report" ;;
        --gate)   [ -n "$MODE" ] && die_usage "modes are mutually exclusive"; MODE="gate" ;;
        --lang)         COV_LANG="${2:-}"; shift ;;
        --test-cmd)     TEST_CMD="${2:-}"; shift ;;
        --report-dir)   REPORT_DIR="${2:-}"; shift ;;
        --progress-file) PROGRESS_FILE="${2:-}"; shift ;;
        --baseline)     BASELINE_FILE="${2:-}"; shift ;;
        --epsilon)      EPSILON="${2:-}"; shift ;;
        --base)         BASE_REF="${2:-}"; shift ;;
        --bash-tool)    BASH_TOOL="${2:-}"; shift ;;
        -h|--help)      usage; exit 0 ;;
        --*)            die_usage "unknown flag '$1'" ;;
        *)              die_usage "unexpected argument '$1'" ;;
    esac
    shift
done

[ -z "$MODE" ] && die_usage "exactly one of --report / --gate is required"
case "$COV_LANG" in
    python|js|ts|bash|liquid) ;;
    "") die_usage "--lang is required" ;;
    *)  die_usage "unsupported --lang '$COV_LANG'" ;;
esac
case "$BASH_TOOL" in auto|bashcov|kcov) ;; *) die_usage "--bash-tool must be auto|bashcov|kcov" ;; esac
# Numeric form+range validation BEFORE any arithmetic (cat-9-base b4).
is_num_in_range "$EPSILON" 100 || die_usage "--epsilon must be a number in [0,100] (got '$EPSILON')"

[ -z "$TEST_CMD" ] && TEST_CMD="$(default_test_cmd "$COV_LANG")"
if [ -z "$REPORT_DIR" ]; then
    REPORT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/covgate-rd.XXXXXXXX") || exit 1
fi

# ─── MODE: --report (advisory, exit 0 always) ────────────────────────────────
if [ "$MODE" = "report" ]; then
    # 1. Fetch base FIRST; a fetch failure must not produce a diff vs stale base.
    #    A "remote/branch" base (origin/main) is fetched; a no-slash base (main)
    #    is a LOCAL ref and must NOT be turned into `git fetch main main` (P1-6).
    git_bin=$(resolve_dep "${COVERAGE_GATE_GIT:-}" git) || git_bin=""
    fetch_ok=1
    if [ -z "$git_bin" ]; then
        fetch_ok=0
    elif printf '%s' "$BASE_REF" | grep -q '/'; then
        base_remote="${BASE_REF%%/*}"
        base_branch="${BASE_REF#*/}"
        "$git_bin" fetch "$base_remote" "$base_branch" >/dev/null 2>&1 || fetch_ok=0
    fi
    if [ "$fetch_ok" = "0" ]; then
        write_progress_block "$PROGRESS_FILE" \
            "COVERAGE_LANG=$COV_LANG" \
            "COVERAGE_REPORT_SKIPPED=fetch-failed (base $BASE_REF unreachable)"
        echo "COVERAGE_REPORT_SKIPPED=fetch-failed"
        exit 0
    fi

    # 2. Produce the coverage report.
    lcov_path=$(produce_report "$REPORT_DIR") || {
        write_progress_block "$PROGRESS_FILE" \
            "COVERAGE_LANG=$COV_LANG" \
            "COVERAGE_REPORT_SKIPPED=tool-unavailable ($COV_LANG coverage tool not found)"
        echo "COVERAGE_REPORT_SKIPPED=tool-unavailable"
        exit 0
    }

    # 3. Diff-coverage via diff-cover (parse "Coverage: NN%").
    diff_pct="n/a"
    dc_bin=$(resolve_dep "${COVERAGE_GATE_DIFF_COVER:-}" diff-cover) || dc_bin=""
    if [ -n "$dc_bin" ]; then
        dc_out=$("$dc_bin" "$lcov_path" --compare-branch="$BASE_REF" 2>/dev/null || true)
        # Capture integer OR decimal percent (P2-7: "Coverage: 66.7%" was dropped
        # by an integer-only pattern, collapsing the advisory number to n/a).
        diff_pct=$(printf '%s\n' "$dc_out" | sed -n 's/.*Coverage:[[:space:]]*\([0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\)%.*/\1/p' | head -1)
        [ -z "$diff_pct" ] && diff_pct="n/a"
    fi

    # 4. Branch% from the local lcov (n/a when no branch data — §R3-gaps / AC9).
    read -r _line_pct branch_pct <<EOF
$(parse_lcov "$lcov_path")
EOF
    # n/a stays bare (NOT 0%); a real number gets a % suffix.
    if [ "$branch_pct" = "n/a" ]; then branch_disp="n/a"; else branch_disp="${branch_pct}%"; fi

    write_progress_block "$PROGRESS_FILE" \
        "COVERAGE_LANG=$COV_LANG" \
        "COVERAGE_BASE=$BASE_REF" \
        "COVERAGE_DIFF=${diff_pct}%" \
        "COVERAGE_BRANCH=${branch_disp}" \
        "COVERAGE_BRANCH_NOTE=branch from total lcov; n/a means tool reports line-only"
    echo "COVERAGE_DIFF=${diff_pct}%  COVERAGE_BRANCH=${branch_disp}"
    exit 0
fi

# ─── MODE: --gate (hard block) ───────────────────────────────────────────────
fail=0

# 1. Produce the coverage report (no fetch — CI checkout already has refs).
lcov_path=$(produce_report "$REPORT_DIR") || {
    echo "ERROR: could not produce coverage report for --lang $COV_LANG (tool missing)" >&2
    exit 1
}

# 1b. Test runner must have passed. A non-zero runner is NOT swallowed: even a
#     valid lcov that would satisfy diff-cover/ratchet fails the gate on a red
#     suite. --report stays advisory and ignores this (exit 0 always).
runner_rc=$(cat "$REPORT_DIR/.runner-rc" 2>/dev/null || echo 0)
if [ "$runner_rc" != "0" ]; then
    echo "GATE_FAIL: test runner exited $runner_rc (suite failed under coverage)" >&2
    fail=1
fi

# 1c. The lcov must EXIST and be NON-EMPTY. A missing/empty report makes
#     diff-cover find no measured lines and exit 0 — i.e. --fail-under=100
#     passes vacuously and an uncovered patch is approved (P1-5). Fail closed.
if [ ! -s "$lcov_path" ]; then
    echo "GATE_FAIL: coverage report empty/missing ($lcov_path) — refusing vacuous pass" >&2
    fail=1
fi

# 2. Patch coverage gate: diff-cover --fail-under=100.
dc_bin=$(resolve_dep "${COVERAGE_GATE_DIFF_COVER:-}" diff-cover) || {
    echo "ERROR: diff-cover not found (seam COVERAGE_GATE_DIFF_COVER)" >&2
    exit 1
}
if ! "$dc_bin" "$lcov_path" --compare-branch="$BASE_REF" --fail-under=100; then
    echo "GATE_FAIL: patch coverage below 100% (diff-cover --fail-under=100)" >&2
    fail=1
fi

# 3. Ratchet: total must not fall below baseline-epsilon. Baseline is READ-ONLY
#    here — never auto-committed (decision: author's commit updates it).
if [ -f "$BASELINE_FILE" ]; then
    baseline=$(jq -r '.total // empty' "$BASELINE_FILE" 2>/dev/null)
    if [ -z "$baseline" ] || ! is_num_in_range "$baseline" 100; then
        echo "ERROR: $BASELINE_FILE has no valid numeric .total (got '$baseline')" >&2
        exit 1
    fi
    read -r current_line _branch <<EOF
$(parse_lcov "$lcov_path")
EOF
    if LC_ALL=C awk -v c="$current_line" -v b="$baseline" -v e="$EPSILON" 'BEGIN{ exit !(c+0 < (b+0) - (e+0)) }'; then
        echo "GATE_FAIL: ratchet — total ${current_line}% < baseline ${baseline}% - ε ${EPSILON}" >&2
        fail=1
    fi
else
    echo "NOTE: $BASELINE_FILE absent; ratchet check skipped" >&2
fi

# 4. Conservative new-pragma backstop.
pv=$(pragma_violations)
if [ -n "$pv" ]; then
    echo "GATE_FAIL: new coverage pragma without justification:" >&2
    printf '  %s\n' "$pv" >&2
    fail=1
fi

exit "$fail"
