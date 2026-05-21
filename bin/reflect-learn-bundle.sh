#!/usr/bin/env bash
set -euo pipefail

# reflect-learn-bundle.sh — Bundle assembly + (optional) LLM workflow for
# /reflect --learn (US-02 desta PR).
#
# Modos:
#   reflect-learn-bundle.sh <PR_NUM> <US_ID>
#     → Emite JSON do bundle no stdout (AC6).
#
#   reflect-learn-bundle.sh <PR_NUM> <US_ID> --with-llm <OUTPUT_DIR>
#     → Monta bundle, invoca `claude --print --max-turns 1` com timeout
#       HARD 600s (AC4), grava raw-llm-output.txt SEMPRE (AC5), parseia
#       jq fail-graceful e produz report.md + proposed.diff + proposal.json
#       em <OUTPUT_DIR> (AC8). Sempre exit 0 quando alcança LLM (fail-soft).
#
# Env overrides (testabilidade):
#   BUNDLE_PRD_PATH         — path para prd.json   (default: ./prd.json)
#   BUNDLE_DOD_PATH         — path para DOD.md     (default: skills/auto-grill-me/references/DOD.md)
#   BUNDLE_SPECS_PATH       — path para TEST-PATTERNS.md
#                              (default: skills/testing/references/TEST-PATTERNS.md)
#   BUNDLE_TEST_GLOB_ROOT   — root pro grep de markers (default: .)
#   BUNDLE_COMMITS_OVERRIDE — texto p/ substituir `gh pr view` (default: usa gh)
#   BUNDLE_CLAUDE_BIN       — path do claude binary (default: claude)
#   BUNDLE_LLM_TIMEOUT_SEC  — override timeout (default: 600)
#
# NÃO escreve refs git. NÃO commita arquivos. Output só em $OUTPUT_DIR + stdout.

usage() {
  sed -n '4,28p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

case "${1:-}" in
  -h|--help) usage 0 ;;
esac

PR_NUM="${1:-}"
US_ID="${2:-}"
[[ -z "$PR_NUM" || -z "$US_ID" ]] && { echo "uso: $(basename "$0") <PR_NUM> <US_ID> [--with-llm <DIR>]" >&2; exit 2; }

WITH_LLM=0
OUT_DIR=""
if [[ "${3:-}" == "--with-llm" ]]; then
  WITH_LLM=1
  OUT_DIR="${4:-}"
  [[ -z "$OUT_DIR" ]] && { echo "--with-llm exige <OUTPUT_DIR>" >&2; exit 2; }
fi

PRD_PATH="${BUNDLE_PRD_PATH:-./prd.json}"
DOD_PATH="${BUNDLE_DOD_PATH:-skills/auto-grill-me/references/DOD.md}"
SPECS_PATH="${BUNDLE_SPECS_PATH:-skills/testing/references/TEST-PATTERNS.md}"
TEST_ROOT="${BUNDLE_TEST_GLOB_ROOT:-.}"
CLAUDE_BIN="${BUNDLE_CLAUDE_BIN:-claude}"
TIMEOUT_SEC="${BUNDLE_LLM_TIMEOUT_SEC:-600}"

command -v jq >/dev/null 2>&1 || { echo "jq não encontrado no PATH" >&2; exit 4; }

# ─── 1) US descrita no prd.json ────────────────────────────────────────────
[[ -f "$PRD_PATH" ]] || { echo "prd.json não encontrado em $PRD_PATH" >&2; exit 5; }
US_JSON="$(jq -c --arg id "$US_ID" '.userStories[]? | select(.id==$id)' "$PRD_PATH")"
[[ -z "$US_JSON" ]] && { echo "US_ID '$US_ID' não existe em $PRD_PATH" >&2; exit 6; }

US_DESC="$(jq -r '.description // ""' <<<"$US_JSON")"
US_TITLE="$(jq -r '.title // ""' <<<"$US_JSON")"

# ─── 2) DoD bullets [bN] do DOD.md (best-effort) ──────────────────────────
DOD_BULLETS_JSON='[]'
if [[ -f "$DOD_PATH" ]]; then
  DOD_BULLETS_JSON="$(
    grep -E '^- \[ \] \[b[0-9]+\] ' "$DOD_PATH" 2>/dev/null \
      | sed -E 's/^- \[ \] \[(b[0-9]+)\] (.*)$/\1\t\2/' \
      | jq -R -s 'split("\n")
                  | map(select(length > 0)
                         | split("\t")
                         | {id: .[0], text: .[1]})' \
      || echo '[]'
  )"
fi

# ─── 3) Specs (tarefa-X-spec-N[-A] OU cat-N-base-spec-N[-A]) do TEST-PATTERNS.md (best-effort) ─────
SPECS_RAW=""
if [[ -f "$SPECS_PATH" ]]; then
  SPECS_RAW="$(
    grep -E '^- \[ \] spec-[^ ]+ \((tarefa-[0-9]+|cat-[0-9]+-base)-spec-[0-9]+(-[A-Z])?\):' "$SPECS_PATH" 2>/dev/null \
      | sed -E 's/^- \[ \] spec-[^ ]+ \(((tarefa-[0-9]+|cat-[0-9]+-base)-spec-[0-9]+(-[A-Z])?)\): (.*)$/\1\t\4/' \
      || true
  )"
fi

# ─── 4) Markers // spec: e # spec: nos testes (best-effort, sem fail) ────
# AC7: `grep -rE '// spec: tarefa-...' tests/ skills/*/bin/test-*.sh` é o
# padrão canônico. Estendemos para `# spec:` (US-03 convenção Python/shell)
# sem quebrar o contrato. Output esperado por linha: "<path>:<lineno>:<matched>".
MARKERS_RAW=""
if [[ -d "$TEST_ROOT" ]]; then
  MARKERS_RAW="$(
    {
      [[ -d "$TEST_ROOT/tests" ]] && \
        grep -rEon '(//|#)[[:space:]]*spec:[[:space:]]*(tarefa-[0-9]+|cat-[0-9]+-base)-spec-[0-9]+(-[A-Z])?' \
          "$TEST_ROOT/tests" 2>/dev/null || true
      ( cd "$TEST_ROOT" 2>/dev/null || exit 0
        shopt -s nullglob 2>/dev/null || true
        for f in skills/*/bin/test-*.sh bin/tests/test_*.sh; do
          [[ -f "$f" ]] || continue
          grep -EonH '(//|#)[[:space:]]*spec:[[:space:]]*(tarefa-[0-9]+|cat-[0-9]+-base)-spec-[0-9]+(-[A-Z])?' "$f" 2>/dev/null || true
        done
      )
    }
  )"
fi

# Indexa markers: id → [path:lineno, ...] via jq (evita awk com -v multiline).
MARKERS_MAP_JSON='{}'
if [[ -n "$MARKERS_RAW" ]]; then
  MARKERS_MAP_JSON="$(
    printf '%s\n' "$MARKERS_RAW" \
      | jq -R -s '
          split("\n")
          | map(select(length > 0))
          | map(capture("^(?<loc>[^:]+:[0-9]+):.*?spec:[[:space:]]*(?<id>(tarefa-[0-9]+|cat-[0-9]+-base)-spec-[0-9]+(-[A-Z])?)"))
          | group_by(.id)
          | map({key: .[0].id, value: ([.[].loc] | unique)})
          | from_entries
        ' 2>/dev/null || echo '{}'
  )"
fi

# Constrói specs[] com test_files derivados dos markers.
SPECS_JSON='[]'
if [[ -n "$SPECS_RAW" ]]; then
  SPECS_JSON="$(
    printf '%s\n' "$SPECS_RAW" \
      | jq -R -s --argjson markers "$MARKERS_MAP_JSON" '
          split("\n")
          | map(select(length > 0))
          | map(split("\t") | {id: .[0],
                                text: .[1],
                                test_files: ($markers[.[0]] // [])})
        '
  )"
fi

# ─── 5) Findings (AC7: tdd_gap_marker_missing para specs sem test_files) ──
FINDINGS_JSON="$(
  jq -c '[ .[] | select(.test_files | length == 0)
                | {type:"tdd_gap_marker_missing", spec_id:.id} ]' <<<"$SPECS_JSON"
)"

# ─── 6) Commits resumo via gh pr view ─────────────────────────────────────
COMMITS_SUMMARY=""
if [[ -n "${BUNDLE_COMMITS_OVERRIDE:-}" ]]; then
  COMMITS_SUMMARY="$BUNDLE_COMMITS_OVERRIDE"
else
  if command -v gh >/dev/null 2>&1; then
    COMMITS_SUMMARY="$(gh pr view "$PR_NUM" --json commits \
      --jq '.commits[]? | "\(.oid[0:7]) \(.messageHeadline // .messageBody // "")"' \
      2>/dev/null | head -50 || true)"
  fi
fi

# ─── 7) Monta bundle JSON canônico (AC6) ──────────────────────────────────
BUNDLE_JSON="$(
  jq -n \
    --arg us_id "$US_ID" \
    --arg title "$US_TITLE" \
    --arg desc "$US_DESC" \
    --argjson bullets "$DOD_BULLETS_JSON" \
    --argjson specs "$SPECS_JSON" \
    --argjson findings "$FINDINGS_JSON" \
    --arg commits "$COMMITS_SUMMARY" \
    '{us_id:$us_id,
      title:$title,
      description:$desc,
      dod_bullets:$bullets,
      specs:$specs,
      findings:$findings,
      results:{},
      commits_summary:$commits}'
)"

# Bundle-only mode (AC6 contract).
if [[ "$WITH_LLM" -eq 0 ]]; then
  printf '%s\n' "$BUNDLE_JSON"
  exit 0
fi

# ─── 8) Modo --with-llm (AC4, AC5, AC8) ───────────────────────────────────
mkdir -p "$OUT_DIR"
RAW_PATH="$OUT_DIR/raw-llm-output.txt"
BUNDLE_FILE="$OUT_DIR/bundle.json"
PROPOSAL_PATH="$OUT_DIR/proposal.json"
REPORT_PATH="$OUT_DIR/report.md"
DIFF_PATH="$OUT_DIR/proposed.diff"

printf '%s\n' "$BUNDLE_JSON" > "$BUNDLE_FILE"

# Prompt one-shot: bundle in, JSON proposal out.
PROMPT="Você é um auditor de DoD/TDD. Recebe um bundle JSON com a US, DoD bullets, specs TDD, e markers de teste de uma PR. Produza UMA resposta APENAS em JSON (sem markdown fences), formato:

{
  \"summary\": \"...uma linha...\",
  \"proposals\": [
    {\"target_file\": \"skills/auto-grill-me/references/DOD.md\", \"action\": \"add_bullet\", \"category_or_task\": \"Tarefa 1\", \"text\": \"novo bullet sugerido\", \"rationale\": \"por que\"}
  ],
  \"findings\": [
    {\"type\": \"<categoria>\", \"detail\": \"...\"}
  ]
}

Bundle:
$BUNDLE_JSON"

# Garante que o raw é gravado SEMPRE (AC5), mesmo se o comando falhar.
: > "$RAW_PATH"
LLM_RC=0
if command -v timeout >/dev/null 2>&1; then
  timeout --foreground "$TIMEOUT_SEC" "$CLAUDE_BIN" --print --max-turns 1 "$PROMPT" \
    > "$RAW_PATH" 2>&1 || LLM_RC=$?
else
  # macOS sem coreutils → fallback via gtimeout ou sem timeout (custo aceito;
  # documentado como Gotcha em commands/reflect.md).
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$TIMEOUT_SEC" "$CLAUDE_BIN" --print --max-turns 1 "$PROMPT" \
      > "$RAW_PATH" 2>&1 || LLM_RC=$?
  else
    "$CLAUDE_BIN" --print --max-turns 1 "$PROMPT" > "$RAW_PATH" 2>&1 || LLM_RC=$?
  fi
fi

# ─── 9) Parse fail-graceful (AC5) ─────────────────────────────────────────
PARSE_OK=0
if [[ -s "$RAW_PATH" ]] && jq -e . "$RAW_PATH" >/dev/null 2>&1; then
  PARSE_OK=1
  # Normaliza schema mínimo (proposals, findings).
  jq '{summary: (.summary // ""),
       proposals: (.proposals // []),
       findings: (.findings // [])}' "$RAW_PATH" > "$PROPOSAL_PATH"
else
  # Fallback: tenta extrair primeiro bloco JSON do output.
  EXTRACTED="$(awk '/^{/{flag=1} flag{print} /^}/{flag=0; exit}' "$RAW_PATH" 2>/dev/null || true)"
  if [[ -n "$EXTRACTED" ]] && jq -e . <<<"$EXTRACTED" >/dev/null 2>&1; then
    PARSE_OK=1
    jq '{summary: (.summary // ""),
         proposals: (.proposals // []),
         findings: (.findings // [])}' <<<"$EXTRACTED" > "$PROPOSAL_PATH"
  else
    # Fail-graceful: emite finding apontando pro raw.
    jq -n --arg raw "$RAW_PATH" --arg rc "$LLM_RC" \
      '{summary: "LLM output unparseable; ver raw-llm-output.txt",
        proposals: [],
        findings: [{type: "llm_output_unparseable",
                    raw_path: $raw,
                    llm_exit_code: $rc}]}' > "$PROPOSAL_PATH"
  fi
fi

# Merge findings do bundle (tdd_gap_marker_missing etc) com os do LLM,
# para visibilidade única no proposal.json.
MERGED_FINDINGS="$(
  jq -s '.[0].findings + .[1] | unique_by(.type + (.spec_id // "") + (.detail // ""))' \
    "$PROPOSAL_PATH" <(printf '%s\n' "$FINDINGS_JSON") 2>/dev/null || cat "$PROPOSAL_PATH" | jq '.findings'
)"
jq --argjson f "$MERGED_FINDINGS" '.findings = $f' "$PROPOSAL_PATH" \
  > "$PROPOSAL_PATH.tmp" && mv "$PROPOSAL_PATH.tmp" "$PROPOSAL_PATH"

# ─── 10) Gera report.md (humano-legível) ──────────────────────────────────
{
  echo "# Reflect --learn — PR #$PR_NUM, $US_ID"
  echo ""
  echo "**Generated:** $(date -u +%FT%TZ)"
  echo "**Title:** $US_TITLE"
  echo "**LLM parse:** $([ "$PARSE_OK" -eq 1 ] && echo OK || echo FAIL)"
  echo "**LLM exit code:** $LLM_RC"
  echo ""
  echo "## Bundle counts"
  echo ""
  echo "- DoD bullets: $(jq 'length' <<<"$DOD_BULLETS_JSON")"
  echo "- Specs: $(jq 'length' <<<"$SPECS_JSON")"
  echo "- Specs sem marker: $(jq 'length' <<<"$FINDINGS_JSON")"
  echo "- Commits no PR: $(printf '%s\n' "$COMMITS_SUMMARY" | grep -c . || true)"
  echo ""
  echo "## DoD × Spec × Teste × Resultado"
  echo ""
  echo "| Spec id | Texto | Test files | Resultado |"
  echo "|---------|-------|------------|-----------|"
  jq -r '.[] | "| \(.id) | \(.text|.[0:80]) | \((.test_files // []) | join(", ")) | \(if (.test_files|length)==0 then "MISSING" else "OK" end) |"' <<<"$SPECS_JSON"
  echo ""
  echo "## Findings"
  echo ""
  jq -r '.findings[]? | "- **\(.type)** — \(.spec_id // .detail // .raw_path // "")"' "$PROPOSAL_PATH"
  echo ""
  echo "## Proposals"
  echo ""
  jq -r '.proposals[]? | "- [\(.action // "?")] \(.target_file // "?") — \(.rationale // .text // "")"' "$PROPOSAL_PATH"
  echo ""
  echo "## Raw LLM output"
  echo ""
  echo "Salvo em \`$RAW_PATH\` (gravação SEMPRE — AC5)."
} > "$REPORT_PATH"

# ─── 11) Gera proposed.diff a partir das proposals (best-effort) ─────────
# Estratégia conservadora: se LLM emitiu unified diff embedded, extrai.
# Caso contrário gera diff vazio + comentário. Humano valida com `git apply --check`.
DIFF_TEXT="$(jq -r '.proposals[]?.diff // empty' "$PROPOSAL_PATH" 2>/dev/null | tr -d '\r' || true)"
if [[ -n "$DIFF_TEXT" ]]; then
  printf '%s\n' "$DIFF_TEXT" > "$DIFF_PATH"
else
  cat > "$DIFF_PATH" <<EOF
# /reflect --learn — proposed.diff
# Generated $(date -u +%FT%TZ)
# Nenhum diff unified emitido pela LLM. Proposals em proposal.json devem ser
# convertidos manualmente antes de aplicar com git apply.
EOF
fi

# stdout informativo (não JSON — modo --with-llm prioriza arquivos no OUT_DIR).
echo "$OUT_DIR"
exit 0
