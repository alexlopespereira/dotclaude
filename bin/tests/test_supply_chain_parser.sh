#!/usr/bin/env bash
# bin/tests/test_supply_chain_parser.sh — Unit tests for sc_parse_command.
# Cobertura: AC2 (managers + ops), AC3 (spec types), AC4 (flags),
# AC6 (aliases + dist-tags + múltiplos pkgs), AC7 (schema), AC8 (subshell limits).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARSER="$SCRIPT_DIR/../lib/supply-chain/parser.sh"

# shellcheck source=../lib/supply-chain/parser.sh
. "$PARSER"

PASS=0; FAIL=0; FAILED=""
_pass(){ PASS=$((PASS+1)); }
_fail(){ FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }

# assert_eq expected actual message
assert_eq() {
  if [ "$2" = "$1" ]; then _pass
  else _fail "$3 :: expected='$1' actual='$2'"
  fi
}

# assert_json_field <json> <jq-filter> <expected> <message>
assert_json_field() {
  local actual; actual=$(echo "$1" | jq -r "$2")
  assert_eq "$3" "$actual" "$4"
}

# Schema validation: every output must be valid JSON with required fields.
assert_schema() {
  local out="$1" msg="$2"
  if echo "$out" | jq -e '(.manager|type=="string") and (.op|type=="string") and (.pkgs|type=="array") and (.flags|type=="array")' >/dev/null 2>&1; then
    _pass
  else
    _fail "$msg :: schema invalid -- $out"
  fi
}

echo "=== sc_parse_command tests ==="

# ─── npm canonical ───────────────────────────────────────────────────────────
out=$(sc_parse_command "npm install"); assert_schema "$out" "T01 npm install schema"
assert_json_field "$out" '.manager' "npm" "T01a"
assert_json_field "$out" '.op' "install" "T01b"
assert_json_field "$out" '.pkgs | length' "0" "T01c (no pkgs)"

out=$(sc_parse_command "npm install lodash")
assert_json_field "$out" '.pkgs[0].name' "lodash" "T02a"
assert_json_field "$out" '.pkgs[0].type' "registry" "T02b"
assert_json_field "$out" '.pkgs[0].spec' "*" "T02c"

out=$(sc_parse_command "npm install lodash@4.17.21")
assert_json_field "$out" '.pkgs[0].name' "lodash" "T03a"
assert_json_field "$out" '.pkgs[0].spec' "4.17.21" "T03b"

out=$(sc_parse_command "npm install lodash@^4.17.0")
assert_json_field "$out" '.pkgs[0].spec' "^4.17.0" "T04a"

# Scoped
out=$(sc_parse_command "npm install @types/node")
assert_json_field "$out" '.pkgs[0].name' "@types/node" "T05a"
assert_json_field "$out" '.pkgs[0].type' "registry" "T05b"
assert_json_field "$out" '.pkgs[0].spec' "*" "T05c"

out=$(sc_parse_command "npm install @types/node@^20")
assert_json_field "$out" '.pkgs[0].name' "@types/node" "T06a"
assert_json_field "$out" '.pkgs[0].spec' "^20" "T06b"

# Aliases / shorthands
out=$(sc_parse_command "npm i lodash")
assert_json_field "$out" '.op' "install" "T07 (npm i alias)"

out=$(sc_parse_command "npm add lodash")
assert_json_field "$out" '.op' "install" "T08 (npm add)"

out=$(sc_parse_command "npm update lodash")
assert_json_field "$out" '.op' "update" "T09 (npm update)"

# Multiple packages
out=$(sc_parse_command "npm install a b c")
assert_json_field "$out" '.pkgs | length' "3" "T10 (3 pkgs)"
assert_json_field "$out" '.pkgs[2].name' "c" "T10b"

# Flags
out=$(sc_parse_command "npm install --ignore-scripts lodash")
assert_json_field "$out" '.flags | index("--ignore-scripts") != null' "true" "T11 (--ignore-scripts)"

out=$(sc_parse_command "npm install lodash --save-dev")
assert_json_field "$out" '.flags | index("--save-dev") != null' "true" "T12 (--save-dev)"

out=$(sc_parse_command "npm install --frozen-lockfile")
assert_json_field "$out" '.flags | index("--frozen-lockfile") != null' "true" "T13 (--frozen-lockfile)"

# ─── git-url variants ────────────────────────────────────────────────────────
out=$(sc_parse_command "npm install github:tanstack/router")
assert_json_field "$out" '.pkgs[0].type' "git-url" "T14a (github:)"
assert_json_field "$out" '.pkgs[0].name' "tanstack/router" "T14b"

out=$(sc_parse_command "npm install github:tanstack/router#79ac49ee")
assert_json_field "$out" '.pkgs[0].type' "git-url" "T15a (github:#sha)"
assert_json_field "$out" '.pkgs[0].name' "tanstack/router" "T15b"

out=$(sc_parse_command "npm install user/repo")
assert_json_field "$out" '.pkgs[0].type' "git-url" "T16 (shorthand user/repo)"

out=$(sc_parse_command "npm install git+https://github.com/x/y.git")
assert_json_field "$out" '.pkgs[0].type' "git-url" "T17 (git+https)"

out=$(sc_parse_command "npm install https://github.com/x/y")
assert_json_field "$out" '.pkgs[0].type' "git-url" "T18 (https://github.com)"

# ─── workspace / local / alias ───────────────────────────────────────────────
out=$(sc_parse_command "pnpm add foo workspace:*")
assert_json_field "$out" '.pkgs[1].type' "workspace" "T19 (workspace:*)"

out=$(sc_parse_command "pnpm add foo workspace:^")
assert_json_field "$out" '.pkgs[1].type' "workspace" "T20 (workspace:^)"

out=$(sc_parse_command "pnpm add foo workspace:1.0.0")
assert_json_field "$out" '.pkgs[1].type' "workspace" "T21 (workspace:1.0.0)"

out=$(sc_parse_command "npm install file:./local-pkg")
assert_json_field "$out" '.pkgs[0].type' "local" "T22 (file:)"

out=$(sc_parse_command "npm install link:./local")
assert_json_field "$out" '.pkgs[0].type' "local" "T23 (link:)"

out=$(sc_parse_command "npm install portal:./local")
assert_json_field "$out" '.pkgs[0].type' "local" "T24 (portal:)"

out=$(sc_parse_command "pnpm add catalog:default")
assert_json_field "$out" '.pkgs[0].type' "local" "T25 (catalog:)"

out=$(sc_parse_command "npm install ./pkg-1.0.0.tgz")
assert_json_field "$out" '.pkgs[0].type' "local" "T26 (.tgz)"

out=$(sc_parse_command "npm install npm:@scope/alias@1.0.0")
assert_json_field "$out" '.pkgs[0].type' "alias" "T27 (npm: alias)"

# ─── pnpm / yarn / bun ───────────────────────────────────────────────────────
out=$(sc_parse_command "pnpm add foo"); assert_json_field "$out" '.manager' "pnpm" "T28a"
assert_json_field "$out" '.op' "install" "T28b"

out=$(sc_parse_command "pnpm dlx create-foo")
assert_json_field "$out" '.op' "run-ephemeral" "T29 (pnpm dlx)"

out=$(sc_parse_command "yarn add foo"); assert_json_field "$out" '.manager' "yarn" "T30a"
assert_json_field "$out" '.op' "install" "T30b"

out=$(sc_parse_command "yarn dlx foo")
assert_json_field "$out" '.op' "run-ephemeral" "T31 (yarn dlx)"

out=$(sc_parse_command "bun add foo")
assert_json_field "$out" '.manager' "bun" "T32a"
assert_json_field "$out" '.op' "install" "T32b"

# ─── pip / pipx / uv ─────────────────────────────────────────────────────────
out=$(sc_parse_command "pip install requests")
assert_json_field "$out" '.manager' "pip" "T33a"
assert_json_field "$out" '.op' "install" "T33b"
assert_json_field "$out" '.pkgs[0].name' "requests" "T33c"

out=$(sc_parse_command "pip install -r requirements.txt")
assert_json_field "$out" '.pkgs | length' "0" "T34 (pip -r → pkgs=[])"

out=$(sc_parse_command "pip install requests -U")
assert_json_field "$out" '.op' "update" "T35 (pip -U promotes to update)"

out=$(sc_parse_command "pipx install black")
assert_json_field "$out" '.op' "install" "T36 (pipx install)"

out=$(sc_parse_command "pipx run black")
assert_json_field "$out" '.op' "run-ephemeral" "T37 (pipx run)"

out=$(sc_parse_command "uv add requests")
assert_json_field "$out" '.op' "install" "T38 (uv add)"

out=$(sc_parse_command "uv pip install requests")
assert_json_field "$out" '.op' "install" "T39a (uv pip install)"
assert_json_field "$out" '.pkgs[0].name' "requests" "T39b"

out=$(sc_parse_command "uv tool install graphifyy")
assert_json_field "$out" '.op' "install" "T40a (uv tool install)"
assert_json_field "$out" '.pkgs[0].name' "graphifyy" "T40b"

out=$(sc_parse_command "uv tool run black")
assert_json_field "$out" '.op' "run-ephemeral" "T41 (uv tool run)"

# ─── ephemeral runners ───────────────────────────────────────────────────────
out=$(sc_parse_command "npx create-vite@latest")
assert_json_field "$out" '.manager' "npx" "T42a"
assert_json_field "$out" '.op' "run-ephemeral" "T42b"
assert_json_field "$out" '.pkgs[0].name' "create-vite" "T42c"
assert_json_field "$out" '.pkgs[0].spec' "latest" "T42d (dist-tag)"

out=$(sc_parse_command "uvx black")
assert_json_field "$out" '.manager' "uvx" "T43a"
assert_json_field "$out" '.op' "run-ephemeral" "T43b"
assert_json_field "$out" '.pkgs[0].name' "black" "T43c"

out=$(sc_parse_command "bunx vite")
assert_json_field "$out" '.manager' "bunx" "T44a"
assert_json_field "$out" '.op' "run-ephemeral" "T44b"

# ─── op=other / non-install ──────────────────────────────────────────────────
out=$(sc_parse_command "git status")
assert_json_field "$out" '.op' "other" "T45 (git status)"

out=$(sc_parse_command "echo npm install foo")
assert_json_field "$out" '.op' "other" "T46 (echo wraps install string)"

out=$(sc_parse_command "make install")
assert_json_field "$out" '.op' "other" "T47 (make install — different domain)"

# ─── Subshell / wrapper limits (AC8) ─────────────────────────────────────────
out=$(sc_parse_command "bash -c 'npm install foo'")
assert_json_field "$out" '.op' "other" "T48 (bash -c → other)"
assert_json_field "$out" '.manager' "other" "T48b"

out=$(sc_parse_command "sh -c 'npm install foo'")
assert_json_field "$out" '.op' "other" "T49 (sh -c → other)"

out=$(sc_parse_command "eval npm install foo")
assert_json_field "$out" '.op' "other" "T50 (eval → other)"

out=$(sc_parse_command "nohup npm install foo")
assert_json_field "$out" '.op' "other" "T51 (nohup → other)"

# ─── Dist-tags pass through ──────────────────────────────────────────────────
out=$(sc_parse_command "npm install foo@latest")
assert_json_field "$out" '.pkgs[0].name' "foo" "T52a (latest dist-tag)"
assert_json_field "$out" '.pkgs[0].spec' "latest" "T52b"

out=$(sc_parse_command "npm install foo@next")
assert_json_field "$out" '.pkgs[0].spec' "next" "T53 (next dist-tag)"

out=$(sc_parse_command "npm install foo@beta")
assert_json_field "$out" '.pkgs[0].spec' "beta" "T54 (beta dist-tag)"

# ─── Schema enforcement on all branches ──────────────────────────────────────
out=$(sc_parse_command "")
assert_schema "$out" "T55 empty schema"
assert_json_field "$out" '.op' "other" "T55b empty → other"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed tests:$FAILED"
  exit 1
fi
exit 0
