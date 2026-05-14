#!/usr/bin/env bash
# bin/lib/supply-chain/parser.sh — sintatic parser of install commands.
# Used by hooks/supply-chain-guard.sh (US-05).
#
# sc_parse_command "<command-string>" → JSON to stdout
#   {manager, op, pkgs: [{name, spec, type, raw}], flags: []}
#
# Pure: no network, no filesystem reads. Limit: subshells/wrappers
# (bash -c, eval, nohup) reduce to op=other (documented in Princípio 13
# and skills/supply-chain-guard/SKILL.md §(e)).

# Classify a single package spec into {name, spec, type, raw} JSON.
_sc_parse_spec() {
  local raw="$1"
  local name spec type

  case "$raw" in
    'github:'*)
      type="git-url"; spec="$raw"
      name="${raw#github:}"; name="${name%%#*}"
      ;;
    'git+'*|'git@'*)
      type="git-url"; spec="$raw"; name="$raw"
      ;;
    'http://github.com/'*|'https://github.com/'*|'http://gitlab.com/'*|'https://gitlab.com/'*|'http://bitbucket.org/'*|'https://bitbucket.org/'*)
      type="git-url"; spec="$raw"; name="$raw"
      ;;
    'workspace:'*)
      type="workspace"; spec="$raw"; name=""
      ;;
    'file:'*|'link:'*|'portal:'*)
      type="local"; spec="$raw"; name=""
      ;;
    'catalog:'*)
      type="local"; spec="$raw"; name=""
      ;;
    'npm:'*)
      type="alias"; spec="$raw"; name="$raw"
      ;;
    *.tgz|*.tar.gz|*.tar)
      type="local"; spec="$raw"; name=""
      ;;
    ./*|../*|/*)
      type="local"; spec="$raw"; name=""
      ;;
    *)
      # Heuristic for npm git shorthand: "user/repo" without leading @ and without '@version'
      if [[ "$raw" =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+(#[A-Za-z0-9_.-]+)?$ ]]; then
        type="git-url"; spec="$raw"; name="${raw%%#*}"
      else
        type="registry"
        if [[ "$raw" == @* ]]; then
          # Scoped: @scope/pkg or @scope/pkg@version
          if [[ "$raw" =~ ^(@[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(@(.+))?$ ]]; then
            name="${BASH_REMATCH[1]}"
            spec="${BASH_REMATCH[3]:-*}"
          else
            name="$raw"; spec="*"
          fi
        else
          if [[ "$raw" == *@* ]]; then
            name="${raw%@*}"; spec="${raw##*@}"
          else
            name="$raw"; spec="*"
          fi
        fi
      fi
      ;;
  esac

  jq -n -c \
    --arg n "$name" --arg s "$spec" --arg t "$type" --arg r "$raw" \
    '{name:$n, spec:$s, type:$t, raw:$r}'
}

sc_parse_command() {
  local cmd="$1"

  # Strip leading/trailing whitespace
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  cmd="${cmd%"${cmd##*[![:space:]]}"}"

  # Subshell / wrapper detection → op=other (limite conhecido)
  case "$cmd" in
    'bash -c '*|'sh -c '*|'zsh -c '*|'eval '*|'nohup '*|'time '*|'env '*'='*' '*|'env '*)
      jq -n -c '{manager:"other", op:"other", pkgs:[], flags:[]}'
      return 0
      ;;
  esac

  # Simple whitespace tokenization (limit: doesn't expand $vars, doesn't
  # honor quoted args with spaces — acceptable for install commands which
  # never use such constructs in practice).
  local -a tokens
  read -r -a tokens <<< "$cmd"

  local manager="${tokens[0]:-}"
  local sub1="${tokens[1]:-}"
  local sub2="${tokens[2]:-}"
  local op="other"
  local start_idx=2

  case "$manager" in
    npm)
      case "$sub1" in
        i|install|add)             op="install" ;;
        update|up)                 op="update" ;;
        *)                         op="other" ;;
      esac
      ;;
    pnpm)
      case "$sub1" in
        add)                       op="install" ;;
        i|install)                 op="install" ;;
        update|up|upgrade)         op="update" ;;
        dlx)                       op="run-ephemeral" ;;
        *)                         op="other" ;;
      esac
      ;;
    yarn)
      case "$sub1" in
        add)                       op="install" ;;
        install)                   op="install" ;;
        upgrade)                   op="update" ;;
        dlx)                       op="run-ephemeral" ;;
        *)                         op="other" ;;
      esac
      ;;
    bun)
      case "$sub1" in
        add)                       op="install" ;;
        install|i)                 op="install" ;;
        update|up)                 op="update" ;;
        *)                         op="other" ;;
      esac
      ;;
    pip|pip3)
      case "$sub1" in
        install)                   op="install" ;;
        *)                         op="other" ;;
      esac
      ;;
    pipx)
      case "$sub1" in
        install)                   op="install" ;;
        run)                       op="run-ephemeral" ;;
        *)                         op="other" ;;
      esac
      ;;
    uv)
      case "$sub1" in
        add)
          op="install" ;;
        pip)
          case "$sub2" in
            install) op="install"; start_idx=3 ;;
            *)       op="other" ;;
          esac
          ;;
        tool)
          case "$sub2" in
            install) op="install"; start_idx=3 ;;
            run)     op="run-ephemeral"; start_idx=3 ;;
            *)       op="other" ;;
          esac
          ;;
        *) op="other" ;;
      esac
      ;;
    npx)
      manager="npx"; op="run-ephemeral"; start_idx=1
      ;;
    uvx)
      manager="uvx"; op="run-ephemeral"; start_idx=1
      ;;
    bunx)
      manager="bunx"; op="run-ephemeral"; start_idx=1
      ;;
    *)
      manager="other"; op="other"
      ;;
  esac

  if [ "$op" = "other" ]; then
    jq -n -c --arg m "$manager" '{manager:$m, op:"other", pkgs:[], flags:[]}'
    return 0
  fi

  local pkgs_json="[]"
  local flags_json="[]"
  local skip_next=0
  local i

  for ((i=start_idx; i<${#tokens[@]}; i++)); do
    local tok="${tokens[$i]}"

    if [ "$skip_next" = "1" ]; then
      skip_next=0
      continue
    fi

    case "$tok" in
      # pip/uv: -r requirements.txt / -c constraints.txt — file install (no pkg specs)
      -r|--requirement|-c|--constraint)
        skip_next=1
        flags_json=$(echo "$flags_json" | jq -c --arg f "$tok" '. + [$f]')
        continue
        ;;
      -U|--upgrade)
        op="update"
        flags_json=$(echo "$flags_json" | jq -c --arg f "$tok" '. + [$f]')
        continue
        ;;
      --ignore-scripts|--frozen-lockfile|--no-save|--save-dev|-D|--dev|-g|--global|--save|-S|--save-exact|-E)
        flags_json=$(echo "$flags_json" | jq -c --arg f "$tok" '. + [$f]')
        continue
        ;;
      -*)
        # Unknown/other flag: capture but don't act on it
        flags_json=$(echo "$flags_json" | jq -c --arg f "$tok" '. + [$f]')
        continue
        ;;
      *)
        local spec_json
        spec_json=$(_sc_parse_spec "$tok")
        pkgs_json=$(echo "$pkgs_json" | jq -c --argjson p "$spec_json" '. + [$p]')
        continue
        ;;
    esac
  done

  jq -n -c \
    --arg m "$manager" --arg op "$op" \
    --argjson pkgs "$pkgs_json" --argjson flags "$flags_json" \
    '{manager:$m, op:$op, pkgs:$pkgs, flags:$flags}'
}

# Allow direct invocation for ad-hoc testing: `parser.sh "npm install foo"`
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  sc_parse_command "$@"
fi
