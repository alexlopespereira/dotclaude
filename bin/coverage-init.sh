#!/usr/bin/env bash
# coverage-init.sh — provision a project as coverage-ready (US-02).
#
# O QUE FAZ
#   Detecta a linguagem DOMINANTE do projeto-alvo (contagem de extensões, com
#   vendor dirs podados), copia o template de config de cobertura correspondente
#   (skills/testing/templates/coverage/<lang>/), cria um .coverage-baseline.json
#   inicial e — quando o template de CI (US-03) existe — copia coverage-ci.yml.
#   IDEMPOTENTE: a 2ª execução converge ao mesmo estado, nunca duplica config
#   nem sobrescreve um baseline já ratcheted.
#
# QUANDO USAR
#   1× por projeto, via /coverage-init, para torná-lo coverage-ready antes de o
#   gate (coverage-gate.sh) entrar em vigor. full-cycle pode chamá-lo como fatia 0.
#
# DECISÃO (baseline / AC4)
#   init NÃO executa a suíte do projeto-alvo — rodar a suíte de um projeto
#   arbitrário durante o provisionamento é um efeito colateral pesado e pode
#   falhar/travar. O total medido é injetado via seam COVERAGE_INIT_MEASURED_TOTAL
#   quando o chamador já mediu; sem o seam, o baseline inicializa em 0 com nota
#   ("ainda não instrumentado") e o ratchet sobe a partir daí via CI.
#
# [SUPOSIÇÃO] kcov-macOS-frágil (AC7): a 1ª execução faz probe de kcov no host e
#   registra no output se ele roda. Para bash, bashcov entrega LINE coverage
#   apenas (branch é Ruby-only no SimpleCov) → o relatório declara branch=n/a.
#
# SEAMS (env var)
#   COVERAGE_INIT_TEMPLATES_DIR   diretório de templates (default: ../skills/...)
#   COVERAGE_INIT_MEASURED_TOTAL  total de cobertura já medido (numérico 0..100)
#   COVERAGE_INIT_KCOV            binário kcov a sondar (default: PATH)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_TEMPLATES="$SCRIPT_DIR/../skills/testing/templates/coverage"
TEMPLATES_DIR="${COVERAGE_INIT_TEMPLATES_DIR:-$DEFAULT_TEMPLATES}"

usage() {
    cat >&2 <<'USAGE'
Usage: coverage-init.sh [--target <dir>] [--lang <python|js|ts|bash|liquid>]

Provisiona o projeto-alvo como coverage-ready: detecta a linguagem dominante,
copia o template de config, cria .coverage-baseline.json e (se existir) o CI.

Options:
  --target <dir>   Projeto a provisionar (default: diretório corrente).
  --lang <lang>    Força a linguagem (pula a auto-detecção).
  -h, --help       Mostra esta ajuda.
USAGE
}
die_usage() { [ -n "${1:-}" ] && echo "ERROR: $1" >&2; usage; exit 2; }

# ── numeric form+range validation (espelha coverage-gate.sh) ────────────────
is_num_in_range() {
    local v="$1" max="$2"
    case "$v" in ''|*[!0-9.]*) return 1 ;; esac
    case "$v" in *.*.*) return 1 ;; esac
    case "$v" in .|*.) return 1 ;; esac
    LC_ALL=C awk -v x="$v" -v m="$max" 'BEGIN{ exit !(x+0 >= 0 && x+0 <= m) }'
}

# ── conta arquivos de um conjunto de extensões sob $TARGET, podando vendor ───
count_ext() {
    # $@ = extensões (sem ponto). Poda .git, node_modules, venvs, build dirs.
    local find_expr=() ext
    for ext in "$@"; do find_expr+=( -o -name "*.$ext" ); done
    # remove o primeiro "-o"
    find_expr=( "${find_expr[@]:1}" )
    find "$TARGET" -type d \( \
            -name .git -o -name node_modules -o -name .venv -o -name venv \
            -o -name vendor -o -name dist -o -name build -o -name __pycache__ \
            -o -name .tox -o -name site-packages -o -name coverage \
        \) -prune -o -type f \( "${find_expr[@]}" \) -print 2>/dev/null | wc -l | tr -d ' '
}

# ── detecta a linguagem dominante por contagem de extensões ─────────────────
detect_lang() {
    local n_py n_js n_sh n_liq best_lang best_n
    n_py=$(count_ext py)
    n_js=$(count_ext js jsx mjs cjs ts tsx)
    n_sh=$(count_ext sh)
    n_liq=$(count_ext liquid)
    best_lang=""; best_n=0
    # ordem de desempate determinística: python, js, bash, liquid
    local pair lang n
    for pair in "python:$n_py" "js:$n_js" "bash:$n_sh" "liquid:$n_liq"; do
        lang="${pair%%:*}"; n="${pair#*:}"
        if [ "$n" -gt "$best_n" ]; then best_n="$n"; best_lang="$lang"; fi
    done
    [ "$best_n" -eq 0 ] && return 1
    printf '%s' "$best_lang"
}

# ── mapa lang → "template_subpath dest_name" ────────────────────────────────
template_for() {
    case "$1" in
        python)       echo "python/.coveragerc .coveragerc" ;;
        js|ts)        echo "js/.c8rc.json .c8rc.json" ;;
        liquid)       echo "liquid/.c8rc.json .c8rc.json" ;;
        bash)         echo "bash/.simplecov .simplecov" ;;
        *)            return 1 ;;
    esac
}

# ── probe de kcov no host (AC7) ─────────────────────────────────────────────
# Ecoa "available" ou "absent". Não falha o script.
probe_kcov() {
    local k="${COVERAGE_INIT_KCOV:-kcov}"
    if [ -x "$k" ] || command -v "$k" >/dev/null 2>&1; then
        echo "available"
    else
        echo "absent"
    fi
}

# ── V1: o projeto já configura cobertura? (criar .coveragerc o sombrearia) ───
# .coveragerc tem PRECEDÊNCIA sobre [tool.coverage] do pyproject; criá-lo
# descartaria silenciosamente o `source=`/omit do projeto. O gate força --branch
# via flag CLI, então pular o arquivo é seguro.
python_has_cov_config() {
    local t="$1"
    grep -q '\[tool\.coverage' "$t/pyproject.toml" 2>/dev/null && return 0
    grep -q '\[coverage:run\]' "$t/setup.cfg"     2>/dev/null && return 0
    grep -q '\[coverage:run\]' "$t/tox.ini"       2>/dev/null && return 0
    return 1
}

# ── arg parse ───────────────────────────────────────────────────────────────
TARGET="$PWD"
LANG_OVERRIDE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="${2:-}"; shift ;;
        --lang)   LANG_OVERRIDE="${2:-}"; shift ;;
        -h|--help) usage; exit 0 ;;
        --*) die_usage "unknown flag '$1'" ;;
        *)   die_usage "unexpected argument '$1'" ;;
    esac
    shift
done

[ -d "$TARGET" ] || die_usage "--target '$TARGET' não é um diretório"
[ -d "$TEMPLATES_DIR" ] || { echo "ERROR: templates dir ausente: $TEMPLATES_DIR" >&2; exit 1; }
TARGET="$(cd "$TARGET" && pwd)"

# ── 1. detecta (ou usa override) a linguagem ────────────────────────────────
if [ -n "$LANG_OVERRIDE" ]; then
    case "$LANG_OVERRIDE" in
        python|js|ts|bash|liquid) DETECTED="$LANG_OVERRIDE" ;;
        *) die_usage "unsupported --lang '$LANG_OVERRIDE'" ;;
    esac
else
    DETECTED=$(detect_lang) || { echo "ERROR: nenhuma linguagem suportada detectada em $TARGET" >&2; exit 1; }
fi
echo "coverage-init: target=$TARGET lang=$DETECTED"

# ── 2. copia o template de config (idempotente: não clobber; V1: não sombreia) ─
if [ "$DETECTED" = "python" ] && python_has_cov_config "$TARGET"; then
    # V1: projeto já configura cobertura (pyproject/setup.cfg/tox.ini) → criar
    # .coveragerc teria precedência e sombrearia (ex.: source=). NÃO criar.
    echo "  config: projeto já tem [tool.coverage]/[coverage:run] — .coveragerc NÃO criado (evita shadow)"
else
    read -r tpl_sub dest_name <<EOF
$(template_for "$DETECTED")
EOF
    SRC="$TEMPLATES_DIR/$tpl_sub"
    DEST="$TARGET/$dest_name"
    [ -f "$SRC" ] || { echo "ERROR: template ausente: $SRC" >&2; exit 1; }
    if [ -f "$DEST" ]; then
        echo "  config: $dest_name já existe — preservado (idempotente)"
    else
        cp "$SRC" "$DEST"
        echo "  config: copiado $tpl_sub → $dest_name"
    fi
fi

# ── 3. probe de kcov + nota de cobertura de bash (AC7) ──────────────────────
if [ "$DETECTED" = "bash" ]; then
    KCOV_STATE=$(probe_kcov)
    if [ "$KCOV_STATE" = "available" ]; then
        echo "  bash: kcov $KCOV_STATE no host; bashcov line-only (branch=n/a), kcov disponível como fallback"
    else
        echo "  bash: kcov $KCOV_STATE no host ([SUPOSIÇÃO] kcov-macOS-frágil) — cobertura cai em bashcov line-only (branch=n/a)"
    fi
fi

# ── 4. baseline inicial (idempotente: não sobrescreve ratchet existente) ─────
BASELINE="$TARGET/.coverage-baseline.json"
MEASURED="${COVERAGE_INIT_MEASURED_TOTAL:-}"
if [ -f "$BASELINE" ]; then
    echo "  baseline: .coverage-baseline.json já existe — preservado (ratchet não regride)"
else
    if [ -n "$MEASURED" ]; then
        is_num_in_range "$MEASURED" 100 || { echo "ERROR: COVERAGE_INIT_MEASURED_TOTAL inválido: '$MEASURED'" >&2; exit 1; }
        total="$MEASURED"
        note="total medido na 1a execução; ratchet sobe a partir daqui (coverage-gate.sh --gate)"
    else
        total="0"
        note="baseline inicial; ainda não instrumentado (total=0). Re-rode com COVERAGE_INIT_MEASURED_TOTAL após medir, ou deixe o CI subir o ratchet."
    fi
    cat > "$BASELINE" <<JSON
{
  "total": $total,
  "lang": "$DETECTED",
  "epsilon": 0.5,
  "note": "$note"
}
JSON
    echo "  baseline: .coverage-baseline.json criado (total=$total)"
fi

# ── 5. vendora coverage-gate.sh para scripts/ci/ do target (P0-2) ───────────
# O CI (coverage-ci.yml) chama scripts/ci/coverage-gate.sh — o path interno
# skills/ralph-adversarial/lib/... só existe no dotclaude e daria exit 127 no
# projeto-alvo (travando o required check p/ sempre). Copiado overwrite p/
# manter a cópia vendorada em sincronia com a fonte do dotclaude.
GATE_SRC="${COVERAGE_INIT_GATE_SRC:-$SCRIPT_DIR/../skills/ralph-adversarial/lib/coverage-gate.sh}"
if [ -f "$GATE_SRC" ]; then
    mkdir -p "$TARGET/scripts/ci"
    cp "$GATE_SRC" "$TARGET/scripts/ci/coverage-gate.sh"
    chmod +x "$TARGET/scripts/ci/coverage-gate.sh"
    echo "  gate: vendorado coverage-gate.sh → scripts/ci/"
else
    echo "  gate: AVISO — coverage-gate.sh ausente em $GATE_SRC; o CI quebraria sem o script vendorado" >&2
fi

# ── 6. copia o template de CI quando US-03 já o produziu (condicional) ──────
CI_SRC="$TEMPLATES_DIR/coverage-ci.yml"
if [ -f "$CI_SRC" ]; then
    mkdir -p "$TARGET/.github/workflows"
    CI_DEST="$TARGET/.github/workflows/coverage-ci.yml"
    if [ -f "$CI_DEST" ]; then
        echo "  ci: coverage-ci.yml já existe — preservado (idempotente)"
    else
        # V2: parametriza o job pela linguagem DETECTADA (template usa __LANG__).
        # Antes copiava verbatim → job `--lang bash` rodava num projeto Python.
        sed "s/__LANG__/$DETECTED/g" "$CI_SRC" > "$CI_DEST"
        echo "  ci: gerado coverage-ci.yml (--lang $DETECTED) → .github/workflows/"
    fi
else
    echo "  ci: template coverage-ci.yml ausente (US-03 ainda não entregue) — pulado"
fi

echo "coverage-init: pronto."
exit 0
