#!/usr/bin/env bash
# spec: US-01-browser-secrets-skill-content
# Regressão documental da skill browser-secrets (US-01).
# Cada bloco mapeia 1:1 com um AC do US-01. ACs [CAT3-MANUAL] (AC14.a/15.a/16.a) não são
# automatizáveis (exigem sessão real / /doctor / fluxo ponta-a-ponta autenticado) e ficam
# fora deste teste por design — validados pós-merge.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$SCRIPT_DIR/.."
SKILL_MD="$SKILL_DIR/SKILL.md"
REFS_DIR="$SKILL_DIR/references"
EX_DIR="$SKILL_DIR/examples"

FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }

# AC1: a skill é uma PASTA com SKILL.md e subdirs references/ + examples/ previstos.
[[ -f "$SKILL_MD" ]] || fail "AC1: SKILL.md ausente em $SKILL_MD"
[[ -d "$REFS_DIR" ]] || fail "AC1: subdir references/ ausente"
[[ -d "$EX_DIR"   ]] || fail "AC1: subdir examples/ ausente"
[[ -f "$REFS_DIR/probe-endpoints.md" ]] || fail "AC1: references/probe-endpoints.md ausente"
[[ -f "$EX_DIR/report-and-audit.md"  ]] || fail "AC1: examples/report-and-audit.md ausente"

# AC2: frontmatter YAML com name e description; description com trigger phrases.
head -1 "$SKILL_MD" | grep -qE '^---$' || fail "AC2: frontmatter não abre com '---'"
FRONTMATTER="$(awk '/^---$/{c++; next} c>=2{exit} c==1{print}' "$SKILL_MD")"
grep -qE '^name:[[:space:]]*browser-secrets[[:space:]]*$' <<<"$FRONTMATTER" \
  || fail "AC2: campo 'name: browser-secrets' ausente no frontmatter"
# Isola o VALOR de 'description' (não 'name', não o corpo).
DESC="$(awk '/^---$/{c++; next} c>=2{exit} c==1 && /^description:/{sub(/^description:[[:space:]]*/,""); print}' "$SKILL_MD")"
[[ -n "$DESC" ]] || fail "AC2: campo 'description' ausente/vazio no frontmatter"
# o-que-faz + quando-usar marcados explicitamente no valor de description.
grep -qiF 'o que faz' <<<"$DESC" || fail "AC2: 'o que faz' ausente no VALOR de description"
grep -qiF 'quando usar' <<<"$DESC" || fail "AC2: 'quando usar' ausente no VALOR de description"
# trigger phrases exigidas pelo AC — asseridas SÓ no valor de description.
for phrase in 'criar token' 'gerar API key' 'setup ferramenta web' 'provisionar secret'; do
  grep -qiF "$phrase" <<<"$DESC" \
    || fail "AC2: trigger phrase '$phrase' ausente NO VALOR de description"
done

# AC3: relação com Princípio 12 ramo 1B — dentro da escada, autonomia≠precedência, CLI vence.
grep -qiE 'Princípio 12|Principio 12' "$SKILL_MD" || fail "AC3: referência ao Princípio 12 ausente"
grep -qiE 'ramo 1B|1B' "$SKILL_MD" || fail "AC3: menção ao ramo 1B ausente"
grep -qiE 'CLI *> *MCP *> *API *> *Playwright' "$SKILL_MD" \
  || fail "AC3: escada CLI > MCP > API > Playwright ausente"
grep -qiE 'autonomia, não precedência|autonomia.*não.*precedência' "$SKILL_MD" \
  || fail "AC3: 'autonomia, não precedência' ausente"
grep -qiF 'aws iam create-access-key' "$SKILL_MD" \
  || fail "AC3: exemplo 'aws iam create-access-key' (CLI vence) ausente"

# AC4: 3 triggers + check-exists-first (3 fontes) + regra de desambiguação.
grep -qiE '401/403|401.*403' "$SKILL_MD" || fail "AC4: trigger falha auth 401/403 ausente"
grep -qiE 'intent de setup|intent.*setup' "$SKILL_MD" || fail "AC4: trigger intent de setup ausente"
grep -qiE 'referenciada-mas-ausente|referenciada.*ausente' "$SKILL_MD" \
  || fail "AC4: trigger env var referenciada-mas-ausente ausente"
grep -qiE 'check-exists-first' "$SKILL_MD" || fail "AC4: precondição check-exists-first ausente"
grep -qiF '~/.claude/secrets/' "$SKILL_MD" || fail "AC4: check em ~/.claude/secrets/ ausente"
grep -qiE 'CLI da tool|CLI da ferramenta' "$SKILL_MD" || fail "AC4: check na CLI da tool ausente"
grep -qiE 'ambígu|ambigu' "$SKILL_MD" || fail "AC4: regra 'pergunta se ambíguo' ausente"

# AC5: destino .env + guarda de .gitignore ANTES de escrever (Princípio 7).
grep -qiE '\.gitignore' "$SKILL_MD" || fail "AC5: guarda de .gitignore ausente"
grep -qiE 'ANTES de escrever|antes.*escrev' "$SKILL_MD" \
  || fail "AC5: ordem 'verifica gitignore ANTES de escrever' ausente"
grep -qiE 'Princípio 7|Principio 7' "$SKILL_MD" || fail "AC5: referência ao Princípio 7 ausente"

# AC6: confirmação MASCARADA (últimos 4 chars) + segredo cru nunca ecoado.
grep -qiE 'masc' "$SKILL_MD" || fail "AC6: confirmação mascarada ausente"
grep -qiE 'últimos 4|ultimos 4|sk-\.\.\.' "$SKILL_MD" || fail "AC6: 'últimos 4 chars' / exemplo ausente"
grep -qiE 'cru nunca.*ecoad|nunca.*ecoad.*transcript|segredo cru' "$SKILL_MD" \
  || fail "AC6: regra 'segredo cru nunca ecoado' ausente"

# AC7: captura em 3 camadas (regex prefixo → DOM Copy/Reveal → pede ao usuário).
grep -qiE '3 camadas|em camadas' "$SKILL_MD" || fail "AC7: captura em camadas ausente"
grep -qiE 'sk-.*ghp_.*re_|prefixo conhecido' "$SKILL_MD" || fail "AC7: camada 1 regex de prefixo ausente"
grep -qiE 'Copy/Reveal|Copy.*Reveal|seletor DOM' "$SKILL_MD" || fail "AC7: camada 2 seletor DOM ausente"
grep -qiE 'pede ao usuário colar|pede.*colar|não inventa' "$SKILL_MD" \
  || fail "AC7: camada 3 (pausa e pede ao usuário) ausente"

# AC8: verificação P14 — live probe → fallback formato → loop 3x → escala; delega a verify-before-handoff.
grep -qiE 'Princípio 14|Principio 14' "$SKILL_MD" || fail "AC8: referência ao Princípio 14 ausente"
grep -qiE 'live probe' "$SKILL_MD" || fail "AC8: live probe ausente"
grep -qiF '/v1/models' "$SKILL_MD" || fail "AC8: exemplo GET /v1/models ausente"
grep -qiF 'gh api user' "$SKILL_MD" || fail "AC8: exemplo gh api user ausente"
grep -qiE 'fallback.*formato|assert de formato' "$SKILL_MD" || fail "AC8: fallback assert de formato ausente"
grep -qiE '3x|3 tentativas|auto-fix' "$SKILL_MD" || fail "AC8: loop auto-fix 3x ausente"
grep -qiE 'escala' "$SKILL_MD" || fail "AC8: escala após falhas ausente"
grep -qiE 'nomeia.*caminho|report nomeia|caminho de verificação usado' "$SKILL_MD" \
  || fail "AC8: report nomeia o caminho de verificação ausente"
grep -qiF 'verify-before-handoff' "$SKILL_MD" || fail "AC8: delegação a verify-before-handoff ausente"

# AC9: tiered proactivity — free/low-risk proativo; Zona 3/custo/destrutivo/OAuth = confirm gate.
grep -qiE 'free */ *low-risk|free/low-risk|low-risk' "$SKILL_MD" || fail "AC9: categoria free/low-risk ausente"
grep -qiE 'proativo, sem perguntar|proativo.*sem perguntar' "$SKILL_MD" \
  || fail "AC9: 'proativo sem perguntar' ausente"
grep -qiE 'Zona 3' "$SKILL_MD" || fail "AC9: Zona 3 ausente"
grep -qiF '*.stripe.com' "$SKILL_MD" || fail "AC9: exemplo *.stripe.com ausente"
grep -qiE 'OAuth' "$SKILL_MD" || fail "AC9: caso OAuth/multi-valor ausente"
grep -qiE 'confirm gate' "$SKILL_MD" || fail "AC9: confirm gate (browser-actions + P11) ausente"
grep -qiE 'Princípio 11|Principio 11|P11' "$SKILL_MD" || fail "AC9: referência ao Princípio 11 ausente"

# AC10: report (campos) + audit.jsonl append-only (campos, nunca segredo cru).
for field in tool tipo escopo destino verificação trigger; do
  grep -qiE "$field" "$SKILL_MD" || fail "AC10: campo de report '$field' ausente"
done
grep -qiE 'ação-do-usuário|ação sua|ação do usuário' "$SKILL_MD" || fail "AC10: campo ação-do-usuário ausente"
grep -qiF '~/.claude/cache/browser-secrets/audit.jsonl' "$SKILL_MD" \
  || fail "AC10: caminho do audit.jsonl ausente"
grep -qiE 'append-only' "$SKILL_MD" || fail "AC10: audit append-only ausente"
grep -qiE 'timestamp' "$SKILL_MD" || fail "AC10: campo timestamp do audit ausente"
grep -qiE 'tail' "$SKILL_MD" || fail "AC10: campo tail mascarado do audit ausente"
grep -qiE 'nunca.*segredo cru|segredo cru' "$SKILL_MD" || fail "AC10: 'nunca segredo cru' no audit ausente"

# AC11: link de revogação quando conhecido; senão página genérica de settings/tokens.
grep -qiE 'revogação|revogar' "$SKILL_MD" || fail "AC11: link de revogação ausente"
grep -qiE 'quando conhecido' "$SKILL_MD" || fail "AC11: 'quando conhecido' ausente"
grep -qiE 'settings/tokens|settings.*tokens|página genérica' "$SKILL_MD" \
  || fail "AC11: fallback para página genérica de settings/tokens ausente"

# AC12: seção Gotchas com (a) profile quente, (b) key revelada-uma-vez, (c) scope/least-privilege.
grep -qiE '^## *Gotchas' "$SKILL_MD" || fail "AC12: seção '## Gotchas' ausente"
GOTCHAS="$(awk 'tolower($0) ~ /^## *gotchas/{f=1; next} f && /^## /{exit} f{print}' "$SKILL_MD")"
[[ -n "$GOTCHAS" ]] || fail "AC12: seção '## Gotchas' vazia"
grep -qiE 'profile.*quente|profile autenticado quente' <<<"$GOTCHAS" \
  || fail "AC12(a): gotcha profile quente / pausa 1x ausente DENTRO de Gotchas"
grep -qiE 'pausar 1x|pausa 1x|pausar uma vez' <<<"$GOTCHAS" \
  || fail "AC12(a): menção a pausar 1x por profile/slot ausente DENTRO de Gotchas"
grep -qiE 'revelada-uma-vez|revelada uma vez|só 1x|so 1x' <<<"$GOTCHAS" \
  || fail "AC12(b): gotcha key revelada-uma-vez ausente DENTRO de Gotchas"
grep -qiE 'least-privilege|least privilege|escopo mínimo|scope inference' <<<"$GOTCHAS" \
  || fail "AC12(c): gotcha scope inference / least-privilege ausente DENTRO de Gotchas"

# AC13: delegação explícita a browser-actions (auth pre-check, eTLD+1, blocklist) — não duplica.
grep -qiF 'browser-actions' "$SKILL_MD" || fail "AC13: delegação a browser-actions ausente"
grep -qiE 'não duplica|nao duplica' "$SKILL_MD" || fail "AC13: declaração 'não duplica' ausente"
grep -qiE 'auth pre-check' "$SKILL_MD" || fail "AC13: delegação de auth pre-check ausente"
grep -qiE 'eTLD\+1' "$SKILL_MD" || fail "AC13: delegação de eTLD+1 announce ausente"
grep -qiE 'blocklist.*Zona 3|Zona 3' "$SKILL_MD" || fail "AC13: delegação de blocklist Zona 3 ausente"

if (( FAIL )); then
  echo "test-skill-content.sh: FAIL" >&2
  exit 1
fi
echo "test-skill-content.sh: PASS"
