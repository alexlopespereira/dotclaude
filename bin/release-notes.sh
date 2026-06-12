#!/usr/bin/env bash
# bin/release-notes.sh — lógica de release CalVer + agrupamento de notas (US-09).
#
# DECISÃO (AC4) — RELEASE-NOTES-ONLY, sem commit de CHANGELOG na main:
#   A US-01 ligou branch protection na main (required check bin-tests). Um
#   workflow que gerasse CHANGELOG.md e commitasse de volta na main entraria em
#   loop com a protection (precisaria de PR/CI a cada push) ou exigiria bypass de
#   admin. Por isso este pipeline NÃO escreve na árvore da main: ele cria uma tag
#   CalVer e publica as notas como *GitHub Release notes* anexadas à tag. A tag
#   não é uma branch protegida — o push da tag e o `gh release create` não
#   tocam a main nem disparam a protection. As notas ficam versionadas no objeto
#   Release do GitHub, derivadas dos Conventional Commits desde a última tag.
#
# SEM ACTION DE TERCEIROS (AC1, D9): toda a lógica é bash puro + git + gh. O
# workflow (.github/workflows/release.yml) só usa actions/checkout oficial e
# chama `bash bin/release-notes.sh run`.
#
# TESTABILIDADE (AC2/AC3): a versão (compute_tag/next_calver) e o agrupamento
# (group_commits) são funções PURAS, sourceadas por bin/tests/test_release_notes.sh.
# O `run` (git/gh, efeitos colaterais) fica atrás do guard ${BASH_SOURCE[0]}.
#
# Uso:   bin/release-notes.sh run        (no workflow; cria tag + Release)
#        bin/release-notes.sh notes      (imprime as notas do range corrente)

set -uo pipefail

# next_calver <today_YYYY.MM.DD> <existing_tag_names_multiline>
# Base = vYYYY.MM.DD; em colisão no mesmo dia, sufixa -1, -2, ... até um nome livre.
next_calver() {
  local today="$1" existing="$2" base n candidate
  base="v${today}"
  if ! printf '%s\n' "$existing" | grep -qx -- "$base"; then
    printf '%s\n' "$base"
    return 0
  fi
  n=1
  while :; do
    candidate="${base}-${n}"
    if ! printf '%s\n' "$existing" | grep -qx -- "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    n=$((n + 1))
  done
}

# compute_tag <today_YYYY.MM.DD> <current_sha> <tag<TAB>sha lines>
# Idempotência (AC2): se o commit corrente já tem alguma tag v*, devolve vazio
# (re-run não cria duplicata). Senão, próxima CalVer via next_calver.
compute_tag() {
  local today="$1" sha="$2" pairs="$3" already names
  already=$(printf '%s\n' "$pairs" | awk -v s="$sha" 'NF>=2 && $2==s {print $1; exit}')
  if [ -n "$already" ]; then
    return 0
  fi
  names=$(printf '%s\n' "$pairs" | awk 'NF>=1 {print $1}')
  next_calver "$today" "$names"
}

# group_commits — lê subjects de Conventional Commits no stdin, um por linha,
# e emite seções markdown por tipo, em ordem fixa. Tipos fora do conjunto e
# linhas que não casam o padrão `tipo[(escopo)][!]: assunto` são ignorados.
group_commits() {
  local input pair t label body any=0
  input=$(cat)
  for pair in "feat:Features" "fix:Fixes" "docs:Docs" "refactor:Refactor" "ci:CI"; do
    t="${pair%%:*}"
    label="${pair#*:}"
    body=$(printf '%s\n' "$input" | sed -n -E "s/^${t}(\([^)]+\))?!?: *(.+)$/- \2/p")
    if [ -n "$body" ]; then
      [ "$any" -eq 1 ] && printf '\n'
      printf '### %s\n%s\n' "$label" "$body"
      any=1
    fi
  done
}

# release_notes — notas do range desde a última tag (ou histórico inteiro).
release_notes() {
  local last range
  last=$(git describe --tags --abbrev=0 2>/dev/null || true)
  range="${last:+$last..}HEAD"
  local notes
  notes=$(git log --no-merges --format='%s' "$range" | group_commits)
  if [ -z "$notes" ]; then
    printf 'Sem mudanças classificáveis (Conventional Commits) desde %s.\n' "${last:-o início}"
  else
    printf '%s\n' "$notes"
  fi
}

# run — orquestra o release (chamado pelo workflow). git/gh reais.
run() {
  local sha today pairs tag notes
  sha=$(git rev-parse HEAD)
  today=$(date -u +%Y.%m.%d)
  # refname<TAB>commit-sha; %(*objectname) desreferencia tags anotadas, vazio em leves.
  pairs=$(git for-each-ref --format='%(refname:short)%09%(objectname) %(*objectname)' refs/tags/ \
    | awk -F'\t' '{split($2,a," "); print $1"\t"(a[2]?a[2]:a[1])}')

  tag=$(compute_tag "$today" "$sha" "$pairs")
  if [ -z "$tag" ]; then
    echo "skip: HEAD ($sha) já está taggeado — nada a fazer (idempotente)."
    return 0
  fi

  notes=$(release_notes)
  echo "Criando tag $tag em $sha"
  git tag "$tag" "$sha"
  git push origin "refs/tags/$tag"
  printf '%s\n' "$notes" | gh release create "$tag" --title "$tag" --notes-file -
  echo "Release $tag publicado."
}

# Guard: só executa quando rodado direto (não quando sourceado pelos testes).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-run}"
  case "$cmd" in
    run)   run ;;
    notes) release_notes ;;
    *)     echo "Uso: release-notes.sh [run|notes]" >&2; exit 2 ;;
  esac
fi
