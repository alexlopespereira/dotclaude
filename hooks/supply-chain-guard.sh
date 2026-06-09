#!/usr/bin/env bash
# hooks/supply-chain-guard.sh — PreToolUse hook (Bash matcher).
# Fail-closed gate vs supply-chain attacks (Princípio 13 da CLAUDE.md global).
# Skill operacional: ~/.claude/skills/supply-chain-guard/SKILL.md
# ADR: docs/adr/0002-supply-chain-cooldown-gate.md

set -u

# ─── Locate libs ─────────────────────────────────────────────────────────────
# Suporta:
#   - SC_LIB_DIR override (used in tests)
#   - sibling repo (`hooks/supply-chain-guard.sh` → `bin/lib/supply-chain/`)
#   - canonical install (`~/.claude/hooks/...` → `~/Projects/dotclaude/bin/lib/supply-chain/`)
_locate_lib_dir() {
  if [ -n "${SC_LIB_DIR:-}" ] && [ -d "$SC_LIB_DIR" ]; then
    echo "$SC_LIB_DIR"; return 0
  fi
  local script_dir; script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
  if [ -d "${script_dir}/../bin/lib/supply-chain" ]; then
    (cd "${script_dir}/../bin/lib/supply-chain" && pwd)
    return 0
  fi
  if [ -d "${HOME}/Projects/dotclaude/bin/lib/supply-chain" ]; then
    echo "${HOME}/Projects/dotclaude/bin/lib/supply-chain"; return 0
  fi
  return 1
}

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$COMMAND" ] && exit 0

LIB_DIR=$(_locate_lib_dir) || {
  echo "[supply-chain-guard] WARNING: lib dir not found; allowing '$COMMAND' (fail-open instalação não-canônica)" >&2
  exit 0
}

# shellcheck source=../bin/lib/supply-chain/parser.sh
. "${LIB_DIR}/parser.sh"
# shellcheck source=../bin/lib/supply-chain/registry.sh
. "${LIB_DIR}/registry.sh"
# shellcheck source=../bin/lib/supply-chain/audit.sh
. "${LIB_DIR}/audit.sh"

# Split compound commands (`;`, `&&`, `||`, `|`, `&`) into independent segments
# and parse each. Redirect tokens (2>&1, >file, …) are dropped without creating
# a boundary. Each segment is validated independently; PROBLEMS aggregate.
SEGMENTS_JSON=$(sc_parse_command_segments "$COMMAND")

# If no segment is an install/update/run-ephemeral, this isn't an install
# command — permit (no audit, matching legacy op=other behavior).
ACTIONABLE=$(printf '%s' "$SEGMENTS_JSON" | jq -r '[.[] | select(.op != "other")] | length' 2>/dev/null)
if [ -z "$ACTIONABLE" ] || [ "$ACTIONABLE" = "0" ]; then
  exit 0
fi

COOLDOWN_DAYS="${SC_COOLDOWN_DAYS:-14}"
NOW=$(date -u +%s)
COOLDOWN_SECS=$(( COOLDOWN_DAYS * 86400 ))

PROBLEMS=()
NSEG=$(printf '%s' "$SEGMENTS_JSON" | jq -r 'length')

for ((seg=0; seg<NSEG; seg++)); do
CMD_JSON=$(printf '%s' "$SEGMENTS_JSON" | jq -c ".[$seg]")
MANAGER=$(printf '%s' "$CMD_JSON" | jq -r '.manager')
OP=$(printf '%s' "$CMD_JSON" | jq -r '.op')

# Non-install segment (e.g. the `| tail -80` tail of a pipe) → skip its checks.
if [ "$OP" = "other" ]; then
  continue
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────
_registry_for_manager() {
  case "$1" in
    npm|pnpm|yarn|bun|npx|bunx) echo "npm" ;;
    pip|pip3|pipx|uv|uvx)       echo "pypi" ;;
    *)                          echo "" ;;
  esac
}

# Parse ISO 8601 timestamp to epoch seconds. macOS + GNU date both supported.
_iso_to_epoch() {
  local iso="$1"
  # Strip fractional seconds and tz suffix variations for portable parsing.
  local clean; clean=$(printf '%s' "$iso" | sed -E 's/\.[0-9]+(Z|\+[0-9]{2}:?[0-9]{2}|-[0-9]{2}:?[0-9]{2})?$/Z/; s/Z$//')
  date -j -u -f "%Y-%m-%dT%H:%M:%S" "$clean" "+%s" 2>/dev/null || \
    date -u -d "$iso" +%s 2>/dev/null
}

# ─── Camada 1: Cooldown ──────────────────────────────────────────────────────
REGISTRY=$(_registry_for_manager "$MANAGER")
if [ -n "$REGISTRY" ]; then
  TREE_OUT=$(sc_resolve_tree "$CMD_JSON" 2>/dev/null || true)
  if [ -n "$TREE_OUT" ]; then
    while IFS= read -r pkgver; do
      [ -z "$pkgver" ] && continue
      PKG="${pkgver%@*}"
      VER="${pkgver##*@}"
      # Skip empty pkg names (defensive)
      [ -z "$PKG" ] && continue

      # npx/bunx com o pacote já presente em ./node_modules executam o binário
      # LOCAL — nenhum download acontece, logo não há evento de supply-chain a
      # validar. Sem este skip, todo release fresco (<14d) do pacote bloquearia
      # o comando canônico `npx playwright test` em repos que já o têm instalado.
      # Restrições (review adversário, P0): (a) só spec IMPLÍCITA ('*') — com
      # `npx pkg@versão`/`@latest` o npx pode baixar do registry mesmo havendo
      # cópia local de outra versão → cooldown mantém; (b) exige package.json
      # real — diretório vazio plantado não conta como install local.
      case "$MANAGER:$OP" in
        npx:run-ephemeral|bunx:run-ephemeral)
          if [ "$VER" = "*" ] && [ -f "./node_modules/$PKG/package.json" ]; then
            continue
          fi
          ;;
      esac
      # Skip non-concrete dist-tags only for the cooldown path — registry
      # lookup with `latest` works in npm view but is fragile. We attempt
      # and treat lookup failure as PARTIAL_RESOLUTION.

      pubtime=$(sc_get_publish_time "$REGISTRY" "$PKG" "$VER" 2>&1) || {
        case "$pubtime" in
          *NETWORK_ERROR*)      PROBLEMS+=("cooldown:network-error($PKG@$VER)") ;;
          *REGISTRY_5XX*)       PROBLEMS+=("cooldown:registry-5xx($PKG@$VER)") ;;
          *PACKAGE_NOT_FOUND*)  PROBLEMS+=("cooldown:package-not-found($PKG@$VER)") ;;
          *VERSION_NOT_FOUND*)  PROBLEMS+=("cooldown:version-not-found($PKG@$VER)") ;;
          *)                    PROBLEMS+=("cooldown:lookup-failed($PKG@$VER)") ;;
        esac
        continue
      }

      pub_epoch=$(_iso_to_epoch "$pubtime")
      if [ -z "$pub_epoch" ]; then
        PROBLEMS+=("cooldown:bad-time($PKG@$VER:$pubtime)")
        continue
      fi
      age=$(( NOW - pub_epoch ))
      if [ "$age" -lt "$COOLDOWN_SECS" ]; then
        days=$(( age / 86400 ))
        PROBLEMS+=("cooldown:fresh($PKG@$VER published ${days}d ago, threshold ${COOLDOWN_DAYS}d)")
      fi
    done <<< "$TREE_OUT"
  fi
fi

# ─── Camada 2: D1 — git-url deps ─────────────────────────────────────────────
GIT_PKGS=$(printf '%s' "$CMD_JSON" | jq -r '.pkgs[] | select(.type == "git-url") | .raw' 2>/dev/null)
if [ -n "$GIT_PKGS" ]; then
  while IFS= read -r raw; do
    [ -z "$raw" ] && continue
    PROBLEMS+=("git-url:$raw")
  done <<< "$GIT_PKGS"
fi

# ─── Camada 3: D2 — --ignore-scripts mandatório em Node managers ─────────────
case "$MANAGER:$OP" in
  npm:install|npm:update|pnpm:install|pnpm:update|yarn:install|yarn:update|bun:install|bun:update)
    HAS_IS=$(printf '%s' "$CMD_JSON" | jq -r '.flags | index("--ignore-scripts") // "MISSING"' 2>/dev/null)
    if [ "$HAS_IS" = "MISSING" ] || [ "$HAS_IS" = "null" ]; then
      PROBLEMS+=("scripts:--ignore-scripts missing for $MANAGER $OP")
    fi
    ;;
esac

# ─── Camada 4: Lockfile forçado (npm install sem args + lockfile presente) ──
if [ "$MANAGER" = "npm" ] && [ "$OP" = "install" ]; then
  PKGS_COUNT=$(printf '%s' "$CMD_JSON" | jq -r '.pkgs | length' 2>/dev/null)
  if [ "$PKGS_COUNT" = "0" ] && [ -f "./package-lock.json" ]; then
    HAS_FROZEN=$(printf '%s' "$CMD_JSON" | jq -r '.flags | index("--frozen-lockfile") // "MISSING"' 2>/dev/null)
    if [ "$HAS_FROZEN" = "MISSING" ] || [ "$HAS_FROZEN" = "null" ]; then
      PROBLEMS+=("lockfile:bare 'npm install' with lockfile — use 'npm ci' or --frozen-lockfile")
    fi
  fi
fi

done  # end per-segment loop

# ─── Decision ────────────────────────────────────────────────────────────────
if [ "${#PROBLEMS[@]}" -eq 0 ]; then
  sc_audit_log "allow" "$COMMAND" "" 2>/dev/null || true
  exit 0
fi

# Map each problem to the required bypass env var.
BYPASS_REQUIRED=()
for prob in "${PROBLEMS[@]}"; do
  case "$prob" in
    cooldown:*)  BYPASS_REQUIRED+=("CLAUDE_SC_BYPASS_COOLDOWN") ;;
    git-url:*)   BYPASS_REQUIRED+=("CLAUDE_SC_BYPASS_GIT_DEPS") ;;
    scripts:*)   BYPASS_REQUIRED+=("CLAUDE_SC_BYPASS_SCRIPTS") ;;
    lockfile:*)  BYPASS_REQUIRED+=("CLAUDE_SC_BYPASS_LOCKFILE") ;;
  esac
done

# Dedup
UNIQ_BYPASS=$(printf '%s\n' "${BYPASS_REQUIRED[@]}" | sort -u)

# Check that EACH required bypass is set to 1.
ALL_BYPASSED=1
while IFS= read -r need; do
  [ -z "$need" ] && continue
  val="${!need:-}"
  if [ "$val" != "1" ]; then
    ALL_BYPASSED=0
    break
  fi
done <<< "$UNIQ_BYPASS"

if [ "$ALL_BYPASSED" = "1" ]; then
  REASON="${CLAUDE_SC_REASON:-}"
  if [ -z "$REASON" ]; then
    {
      echo "BLOCKED (supply-chain-guard): bypass env(s) presente(s) mas CLAUDE_SC_REASON está vazio."
      echo "Bypass cirúrgico exige justificativa textual obrigatória (Princípio 13)."
      echo ""
      echo "Tente novamente com:"
      echo "  $(echo "$UNIQ_BYPASS" | tr '\n' ' ' | sed 's/ $//')=1 CLAUDE_SC_REASON=\"motivo concreto\" $COMMAND"
    } >&2
    sc_audit_log "block" "$COMMAND" "bypass without REASON" 2>/dev/null || true
    exit 2
  fi
  sc_audit_log "bypass" "$COMMAND" "$REASON" 2>/dev/null || true
  exit 0
fi

# Aggregated block message (Princípio: uma rodada, todos os problemas).
{
  echo "BLOCKED (supply-chain-guard): comando viola Princípio 13 (supply-chain hygiene)."
  echo ""
  echo "Problemas detectados:"
  for p in "${PROBLEMS[@]}"; do
    echo "  • $p"
  done
  echo ""
  echo "Como prosseguir (corrigir o comando):"
  if printf '%s\n' "${PROBLEMS[@]}" | grep -q '^scripts:'; then
    case "$MANAGER" in
      npm|pnpm|yarn|bun)
        echo "  • Adicione --ignore-scripts ao comando."
        ;;
    esac
  fi
  if printf '%s\n' "${PROBLEMS[@]}" | grep -q '^lockfile:'; then
    echo "  • Use 'npm ci' ao invés de 'npm install' (respeita lockfile commitado)."
  fi
  if printf '%s\n' "${PROBLEMS[@]}" | grep -q '^cooldown:fresh'; then
    echo "  • Pacote(s) recém-publicado(s): aguarde 14 dias OU justifique bypass."
  fi
  if printf '%s\n' "${PROBLEMS[@]}" | grep -q '^git-url:'; then
    echo "  • Dependência git-url bloqueada (vetor TanStack): troque por versão de registry OU bypass com REASON."
  fi
  echo ""
  echo "Bypass cirúrgico (cada flag cobre UMA camada — defesa em profundidade):"
  while IFS= read -r env; do
    [ -z "$env" ] && continue
    echo "  • ${env}=1"
  done <<< "$UNIQ_BYPASS"
  echo "  • CLAUDE_SC_REASON=\"texto justificando bypass\"  (obrigatório)"
  echo ""
  echo "Exemplo de invocação corrigida:"
  ONELINE_ENVS=$(echo "$UNIQ_BYPASS" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ //; s/ $//')
  # shellcheck disable=SC2001
  ONELINE_ENVS=$(echo "$ONELINE_ENVS" | sed 's/[A-Z_]*$/&=1/; s/ /=1 /g')
  echo "  ${ONELINE_ENVS} CLAUDE_SC_REASON=\"motivo concreto\" $COMMAND"
  echo ""
  echo "Detalhes: ~/.claude/skills/supply-chain-guard/SKILL.md"
} >&2

PROBLEMS_JOINED=$(printf '%s; ' "${PROBLEMS[@]}")
sc_audit_log "block" "$COMMAND" "$PROBLEMS_JOINED" 2>/dev/null || true
exit 2
