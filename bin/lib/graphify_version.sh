#!/usr/bin/env bash
# bin/lib/graphify_version.sh — Helpers compartilhados para detecção de versão
# da CLI graphify e drift contra artefatos committados.
#
# Sourced por bin/checkout-sync-all.sh e bin/graphify-init.sh.
# Não tem efeito quando executado diretamente.
#
# Motivação (ADR 0001 Errata 2026-05-12):
#   graphify CLI não expõe `--version`. O método canônico de instalação é
#   `uv tool install graphifyy` (Mitigation #1 do ADR), então `uv tool list`
#   é a fonte primária. Fallback: `pip show graphifyy` para envs sem uv.
#
#   Quando a CLI local diverge da versão que gerou os artefatos committados
#   em graphify-out/, `graphify update .` produz diff estrutural (PR #11 do
#   advisory-ia caiu nessa: 0.7.8 → 0.7.10 mudou 267 nodes → 636 nodes em
#   mesmo código). Sem detecção, /sync regenera dirty silenciosamente.

# Retorna a versão (ex: "0.7.10") da CLI graphify instalada localmente.
# Imprime string vazia se não conseguir detectar.
_graphify_installed_version() {
  local v=""
  if command -v uv >/dev/null 2>&1; then
    v=$(uv tool list 2>/dev/null | awk '/^graphifyy / {print $2}' | sed 's/^v//' | head -1)
  fi
  if [ -z "$v" ] && command -v pip >/dev/null 2>&1; then
    v=$(pip show graphifyy 2>/dev/null | awk '/^Version:/ {print $2}' | head -1)
  fi
  printf '%s' "$v"
}

# Imprime warning na stdout se a versão committada em
# <slot>/graphify-out/.graphify_version diferir da instalada localmente.
# Silencioso quando:
#   - arquivo .graphify_version ausente (repo pré-2026-05-12 ou não-Graphified)
#   - versão committada vazia
#   - versão local indetectável (uv/pip indisponíveis)
#   - versões iguais
# Args:
#   $1  slot_path  caminho do checkout
_graphify_drift_check() {
  local slot="$1"
  local vfile="$slot/graphify-out/.graphify_version"
  [ -f "$vfile" ] || return 0
  local committed
  committed=$(tr -d ' \n\r' < "$vfile" 2>/dev/null)
  [ -n "$committed" ] || return 0
  local local_ver
  local_ver=$(_graphify_installed_version)
  [ -n "$local_ver" ] || return 0
  if [ "$committed" != "$local_ver" ]; then
    echo "  ⚠ graphify CLI drift: committed=$committed local=$local_ver"
    echo "    Refresh: /commit-push-pr 'chore: refresh graphify-out/ (CLI $local_ver)'"
  fi
}
