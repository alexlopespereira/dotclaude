#!/usr/bin/env bash
# auth-preflight.sh — probe consolidado de credenciais no início de tarefa longa.
#
# O QUE FAZ: proba a saúde de auth das CLIs/keys do catálogo (gh, gcloud, sf,
# codex, gemini) e imprime 1 linha por tool + UM pedido consolidado de
# renovação quando há pendências — em vez de 3 interrupções espalhadas
# mid-task (R5 de ~/analise-interrupcoes/autonomia-recomendacoes.md).
# Operacional: skills/auth-preflight/SKILL.md.
#
# MODOS:
#   auto (default)      — proba o catálogo inteiro; tool não instalada (ou
#                         gemini sem key) = SKIP, não conta como pendência.
#   requerido (--tools) — proba só as listadas ("a tarefa precisa destas");
#                         ausente vira MISSING e derruba o exit code.
#
# CACHE: só resultado OK é cacheado (TTL default 1h) — DEAD nunca, para que
# uma renovação recém-feita seja vista no próximo run sem --refresh.
#
# SAÍDA: tab-separated `tool<TAB>STATUS<TAB>detalhe`; STATUS ∈ OK|DEAD|MISSING|SKIP.
# Exit: 0 sem pendência; 1 com DEAD/MISSING; 2 uso inválido.
#
# ADVISORY DE EXPIRAÇÃO (US-02 do plano R9): credenciais vencendo em ≤14d no
# inventário do secrets-expiry.sh (--expiry-file) viram linhas '⚠ expira:' após
# os probes (texto) ou o campo "expiring" (--json). Advisory NUNCA conta como
# pendência — os exit codes acima ficam inalterados.
#
# Probes com teto perl-alarm (SIGALRM → exit 142), mesmo idioma do preflight
# do Ralph (ralph-adversarial.sh) e do ship.sh. A key do Gemini nunca entra em
# argv (visível em `ps`): vai por header via `curl -K -` (config no stdin).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Uso: auth-preflight.sh [opções]
  --tools LIST     modo requerido: só estas tools, separadas por vírgula
                   (gh,gcloud,sf,codex,gemini); ausente = MISSING (exit 1)
  --cache-dir DIR  default ~/.claude/cache/auth-preflight
  --ttl SECONDS    validade do cache de OK (default 3600)
  --timeout SECONDS  teto por probe (default 15)
  --refresh        ignora e re-popula o cache
  --json           saída JSON ({"tools":[...],"pending":N,"expiring":[...]})
                   em vez de texto
  --expiry-file F  inventário de expiração do secrets-expiry.sh
                   (default ~/.claude/cache/secrets/expiry.jsonl); vencendo em
                   ≤14d vira advisory '⚠ expira:' — nunca pendência
EOF
}

CACHE_DIR="$HOME/.claude/cache/auth-preflight"
TTL=3600
TIMEOUT=15
REFRESH=false
JSON=false
TOOLS=""
EXPIRY_FILE="$HOME/.claude/cache/secrets/expiry.jsonl"

need_val() {  # need_val <flag> <$#> — flag de valor sem valor → uso inválido
  # (sem a guarda, `shift 2` com $#=1 falha SEM consumir $1 e o while abaixo
  # nunca termina — finding da review US-02; idioma do secrets-expiry.sh)
  [ "$2" -ge 2 ] || { echo "faltando valor para $1" >&2; usage >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tools)     need_val "$1" $#; TOOLS="$2"; shift 2 ;;
    --cache-dir) need_val "$1" $#; CACHE_DIR="$2"; shift 2 ;;
    --ttl)       need_val "$1" $#; TTL="$2"; shift 2 ;;
    --timeout)   need_val "$1" $#; TIMEOUT="$2"; shift 2 ;;
    --expiry-file) need_val "$1" $#; EXPIRY_FILE="$2"; shift 2 ;;
    --refresh)   REFRESH=true; shift ;;
    --json)      JSON=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "opção desconhecida: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ─── Catálogo table-driven: tool <TAB> probe <TAB> hint de renovação ─────────
# gemini usa probe sintético __gemini__ (curl -K - com key por header/stdin).
catalog() {
  printf '%s\n' \
    "gh	gh auth status	gh auth login" \
    "gcloud	gcloud auth print-access-token	gcloud auth login" \
    "sf	sf org display --json	sf org login web" \
    "codex	codex login status	codex login" \
    "gemini	__gemini__	provisione via skill browser-secrets"
}

# --tools: valida nomes contra o catálogo (typo → uso inválido, não SKIP mudo)
if [ -n "$TOOLS" ]; then
  for t in $(printf '%s' "$TOOLS" | tr ',' ' '); do
    catalog | cut -f1 | grep -qx "$t" || {
      echo "tool desconhecida em --tools: $t" >&2; usage >&2; exit 2; }
  done
fi

mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/status.tsv"   # linhas: tool<TAB>epoch (só OK)
touch "$CACHE_FILE"
NOW=$(date +%s)

# Key do Gemini: env primeiro, fallback ./.env (padrão browser-secrets grava lá).
APF_GEMINI_KEY="${GEMINI_API_KEY:-}"
if [ -z "$APF_GEMINI_KEY" ] && [ -f ./.env ]; then
  APF_GEMINI_KEY=$(grep -m1 '^GEMINI_API_KEY=' ./.env | cut -d= -f2- | tr -d '"'"'")
fi
export APF_GEMINI_KEY

# in_scope <tool> — modo requerido filtra; modo auto aceita tudo.
in_scope() {
  [ -z "$TOOLS" ] && return 0
  printf '%s' "$TOOLS" | tr ',' '\n' | grep -qx "$1"
}

TEXT_OUT=""
JSON_ITEMS=""
PENDING=""
NPEND=0
NEWCACHE=""

emit() {  # emit <tool> <status> <detail>
  TEXT_OUT="${TEXT_OUT}$(printf '%s\t%s\t%s' "$1" "$2" "$3")
"
  [ -n "$JSON_ITEMS" ] && JSON_ITEMS="${JSON_ITEMS},"
  JSON_ITEMS="${JSON_ITEMS}$(printf '{"tool":"%s","status":"%s","detail":"%s"}' "$1" "$2" "$3")"
}

while IFS='	' read -r tool probe hint; do
  in_scope "$tool" || { # fora do escopo requerido: preserva cache existente
    entry=$(awk -F'\t' -v t="$tool" '$1==t' "$CACHE_FILE")
    [ -n "$entry" ] && NEWCACHE="${NEWCACHE}${entry}
"
    continue
  }

  # disponibilidade: binário no PATH; gemini = key presente + curl
  if [ "$tool" = "gemini" ]; then
    if [ -z "$APF_GEMINI_KEY" ] || ! command -v curl >/dev/null 2>&1; then
      if [ -n "$TOOLS" ]; then
        emit "$tool" MISSING "GEMINI_API_KEY ausente (env e ./.env) — provisione via browser-secrets"
        NPEND=$((NPEND+1)); PENDING="${PENDING}[gemini] $hint; "
      else
        emit "$tool" SKIP "GEMINI_API_KEY ausente — fora do escopo"
      fi
      continue
    fi
  elif ! command -v "$tool" >/dev/null 2>&1; then
    if [ -n "$TOOLS" ]; then
      emit "$tool" MISSING "não instalada — instale e autentique ($hint)"
      NPEND=$((NPEND+1)); PENDING="${PENDING}[$tool] $hint; "
    else
      emit "$tool" SKIP "não instalada"
    fi
    continue
  fi

  # cache de OK ainda fresco → não re-proba
  if [ "$REFRESH" = "false" ]; then
    epoch=$(awk -F'\t' -v t="$tool" '$1==t{print $2}' "$CACHE_FILE")
    if [ -n "$epoch" ] && [ $((NOW - epoch)) -lt "$TTL" ]; then
      emit "$tool" OK "(cache $(( (NOW - epoch) / 60 ))m)"
      NEWCACHE="${NEWCACHE}${tool}	${epoch}
"
      continue
    fi
  fi

  if [ "$tool" = "gemini" ]; then
    probe='printf '\''url = "https://generativelanguage.googleapis.com/v1beta/models"\nheader = "x-goog-api-key: %s"\n'\'' "$APF_GEMINI_KEY" | curl -fsS --max-time '"$TIMEOUT"' -K -'
  fi

  rc=0
  perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" bash -c "$probe" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    emit "$tool" OK ""
    NEWCACHE="${NEWCACHE}${tool}	${NOW}
"
  elif [ "$rc" -eq 142 ]; then
    emit "$tool" DEAD "timeout ${TIMEOUT}s — renove: $hint"
    NPEND=$((NPEND+1)); PENDING="${PENDING}[$tool] $hint; "
  else
    emit "$tool" DEAD "renove: $hint"
    NPEND=$((NPEND+1)); PENDING="${PENDING}[$tool] $hint; "
  fi
done <<EOF
$(catalog)
EOF

printf '%s' "$NEWCACHE" > "$CACHE_FILE"

# ─── Advisory de expiração (US-02 do plano R9) — delega ao `due` ─────────────
# Fonte ÚNICA da semântica do inventário é secrets-expiry.sh (code-review R9:
# a cópia inline divergiu no nascimento — `days` vs `days_left`, corrupção
# silenciosa → []). rc do due: 0 sem due / 1 há due / 3 corrompido. Corrupção
# nunca é silenciosa (texto: aviso em stderr; --json: campo expiring_error) e
# nunca derruba o preflight (advisory não é pendência). Entrada já vencida
# (days_left < 0) rende "vencida há Nd", não "expira em -Nd".
EXPIRING="[]"; EXPIRY_ERROR=""
SE_SCRIPT="$SCRIPT_DIR/secrets-expiry.sh"
if [ -f "$EXPIRY_FILE" ] && [ -f "$SE_SCRIPT" ]; then
  DUE_RC=0
  DUE_OUT=$(bash "$SE_SCRIPT" due --days 14 --json --file "$EXPIRY_FILE" 2>/dev/null) || DUE_RC=$?
  case "$DUE_RC" in
    0|1) EXPIRING=$(printf '%s' "$DUE_OUT" | jq -c 'map({key_name, days_left})' 2>/dev/null) \
           || EXPIRING="[]" ;;
    3)   EXPIRY_ERROR="inventário de secrets ilegível: $EXPIRY_FILE" ;;
  esac
fi

if [ "$JSON" = "true" ]; then
  EXP_ERR_JSON=""
  [ -z "$EXPIRY_ERROR" ] \
    || EXP_ERR_JSON=$(printf ',"expiring_error":%s' "$(printf '%s' "$EXPIRY_ERROR" | jq -Rc .)")
  printf '{"tools":[%s],"pending":%d,"expiring":%s%s}\n' \
    "$JSON_ITEMS" "$NPEND" "$EXPIRING" "$EXP_ERR_JSON"
else
  [ -z "$EXPIRY_ERROR" ] || echo "⚠ $EXPIRY_ERROR (advisory suprimido)" >&2
  printf '%s' "$TEXT_OUT"
  if [ "$EXPIRING" != "[]" ]; then
    printf '%s' "$EXPIRING" | jq -r '.[] |
      if .days_left < 0
      then "⚠ vencida: \(.key_name) há \(-(.days_left))d — renove agora"
      else "⚠ expira: \(.key_name) em \(.days_left)d — renove proativamente"
      end'
  fi
  if [ "$NPEND" -gt 0 ]; then
    printf '→ %d pendência(s) — resolva TUDO num único pedido consolidado: %s\n' \
      "$NPEND" "${PENDING%; }"
  fi
fi

[ "$NPEND" -gt 0 ] && exit 1
exit 0
