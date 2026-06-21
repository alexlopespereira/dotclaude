#!/usr/bin/env bash
set -u
# test_doc_sync.sh — consistência ESTRUTURAL entre o DoD lean e o canônico +
# aviso não-fatal de divergência de CLAUDE.md no install (US-07).
#
# Os dois documentos têm convenção de heading distinta DE PROPÓSITO (full↔lean
# é design — D10): o canônico docs/definition_of_done.md usa `### N.` / `## Categoria N`,
# o lean skills/auto-grill-me/references/DOD.md usa `### Tarefa N` / `### DoD-base — Categoria N`.
# O contrato que importa é ESTRUTURAL: o CONJUNTO de IDs de Tarefa e de Categoria
# tem que bater nos dois. Conteúdo de bullet NÃO é comparado.
#
#   AC1: detecta (vermelho) quando um heading Tarefa-N existe só no lean — provado
#        com fixture no próprio teste; e passa (verde) no estado atual do repo.
#   AC2: extratores olham SÓ presença/ausência de IDs de heading — nunca bullets.
#   AC3: `sync.sh install` avisa (sem abortar, exit 0) quando ~/.claude/CLAUDE.md
#        diverge do CLAUDE.md do repo; não avisa quando são idênticos.
#   AC4: roda sob bin/tests/run-all.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LEAN="$REPO_ROOT/skills/auto-grill-me/references/DOD.md"
CANON="$REPO_ROOT/docs/definition_of_done.md"
SYNC="$REPO_ROOT/sync.sh"

PASS=0; FAIL=0; FAILED=""
_pass() { PASS=$((PASS+1)); }
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }

# ── Extratores estruturais — SÓ IDs de heading (AC2: nunca tocam bullets) ─────
# Tarefa: nº logo após '### ' (canônico '### N.') ou após '### Tarefa ' (lean).
# A âncora ^### + prefixo garante pegar só o ID do heading, nunca números soltos
# no resto da linha (ex.: "Online Store 2.0").
extract_tasks() { grep -oE '^### (Tarefa )?[0-9]+' "$1" | grep -oE '[0-9]+' | sort -nu; }
# Categoria: nº após 'Categoria' num heading h2/h3 (lean: '### DoD-base — Categoria N';
# canônico: '## Categoria N').
extract_cats()  { grep -oE '^#{2,3} .*Categoria [0-9]+' "$1" | grep -oE 'Categoria [0-9]+' | grep -oE '[0-9]+' | sort -nu; }

# assert_sets_equal <label> <idsA-sorted> <idsB-sorted> — falha listando os IDs
# presentes só em A ou só em B. Comparação estrutural pura.
assert_sets_equal() {
  local label="$1" a="$2" b="$3" only_a only_b
  only_a="$(comm -23 <(printf '%s\n' "$a") <(printf '%s\n' "$b"))"
  only_b="$(comm -13 <(printf '%s\n' "$a") <(printf '%s\n' "$b"))"
  if [ -z "$only_a" ] && [ -z "$only_b" ]; then _pass
  else _fail "$label :: só-A=[$(echo $only_a)] só-B=[$(echo $only_b)]"; fi
}

[ -f "$LEAN" ]  || { echo "FAIL: lean ausente: $LEAN" >&2; exit 1; }
[ -f "$CANON" ] || { echo "FAIL: canônico ausente: $CANON" >&2; exit 1; }
[ -f "$SYNC" ]  || { echo "FAIL: sync.sh ausente: $SYNC" >&2; exit 1; }

TMP="$(mktemp -d -t doc-sync.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

LT="$(extract_tasks "$LEAN")"; CT="$(extract_tasks "$CANON")"
LC="$(extract_cats "$LEAN")";  CC="$(extract_cats "$CANON")"

# Sanidade: extratores acharam algo (regra de heading não mudou silenciosamente).
[ -n "$LT" ] && _pass || _fail "extract_tasks(lean) vazio — convenção de heading mudou?"
[ -n "$CT" ] && _pass || _fail "extract_tasks(canônico) vazio — convenção de heading mudou?"
[ -n "$LC" ] && _pass || _fail "extract_cats(lean) vazio"
[ -n "$CC" ] && _pass || _fail "extract_cats(canônico) vazio"

# ═══ AC1 (verde) — estado atual do repo: conjuntos de IDs batem ══════════════
assert_sets_equal "AC1 Tarefa-IDs lean==canônico (repo atual)"   "$LT" "$CT"
assert_sets_equal "AC1 Categoria-IDs lean==canônico (repo atual)" "$LC" "$CC"

# ═══ AC1 (vermelho) — fixture: Tarefa só no lean DEVE divergir ════════════════
cp "$LEAN" "$TMP/lean-fixture.md"
printf '\n### Tarefa 99 — fixture só no lean (deve quebrar o check estrutural)\n- bullet ignorado\n' \
  >> "$TMP/lean-fixture.md"
FT="$(extract_tasks "$TMP/lean-fixture.md")"
only_fix="$(comm -23 <(printf '%s\n' "$FT") <(printf '%s\n' "$CT"))"
if printf '%s\n' "$only_fix" | grep -qx 99; then _pass
else _fail "AC1 vermelho: fixture com 'Tarefa 99' deveria divergir do canônico (só-lean=[$only_fix])"; fi
# E a comparação estrutural detecta a divergência (não fica verde por engano).
if [ "$FT" != "$CT" ]; then _pass
else _fail "AC1 vermelho: conjunto de Tarefa-IDs do fixture deveria diferir do canônico"; fi

# ═══ AC2 — bullets divergentes NÃO afetam os IDs extraídos ═══════════════════
cp "$LEAN" "$TMP/a.md"; cp "$LEAN" "$TMP/b.md"
printf '\n- bullet exclusivo de A com número solto 12345\n' >> "$TMP/a.md"
printf '\n- bullet totalmente diferente em B sem número\n'  >> "$TMP/b.md"
assert_sets_equal "AC2 bullets divergentes não mexem em Tarefa-IDs"   "$(extract_tasks "$TMP/a.md")" "$(extract_tasks "$TMP/b.md")"
assert_sets_equal "AC2 bullets divergentes não mexem em Categoria-IDs" "$(extract_cats "$TMP/a.md")"  "$(extract_cats "$TMP/b.md")"
# Garantia extra: o número solto no bullet NÃO virou um Tarefa-ID fantasma.
if printf '%s\n' "$(extract_tasks "$TMP/a.md")" | grep -qx 12345; then
  _fail "AC2 número de bullet (12345) vazou como Tarefa-ID — extrator olhou conteúdo"
else _pass; fi

# ═══ AC3 — install avisa (sem abortar) na divergência do CLAUDE GLOBAL ════════
# A fonte-da-verdade do CLAUDE.md global agora é CLAUDE.global.md (repo), instalada
# em ~/.claude/CLAUDE.md. O CLAUDE.md de raiz do repo é um STUB pequeno e NÃO é
# instalado (mata a duplicação global↔projeto ao trabalhar no próprio dotclaude).
mk_min_repo() { mkdir -p "$1"; cp "$SYNC" "$1/sync.sh"; chmod +x "$1/sync.sh"; }

# Caso divergente: ~/.claude/CLAUDE.md != CLAUDE.global.md do repo → aviso em
# stderr, exit 0, e a versão global do repo sobrescreve a instalada. --force pula
# o guard de abort (edit local), expondo o aviso pós-guard.
REPO_D="$TMP/div/repo"; HOME_D="$TMP/div/home"
mk_min_repo "$REPO_D"; mkdir -p "$HOME_D"
printf 'REPO-GLOBAL\n'  > "$REPO_D/CLAUDE.global.md"
printf 'STUB\n'         > "$REPO_D/CLAUDE.md"          # stub: NUNCA instalado
printf 'STALE-CLAUDE\n' > "$HOME_D/CLAUDE.md"
out_d="$(SYNC_CLAUDE_HOME="$HOME_D" SYNC_LOCAL_BIN="$TMP/div/bin" \
         bash "$REPO_D/sync.sh" install --force 2>&1)"; rc_d=$?
[ "$rc_d" -eq 0 ] && _pass || _fail "AC3 install --force divergente deveria sair 0 (rc=$rc_d)"
printf '%s\n' "$out_d" | grep -q 'CLAUDE.md divergia' && _pass \
  || _fail "AC3 aviso 'CLAUDE.md divergia' ausente no output do install"
[ "$(cat "$HOME_D/CLAUDE.md")" = "REPO-GLOBAL" ] && _pass \
  || _fail "AC3 install deveria instalar CLAUDE.global.md em ~/.claude/CLAUDE.md"

# AC5 — install NÃO vaza o stub nem cria ~/.claude/CLAUDE.global.md.
[ "$(cat "$HOME_D/CLAUDE.md")" != "STUB" ] && _pass \
  || _fail "AC5 ~/.claude/CLAUDE.md recebeu o stub (deveria ser o conteúdo global)"
[ ! -f "$HOME_D/CLAUDE.global.md" ] && _pass \
  || _fail "AC5 install não deveria criar ~/.claude/CLAUDE.global.md"

# Caso idêntico: NÃO avisa.
REPO_S="$TMP/same/repo"; HOME_S="$TMP/same/home"
mk_min_repo "$REPO_S"; mkdir -p "$HOME_S"
printf 'SAME\n' > "$REPO_S/CLAUDE.global.md"; printf 'STUB\n' > "$REPO_S/CLAUDE.md"
printf 'SAME\n' > "$HOME_S/CLAUDE.md"
out_s="$(SYNC_CLAUDE_HOME="$HOME_S" SYNC_LOCAL_BIN="$TMP/same/bin" \
         bash "$REPO_S/sync.sh" install 2>&1)"; rc_s=$?
[ "$rc_s" -eq 0 ] && _pass || _fail "AC3 install idêntico deveria sair 0 (rc=$rc_s)"
if printf '%s\n' "$out_s" | grep -q 'CLAUDE.md divergia'; then
  _fail "AC3 não deveria avisar quando o CLAUDE global é idêntico"
else _pass; fi

# ═══ AC6 — backup copia ~/.claude/CLAUDE.md → repo/CLAUDE.global.md (stub intacto)
REPO_B="$TMP/bak/repo"; HOME_B="$TMP/bak/home"
mk_min_repo "$REPO_B"; mkdir -p "$HOME_B"
printf 'OLD-GLOBAL\n' > "$REPO_B/CLAUDE.global.md"
printf 'STUB-KEEP\n'  > "$REPO_B/CLAUDE.md"
printf 'NEW-GLOBAL\n' > "$HOME_B/CLAUDE.md"
out_b="$(SYNC_CLAUDE_HOME="$HOME_B" SYNC_LOCAL_BIN="$TMP/bak/bin" \
         bash "$REPO_B/sync.sh" backup --force 2>&1)"; rc_b=$?
[ "$rc_b" -eq 0 ] && _pass || _fail "AC6 backup --force deveria sair 0 (rc=$rc_b)"
[ "$(cat "$REPO_B/CLAUDE.global.md")" = "NEW-GLOBAL" ] && _pass \
  || _fail "AC6 backup deveria atualizar repo/CLAUDE.global.md com ~/.claude/CLAUDE.md"
[ "$(cat "$REPO_B/CLAUDE.md")" = "STUB-KEEP" ] && _pass \
  || _fail "AC6 backup NÃO deveria tocar o stub repo/CLAUDE.md"

# ═══ AC8 — pós-rename, install NÃO-force trata home na versão histórica como STALE
# (upgrade seguro), não como edit local (mantém o elo VM pull→install vivo). Usa
# git real: V1 sob CLAUDE.md → rename p/ CLAUDE.global.md + bump V2 + stub novo.
if command -v git >/dev/null 2>&1; then
  REPO_G="$TMP/git/repo"; HOME_G="$TMP/git/home"
  mk_min_repo "$REPO_G"; mkdir -p "$HOME_G"
  git -C "$REPO_G" init -q
  git -C "$REPO_G" config user.email t@t; git -C "$REPO_G" config user.name t
  printf 'V1-FULL\n' > "$REPO_G/CLAUDE.md"
  git -C "$REPO_G" add -A; git -C "$REPO_G" commit -qm v1
  git -C "$REPO_G" mv CLAUDE.md CLAUDE.global.md
  printf 'V2-FULL\n' > "$REPO_G/CLAUDE.global.md"
  printf 'STUB\n'    > "$REPO_G/CLAUDE.md"
  git -C "$REPO_G" add -A; git -C "$REPO_G" commit -qm rename
  printf 'V1-FULL\n' > "$HOME_G/CLAUDE.md"   # home ainda na V1 pré-rename → stale
  out_g="$(SYNC_CLAUDE_HOME="$HOME_G" SYNC_LOCAL_BIN="$TMP/git/bin" \
           bash "$REPO_G/sync.sh" install 2>&1)"; rc_g=$?
  [ "$rc_g" -eq 0 ] && _pass \
    || _fail "AC8 install non-force deveria sair 0 em home stale (rc=$rc_g): $out_g"
  [ "$(cat "$HOME_G/CLAUDE.md")" = "V2-FULL" ] && _pass \
    || _fail "AC8 install deveria atualizar home stale V1→V2 (got $(cat "$HOME_G/CLAUDE.md"))"
else _pass; _pass; fi

# ═══ Summary ═════════════════════════════════════════════════════════════════
TOTAL=$((PASS + FAIL))
echo "test_doc_sync.sh: $PASS/$TOTAL pass"
if [ "$FAIL" -gt 0 ]; then
  printf 'FALHAS:%s\n' "$FAILED" >&2
  exit 1
fi
exit 0
