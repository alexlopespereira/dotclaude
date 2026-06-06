#!/usr/bin/env bash
# spec: US-01-verify-before-handoff-skill-content
# Regressão documental da skill verify-before-handoff (US-01).
# Cada bloco mapeia 1:1 com um AC do US-01. ACs [CAT3-MANUAL] (AC8.a/b) não são
# automatizáveis (exigem sessão real / /doctor) e ficam fora deste teste por design.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$SCRIPT_DIR/.."
SKILL_MD="$SKILL_DIR/SKILL.md"
REFS_DIR="$SKILL_DIR/references"

FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }

# AC1: a skill é uma PASTA com SKILL.md e subdir references/ previsto.
[[ -f "$SKILL_MD" ]]   || fail "AC1: SKILL.md ausente em $SKILL_MD"
[[ -d "$REFS_DIR" ]]   || fail "AC1: subdir references/ ausente"
[[ -f "$REFS_DIR/hot-paths-catalog.md" ]] \
  || fail "AC1: references/hot-paths-catalog.md ausente"

# AC2: frontmatter YAML com name e description; description com trigger phrases.
#  - frontmatter delimitado por '---' (linha 1 abre, próximo '---' fecha)
head -1 "$SKILL_MD" | grep -qE '^---$' || fail "AC2: frontmatter não abre com '---'"
# Isola o BLOCO de frontmatter (entre o 1º e o 2º '---'), não o arquivo inteiro.
FRONTMATTER="$(awk '/^---$/{c++; next} c>=2{exit} c==1{print}' "$SKILL_MD")"
grep -qE '^name:[[:space:]]*verify-before-handoff[[:space:]]*$' <<<"$FRONTMATTER" \
  || fail "AC2: campo 'name: verify-before-handoff' ausente no frontmatter"
# Isola o VALOR de 'description' (não 'name', não o corpo) — Codex Iter2 P1:
# grep file-wide passaria com as frases no corpo e a description vazia.
DESC="$(awk '/^---$/{c++; next} c>=2{exit} c==1 && /^description:/{sub(/^description:[[:space:]]*/,""); print}' "$SKILL_MD")"
[[ -n "$DESC" ]] || fail "AC2: campo 'description' ausente/vazio no frontmatter"
# trigger phrases exigidas pelo AC — asseridas SÓ no valor de description.
for phrase in 'verificar antes de entregar' 'confirmar output' 'auto-verificação'; do
  grep -qiF "$phrase" <<<"$DESC" \
    || fail "AC2: trigger phrase '$phrase' ausente NO VALOR de description"
done

# AC3: seção Gotchas com erros reais — email vazio + falso-positivo do classificador soft.
grep -qiE '^## *Gotchas' "$SKILL_MD" || fail "AC3: seção '## Gotchas' ausente"
# Isola o BLOCO da seção (de '## Gotchas' até o próximo heading '## ') — Codex Iter2 P1:
# os casos têm de estar DENTRO de Gotchas, não em qualquer lugar do arquivo.
GOTCHAS="$(awk 'tolower($0) ~ /^## *gotchas/{f=1; next} f && /^## /{exit} f{print}' "$SKILL_MD")"
[[ -n "$GOTCHAS" ]] || fail "AC3: seção '## Gotchas' vazia"
grep -qiE 'e-?mail[s]? *(vazio|vazios|em branco)' <<<"$GOTCHAS" \
  || fail "AC3: gotcha do e-mail vazio ausente DENTRO da seção Gotchas"
grep -qiE 'falso-positivo.*(classificador )?soft|classificador soft' <<<"$GOTCHAS" \
  || fail "AC3: gotcha do falso-positivo do classificador soft ausente DENTRO da seção Gotchas"

# AC4: padrão de evidência (funcional ponta-a-ponta, teto/fronteira/piso) — não a intenção.
grep -qiE 'funcional ponta-a-ponta' "$SKILL_MD" \
  || fail "AC4: 'funcional ponta-a-ponta' ausente"
grep -qiE 'teto *=? *valor de usuário|valor de usuário.*teto|TETO' "$SKILL_MD" \
  || fail "AC4: teto = valor de usuário ausente"
grep -qiE 'fronteira *=? *critério de aceitação|critério de aceitação' "$SKILL_MD" \
  || fail "AC4: fronteira = critério de aceitação ausente"
grep -qiE 'piso.*(observar|olhar).*(realizado|artefato)|observar o (artefato )?realizado' "$SKILL_MD" \
  || fail "AC4: piso = observar o realizado ausente"
grep -qiE 'não a intenção|intenção *≠ *resultado|intenção .* resultado' "$SKILL_MD" \
  || fail "AC4: contraste com a intenção ausente"

# AC5: loop de auto-fix (limite 3x, escala ambíguo/destrutivo, re-verifica funcional cada tentativa).
grep -qiE '3 *(tentativas|x|×)|limite.*3|3.*tentativas' "$SKILL_MD" \
  || fail "AC5: limite de 3 tentativas ausente"
grep -qiE 'escala' "$SKILL_MD" || fail "AC5: escala (para ambíguo/destrutivo) ausente"
grep -qiE 'ambígua|ambíguo|ambigua|ambiguo' "$SKILL_MD" \
  || fail "AC5: caso ambíguo ausente"
grep -qiE 'destrutiv' "$SKILL_MD" || fail "AC5: caso destrutivo ausente"
grep -qiE 're-?(roda|verifica|verificação).*(funcional|MESMA)|cada tentativa' "$SKILL_MD" \
  || fail "AC5: re-verificação funcional a cada tentativa ausente"

# AC6: regra de escopo (Finding #2) — classificador GENÉRICO, não Resend-específico.
grep -qiE 'send *\| *create *\| *delete *\| *deploy *\| *publish|send \| create \| delete \| deploy \| publish' "$SKILL_MD" \
  || grep -qiE 'send.*create.*delete.*deploy.*publish' "$SKILL_MD" \
  || fail "AC6: verbos MCP (send|create|delete|deploy|publish) ausentes"
grep -qiE 'genérico, não Resend-específico|genérico.*não Resend|não Resend-específico' "$SKILL_MD" \
  || fail "AC6: rótulo 'genérico, não Resend-específico' ausente"
grep -qiE 'HTTP mutante externo|POST\|PUT\|DELETE|POST/PUT/DELETE' "$SKILL_MD" \
  || fail "AC6: sinal Bash HTTP mutante externo ausente"
grep -qiE 'repo (que de fato envia|emissor)' "$SKILL_MD" \
  || fail "AC6: calibração no repo emissor ausente"

# AC7: tensão com Princípio 1 — 'valor de usuário' é TETO; piso = observar o realizado.
grep -qiE 'Princípio 1|Principio 1' "$SKILL_MD" \
  || fail "AC7: referência ao Princípio 1 ausente"
grep -qiE 'triviais? isent' "$SKILL_MD" \
  || fail "AC7: menção a tarefas triviais isentas ausente"
grep -qiE 'TETO' "$SKILL_MD" \
  || fail "AC7: 'valor de usuário' como TETO ausente"

if (( FAIL )); then
  echo "test-skill-content.sh: FAIL" >&2
  exit 1
fi
echo "test-skill-content.sh: PASS"
