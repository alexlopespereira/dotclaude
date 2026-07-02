#!/usr/bin/env bash
# secret-capture.sh — captura um secret pro env-file SEM passar pelo transcript.
#
# O QUE FAZ: orquestra a captura de um valor de credencial — via driver
# Playwright local (bin/lib/secret-capture-driver.mjs, perfil Chrome dedicado
# do slot) OU via drop file colado pelo usuário — e o grava como KEY=valor no
# env-file (replace-or-append, chmod 600). O valor flui APENAS por arquivo
# tmp 0600 / env var / builtin: nunca argv de processo externo (visível em
# `ps`), nunca stdout/stderr do wrapper (persistidos no transcript). O único
# eco do valor é o tail MASCARADO.
#
# FLUXO: guarda .gitignore → captura → escrita no env-file → probe opcional
# (valor via env var com o próprio nome da KEY) → report mascarado → linha de
# audit no jsonl da browser-secrets → upsert no inventário (secrets-expiry.sh
# add). Guarda .gitignore: env-file não coberto ganha entrada ANTES da
# escrita; drop path não coberto ABORTA sem ler (o valor já está num path
# versionável — normalizar depois esconderia a exposição); fora de repo git
# não há risco de commit → sem guarda. [SUPOSIÇÃO] env-file já *trackeado*
# no git não é salvo pela guarda (check-ignore não cobre tracked) — cenário
# exige `git add .env` manual prévio, fora do alcance deste wrapper.
#
# QUANDO USAR: provisionamento/renovação/rotação de credencial pela skill
# browser-secrets quando o valor não pode ser ecoado (P7/P12); --from-drop
# cobre o fallback "usuário cola o valor" sem colar no chat.
#
# Exit: 0 ok; 2 uso inválido; 3 guarda .gitignore; 4 captura falhou
# (driver/drop); 5 falha de escrita (env-file/audit); 6 probe falhou
# (valor JÁ gravado no env-file para inspeção manual); 7 gate Zona 3
# (domínio sensível sem --allow-sensitive).

set -u

usage() {
  cat <<'EOF'
Uso: secret-capture.sh --provider P --env-key KEY <fonte> [opções]
  fonte (exatamente uma):
    --url U (--selector CSS | --prefix-regex RE)
                        captura via driver Playwright no perfil do slot
    --from-drop [PATH]  move de um drop file (default temp/.secret-drop);
                        o drop é destruído após a escrita
  opções:
    --env-file PATH     destino KEY=valor (default ./.env; chmod 600)
    --slot NAME         slot do perfil chrome (repassado ao driver)
    --pw-root DIR       raiz com node_modules/playwright (repassado ao driver)
    --probe CMD         valida o valor: CMD roda com a env var KEY exportada
                        (o valor NUNCA entra no argv do probe)
    --driver CMD        substitui `node bin/lib/secret-capture-driver.mjs`
                        (seam de teste; sofre word-split)
    --no-inventory      suprime o upsert no inventário de expiração
    --audit-file PATH   audit jsonl (default ~/.claude/cache/browser-secrets/audit.jsonl)
    --expiry-script P   caminho do secrets-expiry.sh (seam de teste)
    --blocklist PATH    blocklist Zona 3 da browser-actions (seam de teste)
    --allow-sensitive   libera --url em domínio sensível da blocklist APÓS
                        confirmação humana (override auditado em stderr)
O valor capturado NUNCA aparece em argv nem no stdout (só tail mascarado).
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROVIDER=""; ENV_KEY=""; URL=""; SELECTOR=""; PREFIX_REGEX=""
FROM_DROP=false; DROP_PATH="temp/.secret-drop"
ENV_FILE="./.env"; SLOT=""; PW_ROOT=""; PROBE=""; DRIVER=""
NO_INVENTORY=false
AUDIT_FILE="$HOME/.claude/cache/browser-secrets/audit.jsonl"
EXPIRY_SCRIPT="$SCRIPT_DIR/secrets-expiry.sh"
ALLOW_SENSITIVE=false
BLOCKLIST="$HOME/.claude/skills/browser-actions/blocklist.json"
[ -f "$BLOCKLIST" ] || BLOCKLIST="$SCRIPT_DIR/../skills/browser-actions/blocklist.json"

need_val() {  # need_val <flag> <$#> — flag de valor sem valor → uso inválido
  [ "$2" -ge 2 ] || { echo "faltando valor para $1" >&2; usage >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --provider)      need_val "$1" $#; PROVIDER="$2"; shift 2 ;;
    --env-key)       need_val "$1" $#; ENV_KEY="$2"; shift 2 ;;
    --url)           need_val "$1" $#; URL="$2"; shift 2 ;;
    --selector)      need_val "$1" $#; SELECTOR="$2"; shift 2 ;;
    --prefix-regex)  need_val "$1" $#; PREFIX_REGEX="$2"; shift 2 ;;
    --from-drop)
      FROM_DROP=true
      # path opcional: consome o próximo arg só se não for outra flag
      if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then DROP_PATH="$2"; shift 2; else shift; fi ;;
    --env-file)      need_val "$1" $#; ENV_FILE="$2"; shift 2 ;;
    --slot)          need_val "$1" $#; SLOT="$2"; shift 2 ;;
    --pw-root)       need_val "$1" $#; PW_ROOT="$2"; shift 2 ;;
    --probe)         need_val "$1" $#; PROBE="$2"; shift 2 ;;
    --driver)        need_val "$1" $#; DRIVER="$2"; shift 2 ;;
    --no-inventory)  NO_INVENTORY=true; shift ;;
    --audit-file)    need_val "$1" $#; AUDIT_FILE="$2"; shift 2 ;;
    --expiry-script) need_val "$1" $#; EXPIRY_SCRIPT="$2"; shift 2 ;;
    --blocklist)     need_val "$1" $#; BLOCKLIST="$2"; shift 2 ;;
    --allow-sensitive) ALLOW_SENSITIVE=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "opção desconhecida: $1" >&2; usage >&2; exit 2 ;;
  esac
done

usage_die() { echo "$1" >&2; usage >&2; exit 2; }

[ -n "$ENV_KEY" ] || usage_die "exige --env-key"
printf '%s' "$ENV_KEY" | LC_ALL=C grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' \
  || usage_die "--env-key não é nome válido de env var: $ENV_KEY"
[ -n "$PROVIDER" ] || usage_die "exige --provider"
if [ -n "$URL" ] && [ "$FROM_DROP" = true ]; then
  usage_die "--url e --from-drop são mutuamente exclusivos"
fi
if [ -z "$URL" ] && [ "$FROM_DROP" = false ]; then
  usage_die "exige uma fonte: --url ou --from-drop"
fi
if [ -n "$URL" ]; then
  if [ -n "$SELECTOR" ] && [ -n "$PREFIX_REGEX" ]; then
    usage_die "--selector e --prefix-regex são mutuamente exclusivos"
  fi
  [ -n "$SELECTOR$PREFIX_REGEX" ] || usage_die "--url exige --selector ou --prefix-regex"
else
  [ -z "$SELECTOR$PREFIX_REGEX" ] || usage_die "--selector/--prefix-regex exigem --url"
fi

# ─── Host da URL (uma derivação só: gate Zona 3 + campo dominio do audit) ────
# Ordem importa: scheme → path → userinfo (@) → porta. Sem o strip de @,
# `https://user:pass@host/x` derivava "user" (finding do delta re-review).
HOST=""
if [ -n "$URL" ]; then
  HOST="${URL#*://}"; HOST="${HOST%%/*}"; HOST="${HOST##*@}"; HOST="${HOST%%:*}"
fi

# ─── Gate Zona 3 (P12) — o driver navega o Chrome AUTENTICADO fora do MCP ────
# O hook block-browser-mutations só intercepta o caminho MCP; sem este gate,
# um --url em domínio sensível abriria o perfil logado sem gate humano
# (finding do code-review R9). FAIL-CLOSED de verdade (delta re-review):
# blocklist ausente/ilegível/sem a chave → também bloqueia — gate não-avaliável
# nunca degrada em silêncio. O match roda sobre ".HOST" (ponto prefixado) para
# cobrir domínio apex: `stripe.com` vira `.stripe.com` e casa `\.stripe\.com`.
# --allow-sensitive (pós-confirm humano no chat) suprime COM auditoria em stderr.
if [ -n "$URL" ]; then
  if [ "$ALLOW_SENSITIVE" = true ]; then
    echo "override --allow-sensitive: gate Zona 3 suprimido para $URL" >&2
  else
    SENS_RE=""
    [ -f "$BLOCKLIST" ] && SENS_RE=$(jq -r '.sensitive_domains_regex // empty' "$BLOCKLIST" 2>/dev/null)
    if [ -z "$SENS_RE" ]; then
      echo "BLOQUEADO (fail-closed): blocklist Zona 3 ausente/ilegível ($BLOCKLIST) — gate não avaliável." >&2
      echo "Repare a blocklist (ou passe --blocklist válida); pós-confirm humano: --allow-sensitive." >&2
      exit 7
    fi
    if printf '.%s' "$HOST" | LC_ALL=C grep -Eq "$SENS_RE"; then
      echo "BLOQUEADO (Zona 3): $URL casa domínio sensível da blocklist (P12)." >&2
      echo "Confirme com o humano e re-rode com --allow-sensitive." >&2
      exit 7
    fi
  fi
fi

# ─── Guarda .gitignore ────────────────────────────────────────────────────────

abs_of() {  # absolutiza e FISICALIZA um path (componentes finais podem não
  # existir: o maior prefixo existente vira `pwd -P` + resto textual).
  # Físico porque git rev-parse --show-toplevel devolve path físico e o strip
  # de prefixo top→rel quebraria com symlink (ex. /var → /private/var).
  local p="$1" d rest="" r
  case "$p" in /*) ;; *) p="$(pwd -P)/$p" ;; esac
  d="$p"
  while [ ! -d "$d" ] && [ "$d" != "/" ]; do
    rest="/$(basename "$d")$rest"
    d=$(dirname "$d")
  done
  r=$(cd "$d" && pwd -P); [ "$r" = "/" ] && r=""
  printf '%s%s' "$r" "$rest"
}

nearest_dir() {  # ancestral existente mais próximo (contexto git de path novo)
  local d="$1"
  while [ ! -d "$d" ] && [ "$d" != "/" ] && [ -n "$d" ]; do d=$(dirname "$d"); done
  printf '%s' "$d"
}

# guard_gitignore <path> <add|require> — 0: coberto / fora de repo / entrada
# adicionada; 1: não coberto (require) ou falha ao adicionar (add)
guard_gitignore() {
  local path="$1" mode="$2" abs top rel
  abs=$(abs_of "$path")
  top=$(git -C "$(nearest_dir "$(dirname "$abs")")" rev-parse --show-toplevel 2>/dev/null) \
    || return 0
  git -C "$top" check-ignore -q "$abs" && return 0
  [ "$mode" = "add" ] || return 1
  rel="${abs#"$top"/}"
  # .gitignore sem \n final: appendar direto colaria na última linha
  if [ -s "$top/.gitignore" ] && [ -n "$(tail -c1 "$top/.gitignore")" ]; then
    printf '\n' >> "$top/.gitignore" 2>/dev/null || return 1
  fi
  printf '/%s\n' "$rel" >> "$top/.gitignore" 2>/dev/null || return 1
}

guard_gitignore "$ENV_FILE" add || {
  echo "não consegui garantir cobertura do env-file no .gitignore: $ENV_FILE" >&2
  exit 3
}
if [ "$FROM_DROP" = true ]; then
  guard_gitignore "$DROP_PATH" require || {
    echo "drop file NÃO coberto por .gitignore — não vou ler: $DROP_PATH" >&2
    echo "(mova para um path gitignored, ex. temp/.secret-drop, e rode de novo)" >&2
    exit 3
  }
fi

# ─── Captura ──────────────────────────────────────────────────────────────────

# TMPENV (rewrite do env-file) também entra no trap: contém o secret em claro
# e ficaria órfão num kill entre mktemp e mv (finding do code-review R9 — vetor
# P7: `.env-rewrite.*` não é coberto pela entrada `/.env` do .gitignore).
# Residual aceito: SIGKILL não roda trap.
TMPVAL=""; TMPENV=""
cleanup() {
  [ -n "$TMPVAL" ] && rm -f "$TMPVAL"
  [ -n "$TMPENV" ] && rm -f "$TMPENV"
  return 0
}
trap cleanup EXIT INT TERM

VALUE=""; ORIGEM=""
if [ -n "$URL" ]; then
  [ -n "$DRIVER" ] || DRIVER="node $SCRIPT_DIR/lib/secret-capture-driver.mjs"
  TMPVAL=$(mktemp "${TMPDIR:-/tmp}/secret-capture.XXXXXX") \
    || { echo "falha ao criar tmp do valor" >&2; exit 5; }
  chmod 600 "$TMPVAL"
  dargs=(--url "$URL" --out "$TMPVAL")
  [ -n "$SELECTOR" ]     && dargs+=(--selector "$SELECTOR")
  [ -n "$PREFIX_REGEX" ] && dargs+=(--prefix-regex "$PREFIX_REGEX")
  [ -n "$SLOT" ]         && dargs+=(--slot "$SLOT")
  [ -n "$PW_ROOT" ]      && dargs+=(--pw-root "$PW_ROOT")
  # stdout do driver → /dev/null: nenhum byte do driver alcança o stdout do
  # wrapper; o valor volta SÓ pelo arquivo tmp 0600 (destruído no trap).
  # Word-split intencional em $DRIVER ("node caminho.mjs").
  # shellcheck disable=SC2086
  if ! $DRIVER "${dargs[@]}" >/dev/null; then
    echo "driver de captura falhou (stderr do driver acima)" >&2
    exit 4
  fi
  VALUE=$(cat "$TMPVAL")
  ORIGEM="url"
else
  [ -f "$DROP_PATH" ] || { echo "drop file ausente: $DROP_PATH" >&2; exit 4; }
  [ -s "$DROP_PATH" ] || { echo "drop file vazio: $DROP_PATH" >&2; exit 4; }
  VALUE=$(cat "$DROP_PATH")
  ORIGEM="drop"
fi

# multi-linha é erro (env-file é linha única); pontas de whitespace aparadas
case "$VALUE" in *$'\n'*)
  echo "valor capturado tem múltiplas linhas — esperado valor de linha única" >&2
  exit 4 ;;
esac
VALUE="${VALUE#"${VALUE%%[![:space:]]*}"}"
VALUE="${VALUE%"${VALUE##*[![:space:]]}"}"
[ -n "$VALUE" ] || { echo "captura sem valor utilizável (vazio)" >&2; exit 4; }

# ─── Escrita no env-file (replace-or-append, 0600) ────────────────────────────

ENV_DIR=$(dirname "$ENV_FILE")
mkdir -p "$ENV_DIR" 2>/dev/null \
  || { echo "falha ao criar diretório do env-file: $ENV_DIR" >&2; exit 5; }
if [ -f "$ENV_FILE" ] && LC_ALL=C grep -Eq "^(export[[:space:]]+)?${ENV_KEY}=" "$ENV_FILE"; then
  # replace in-place via tmp+mv no MESMO dir; valor entra no awk por ENVIRON
  # (nunca -v/argv, visíveis em `ps`). Cobre também `export KEY=` (finding do
  # code-review R9: sem isso appendava duplicata e consumidor first-wins ficava
  # com o valor antigo), preservando o prefixo export da linha original.
  TMPENV=$(mktemp "$ENV_DIR/.env-rewrite.XXXXXX") || TMPENV=""
  if [ -z "$TMPENV" ] \
     || ! SC_KEY="$ENV_KEY" SC_VALUE="$VALUE" awk '
          BEGIN { k = ENVIRON["SC_KEY"]; v = ENVIRON["SC_VALUE"] }
          $0 ~ "^(export[ \t]+)?" k "=" {
            pfx = ($0 ~ /^export[ \t]/) ? "export " : ""
            print pfx k "=" v; next
          }
          { print }' "$ENV_FILE" > "$TMPENV" \
     || ! mv "$TMPENV" "$ENV_FILE"; then
    [ -n "$TMPENV" ] && rm -f "$TMPENV"; TMPENV=""
    echo "falha ao reescrever env-file: $ENV_FILE" >&2; exit 5
  fi
  TMPENV=""   # mv consumiu; trap não tem o que limpar
else
  # printf é builtin: o valor não passa por argv de processo externo
  printf '%s=%s\n' "$ENV_KEY" "$VALUE" >> "$ENV_FILE" 2>/dev/null \
    || { echo "falha ao escrever env-file: $ENV_FILE" >&2; exit 5; }
fi
chmod 600 "$ENV_FILE"

if [ "$ORIGEM" = "drop" ]; then
  rm -f -- "$DROP_PATH"   # move semântico: valor agora SÓ no env-file
fi

# ─── Máscara, probe, audit, inventário ────────────────────────────────────────

# Política canônica da browser-secrets: SÓ os últimos 4 chars (a forma
# anterior first-3+last-4 revelava 7 de 11 chars de um secret curto no
# transcript — finding do code-review R9)
if [ "${#VALUE}" -le 10 ]; then MASKED='****'
else MASKED="...${VALUE: -4}"; fi

# dominio segue o schema documentado do audit.jsonl da browser-secrets
# (finding do code-review R9: dois writers com schemas divergentes no mesmo
# arquivo tornam o audit não-consultável); HOST derivado junto do gate Zona 3
if [ -n "$URL" ]; then DOMINIO="$HOST"; else DOMINIO="local-drop"; fi

append_audit() {  # usa $AUDIT_VERIF; falha de escrita nunca degrada pra rc=0
  mkdir -p "$(dirname "$AUDIT_FILE")" 2>/dev/null \
    && jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg tool "$PROVIDER" --arg dominio "$DOMINIO" --arg tipo "env-secret" \
        --arg tail "$MASKED" --arg destino "$ENV_FILE:$ENV_KEY" --arg v "$AUDIT_VERIF" \
        '{timestamp: $ts, tool: $tool, dominio: $dominio, tipo: $tipo,
          tail: $tail, destino: $destino, verificacao: $v}' >> "$AUDIT_FILE" \
    || { echo "falha ao gravar audit: $AUDIT_FILE" >&2; exit 5; }
}

VERIF="sem probe"; AUDIT_VERIF="none"
if [ -n "$PROBE" ]; then
  # valor entra no probe SÓ pela env var homônima da KEY; stdout/stderr do
  # probe → /dev/null (um probe verboso poderia ecoar o valor no transcript)
  if ( export "$ENV_KEY=$VALUE"; bash -c "$PROBE" ) >/dev/null 2>&1; then
    VERIF="probe OK"; AUDIT_VERIF="live_probe:ok"
  else
    AUDIT_VERIF="live_probe:fail"
    append_audit
    echo "⚠ probe falhou para $ENV_KEY=$MASKED — valor GRAVADO em $ENV_FILE para inspeção manual" >&2
    exit 6
  fi
fi

echo "✔ $ENV_KEY=$MASKED (gravado em $ENV_FILE, $VERIF)"
append_audit

if [ "$NO_INVENTORY" = false ]; then
  # metadados apenas (o valor nunca é passado); falha é non-blocking — o
  # secret já está seguro no env-file, inventário é higiene
  "$EXPIRY_SCRIPT" add --key "$ENV_KEY" --provider "$PROVIDER" \
      --renewal-method secret-capture >/dev/null 2>&1 \
    || echo "⚠ upsert no inventário falhou (non-blocking): $EXPIRY_SCRIPT" >&2
fi
exit 0
