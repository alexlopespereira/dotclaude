#!/usr/bin/env bash
# spec: US-03-principio-14-claude-md
# Regressão documental do Princípio 14 em dotclaude/CLAUDE.md (fonte versionada, US-03).
# Adversarial-robusto: cada assert roda contra a LINHA isolada do Princípio 14
# (extraída da seção "## Princípios"), não contra o arquivo inteiro — assim mover
# o conteúdo pra fora do princípio quebra o teste, como exigido pelo review do US-01.
# ACs [CAT3-MANUAL] (AC7.a) não são automatizáveis e ficam fora por design.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# repo root = .../dotclaude ; skill em skills/verify-before-handoff/bin
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }

[[ -f "$CLAUDE_MD" ]] || { echo "FAIL: CLAUDE.md ausente em $CLAUDE_MD" >&2; exit 1; }

# --- Precondição estrutural: a seção "## Princípios" precede "## Skills disponíveis" ---
princ_ln=$(grep -nxF '## Princípios (sempre ativos)' "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)
skills_ln=$(grep -nxF '## Skills disponíveis' "$CLAUDE_MD" | head -1 | cut -d: -f1 || true)
if [[ -z "$princ_ln" || -z "$skills_ln" || "$princ_ln" -ge "$skills_ln" ]]; then
  echo "FAIL: estrutura de seções inesperada (Princípios=$princ_ln Skills=$skills_ln)" >&2
  exit 1
fi

# AC1: existe um item "14." na lista de Princípios (entre as duas seções).
#  Captura a LINHA do princípio 14 — base dos asserts seguintes.
P14=$(sed -n "${princ_ln},${skills_ln}p" "$CLAUDE_MD" | grep -E '^14\. ' | head -1 || true)
[[ -n "$P14" ]] || fail "AC1: item '14.' ausente na lista de Princípios"

# AC1 (binário/acionável): o princípio impõe uma ação concreta antes do claim,
# não uma aspiração. Verbo imperativo "confirme" + objeto "resultado realizado".
grep -qiE 'confirme .*resultado realizado' <<<"$P14" \
  || fail "AC1: princípio não é acionável/binário (falta 'confirme ... resultado realizado')"

# AC2: referencia a skill verify-before-handoff para o operacional (delega, não duplica).
grep -qiE 'na skill `?verify-before-handoff`?' <<<"$P14" \
  || fail "AC2: princípio não referencia a skill verify-before-handoff para o operacional"
#  guarda contra duplicação inline do operacional: o princípio NÃO deve trazer o
#  detalhe do classificador (lista de verbos MCP) inline — isso vive na skill.
if grep -qiE 'send *\| *create *\| *delete *\| *deploy *\| *publish' <<<"$P14"; then
  fail "AC2: princípio duplica o classificador inline (deveria delegar à skill)"
fi

# AC3: origem rastreável — email vazio + sessão grill + link ao plano-fonte.
grep -qiE 'e-?mail[s]? .*(vazio|vazios)' <<<"$P14" \
  || fail "AC3: origem (incidente do email vazio) ausente no princípio"
grep -qiE 'grill' <<<"$P14" \
  || fail "AC3: origem (sessão de grill) ausente no princípio"
grep -qF '.claude/plans/2026-06-06T02-02-40Z-verify-before-handoff.md' <<<"$P14" \
  || fail "AC3: link para o plano-fonte ausente no princípio"

# AC5: a regra não duplica comportamento default — justificada por evidência empírica.
grep -qiE 'não .*(é )?(o )?comportamento default|não é o comportamento default' <<<"$P14" \
  || fail "AC5: princípio não declara que difere do comportamento default do modelo"
grep -qiE 'evidência empírica|evidencia empirica' <<<"$P14" \
  || fail "AC5: justificativa por evidência empírica ausente"

# AC6: a propagação para ~/.claude/CLAUDE.md ocorre via sync.sh install.
#  Prova estrutural: CLAUDE.md está na lista de artefatos propagados pelo sync.sh.
SYNC="$REPO_ROOT/sync.sh"
[[ -f "$SYNC" ]] || fail "AC6: sync.sh ausente em $SYNC"
grep -qE '"CLAUDE\.md"' "$SYNC" \
  || fail "AC6: CLAUDE.md não consta na lista de propagação do sync.sh install"

if (( FAIL )); then
  echo "test-principle-14.sh: FAIL" >&2
  exit 1
fi
echo "test-principle-14.sh: PASS"
