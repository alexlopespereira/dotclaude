#!/usr/bin/env bash
# parallelism-report.sh — mede aderência ao Princípio 9 (paralelização de
# tool_use) varrendo os transcripts do Claude Code.
#
# O QUE FAZ
#   Varre ~/.claude/projects/<project>/<session>.jsonl, identifica as respostas
#   da API que emitiram tool_use e reporta a fração que emitiu >=2 tool_use
#   (chamadas paralelas), por projeto e agregado.
#
#   FATO central do formato: chamadas PARALELAS da mesma resposta da API
#   compartilham `message.id` mas ocupam LINHAS separadas no jsonl (cada linha
#   carrega 1 bloco tool_use). Contar por linha dá 0% falso — o agrupamento é
#   por message.id. (Verificado nos transcripts reais: 12 linhas tool_use → 7
#   message.ids distintos → 4 com >=2.)
#
# QUANDO USAR
#   Diagnóstico read-only de quão paralelo o agente está de fato sendo. Sem
#   efeitos colaterais — só lê e imprime.
#
# FLUXO PONTA-A-PONTA
#   - Pré-condição: PR_TRANSCRIPT_DIR (default ~/.claude/projects) tem subdirs
#     de projeto com arquivos .jsonl.
#   - Invocação canônica: `bin/parallelism-report.sh [--since N] [--project S]
#     [--format table|jsonl] [--include-sidechains]`.
#   - Encerra com exit 0 no caminho feliz; args inválidos → usage + exit 2.
#
# DEFINIÇÕES
#   - "mensagem-API com tool_use": message.id distinto cujas linhas (somadas)
#     têm >=1 bloco tool_use. É o denominador do %.
#   - "paralela": mensagem-API cujo total de tool_use é >=2. É o numerador.
#   - bucket "unknown": linhas com tool_use SEM message.id — não agrupáveis;
#     contadas e reportadas à parte, NUNCA descartadas em silêncio (não entram
#     no denominador, pois não há como saber a que resposta pertencem).
#   - isSidechain true (subagentes) é excluído por default; --include-sidechains
#     o inclui.
#
# FLAGS
#   --since N            só arquivos com mtime nos últimos N dias (default 14).
#   --project S          só projetos cujo nome de diretório contém a substring S.
#   --format table|jsonl formato de saída (default table).
#   --include-sidechains inclui linhas isSidechain true.
#   --help               esta ajuda.
#
# SEAMS DE TESTE (env):
#   PR_TRANSCRIPT_DIR    raiz dos transcripts (default ~/.claude/projects)

set -u

# ── seams / defaults ─────────────────────────────────────────────────────────
TRANSCRIPT_DIR="${PR_TRANSCRIPT_DIR:-$HOME/.claude/projects}"
SINCE=14
PROJECT=""
FORMAT="table"
INCLUDE_SIDECHAINS=0

# ── usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Uso: parallelism-report.sh [--since N] [--project S] [--format table|jsonl]
                           [--include-sidechains] [--help]

Mede aderência ao Princípio 9: fração de respostas da API com >=2 tool_use
(chamadas paralelas), agrupando por message.id. Read-only.

  --since N             só arquivos com mtime nos últimos N dias (default 14).
  --project S           só projetos cujo diretório contém a substring S.
  --format table|jsonl  formato de saída (default table).
  --include-sidechains  inclui linhas isSidechain true (subagentes).
  --help                esta ajuda.

Bucket 'unknown': tool_use sem message.id é contado e reportado à parte.
EOF
}

die_usage() { usage >&2; exit 2; }

# ── parse args ───────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --since)
      shift
      [ $# -gt 0 ] || die_usage
      # Valida FORMA e COMPRIMENTO antes de qualquer aritmética (cat-9): um
      # número gigante estouraria `[ N -lt M ]` (rc=2, lido como falso em
      # cadeia ||) e poderia virar caminho feliz.
      case "$1" in ''|*[!0-9]*) die_usage ;; esac
      [ "${#1}" -gt 5 ] && die_usage
      [ "$1" -ge 0 ] || die_usage
      SINCE="$1"
      ;;
    --project)
      shift
      [ $# -gt 0 ] || die_usage
      PROJECT="$1"
      ;;
    --format)
      shift
      [ $# -gt 0 ] || die_usage
      case "$1" in table|jsonl) FORMAT="$1" ;; *) die_usage ;; esac
      ;;
    --include-sidechains) INCLUDE_SIDECHAINS=1 ;;
    *) die_usage ;;
  esac
  shift
done

[ -d "$TRANSCRIPT_DIR" ] || { echo "diretório de transcripts inexistente: $TRANSCRIPT_DIR" >&2; exit 1; }

# ── agregação (python3 inline; config via env — sem injeção de args) ─────────
PR_DIR="$TRANSCRIPT_DIR" PR_SINCE="$SINCE" PR_PROJECT="$PROJECT" \
PR_FORMAT="$FORMAT" PR_INCLUDE_SIDECHAINS="$INCLUDE_SIDECHAINS" \
python3 - <<'PY'
import os, sys, json, glob, time
from collections import defaultdict

root      = os.environ["PR_DIR"]
since     = int(os.environ["PR_SINCE"])
project   = os.environ["PR_PROJECT"]
fmt       = os.environ["PR_FORMAT"]
include_s = os.environ["PR_INCLUDE_SIDECHAINS"] == "1"

now    = time.time()
cutoff = now - since * 86400

# Por projeto: tool_use totais por message.id, e contagem de unknown.
# counts[proj][message_id] = total de blocos tool_use somando as linhas.
counts  = defaultdict(lambda: defaultdict(int))
unknown = defaultdict(int)
seen_projects = set()

for proj_dir in sorted(glob.glob(os.path.join(root, "*"))):
    if not os.path.isdir(proj_dir):
        continue
    proj = os.path.basename(proj_dir)
    if project and project not in proj:
        continue
    for path in sorted(glob.glob(os.path.join(proj_dir, "*.jsonl"))):
        try:
            if os.path.getmtime(path) < cutoff:
                continue
        except OSError:
            continue
        seen_projects.add(proj)
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if d.get("isSidechain") and not include_s:
                    continue
                msg = d.get("message")
                if not isinstance(msg, dict):
                    continue
                content = msg.get("content")
                if not isinstance(content, list):
                    continue
                n_tu = sum(
                    1 for c in content
                    if isinstance(c, dict) and c.get("type") == "tool_use"
                )
                if n_tu == 0:
                    continue
                mid = msg.get("id")
                if mid is None:
                    unknown[proj] += n_tu
                else:
                    counts[proj][mid] += n_tu

# Monta linhas por projeto + agregado.
def stats(per_id, unk):
    msgs = len(per_id)
    par  = sum(1 for v in per_id.values() if v >= 2)
    pct  = round(100.0 * par / msgs, 1) if msgs else 0.0
    return msgs, par, pct, unk

rows = []
agg_ids = defaultdict(int)
agg_unknown = 0
for proj in sorted(seen_projects):
    per_id = counts.get(proj, {})
    unk = unknown.get(proj, 0)
    msgs, par, pct, _ = stats(per_id, unk)
    rows.append((proj, msgs, par, pct, unk))
    for k, v in per_id.items():
        agg_ids[k] += v   # message.id é globalmente único — soma segura
    agg_unknown += unk

a_msgs = len(agg_ids)
a_par  = sum(1 for v in agg_ids.values() if v >= 2)
a_pct  = round(100.0 * a_par / a_msgs, 1) if a_msgs else 0.0

if fmt == "jsonl":
    out = sys.stdout
    for proj, msgs, par, pct, unk in rows:
        json.dump({"project": proj, "messages": msgs, "parallel": par,
                   "pct": pct, "unknown": unk}, out)
        out.write("\n")
    json.dump({"project": "AGGREGATE", "messages": a_msgs, "parallel": a_par,
               "pct": a_pct, "unknown": agg_unknown}, out)
    out.write("\n")
else:
    w = 40
    print(f"{'project':<{w}}  {'msgs':>5}  {'parall':>6}  {'pct':>6}  {'unknown':>7}")
    print(f"{'-'*w}  {'-'*5}  {'-'*6}  {'-'*6}  {'-'*7}")
    for proj, msgs, par, pct, unk in rows:
        p = (proj[:w-1] + "…") if len(proj) > w else proj
        print(f"{p:<{w}}  {msgs:>5}  {par:>6}  {str(round(pct))+'%':>6}  {unk:>7}")
    print(f"{'-'*w}  {'-'*5}  {'-'*6}  {'-'*6}  {'-'*7}")
    print(f"{'TOTAL':<{w}}  {a_msgs:>5}  {a_par:>6}  {str(round(a_pct))+'%':>6}  {agg_unknown:>7}")
    if a_msgs == 0:
        print("(nenhuma mensagem-API com tool_use no recorte)")
PY
