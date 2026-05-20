#!/usr/bin/env bash
# spec: tarefa-2-spec-1-A (skill nova/edit + frontmatter description estendido)
# Regressão da subseção "Convenção // spec: em código de teste" da SKILL.md.
# Cada bloco abaixo mapeia 1:1 com um AC do US-03.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_MD="$SCRIPT_DIR/../SKILL.md"

FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }

[[ -f "$SKILL_MD" ]] || { echo "missing SKILL.md at $SKILL_MD" >&2; exit 2; }

# AC1: subseção existe sob "## Lifecycle de Test Specs" com 4 partes.
grep -qE '^### Convenção `// spec:` em código de teste$' "$SKILL_MD" \
  || fail "AC1: heading da subseção ausente"
for part in 'Sintaxe' 'Localização' 'Enforcement' 'Exemplo'; do
  grep -qE "\*\*${part}" "$SKILL_MD" \
    || fail "AC1: parte '${part}' ausente como bold inline"
done

# AC2: sintaxe documentada pra JS/TS, Python, shell.
grep -qE '// spec: tarefa-' "$SKILL_MD"   || fail "AC2: exemplo JS/TS '// spec:' ausente"
grep -qE '^# Python|Python.*# spec:|# spec:.*Python' "$SKILL_MD" \
  || grep -qE '\| Python' "$SKILL_MD" \
  || fail "AC2: menção a Python ausente"
grep -qE '\| Shell|shell.*# spec:|bash' "$SKILL_MD" \
  || fail "AC2: menção a shell/bash ausente"

# AC3: localização (linha imediatamente acima) + múltiplos markers consecutivos.
grep -qiE 'imediatamente acima' "$SKILL_MD" \
  || fail "AC3: 'imediatamente acima' não documentado"
grep -qiE 'múltiplos markers consecutivos|multiplos markers consecutivos' "$SKILL_MD" \
  || fail "AC3: múltiplos markers consecutivos não documentado"

# AC4: SOFT enforcement, finding name, sem hook bloqueante.
grep -qiE 'SOFT' "$SKILL_MD"                          || fail "AC4: 'SOFT' não classificado"
grep -qE 'tdd_gap_marker_missing' "$SKILL_MD"         || fail "AC4: finding name ausente"
grep -qiE 'não bloqueia merge|nao bloqueia merge' "$SKILL_MD" \
  || fail "AC4: 'não bloqueia merge' não documentado"
grep -qiE 'PreToolUse' "$SKILL_MD" \
  || fail "AC4: ausência de hook PreToolUse não declarada"

# AC5: pelo menos 1 exemplo em shell + spec id concreto.
grep -qE 'tarefa-1-spec-3-A|tarefa-[0-9]+-spec-[0-9]+(-[A-Z])?' "$SKILL_MD" \
  || fail "AC5: spec id concreto ausente"
# Shell example: bloco com '# spec:' dentro de fence ```bash ou ```sh
awk '
  /^```bash$|^```sh$/ { in_shell=1; next }
  /^```$/             { in_shell=0; next }
  in_shell && /# spec: tarefa-/ { found=1 }
  END { exit found ? 0 : 1 }
' "$SKILL_MD" || fail "AC5: exemplo em shell com '# spec:' ausente"

# AC6: política referenciada de TEST-PATTERNS.md.
grep -qE 'TEST-PATTERNS\.md' "$SKILL_MD" \
  || fail "AC6: referência a TEST-PATTERNS.md ausente"

if (( FAIL )); then
  echo "test-skill-spec-convention.sh: FAIL" >&2
  exit 1
fi
echo "test-skill-spec-convention.sh: PASS"
