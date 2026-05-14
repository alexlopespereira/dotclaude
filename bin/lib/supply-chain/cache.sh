#!/usr/bin/env bash
# bin/lib/supply-chain/cache.sh — atomic key/value cache for immutable
# registry timestamps. TTL infinito porque o campo "publish_time" de uma
# versão é imutável no registry (vide ADR-0002 §Cache).
#
# Layout: ${SC_CACHE_DIR:-$HOME/.claude/cache/supply-chain}/registry-times/
#         <registry>/<pkg>/<version>.iso
#
# Escrita atômica via write-tmp-rename. mv(2) é atomic dentro do mesmo
# filesystem em POSIX — leitor concorrente nunca vê half-write.

_sc_cache_root() {
  echo "${SC_CACHE_DIR:-$HOME/.claude/cache/supply-chain}/registry-times"
}

# Escape package name for filesystem safety (especially scoped pkgs with /).
_sc_cache_escape() {
  printf '%s' "$1" | sed 's|/|__|g'
}

_sc_cache_path() {
  local registry="$1" pkg="$2" version="$3"
  printf '%s/%s/%s/%s.iso' \
    "$(_sc_cache_root)" "$registry" "$(_sc_cache_escape "$pkg")" "$version"
}

# sc_cache_get <registry> <pkg> <version>
#   On hit: prints cached ISO timestamp to stdout, returns 0.
#   On miss: returns 1, no output.
sc_cache_get() {
  local path; path=$(_sc_cache_path "$1" "$2" "$3")
  [ -f "$path" ] || return 1
  cat "$path"
}

# sc_cache_put <registry> <pkg> <version> <iso-timestamp>
#   Writes atomically. Returns 0 on success.
sc_cache_put() {
  local registry="$1" pkg="$2" version="$3" iso="$4"
  local path; path=$(_sc_cache_path "$registry" "$pkg" "$version")
  local dir; dir=$(dirname "$path")
  mkdir -p "$dir" || return 1
  # $$.$RANDOM avoids tmpfile collision when multiple subshells share the
  # parent's PID (e.g., `( sc_cache_put ... ) &` x N — all subshells inherit
  # the same $$, so plain `${path}.tmp.$$` collides).
  local tmp="${path}.tmp.$$.${RANDOM}.${RANDOM}"
  printf '%s' "$iso" > "$tmp" || return 1
  mv "$tmp" "$path"
}
