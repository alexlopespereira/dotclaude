#!/usr/bin/env bash
# bin/lib/supply-chain/registry.sh — publish-time lookup + dry-run tree
# resolution per package manager. Consumed by hooks/supply-chain-guard.sh.
#
# Error codes (printed to stderr on failure):
#   PACKAGE_NOT_FOUND  — registry returned 404 for the package name
#   VERSION_NOT_FOUND  — package exists, version doesn't
#   NETWORK_ERROR      — DNS failure, connection refused, timeout
#   REGISTRY_5XX       — server error from registry
#   UNSUPPORTED        — registry/manager outside cobertura inicial

SC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./cache.sh
. "$SC_LIB_DIR/cache.sh"

# sc_get_publish_time <registry> <pkg> <version>
#   <registry> ∈ {npm, pypi}. Returns ISO 8601 publish timestamp on stdout.
#   On error, prints classified error code to stderr and returns non-zero.
#   Uses cache when available; populates cache on miss.
sc_get_publish_time() {
  local registry="$1" pkg="$2" version="$3"

  if [ -z "$registry" ] || [ -z "$pkg" ] || [ -z "$version" ]; then
    echo "INVALID_ARGS" >&2
    return 2
  fi

  # Cache hit short-circuits network.
  local cached
  if cached=$(sc_cache_get "$registry" "$pkg" "$version" 2>/dev/null); then
    if [ -n "$cached" ]; then
      printf '%s\n' "$cached"
      return 0
    fi
  fi

  case "$registry" in
    npm)
      _sc_fetch_npm_time "$pkg" "$version"
      ;;
    pypi)
      _sc_fetch_pypi_time "$pkg" "$version"
      ;;
    *)
      echo "UNSUPPORTED" >&2
      return 3
      ;;
  esac
}

# _sc_classify_npm_err <output> — classifica stderr de um `npm view` que falhou
# nos códigos padrão (PACKAGE_NOT_FOUND/VERSION_NOT_FOUND/NETWORK_ERROR/REGISTRY_5XX).
_sc_classify_npm_err() {
  local output="$1"
  if echo "$output" | grep -qE 'E404|not found|Not found|Not Found'; then
    # Distinguish package vs version 404 by presence of version in error.
    if echo "$output" | grep -qE "version.*not (found|in)|No matching version"; then
      echo "VERSION_NOT_FOUND"
    else
      echo "PACKAGE_NOT_FOUND"
    fi
  elif echo "$output" | grep -qE 'ETIMEDOUT|ECONNREFUSED|ENOTFOUND|getaddrinfo|network'; then
    echo "NETWORK_ERROR"
  elif echo "$output" | grep -qE 'E5[0-9]{2}|server error|Service Unavailable'; then
    echo "REGISTRY_5XX"
  else
    # Unknown failure mode: fail-closed.
    echo "NETWORK_ERROR"
  fi
}

# _sc_fetch_npm_time <pkg> <version> — queries `npm view`.
_sc_fetch_npm_time() {
  local pkg="$1" version="$2"
  local output rc

  # Spec NÃO-concreta (*, latest, ^/~ range, dist-tag) precisa resolver para
  # versão concreta ANTES do lookup — `time` é indexado por versão exata.
  # FP real (audit 2026-06): `npx playwright test` → playwright@* →
  # VERSION_NOT_FOUND → block do comando canônico de teste do harness.
  if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'; then
    local resolved
    if [ "$version" = "*" ] || [ "$version" = "latest" ]; then
      resolved=$(npm view "$pkg" dist-tags.latest 2>&1)
      rc=$?
    else
      resolved=$(npm view "$pkg@$version" version --json 2>&1)
      rc=$?
      if [ "$rc" -eq 0 ]; then
        # --json: array de versões satisfazíveis (última = maior) ou escalar.
        resolved=$(printf '%s' "$resolved" | jq -r 'if type=="array" then .[-1] else . end' 2>/dev/null)
      fi
    fi
    if [ "$rc" -ne 0 ]; then
      _sc_classify_npm_err "$resolved" >&2
      return 1
    fi
    resolved=$(printf '%s' "$resolved" | head -1 | tr -d ' \t"')
    if [ -z "$resolved" ] || [ "$resolved" = "null" ]; then
      echo "VERSION_NOT_FOUND" >&2
      return 1
    fi
    version="$resolved"
    # A versão resolvida pode já estar no cache — evita o 2º npm view.
    local cached
    if cached=$(sc_cache_get "npm" "$pkg" "$version" 2>/dev/null) && [ -n "$cached" ]; then
      printf '%s\n' "$cached"
      return 0
    fi
  fi

  # IMPORTANTE: `time.<x.y.z>` é interpretado pelo npm como field-path ANINHADO
  # (time→x→y→z, os pontos da versão viram descida de chave) e retorna VAZIO
  # com rc=0 — por isso o cooldown nunca funcionou live: todo lookup concreto
  # virava VERSION_NOT_FOUND fail-closed. O acesso correto é `time[x.y.z]`.
  output=$(npm view "$pkg@$version" "time[$version]" 2>&1)
  rc=$?

  if [ "$rc" -ne 0 ]; then
    _sc_classify_npm_err "$output" >&2
    return 1
  fi

  # Output should be an ISO timestamp. Empty = version unknown.
  local iso
  iso=$(printf '%s' "$output" | head -1 | tr -d ' \t')
  if [ -z "$iso" ] || ! echo "$iso" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
    echo "VERSION_NOT_FOUND" >&2
    return 1
  fi

  sc_cache_put "npm" "$pkg" "$version" "$iso" 2>/dev/null
  printf '%s\n' "$iso"
}

# _sc_fetch_pypi_time <pkg> <version> — queries pypi.org/pypi/<pkg>/<v>/json.
_sc_fetch_pypi_time() {
  local pkg="$1" version="$2"

  # Spec não-concreta: resolve via packument (URL SEM versão) — .info.version
  # é a release atual e .urls[0].upload_time já é o publish-time dela (evita
  # um segundo fetch). Mesma classe de FP do npm spec '*'.
  if [ -z "$version" ] || [ "$version" = "*" ] || [ "$version" = "latest" ]; then
    local ptmp pcode pbody
    ptmp=$(mktemp)
    pcode=$(curl -sS -o "$ptmp" -w "%{http_code}" --max-time 10 "https://pypi.org/pypi/${pkg}/json" 2>/dev/null) || {
      rm -f "$ptmp"
      echo "NETWORK_ERROR" >&2
      return 1
    }
    pbody=$(cat "$ptmp")
    rm -f "$ptmp"
    case "$pcode" in
      200) : ;;
      404) echo "PACKAGE_NOT_FOUND" >&2; return 1 ;;
      5*)  echo "REGISTRY_5XX" >&2; return 1 ;;
      *)   echo "NETWORK_ERROR" >&2; return 1 ;;
    esac
    version=$(printf '%s' "$pbody" | jq -r '.info.version // empty' 2>/dev/null)
    if [ -z "$version" ]; then
      echo "VERSION_NOT_FOUND" >&2
      return 1
    fi
    local cached
    if cached=$(sc_cache_get "pypi" "$pkg" "$version" 2>/dev/null) && [ -n "$cached" ]; then
      printf '%s\n' "$cached"
      return 0
    fi
    local iso
    iso=$(printf '%s' "$pbody" | jq -r '(.urls // [])[0].upload_time // empty' 2>/dev/null)
    if [ -n "$iso" ] && echo "$iso" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
      sc_cache_put "pypi" "$pkg" "$version" "$iso" 2>/dev/null
      printf '%s\n' "$iso"
      return 0
    fi
    # Packument sem .urls (raro): cai no fetch versionado normal abaixo.
  fi

  local url="https://pypi.org/pypi/${pkg}/${version}/json"
  local body http_code

  # -w writes the HTTP code to stdout; we separate body and status.
  local tmp; tmp=$(mktemp)
  http_code=$(curl -sS -o "$tmp" -w "%{http_code}" --max-time 10 "$url" 2>/dev/null) || {
    rm -f "$tmp"
    echo "NETWORK_ERROR" >&2
    return 1
  }
  body=$(cat "$tmp")
  rm -f "$tmp"

  case "$http_code" in
    200)
      # The response has .urls[].upload_time (or .releases[<v>][0].upload_time).
      local iso
      iso=$(printf '%s' "$body" | jq -r '(.urls // [])[0].upload_time // empty' 2>/dev/null)
      if [ -z "$iso" ]; then
        iso=$(printf '%s' "$body" | jq -r --arg v "$version" '(.releases[$v] // [])[0].upload_time // empty' 2>/dev/null)
      fi
      if [ -z "$iso" ] || ! echo "$iso" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
        echo "VERSION_NOT_FOUND" >&2
        return 1
      fi
      sc_cache_put "pypi" "$pkg" "$version" "$iso" 2>/dev/null
      printf '%s\n' "$iso"
      ;;
    404)
      # PyPI returns 404 for both pkg and version. Can't distinguish without
      # a second call; we conservatively call it VERSION_NOT_FOUND if curl
      # body mentions the version, else PACKAGE_NOT_FOUND.
      if printf '%s' "$body" | grep -q "$version"; then
        echo "VERSION_NOT_FOUND" >&2
      else
        echo "PACKAGE_NOT_FOUND" >&2
      fi
      return 1
      ;;
    5*)
      echo "REGISTRY_5XX" >&2
      return 1
      ;;
    000|"")
      echo "NETWORK_ERROR" >&2
      return 1
      ;;
    *)
      echo "REGISTRY_5XX" >&2
      return 1
      ;;
  esac
}

# sc_resolve_tree <command-json>  (US-05 will integrate; US-03 ships
# the npm + pip variants; pnpm/yarn/bun/uv handlers are stubs that
# fall back to root-only validation marked as PARTIAL_RESOLUTION).
#
# Emits one "<pkg>@<version>" per line on stdout. Empty output means
# "no resolvable packages" (skip-list types). Returns 0 on success,
# 1 on resolver failure (treat as fail-closed in caller).
sc_resolve_tree() {
  local cmd_json="$1"
  local manager op
  manager=$(printf '%s' "$cmd_json" | jq -r '.manager')
  op=$(printf '%s' "$cmd_json" | jq -r '.op')

  case "$manager:$op" in
    npm:install|npm:update)
      _sc_resolve_npm "$cmd_json"
      ;;
    pip:install|pip:update)
      _sc_resolve_pip "$cmd_json"
      ;;
    pnpm:*|yarn:*|bun:*|uv:*|pipx:*|npx:*|uvx:*|bunx:*)
      # Root-only fallback: emit the pkg specs as-is. The hook treats
      # this as PARTIAL_RESOLUTION — cooldown still applies to roots.
      _sc_resolve_root_only "$cmd_json"
      ;;
    *)
      return 1
      ;;
  esac
}

_sc_resolve_root_only() {
  local cmd_json="$1"
  # Emit pkg@spec for non-skip-list types only.
  printf '%s' "$cmd_json" | jq -r '
    .pkgs[]
    | select(.type == "registry")
    | "\(.name)@\(.spec)"
  '
}

_sc_resolve_npm() {
  local cmd_json="$1"
  local pkgs
  pkgs=$(printf '%s' "$cmd_json" | jq -r '
    .pkgs[]
    | select(.type == "registry")
    | "\(.raw)"
  ')
  if [ -z "$pkgs" ]; then
    # `npm install` (no args) — dry-run resolves the entire lockfile/manifest.
    local out
    out=$(npm install --dry-run --json --silent 2>/dev/null) || return 1
    printf '%s' "$out" | jq -r '
      (.added // []) + (.updated // []) + (.changed // [])
      | .[]?
      | "\(.name)@\(.version)"
    '
    return 0
  fi
  # Add-mode: dry-run with the specific packages.
  # shellcheck disable=SC2086
  local out
  out=$(npm install --dry-run --json --silent --no-save $pkgs 2>/dev/null) || {
    # Fallback: root-only.
    _sc_resolve_root_only "$cmd_json"
    return 0
  }
  printf '%s' "$out" | jq -r '
    (.added // []) + (.updated // []) + (.changed // [])
    | .[]?
    | "\(.name)@\(.version)"
  '
}

_sc_resolve_pip() {
  local cmd_json="$1"
  local pkgs
  pkgs=$(printf '%s' "$cmd_json" | jq -r '
    .pkgs[]
    | select(.type == "registry")
    | "\(.raw)"
  ')
  if [ -z "$pkgs" ]; then
    # `pip install -r requirements.txt` — fallback to root-only (the parser
    # already gave us .pkgs=[]; we can't enumerate without manifest path).
    return 0
  fi
  # `pip install --dry-run --report - <pkg>` writes the resolution
  # plan as JSON to stdout (pip ≥ 22.2).
  # shellcheck disable=SC2086
  local out
  out=$(pip install --dry-run --quiet --report - $pkgs 2>/dev/null) || {
    _sc_resolve_root_only "$cmd_json"
    return 0
  }
  printf '%s' "$out" | jq -r '
    (.install // [])
    | .[]?
    | "\(.metadata.name)@\(.metadata.version)"
  ' 2>/dev/null || _sc_resolve_root_only "$cmd_json"
}
