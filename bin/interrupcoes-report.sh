#!/usr/bin/env bash
# interrupcoes-report.sh — lista as INTERRUPÇÕES do Claude Code: pontos em que o
# agente parou de trabalhar e devolveu o controle ao usuário PARA PERGUNTAR algo.
#
# O QUE FAZ
#   Varre ~/.claude/projects/<project>/<session>.jsonl e identifica os turnos em
#   que o assistente encerrou devolvendo a vez ao usuário COM uma pergunta/pedido
#   (em vez de seguir autônomo). Classifica cada uma por categoria e emite um
#   relatório rotulável (markdown), planilha (tsv) ou dados (json). Read-only.
#
#   Motivação: medir quanto o agente interrompe o trabalho para pedir confirmação
#   /escolha/permissão, separando o que é legítimo (destrutivo, billable — ver
#   Princípios 7/11/12) do que poderia ter sido autônomo.
#
# O QUE CONTA COMO INTERRUPÇÃO (precisão > recall)
#   Um turno do assistente é interrupção quando, somadas as condições:
#     (1) o PRÓXIMO evento é um prompt REAL do usuário — não um tool_result, nem
#         injeção de IDE (<ide_selection>/<ide_opened_file>), nem caveat de
#         local-command, nem evento do harness (wakeup de Monitor,
#         task-notification, id toolu_ avulso — falsos positivos, R7); e
#     (2) o turno terminou pedindo algo, detectado por um destes sinais:
#           ask_tool  — usou a tool AskUserQuestion (pergunta estruturada);
#           exit_plan — usou ExitPlanMode (pediu aprovação de plano);
#           question  — o texto final termina em '?' ou casa padrões de pedido
#                       ("quer que eu", "posso prosseguir", "ou prefere", ...);
#           redirect  — o turno pediu algo e a resposta foi um eco de slash
#                       command (/handoff-continue, /full-cycle…): interrupção
#                       real, mas você redirecionou em vez de responder (R7).
#   isSidechain true (subagentes) é sempre excluído — não é interação com você.
#
#   LIMITE CONHECIDO: prompts de PERMISSÃO do harness (allow/deny de tool) NÃO
#   ficam no transcript como conteúdo do assistente; este relatório cobre as
#   perguntas AUTORAIS do agente, que é onde cabe "devia ter feito sozinho".
#
# QUANDO USAR
#   Diagnóstico read-only de autonomia do agente. Sem efeitos colaterais — só lê
#   transcripts e imprime. Para incluir as VMs, use --remote (roda este mesmo
#   script via `ssh ... bash -s`, sem copiar arquivo).
#
# FLUXO PONTA-A-PONTA
#   - Pré-condição: PR_TRANSCRIPT_DIR (default ~/.claude/projects) tem subdirs de
#     projeto com .jsonl.
#   - Local:  bin/interrupcoes-report.sh [--since N] [--format md|tsv|json]
#   - +VMs:   bin/interrupcoes-report.sh --remote vm1=USER@HOST_VM1 \
#                                        --remote vm2=USER@HOST_VM2
#   - Encerra exit 0 no caminho feliz; args inválidos → usage + exit 2.
#
# FLAGS
#   --since N            só arquivos com mtime nos últimos N dias (default 14).
#   --project S          só projetos cujo diretório contém a substring S.
#   --machine NAME       rótulo desta máquina nos registros (default "host").
#   --remote NAME=DEST   inclui a máquina DEST (destino ssh) sob o rótulo NAME;
#                        repetível. Roda este script remoto via `ssh DEST bash -s`.
#   --format md|tsv|json formato de saída (default md).
#   --out FILE           escreve no arquivo em vez de stdout.
#   --emit-json          modo interno: emite só os registros desta máquina (json)
#                        e NÃO processa --remote (usado pelas chamadas ssh).
#   --help               esta ajuda.
#
# SEAMS DE TESTE (env):
#   PR_TRANSCRIPT_DIR    raiz dos transcripts (default ~/.claude/projects)
#   IR_SSH               binário ssh (default "ssh"); permite stub nos testes.

set -u

# ── seams / defaults ─────────────────────────────────────────────────────────
TRANSCRIPT_DIR="${PR_TRANSCRIPT_DIR:-$HOME/.claude/projects}"
SSH_BIN="${IR_SSH:-ssh}"
SINCE=14
PROJECT=""
MACHINE="host"
FORMAT="md"
OUT=""
EMIT_JSON=0
REMOTES=()

usage() {
  cat <<'EOF'
Uso: interrupcoes-report.sh [--since N] [--project S] [--machine NAME]
                            [--remote NAME=DEST]... [--format md|tsv|json]
                            [--out FILE] [--help]

Lista interrupções do Claude Code — turnos em que o agente parou e pediu algo
ao usuário. Read-only. Classifica por categoria para rotulagem.

  --since N             só arquivos com mtime nos últimos N dias (default 14).
  --project S           só projetos cujo diretório contém a substring S.
  --machine NAME        rótulo desta máquina (default "host").
  --remote NAME=DEST    inclui a VM DEST (destino ssh) sob o rótulo NAME; repetível.
  --format md|tsv|json  formato de saída (default md).
  --out FILE            escreve no arquivo em vez de stdout.
  --help                esta ajuda.

Exemplo cobrindo host + 2 VMs:
  interrupcoes-report.sh --remote vm1=USER@HOST_VM1 \
                         --remote vm2=USER@HOST_VM2 --out ~/interrupcoes.md
EOF
}

die_usage() { usage >&2; exit 2; }

# ── parse args ───────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --since)
      shift; [ $# -gt 0 ] || die_usage
      case "$1" in ''|*[!0-9]*) die_usage ;; esac
      [ "${#1}" -gt 5 ] && die_usage
      [ "$1" -ge 0 ] || die_usage
      SINCE="$1" ;;
    --project) shift; [ $# -gt 0 ] || die_usage; PROJECT="$1" ;;
    --machine) shift; [ $# -gt 0 ] || die_usage; MACHINE="$1" ;;
    --remote)
      shift; [ $# -gt 0 ] || die_usage
      case "$1" in *=*) REMOTES+=("$1") ;; *) die_usage ;; esac ;;
    --format) shift; [ $# -gt 0 ] || die_usage
      case "$1" in md|tsv|json) FORMAT="$1" ;; *) die_usage ;; esac ;;
    --out) shift; [ $# -gt 0 ] || die_usage; OUT="$1" ;;
    --emit-json) EMIT_JSON=1 ;;
    *) die_usage ;;
  esac
  shift
done

[ -d "$TRANSCRIPT_DIR" ] || { echo "diretório de transcripts inexistente: $TRANSCRIPT_DIR" >&2; exit 1; }

# ── detecção (python inline; config via env — sem injeção de args) ───────────
# Emite um array JSON de registros crus desta máquina.
detect_local() {
  PR_DIR="$TRANSCRIPT_DIR" PR_SINCE="$SINCE" PR_PROJECT="$PROJECT" PR_MACHINE="$MACHINE" \
  python3 - <<'PY'
import os, sys, json, glob, time, re

root    = os.environ["PR_DIR"]
since   = int(os.environ["PR_SINCE"])
project = os.environ["PR_PROJECT"]
machine = os.environ["PR_MACHINE"]
cutoff  = time.time() - since * 86400

NOISE = ("<ide_selection", "<ide_opened_file", "<command-message", "<command-name",
         "<command-args", "<local-command-stdout", "<local-command-stderr",
         "<user-prompt-submit-hook", "Caveat:", "[Request interrupted")

# Eventos do harness que chegam como mensagem de user mas NÃO são resposta sua:
# wakeups de Monitor, task-notifications de background e ids de tool_use avulsos
# (34 falsos positivos no período 2026-06-17→07-01 — R7 da análise de autonomia).
FALSE_POSITIVE = re.compile(r"toolu_|Monitor event:|<task-notification")

# Eco de slash command como resposta = interrupção REAL, mas de tipo distinto:
# você redirecionou (/handoff-continue, /full-cycle…) em vez de responder.
CMD_RE = re.compile(r"<command-name>\s*(/[\w-]+)")

def user_text(c):
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(b.get("text", "") for b in c
                        if isinstance(b, dict) and b.get("type") == "text")
    return ""

def is_real_prompt(c):
    if isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
        return False
    t = user_text(c).strip()
    if not t or t.startswith(NOISE):
        return False
    if FALSE_POSITIVE.search(t):
        return False
    s = re.sub(r"<(ide_selection|ide_opened_file|system-reminder)[\s\S]*?</\1>", "", t).strip()
    s = re.sub(r"<[^>]+>", "", s).strip()
    return len(s) >= 2

def slash_redirect(c):
    m = CMD_RE.search(user_text(c))
    return m.group(1) if m else None

def looks_like_question(txt):
    s = txt.strip()
    if not s:
        return False
    lines = [l for l in s.splitlines() if l.strip()]
    if lines and lines[-1].rstrip().rstrip("*_`)").endswith("?"):
        return True
    tail = s[-600:].lower()
    pats = ["quer que eu", "você prefere", "voce prefere", "ou prefere", "prefere que",
            "posso prosseguir", "posso seguir", "confirma", "devo ", "deseja ",
            "qual você", "qual voce", "me diga qual", "do you want", "should i ",
            "would you like", "shall i ", "prefere revisar", "ok pra", "ok para"]
    return any(p in tail for p in pats)

def proj_name(path, cwd):
    if cwd:
        return cwd
    return os.path.basename(os.path.dirname(path))

records = []
for proj_dir in sorted(glob.glob(os.path.join(root, "*"))):
    if not os.path.isdir(proj_dir):
        continue
    if project and project not in os.path.basename(proj_dir):
        continue
    for path in sorted(glob.glob(os.path.join(proj_dir, "*.jsonl"))):
        try:
            if os.path.getmtime(path) < cutoff:
                continue
        except OSError:
            continue
        prev = None; last_prompt = None; cwd = None
        try:
            fh = open(path, encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in fh:
            try:
                o = json.loads(line)
            except (ValueError, TypeError):
                continue
            if o.get("isSidechain"):
                continue
            if o.get("cwd"):
                cwd = o["cwd"]
            m = o.get("message")
            if not isinstance(m, dict):
                continue
            role = m.get("role"); c = m.get("content"); ts = o.get("timestamp")
            if role == "assistant":
                txt = ""; tools = []; asks = []
                if isinstance(c, list):
                    for b in c:
                        if not isinstance(b, dict):
                            continue
                        if b.get("type") == "text":
                            txt += b.get("text", "")
                        elif b.get("type") == "tool_use":
                            tools.append(b.get("name"))
                            if b.get("name") == "AskUserQuestion":
                                for q in b.get("input", {}).get("questions", []):
                                    asks.append(q.get("question", ""))
                elif isinstance(c, str):
                    txt = c
                if txt.strip() or tools:
                    prev = {"txt": txt, "tools": tools, "ts": ts, "asks": asks}
            elif role == "user":
                if not prev:
                    continue
                cmd = slash_redirect(c)
                if not cmd and not is_real_prompt(c):
                    continue
                kind = None; q = None
                if prev["asks"]:
                    kind = "ask_tool"; q = " | ".join(prev["asks"])
                elif "ExitPlanMode" in prev["tools"]:
                    kind = "exit_plan"; q = prev["txt"].strip()[-500:] or "[plano para aprovação]"
                elif looks_like_question(prev["txt"]):
                    kind = "question"; q = prev["txt"].strip()[-500:]
                if kind and cmd:
                    kind = "redirect"
                if kind:
                    records.append({
                        "machine": machine,
                        "project": proj_name(path, cwd),
                        "session": os.path.basename(path),
                        "ts": prev["ts"] or ts,
                        "kind": kind,
                        "question": q,
                        "user_reply": cmd if cmd else user_text(c).strip()[:200],
                    })
                last_prompt = user_text(c).strip()
                prev = None
        fh.close()
print(json.dumps(records, ensure_ascii=False))
PY
}

# ── modo interno: só emite os registros desta máquina ────────────────────────
if [ "$EMIT_JSON" -eq 1 ]; then
  detect_local
  exit 0
fi

# ── coleta local + remotos ───────────────────────────────────────────────────
ALL_JSON="$(detect_local)"

for spec in "${REMOTES[@]:-}"; do
  [ -n "$spec" ] || continue
  name="${spec%%=*}"; dest="${spec#*=}"
  [ -n "$name" ] && [ -n "$dest" ] || { echo "remote inválido: $spec" >&2; exit 2; }
  # Pipa ESTE script para o bash remoto em modo --emit-json (self-contained).
  remote_json="$("$SSH_BIN" -o ConnectTimeout=8 "$dest" bash -s -- \
      --emit-json --since "$SINCE" --machine "$name" < "$0" 2>/dev/null)"
  if [ -z "$remote_json" ]; then
    echo "aviso: sem dados de $name ($dest) — inacessível ou vazio" >&2
    remote_json="[]"
  fi
  ALL_JSON="$ALL_JSON"$'\n'"$remote_json"
done

# ── categorização + render (python inline) ───────────────────────────────────
# Cada máquina contribui uma linha = um array JSON; PR_DATA aponta para o arquivo
# com essas linhas. O programa python vem pelo heredoc (stdin), por isso os dados
# NÃO podem vir por stdin — daí o arquivo via env (seam sem injeção de args).
render() {
  PR_FORMAT="$FORMAT" PR_DATA="$1" python3 - <<'PY'
import os, sys, json, re
from collections import Counter

fmt = os.environ["PR_FORMAT"]

recs = []
with open(os.environ["PR_DATA"], encoding="utf-8") as _fh:
    for line in _fh:
        line = line.strip()
        if not line:
            continue
        try:
            arr = json.loads(line)
        except (ValueError, TypeError):
            continue
        if isinstance(arr, list):
            recs.extend(arr)

def categorize(r):
    if r["kind"] == "redirect":
        return "redirect (slash command como resposta)"
    if r["kind"] != "question":
        return "ask_tool/exit_plan"
    s = (r.get("question") or "").lower()
    if re.search(r"\b(deploy|gcloud|cloud run|cloud build|builds submit|redeploy|billá|bilha|pago|custo|workflow run|gh workflow|stripe|aws|publicar|release|npm publish|produç)", s):
        return "externo/billable/deploy"
    if re.search(r"force|--admin|reset --hard|rm -rf|revogar|rotacionar|deletar|apagar|destrutiv", s):
        return "destrutivo/irreversível"
    if re.search(r"\b(merge|mergeie|mergear|commit|commite|abra? (o )?pr|abrir (o )?pr|push|abro os prs|abro o pr)\b", s):
        return "commit/PR/merge"
    if re.search(r"ou prefere|prefere revisar|prefere você|prefere voce|você mesmo|voce mesmo|ou você|ou voce|você dispara|voce dispara", s):
        return "revisar-antes / você-faz-vs-eu-faço"
    if re.search(r"\bqual\b|\bquais\b|me diga qual|opção|opcao|escolh|prefere .* ou ", s):
        return "escolha entre opções / qual escopo"
    if re.search(r"quer que eu|posso (prosseguir|seguir|continuar|começar|comecar|fazer)|devo |sigo |ok pra|ok para|deseja que|confirma|avanç", s):
        return "confirmar-antes-de-prosseguir"
    return "outro / esclarecimento"

def clean_question(q):
    s = (q or "").strip()
    if len(s) >= 480:  # cauda truncada — alinha a um começo limpo
        m = re.search(r"[.!?\n]\s+(\S)", s[:200])
        if m:
            s = s[m.start(1):]
        else:
            sp = s.find(" ")
            if 0 < sp < 60:
                s = s[sp + 1:]
        s = "…" + s
    return s.strip()

def clean_reply(u):
    s = (u or "").strip()
    s = re.sub(r"<local-command-[^>]*>.*", "", s, flags=re.S)
    s = re.sub(r"<command-(message|name|args)>.*?</command-\1>", "", s, flags=re.S)
    s = re.sub(r"<[^>]+>", "", s)
    return re.sub(r"\s+", " ", s).strip()

def projshort(p):
    return (p.replace("/Users/dev/Projects/", "").replace("/home/dev/Projects/", "")
             .replace("/Users/dev/", "~/").replace("/home/dev/", "~/"))

for r in recs:
    r["categoria"] = categorize(r)
    r["question"] = clean_question(r.get("question"))
    r["user_reply"] = clean_reply(r.get("user_reply"))
    r["ts_short"] = (r.get("ts") or "")[:16].replace("T", " ")

recs.sort(key=lambda r: (r["machine"], r["project"], r.get("ts") or ""))
cat_counts = Counter(r["categoria"] for r in recs)
mach_counts = Counter(r["machine"] for r in recs)

if fmt == "json":
    json.dump(recs, sys.stdout, ensure_ascii=False, indent=1)
    print()
elif fmt == "tsv":
    w = sys.stdout.write
    w("idx\tROTULO\tmaquina\tprojeto\tdata\tcategoria\tpergunta\tresposta\tsessao\n")
    for i, r in enumerate(recs, 1):
        q = re.sub(r"\s+", " ", r["question"]).strip()
        w("\t".join([str(i), "", r["machine"], projshort(r["project"]), r["ts_short"],
                     r["categoria"], q, r["user_reply"], r["session"][:8]]) + "\n")
else:  # md
    w = sys.stdout.write
    w("# Interrupções do Claude Code — pedidos ao usuário\n\n")
    w("Total: **%d** (%s).\n\n" % (
        len(recs), " · ".join("%s %d" % (m, n) for m, n in sorted(mach_counts.items()))))
    w("Marque **`[A]`** = *queria que o Claude fizesse sozinho*; **`[P]`** = *ok ter perguntado*.\n\n")
    w("## Resumo por categoria\n\n")
    for c, n in cat_counts.most_common():
        w("- **%s** — %d\n" % (c, n))
    w("\n---\n\n")
    idx = 0
    for c, _ in cat_counts.most_common():
        w("## %s\n\n" % c)
        for r in recs:
            if r["categoria"] != c:
                continue
            idx += 1
            q = re.sub(r"\n{2,}", "\n", r["question"]).replace("\n", "\n> ")
            w("**#%d** `[ ]`  ·  %s · %s · %s\n\n" % (idx, r["machine"], projshort(r["project"]), r["ts_short"]))
            w("> **Claude:** %s\n\n" % q)
            if r["user_reply"]:
                w("> **Você respondeu:** %s\n\n" % r["user_reply"])
            w("\n")
PY
}

DATA_FILE="$(mktemp)"
trap 'rm -f "$DATA_FILE"' EXIT
printf '%s\n' "$ALL_JSON" > "$DATA_FILE"

if [ -n "$OUT" ]; then
  render "$DATA_FILE" > "$OUT"
  echo "relatório escrito em: $OUT" >&2
else
  render "$DATA_FILE"
fi
