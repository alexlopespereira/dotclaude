#!/usr/bin/env bash
# bin/tests/test_secret_capture.sh — US-03 do ciclo R9 (ciclo de vida de
# secrets): captura segura em bin/secret-capture.sh (wrapper) +
# bin/lib/secret-capture-driver.mjs (driver Playwright local).
#
# Mapa AC → bloco de asserts (contrato de cobertura do plano
# .claude/plans/2026-07-02T12-53-27Z-r9-secrets-lifecycle.md):
#   AC1  combinações inválidas de args → usage + rc=2 sem efeito colateral → bloco AC1
#   AC2  guarda .gitignore (env-file add; drop require; fora de repo skip)  → bloco AC2
#   AC3  env-file: append novo, replace in-place, chmod 600                 → bloco AC3
#   AC4  valor-sentinela NUNCA no stdout/stderr; tail mascarado presente    → bloco AC4
#   AC5  probe recebe valor via env var (nunca argv); falha → rc=6          → bloco AC5
#   AC6  --from-drop move + destrói; ausente/vazio → erro claro             → bloco AC6
#   AC7  audit mascarado + upsert inventário; --no-inventory suprime        → bloco AC7
#   AC8  driver: node --check + âncoras de segurança no fonte               → bloco AC8
#   AC9  fixtures neutras sem prefixos reais do catálogo (ressalva #3)      → bloco AC9
#   AC10 cobertura de patch 100% nos branches bash — provada por exaustão
#        nos blocos acima (parse, guardas, escrita, probe, audit, inventário,
#        falhas de driver/drop/escrita). EXCEÇÃO DECLARADA: o driver
#        bin/lib/secret-capture-driver.mjs não roda em CI (browser real);
#        cobertura dele = sanidade sintática (node --check) + âncoras de
#        segurança do bloco AC8, conforme Objetivo #1 do plano R9.
#
# Hermético: tudo em mktemp; $HOME nunca é tocado (audit/expiry/env sempre
# via flags de seam). Fixtures de valor são NEUTRAS (AC9) para não casar os
# regexes de conteúdo do secret-scan block-dangerous-git.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SC="$REPO_ROOT/bin/secret-capture.sh"
DRIVER_SRC="$REPO_ROOT/bin/lib/secret-capture-driver.mjs"

PASS=0; FAIL=0; FAILED=""
_fail() { FAIL=$((FAIL+1)); FAILED="${FAILED}
  ✗ $1"; }
_pass() { PASS=$((PASS+1)); }
assert_rc()       { [ "$1" = "$2" ] && _pass || _fail "$3 :: expected rc=$2 got rc=$1"; }
assert_contains() { case "$1" in *"$2"*) _pass ;; *) _fail "$3 :: needle '$2' not found";; esac; }
assert_not_contains() { case "$1" in *"$2"*) _fail "$3 :: needle '$2' found but should NOT be";; *) _pass;; esac; }

TMP=$(mktemp -d); trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# Valores de fixture — NEUTROS (AC9): nenhum prefixo real do catálogo.
# Máscara canônica: SÓ os últimos 4 chars (code-review R9 — first-3+last-4
# revelava 7 de 11 chars de secret curto no transcript).
SENTINEL="tok-neutral-fixture-77aa-0042"   # >10 chars → máscara ...0042
MASKED="...0042"
SHORTVAL="nv8k12"                          # ≤10 chars → máscara ****
OLDVAL="old-neutral-prev-11"

# Blocklist SEMPRE a do repo (hermético — o default $HOME/.claude/... depende
# do estado da máquina; delta re-review R9). Flags posteriores vencem: casos
# que precisam de blocklist custom passam o próprio --blocklist depois.
BLK="$REPO_ROOT/skills/browser-actions/blocklist.json"
run_sc() {  # stdout em $OUT, stderr em $ERR, rc em $RC
  OUT=$(bash "$SC" --blocklist "$BLK" "$@" 2>"$TMP/stderr.txt"); RC=$?; ERR=$(cat "$TMP/stderr.txt")
}
run_sc_in() {  # run_sc com cwd no 1º arg (testa defaults relativos)
  local d="$1"; shift
  OUT=$(cd "$d" && bash "$SC" --blocklist "$BLK" "$@" 2>"$TMP/stderr.txt"); RC=$?; ERR=$(cat "$TMP/stderr.txt")
}
perms_of() { perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$1"; }

# ─── Stubs ───────────────────────────────────────────────────────────────────
STUBS="$TMP/stubs"; mkdir -p "$STUBS/nodebin"
DRIVER_LOG="$TMP/driver-calls.log"
PROBE_LOG="$TMP/probe-calls.log"
EXPIRY_LOG="$TMP/expiry-calls.log"
NODE_LOG="$TMP/node-calls.log"

cat > "$STUBS/driver-ok.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$DRIVER_LOG"
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "--out" ] && out="\$a"; prev="\$a"; done
printf '%s' "$SENTINEL" > "\$out"
EOF
cat > "$STUBS/driver-fail.sh" <<EOF
#!/usr/bin/env bash
echo "driver-fail chamado" >> "$DRIVER_LOG"
exit 1
EOF
cat > "$STUBS/driver-empty.sh" <<EOF
#!/usr/bin/env bash
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "--out" ] && out="\$a"; prev="\$a"; done
: > "\$out"
EOF
cat > "$STUBS/nodebin/node" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$NODE_LOG"
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "--out" ] && out="\$a"; prev="\$a"; done
printf '%s' "$SENTINEL" > "\$out"
EOF
cat > "$STUBS/probe-ok.sh" <<EOF
#!/usr/bin/env bash
{ echo "argv:\$*"; echo "envval:\${CAP_TOKEN:-unset}"; } >> "$PROBE_LOG"
exit 0
EOF
cat > "$STUBS/probe-fail.sh" <<EOF
#!/usr/bin/env bash
{ echo "argv:\$*"; echo "envval:\${CAP_TOKEN:-unset}"; } >> "$PROBE_LOG"
exit 1
EOF
cat > "$STUBS/expiry-stub.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$EXPIRY_LOG"
exit "\${EXPIRY_STUB_RC:-0}"
EOF
chmod +x "$STUBS"/*.sh "$STUBS/nodebin/node"

DRV_OK="$STUBS/driver-ok.sh"
AUDIT="$TMP/audit.jsonl"
EXPIRY="$STUBS/expiry-stub.sh"
# args comuns de fonte URL (driver stubado)
SRC_URL=(--url https://example.test/keys --selector '#tok' --driver "$DRV_OK")

[ -f "$SC" ] || { echo "FAIL: $SC inexistente" >&2; echo "test_secret_capture: PASS=0 FAIL=1"; exit 1; }
[ -f "$DRIVER_SRC" ] || { echo "FAIL: $DRIVER_SRC inexistente" >&2; echo "test_secret_capture: PASS=0 FAIL=1"; exit 1; }

# ─── AC1: combinações inválidas → usage em stderr + rc=2, sem efeito ─────────
E1="$TMP/ac1/.env"

run_sc
assert_rc "$RC" 2 "AC1 sem args → rc=2"
assert_contains "$ERR" "Uso:" "AC1 sem args imprime usage em stderr"

run_sc --provider p --url u --selector s --env-file "$E1"
assert_rc "$RC" 2 "AC1 sem --env-key → rc=2"
assert_contains "$ERR" "--env-key" "AC1 sem --env-key nomeia a flag"

run_sc --env-key CAP_TOKEN --url u --selector s --env-file "$E1"
assert_rc "$RC" 2 "AC1 sem --provider → rc=2"
assert_contains "$ERR" "--provider" "AC1 sem --provider nomeia a flag"

run_sc --provider p --env-key CAP_TOKEN --url u --env-file "$E1"
assert_rc "$RC" 2 "AC1 --url sem --selector/--prefix-regex → rc=2"

run_sc --provider p --env-key CAP_TOKEN --url u --selector s --from-drop --env-file "$E1"
assert_rc "$RC" 2 "AC1 --url junto com --from-drop → rc=2"

run_sc --provider p --env-key CAP_TOKEN --env-file "$E1"
assert_rc "$RC" 2 "AC1 sem fonte (--url nem --from-drop) → rc=2"

run_sc --provider p --env-key CAP_TOKEN --url u --selector s --prefix-regex r --env-file "$E1"
assert_rc "$RC" 2 "AC1 --selector e --prefix-regex juntos → rc=2"

run_sc --provider p --env-key CAP_TOKEN --from-drop "$TMP/d" --selector s --env-file "$E1"
assert_rc "$RC" 2 "AC1 --selector sem --url → rc=2"

run_sc --provider p --env-key 1BAD-KEY --url u --selector s --env-file "$E1"
assert_rc "$RC" 2 "AC1 --env-key inválido como nome de env var → rc=2"

run_sc --provider p --env-key CAP_TOKEN --url u --selector s --frobnica --env-file "$E1"
assert_rc "$RC" 2 "AC1 flag desconhecida → rc=2"

run_sc --provider p --env-key
assert_rc "$RC" 2 "AC1 flag de valor sem valor → rc=2"
assert_contains "$ERR" "faltando valor" "AC1 valor faltando nomeado no erro"

run_sc --help
assert_rc "$RC" 0 "AC1 --help → rc=0"
assert_contains "$OUT" "Uso:" "AC1 --help imprime usage em stdout"

[ ! -e "$E1" ] && _pass || _fail "AC1 nenhum erro de parsing tocou o env-file"

# ─── AC2: guarda .gitignore (3+ fixtures) ────────────────────────────────────
# Fixture 1: repo git, env-file não coberto → entrada adicionada ANTES da escrita
R1="$TMP/repo-add"; mkdir -p "$R1"; git -C "$R1" init -q
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$R1/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "AC2 repo sem cobertura → rc=0 (entrada adicionada)"
[ -f "$R1/.gitignore" ] && _pass || _fail "AC2 .gitignore criado no toplevel"
grep -q '^/\.env$' "$R1/.gitignore" && _pass || _fail "AC2 entrada /.env no .gitignore"
git -C "$R1" check-ignore -q "$R1/.env" && _pass || _fail "AC2 env-file coberto pós-run"
grep -q "^CAP_TOKEN=$SENTINEL\$" "$R1/.env" && _pass || _fail "AC2 env-file escrito após a guarda"

# re-run com cobertura já presente → sem duplicata no .gitignore
GI_LINES=$(wc -l < "$R1/.gitignore" | tr -d ' ')
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$R1/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "AC2 já coberto → rc=0"
[ "$(wc -l < "$R1/.gitignore" | tr -d ' ')" = "$GI_LINES" ] && _pass \
  || _fail "AC2 já coberto → .gitignore sem entrada duplicada"

# .gitignore existente SEM \n final: append não pode colar na última linha
R1B="$TMP/repo-nonl"; mkdir -p "$R1B"; git -C "$R1B" init -q
printf 'other.txt' > "$R1B/.gitignore"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$R1B/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "AC2 .gitignore sem newline final → rc=0"
git -C "$R1B" check-ignore -q "$R1B/.env" && _pass \
  || _fail "AC2 entrada não colou na última linha (cobertura efetiva)"
grep -q '^other.txt$' "$R1B/.gitignore" && _pass \
  || _fail "AC2 linha pré-existente preservada intacta"

# env-file em subdir ainda inexistente do repo: guarda acha o repo pelo
# ancestral existente mais próximo e cobre ANTES do mkdir da escrita
R1C="$TMP/repo-subdir"; mkdir -p "$R1C"; git -C "$R1C" init -q
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$R1C/newdir/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "AC2 env-file em subdir inexistente → rc=0"
git -C "$R1C" check-ignore -q "$R1C/newdir/.env" && _pass \
  || _fail "AC2 subdir inexistente coberto no .gitignore"
grep -q "^CAP_TOKEN=$SENTINEL\$" "$R1C/newdir/.env" && _pass \
  || _fail "AC2 env-file do subdir escrito"

# prova de ordem (guarda ANTES da escrita): .gitignore imutável → aborta sem escrever
R2="$TMP/repo-order"; mkdir -p "$R2"; git -C "$R2" init -q
touch "$R2/.gitignore"; chmod 444 "$R2/.gitignore"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$R2/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 3 "AC2 falha ao cobrir env-file → rc=3"
[ ! -e "$R2/.env" ] && _pass || _fail "AC2 guarda falhou → env-file NÃO escrito (ordem provada)"
chmod 644 "$R2/.gitignore"

# Fixture 2: drop path em repo, não coberto → aborta sem ler o drop
R3="$TMP/repo-drop"; mkdir -p "$R3/temp"; git -C "$R3" init -q
printf '%s' "$SENTINEL" > "$R3/temp/.secret-drop"
run_sc --provider testprov --env-key CAP_TOKEN --from-drop "$R3/temp/.secret-drop" \
  --env-file "$TMP/ac2-drop.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 3 "AC2 drop não coberto em repo → rc≠0 (3)"
assert_contains "$ERR" "gitignore" "AC2 abort do drop nomeia a guarda .gitignore"
[ -f "$R3/temp/.secret-drop" ] && _pass || _fail "AC2 drop intacto (não lido/destruído)"
[ ! -e "$TMP/ac2-drop.env" ] && _pass || _fail "AC2 abort do drop → env-file não tocado"

# drop coberto por .gitignore → segue
R3B="$TMP/repo-drop-ok"; mkdir -p "$R3B/temp"; git -C "$R3B" init -q
printf 'temp/\n.env\n' > "$R3B/.gitignore"
printf '%s' "$SENTINEL" > "$R3B/temp/.secret-drop"
run_sc --provider testprov --env-key CAP_TOKEN --from-drop "$R3B/temp/.secret-drop" \
  --env-file "$R3B/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "AC2 drop coberto → rc=0"
grep -q "^CAP_TOKEN=$SENTINEL\$" "$R3B/.env" && _pass || _fail "AC2 drop coberto → env escrito"

# Fixture 3: fora de repo git → segue sem guarda (nenhum .gitignore criado)
N1="$TMP/norepo"; mkdir -p "$N1"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$N1/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "AC2 fora de repo → rc=0 sem guarda"
[ ! -e "$N1/.gitignore" ] && _pass || _fail "AC2 fora de repo → nenhum .gitignore criado"
grep -q "^CAP_TOKEN=$SENTINEL\$" "$N1/.env" && _pass || _fail "AC2 fora de repo → env escrito"

# ─── AC3: escrita no env-file (append novo, replace in-place, 0600) ──────────
E3="$TMP/ac3/.env"; mkdir -p "$TMP/ac3"
printf 'OTHER=keepme\n' > "$E3"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$E3" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "AC3 append de chave nova → rc=0"
OUT_APPEND="$OUT"; ERR_APPEND="$ERR"
grep -q '^OTHER=keepme$' "$E3" && _pass || _fail "AC3 linha pré-existente preservada"
[ "$(grep -c '^CAP_TOKEN=' "$E3")" = "1" ] && _pass || _fail "AC3 append: exatamente 1 linha da chave"
grep -q "^CAP_TOKEN=$SENTINEL\$" "$E3" && _pass || _fail "AC3 append: valor correto"
[ "$(perms_of "$E3")" = "600" ] && _pass || _fail "AC3 append: env-file com 0600"

E3B="$TMP/ac3/replace.env"
printf 'FIRST=1\nCAP_TOKEN=%s\nLAST=2\n' "$OLDVAL" > "$E3B"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$E3B" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "AC3 replace de chave existente → rc=0"
[ "$(grep -c '^CAP_TOKEN=' "$E3B")" = "1" ] && _pass || _fail "AC3 replace: sem duplicata"
grep -q "^CAP_TOKEN=$SENTINEL\$" "$E3B" && _pass || _fail "AC3 replace: valor novo no lugar"
assert_not_contains "$(cat "$E3B")" "$OLDVAL" "AC3 replace: valor antigo removido"
grep -q '^FIRST=1$' "$E3B" && grep -q '^LAST=2$' "$E3B" && _pass \
  || _fail "AC3 replace: linhas vizinhas preservadas"
[ "$(wc -l < "$E3B" | tr -d ' ')" = "3" ] && _pass || _fail "AC3 replace: total de linhas inalterado"
[ "$(perms_of "$E3B")" = "600" ] && _pass || _fail "AC3 replace: env-file com 0600"

# falhas de escrita nunca degradam para rc=0 (idioma RF1 do US-01)
touch "$TMP/plainfile"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$TMP/plainfile/sub/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 5 "AC3 mkdir do env-file impossível → rc=5"

mkdir -p "$TMP/ac3/dir.env/.env"   # env-file apontando pra diretório
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$TMP/ac3/dir.env/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 5 "AC3 env-file é diretório → rc=5"

RO="$TMP/ac3/ro"; mkdir -p "$RO"
printf 'CAP_TOKEN=%s\n' "$OLDVAL" > "$RO/.env"; chmod 555 "$RO"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$RO/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 5 "AC3 replace em diretório read-only → rc=5"
chmod 755 "$RO"

# ─── AC4: valor-sentinela NUNCA no stdout/stderr; tail mascarado presente ────
assert_not_contains "$OUT_APPEND$ERR_APPEND" "$SENTINEL" \
  "AC4 sentinela ausente do stdout/stderr do wrapper"
assert_contains "$OUT_APPEND" "$MASKED" "AC4 par positivo: tail mascarado no stdout"
assert_contains "$OUT_APPEND" "CAP_TOKEN" "AC4 report nomeia a chave gravada"

# valor curto (≤10) → máscara total, sem vazar prefixo/sufixo
D4="$TMP/ac4"; mkdir -p "$D4"
printf '%s' "$SHORTVAL" > "$D4/drop"
run_sc --provider testprov --env-key CAP_TOKEN --from-drop "$D4/drop" \
  --env-file "$D4/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "AC4 valor curto → rc=0"
assert_not_contains "$OUT$ERR" "$SHORTVAL" "AC4 valor curto ausente do stdout/stderr"
assert_contains "$OUT" '****' "AC4 valor curto → máscara total ****"

# TMPDIR dedicado: o tmp do valor é destruído e nada com o sentinela sobra
TD="$TMP/tmpdir"; mkdir -p "$TD" "$TMP/ac4b"
OUT=$(TMPDIR="$TD" bash "$SC" --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$TMP/ac4b/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY" \
  2>"$TMP/stderr.txt"); RC=$?; ERR=$(cat "$TMP/stderr.txt")
assert_rc "$RC" 0 "AC4 run com TMPDIR dedicado → rc=0"
[ -z "$(ls -A "$TD")" ] && _pass || _fail "AC4 arquivo tmp do valor destruído após o run"

# ─── AC5: probe com valor via env var (nunca argv); falha → rc=6 ─────────────
D5="$TMP/ac5"; mkdir -p "$D5"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$D5/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY" \
  --probe "$STUBS/probe-ok.sh arg-visivel"
assert_rc "$RC" 0 "AC5 probe OK → rc=0"
assert_contains "$OUT" "probe OK" "AC5 report menciona probe OK"
grep -q "^envval:$SENTINEL\$" "$PROBE_LOG" && _pass \
  || _fail "AC5 env var com o valor chegou ao probe"
grep '^argv:' "$PROBE_LOG" | grep -q "$SENTINEL" \
  && _fail "AC5 argv do probe contém o valor (proibido)" || _pass
grep -q '^argv:arg-visivel$' "$PROBE_LOG" && _pass \
  || _fail "AC5 par positivo: argv não-secreto do probe registrado"

D5B="$TMP/ac5-fail"; mkdir -p "$D5B"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$D5B/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY" \
  --probe "$STUBS/probe-fail.sh"
assert_rc "$RC" 6 "AC5 probe falhou → rc=6 (≠0)"
assert_contains "$ERR" "probe falhou" "AC5 aviso de probe falho em stderr"
assert_not_contains "$OUT$ERR" "$SENTINEL" "AC5 aviso de falha não vaza o valor"
grep -q "^CAP_TOKEN=$SENTINEL\$" "$D5B/.env" && _pass \
  || _fail "AC5 env-file preservado com o valor gravado (inspeção manual)"
tail -1 "$AUDIT" | jq -e '.verificacao == "live_probe:fail"' >/dev/null && _pass \
  || _fail "AC5 audit registra live_probe:fail (formato do schema documentado)"

# ─── AC6: --from-drop move + destrói; ausente/vazio → erro claro ─────────────
D6="$TMP/ac6"; mkdir -p "$D6"
printf '%s' "$SENTINEL" > "$D6/drop"
run_sc --provider testprov --env-key CAP_TOKEN --from-drop "$D6/drop" \
  --env-file "$D6/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "AC6 drop válido → rc=0"
grep -q "^CAP_TOKEN=$SENTINEL\$" "$D6/.env" && _pass || _fail "AC6 valor movido pro env-file"
[ ! -e "$D6/drop" ] && _pass || _fail "AC6 drop destruído após mover"

run_sc --provider testprov --env-key CAP_TOKEN --from-drop "$TMP/ghost-drop" \
  --env-file "$D6/g.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 4 "AC6 drop ausente → rc=4"
assert_contains "$ERR" "ausente" "AC6 drop ausente nomeado no erro"

touch "$D6/empty-drop"
run_sc --provider testprov --env-key CAP_TOKEN --from-drop "$D6/empty-drop" \
  --env-file "$D6/e.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 4 "AC6 drop vazio → rc=4"
assert_contains "$ERR" "vazio" "AC6 drop vazio nomeado no erro"

printf '   \n' > "$D6/blank-drop"
run_sc --provider testprov --env-key CAP_TOKEN --from-drop "$D6/blank-drop" \
  --env-file "$D6/b.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 4 "AC6 drop só com whitespace → rc=4"

printf 'linha-um\nlinha-dois\n' > "$D6/multi-drop"
run_sc --provider testprov --env-key CAP_TOKEN --from-drop "$D6/multi-drop" \
  --env-file "$D6/m.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 4 "AC6 drop multi-linha → rc=4"
assert_contains "$ERR" "linha" "AC6 multi-linha nomeado no erro"

# path default temp/.secret-drop quando --from-drop vem sem valor
DD1="$TMP/dropdef1"; mkdir -p "$DD1/temp"
printf '%s' "$SENTINEL" > "$DD1/temp/.secret-drop"
run_sc_in "$DD1" --provider testprov --env-key CAP_TOKEN --from-drop \
  --env-file "$DD1/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "AC6 --from-drop sem path (flag seguinte) → usa default"
[ ! -e "$DD1/temp/.secret-drop" ] && _pass || _fail "AC6 drop default destruído"
grep -q "^CAP_TOKEN=$SENTINEL\$" "$DD1/.env" && _pass || _fail "AC6 drop default → env escrito"

# --from-drop como último arg + env-file default ./.env
DD2="$TMP/dropdef2"; mkdir -p "$DD2/temp"
printf '%s' "$SENTINEL" > "$DD2/temp/.secret-drop"
run_sc_in "$DD2" --provider testprov --env-key CAP_TOKEN \
  --audit-file "$AUDIT" --expiry-script "$EXPIRY" --from-drop
assert_rc "$RC" 0 "AC6 --from-drop como último arg → default + rc=0"
grep -q "^CAP_TOKEN=$SENTINEL\$" "$DD2/.env" && _pass \
  || _fail "AC6 env-file default ./.env criado no cwd"
[ "$(perms_of "$DD2/.env")" = "600" ] && _pass || _fail "AC6 env-file default com 0600"

# ─── AC7: audit mascarado + upsert no inventário; --no-inventory suprime ─────
A7="$TMP/ac7-audit.jsonl"; D7="$TMP/ac7"; mkdir -p "$D7"
: > "$EXPIRY_LOG"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$D7/.env" --audit-file "$A7" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "AC7 run base → rc=0"
[ "$(wc -l < "$A7" | tr -d ' ')" = "1" ] && _pass || _fail "AC7 exatamente 1 linha de audit"
# schema alinhado ao documentado na skill browser-secrets (code-review R9:
# dois writers com schemas divergentes no mesmo audit.jsonl)
tail -1 "$A7" | jq -e '.tool == "testprov" and .dominio == "example.test"
  and .tipo == "env-secret"
  and .tail == "...0042" and (.destino | contains("CAP_TOKEN"))
  and .verificacao == "none" and (.timestamp | length > 0)' >/dev/null \
  && _pass || _fail "AC7 linha de audit com campos do schema documentado"
grep -q "$SENTINEL" "$A7" && _fail "AC7 valor cru vazou pro audit" || _pass
grep -q "$MASKED" "$A7" && _pass || _fail "AC7 par positivo: tail mascarado presente no audit"
grep -q -- "add --key CAP_TOKEN --provider testprov" "$EXPIRY_LOG" && _pass \
  || _fail "AC7 upsert no inventário via secrets-expiry add (call-log)"
grep -q -- "--renewal-method secret-capture" "$EXPIRY_LOG" && _pass \
  || _fail "AC7 upsert registra renewal-method secret-capture"
grep -q "$SENTINEL" "$EXPIRY_LOG" && _fail "AC7 valor vazou pro inventário" || _pass

EXP_LINES=$(wc -l < "$EXPIRY_LOG" | tr -d ' ')
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$D7/.env" --audit-file "$A7" --expiry-script "$EXPIRY" --no-inventory
assert_rc "$RC" 0 "AC7 --no-inventory → rc=0"
[ "$(wc -l < "$EXPIRY_LOG" | tr -d ' ')" = "$EXP_LINES" ] && _pass \
  || _fail "AC7 --no-inventory suprime o upsert (call-log inalterado)"

OUT=$(EXPIRY_STUB_RC=1 bash "$SC" --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$D7/.env" --audit-file "$A7" --expiry-script "$EXPIRY" \
  2>"$TMP/stderr.txt"); RC=$?; ERR=$(cat "$TMP/stderr.txt")
assert_rc "$RC" 0 "AC7 upsert falho é non-blocking → rc=0"
assert_contains "$ERR" "inventário" "AC7 upsert falho avisado em stderr"

mkdir -p "$TMP/audit-as-dir"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$D7/.env" --audit-file "$TMP/audit-as-dir" --expiry-script "$EXPIRY"
assert_rc "$RC" 5 "AC7 falha de escrita do audit → rc=5 (nunca 0 silencioso)"

# ─── RF code-review R9: export KEY=, sobra de rewrite, gate Zona 3 ───────────
# export KEY= existente é substituído no lugar (prefixo preservado, sem duplicata)
DE="$TMP/rf-export"; mkdir -p "$DE"
printf 'export CAP_TOKEN=%s\nOTHER=1\n' "$OLDVAL" > "$DE/.env"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$DE/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "RF export: replace de 'export KEY=' → rc=0"
grep -q "^export CAP_TOKEN=$SENTINEL\$" "$DE/.env" && _pass \
  || _fail "RF export: linha substituída preservando o prefixo export"
[ "$(grep -c "CAP_TOKEN=" "$DE/.env")" = "1" ] && _pass \
  || _fail "RF export: sem duplicata (consumidor first-wins pegaria o valor velho)"
assert_not_contains "$(cat "$DE/.env")" "$OLDVAL" "RF export: valor antigo removido"
# nenhum .env-rewrite.* órfão sobra no caminho feliz (o trap cobre os demais)
ls "$DE"/.env-rewrite.* >/dev/null 2>&1 && _fail "RF rewrite: sobrou .env-rewrite.* com secret" || _pass

# Gate Zona 3 (P12): --url em domínio sensível → exit 7 SEM invocar o driver
DZ="$TMP/rf-zona3"; mkdir -p "$DZ"
: > "$DRIVER_LOG"
run_sc --provider testprov --env-key CAP_TOKEN \
  --url "https://dashboard.stripe.com/apikeys" --selector '#tok' --driver "$DRV_OK" \
  --env-file "$DZ/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 7 "RF zona3: domínio sensível sem --allow-sensitive → rc=7"
assert_contains "$ERR" "BLOQUEADO (Zona 3)" "RF zona3: mensagem nomeia o gate"
[ ! -s "$DRIVER_LOG" ] && _pass || _fail "RF zona3: driver NÃO invocado no bloqueio"
[ ! -f "$DZ/.env" ] && _pass || _fail "RF zona3: env-file não tocado no bloqueio"
# --allow-sensitive (pós-confirm humano) → prossegue COM linha de auditoria
run_sc --provider testprov --env-key CAP_TOKEN \
  --url "https://dashboard.stripe.com/apikeys" --selector '#tok' --driver "$DRV_OK" \
  --allow-sensitive \
  --env-file "$DZ/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "RF zona3: --allow-sensitive prossegue → rc=0"
assert_contains "$ERR" "override --allow-sensitive" "RF zona3: override auditado em stderr"
grep -q "stripe" "$DRIVER_LOG" && _pass || _fail "RF zona3: par positivo — driver invocado com o override"
# domínio NÃO-sensível nunca dispara o gate (par negativo do match)
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$DZ/.env2" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "RF zona3: domínio neutro não dispara o gate"
assert_not_contains "$ERR" "Zona 3" "RF zona3: sem menção ao gate em domínio neutro"

# apex sem subdomínio TAMBÉM bloqueia — o match roda sobre ".HOST"
# (delta re-review: `stripe.com` não casava `\.stripe\.com` e passava reto)
run_sc --provider testprov --env-key CAP_TOKEN \
  --url "https://stripe.com/apikeys" --selector '#tok' --driver "$DRV_OK" \
  --env-file "$DZ/.env3" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 7 "RF zona3: domínio apex (sem subdomínio) também bloqueia"

# fail-closed de verdade: blocklist corrompida ou ausente → bloqueia --url
# (delta re-review: SENS_RE vazio degradava o gate em silêncio)
printf 'não é json\n' > "$TMP/blk-corrupta.json"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --blocklist "$TMP/blk-corrupta.json" \
  --env-file "$DZ/.env4" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 7 "RF zona3: blocklist corrompida → fail-closed (rc=7)"
assert_contains "$ERR" "fail-closed" "RF zona3: mensagem nomeia o fail-closed"
run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --blocklist "$TMP/blk-inexistente.json" \
  --env-file "$DZ/.env4" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 7 "RF zona3: blocklist ausente → fail-closed (rc=7)"
# --from-drop não passa pelo gate (sem URL, sem browser) mesmo sem blocklist
DZD="$TMP/rf-zona3-drop"; mkdir -p "$DZD"; printf '%s' "$SENTINEL" > "$DZD/drop"
run_sc --provider testprov --env-key CAP_TOKEN --from-drop "$DZD/drop" \
  --blocklist "$TMP/blk-inexistente.json" \
  --env-file "$DZD/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "RF zona3: --from-drop ignora o gate (não navega browser)"

# dominio do audit com userinfo na URL → host real, não "user"
# (delta re-review: strip de porta antes do @ derivava o userinfo)
DU="$TMP/rf-userinfo"; mkdir -p "$DU"; AUI="$TMP/rf-userinfo-audit.jsonl"
run_sc --provider testprov --env-key CAP_TOKEN \
  --url "https://user:pass@example.test/x" --selector '#tok' --driver "$DRV_OK" \
  --env-file "$DU/.env" --audit-file "$AUI" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "RF userinfo: captura ok"
tail -1 "$AUI" | jq -e '.dominio == "example.test"' >/dev/null && _pass \
  || _fail "RF userinfo: dominio do audit é o host real (não o userinfo)"

# ─── Driver seam: composição default, forwarding e falhas ────────────────────
DS="$TMP/drvseam"; mkdir -p "$DS"
run_sc --provider testprov --env-key CAP_TOKEN --url https://example.test/k \
  --prefix-regex 'nk_' --slot slot-x --pw-root /pw/root --driver "$DRV_OK" \
  --env-file "$DS/.env" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 0 "DRV forwarding → rc=0"
LAST_DRV=$(tail -1 "$DRIVER_LOG")
assert_contains "$LAST_DRV" "--prefix-regex nk_" "DRV --prefix-regex repassado"
assert_contains "$LAST_DRV" "--slot slot-x" "DRV --slot repassado"
assert_contains "$LAST_DRV" "--pw-root /pw/root" "DRV --pw-root repassado"
assert_contains "$LAST_DRV" "--url https://example.test/k" "DRV --url repassado"
assert_not_contains "$LAST_DRV" "--selector" "DRV --selector ausente quando não passado"

run_sc --provider testprov --env-key CAP_TOKEN "${SRC_URL[@]}" \
  --env-file "$DS/.env2" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
LAST_DRV=$(tail -1 "$DRIVER_LOG")
assert_not_contains "$LAST_DRV" "--slot" "DRV --slot ausente quando não passado"
assert_not_contains "$LAST_DRV" "--pw-root" "DRV --pw-root ausente quando não passado"
assert_not_contains "$LAST_DRV" "$SENTINEL" "DRV argv do driver nunca contém o valor"

# default: sem --driver, wrapper compõe `node <lib>/secret-capture-driver.mjs`
OUT=$(PATH="$STUBS/nodebin:$PATH" bash "$SC" --provider testprov --env-key CAP_TOKEN \
  --url https://example.test/k --selector '#tok' \
  --env-file "$DS/.env3" --audit-file "$AUDIT" --expiry-script "$EXPIRY" \
  2>"$TMP/stderr.txt"); RC=$?; ERR=$(cat "$TMP/stderr.txt")
assert_rc "$RC" 0 "DRV default (node + driver.mjs) → rc=0"
grep -q "secret-capture-driver.mjs" "$NODE_LOG" && _pass \
  || _fail "DRV default invoca node com o caminho do driver .mjs"
grep -q "^CAP_TOKEN=$SENTINEL\$" "$DS/.env3" && _pass || _fail "DRV default → env escrito"

run_sc --provider testprov --env-key CAP_TOKEN --url u --selector s \
  --driver "$STUBS/driver-fail.sh" \
  --env-file "$DS/.env4" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 4 "DRV driver com rc≠0 → rc=4"
assert_contains "$ERR" "driver" "DRV falha do driver nomeada no erro"
[ ! -e "$DS/.env4" ] && _pass || _fail "DRV driver falho → env-file não tocado"

run_sc --provider testprov --env-key CAP_TOKEN --url u --selector s \
  --driver "$STUBS/driver-empty.sh" \
  --env-file "$DS/.env5" --audit-file "$AUDIT" --expiry-script "$EXPIRY"
assert_rc "$RC" 4 "DRV driver sem valor no --out → rc=4"
[ ! -e "$DS/.env5" ] && _pass || _fail "DRV valor vazio → env-file não tocado"

# ─── AC8: driver .mjs — sanidade sintática + âncoras de segurança ────────────
if command -v node >/dev/null 2>&1; then
  node --check "$DRIVER_SRC" 2>"$TMP/nodecheck.txt" && _pass \
    || _fail "AC8 node --check falhou: $(cat "$TMP/nodecheck.txt")"
else
  echo "SKIP declarado: node ausente — sanidade sintática do driver não verificada aqui"
fi

DRV_SRC_TXT=$(cat "$DRIVER_SRC")
grep -q 'screenshot(' "$DRIVER_SRC" && _fail "AC8 driver contém chamada de screenshot" || _pass
assert_contains "$DRV_SRC_TXT" "0o600" "AC8 tmp de saída escrito com modo 0600"
assert_contains "$DRV_SRC_TXT" ".lock" "AC8 protocolo de lock: dir .lock"
assert_contains "$DRV_SRC_TXT" "mkdirSync" "AC8 protocolo de lock: mkdir-como-lock"
assert_contains "$DRV_SRC_TXT" "process.kill" "AC8 protocolo de lock: liveness via kill -0"
assert_contains "$DRV_SRC_TXT" "--pw-root" "AC8 fallback --pw-root na resolução do playwright"
assert_contains "$DRV_SRC_TXT" "launchPersistentContext" "AC8 usa o perfil persistente dedicado"
assert_contains "$DRV_SRC_TXT" "chrome-profile-" "AC8 perfil por slot (chrome-profile-<slot>)"

# ─── AC9: fixtures neutras — nenhum prefixo real do catálogo nos valores ─────
# (padrões montados por concatenação pra este arquivo nunca conter o literal)
ALL_VALUES="$SENTINEL $SHORTVAL $OLDVAL linha-um linha-dois"
for pfx in 'sk''-' 'ghp''_' 're''_' 'xo''x' 'glpat''-' 'AI''za'; do
  case "$ALL_VALUES" in
    *"$pfx"*) _fail "AC9 fixture contém prefixo real do catálogo: $pfx" ;;
    *) _pass ;;
  esac
done

# ─── Sumário ─────────────────────────────────────────────────────────────────
echo "test_secret_capture: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Falhas:$FAILED" >&2
  exit 1
fi
exit 0
