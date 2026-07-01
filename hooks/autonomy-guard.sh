#!/usr/bin/env bash
# hooks/autonomy-guard.sh — Hook Stop: backstop determinístico do Princípio 15
# (autonomia por default) — R1 da análise de interrupções de 2026-07-01.
#
# O QUE FAZ: ao fim de cada turno (evento Stop), parseia o transcript JSONL e
# detecta turno-pergunta auto-aprovável ("Quer que eu…?", "Posso prosseguir…?",
# "Confirma…?", menu (A)/(B) com recomendação — PT+EN, derivados do detector
# calibrado bin/interrupcoes-report.sh). Allowlist ANTES dos padrões hot (gates
# legítimos do P15 a–e): AskUserQuestion/ExitPlanMode no turno, pedido de
# credencial/login/2FA/código, custo/cota/billing, irreversível em produção.
#
# QUANDO DISPARA: registrado sob Stop via sync.sh install (US-03). Stop hooks
# rodam em paralelo e ignoram matcher (registro com matcher:"" é inócuo, igual
# aos Stop hooks existentes). Timeout 5000ms no registro — nunca trava a sessão.
#
# MODOS (resolução: env AUTONOMY_GUARD_MODE > arquivo de modo > "advisory"):
#   advisory (default) — só audita 1 linha JSONL por turno hot/allowlist;
#            stdout VAZIO, exit 0. Rollout advisory-first: o audit alimenta o
#            tuning de falso-positivo antes de qualquer promoção a block.
#   block    — emite {"decision":"block","reason":<instrução P15>} no stdout,
#            exit 0 (contrato de hook Stop: o harness re-apresenta o reason ao
#            modelo, que continua o turno executando a própria recomendação).
#            Block efetivo SOMENTE quando o marcador de VM está presente
#            (AUTONOMY_GUARD_VM_MARKER) — host NUNCA bloqueia: degrada a
#            advisory + evento "host-never-blocks" no audit. Orçamento por
#            sessão AUTONOMY_GUARD_MAX_BLOCKS (default 2; estado em arquivo no
#            dir do audit) é o ANTI-LOOP PRIMÁRIO (stop_hook_active é
#            best-effort, não garantido pelo contrato); esgotado → degrada a
#            advisory + evento "BLOCK_BUDGET_EXHAUSTED". Allowlist SEMPRE
#            vence block (gates legítimos do P15 nunca são bloqueados).
#
# PARSING (Revisão Adversária do plano autonomy-guard, Falhas #1/#3/#5):
# iteração REVERSA do JSONL acumulando linhas assistant consecutivas
# (não-sidechain) até o último prompt REAL do usuário — tool_result, ecos de
# <local-command-*> e injeções não contam como prompt. Texto = APENAS blocks
# type=="text" (thinking excluído). SEM tail fixo: turnos longos (centenas de
# tool_results) são cobertos porque o arquivo é lido inteiro e varrido do fim.
#
# CONTRATO: best-effort, fail-open, SEMPRE exit 0 — bug aqui NUNCA derruba o
# turno do usuário. stop_hook_active é guard best-effort ('.stop_hook_active //
# false'; o anti-loop primário — orçamento de blocks — chega na US-02). Sem
# operação de rede (parsing 100% local).
#
# AUDIT (1 linha JSON por turno hot/allowlist; cold não audita):
#   {ts, session_id, mode, match, allowlist_reason, decision, event}
#   hot → match=<padrão>, decision="advisory"|"block"; allowlist →
#   allowlist_reason=<r>, decision=null. event marca degradações do block:
#   "host-never-blocks" | "BLOCK_BUDGET_EXHAUSTED" | "budget-state-error".
#
# SEAMS (env, p/ teste e tuning):
#   AUTONOMY_GUARD_AUDIT      → path do audit.jsonl
#                               (default ~/.claude/cache/autonomy/audit.jsonl)
#   AUTONOMY_GUARD_AUDIT_MAX_BYTES → teto de rotação do audit (default 10 MiB;
#                               acima disso vira <audit>.1 — 1 histórico)
#   AUTONOMY_GUARD_MODE       → força o modo (vence o arquivo de modo)
#   AUTONOMY_GUARD_MODE_FILE  → path do arquivo de modo
#                               (default ~/.claude/cache/autonomy/mode)
#   AUTONOMY_GUARD_VM_MARKER  → path do marcador de VM
#                               (default ~/.claude/.vm-profile)
#   AUTONOMY_GUARD_MAX_BLOCKS → orçamento de blocks por session_id (default 2)
#   AUTONOMY_GUARD_PY         → binário python (default python3; seam fail-open)
#   AUTONOMY_GUARD_DEBUG      → 1 → traços em stderr

PYCODE=$(cat <<'PYEOF'
import json
import os
import re
import sys
import time
from datetime import datetime, timezone


def _dbg(msg):
    if os.environ.get("AUTONOMY_GUARD_DEBUG"):
        sys.stderr.write("autonomy-guard: %s\n" % msg)


def fail_open(msg=None):
    if msg:
        _dbg(msg)
    sys.exit(0)


# Prefixos de "user line" que NÃO são prompt real (idem interrupcoes-report.sh).
NOISE = ("<ide_selection", "<ide_opened_file", "<command-message", "<command-name",
         "<command-args", "<local-command-stdout", "<local-command-stderr",
         "<user-prompt-submit-hook", "Caveat:", "[Request interrupted")

# Allowlist textual (gates legítimos do P15 a–e) — checada ANTES dos hot.
ALLOWLIST_TOOLS = {
    "AskUserQuestion": "ask-user-question",
    "ExitPlanMode": "exit-plan-mode",
}
ALLOWLIST_TEXT = (
    ("credential-request",
     r"credencia|senha\b|password|\blogin\b|\blogar\b|\b2fa\b|autentica"
     r"|c[oó]digo de verifica|verification code|api key"),
    ("cost-quota",
     r"\bcusto|\bcota\b|\bquota\b|billing|cobran[çc]a|fatura|\bpago\b|R\$|US\$"),
    ("irreversible-production",
     r"irrevers[ií]vel|irreversible|n[aã]o pode ser desfeit|cannot be undone"),
)

# Padrões hot derivados do detector calibrado (bin/interrupcoes-report.sh),
# PT+EN — mudanças lá devem ser espelhadas aqui (code-review 2026-07-01, V6).
# Exclusões DELIBERADAS da fonte (precisão > recall): '?' final solto e
# "qual você"/"me diga qual" (escolha real de escopo = gate P15-a, não
# auto-aprovável); "você prefere"/"ou prefere" já cobertos por "prefere".
HOT = (
    "quer que eu",
    r"posso (prosseguir|seguir|continuar|come[çc]ar|fazer)",
    "confirma",
    r"\bdevo ",
    r"\bdeseja ",
    "prefere",
    r"\bok pra\b",
    r"\bok para\b",
    "do you want",
    r"\bshould i ",
    "would you like",
    r"\bshall i ",
)


def user_text(c):
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return " ".join(b.get("text", "") for b in c
                        if isinstance(b, dict) and b.get("type") == "text")
    return ""


def is_real_prompt(c):
    """Prompt REAL do usuário: exclui tool_result, ecos de local-command e injeções."""
    if isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
        return False
    t = user_text(c).strip()
    if not t or t.startswith(NOISE):
        return False
    s = re.sub(r"<(ide_selection|ide_opened_file|system-reminder)[\s\S]*?</\1>", "", t).strip()
    s = re.sub(r"<[^>]+>", "", s).strip()
    return len(s) >= 2


def last_assistant_turn(path):
    """Itera o JSONL em REVERSA acumulando linhas assistant (não-sidechain) até
    o último prompt real do usuário (Falhas #1/#5). → (texto, [tool names]).
    Texto = só blocks type=="text" (Falha #3)."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
    texts, tools = [], []
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(o, dict) or o.get("isSidechain"):
            continue
        m = o.get("message")
        if not isinstance(m, dict):
            continue
        role, c = m.get("role"), m.get("content")
        if role == "assistant":
            if isinstance(c, list):
                for b in c:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "text":
                        texts.append(b.get("text", ""))
                    elif b.get("type") == "tool_use":
                        tools.append(b.get("name") or "")
            elif isinstance(c, str):
                texts.append(c)
        elif role == "user" and is_real_prompt(c):
            break
        # user não-real (tool_result/eco/injeção) e outros types → continua
    texts.reverse()
    tools.reverse()
    return "\n".join(texts), tools


def classify(text, tools):
    """→ ('allowlist', reason) | ('hot', match) | ('cold', None). Allowlist primeiro."""
    for t in tools:
        if t in ALLOWLIST_TOOLS:
            return "allowlist", ALLOWLIST_TOOLS[t]
    low = text.lower()
    for reason, pat in ALLOWLIST_TEXT:
        if re.search(pat, low):
            return "allowlist", reason
    for pat in HOT:
        if re.search(pat, low):
            return "hot", pat
    if re.search(r"\(a\)", low) and re.search(r"\(b\)", low) and "recomend" in low:
        return "hot", "menu-ab-recomendado"
    return "cold", None


# Reason do block: instrução P15 re-apresentada ao modelo (turno continua).
BLOCK_REASON = (
    "Backstop do P15 (autonomia por default): este turno terminou pedindo "
    "confirmação para um próximo passo auto-aprovável. Execute AGORA a "
    "recomendação que você já redigiu, registrando a decisão como [SUPOSIÇÃO] "
    "com a ação default tomada. Pergunte ao usuário SOMENTE nos gates (a)-(e) "
    "do P15: (a) ambiguidade real sem default sensato, (b) efeito irreversível "
    "em produção, (c) custo/cota, (d) input/credencial que só o usuário tem, "
    "(e) gates de segurança P7/P11/P12."
)


def vm_marker_present():
    marker = os.environ.get("AUTONOMY_GUARD_VM_MARKER") \
        or os.path.expanduser("~/.claude/.vm-profile")
    return os.path.exists(marker)


def consume_block_budget(state_dir, session_id):
    """Anti-loop PRIMÁRIO (Falha #2: stop_hook_active é best-effort). Estado =
    1 arquivo-contador por session_id sob o dir do audit; sessão nova começa
    do zero (reset natural). → 'ok' (consumiu 1) | 'exhausted' | 'state-error'
    (não persistível → NÃO bloqueia, senão loop infinito sem contador)."""
    try:
        limit = int(os.environ.get("AUTONOMY_GUARD_MAX_BLOCKS") or 2)
    except ValueError:
        limit = 2
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", session_id) or "no-session"
    path = os.path.join(state_dir, "block-budget-%s.count" % safe)
    try:
        with open(path) as fh:
            used = int(fh.read().strip() or 0)
    except (OSError, ValueError):
        used = 0
    if used >= limit:
        return "exhausted"
    try:
        if state_dir:
            os.makedirs(state_dir, exist_ok=True)
        with open(path, "w") as fh:
            fh.write(str(used + 1))
    except OSError as e:
        _dbg("falha persistindo orçamento: %s" % e)
        return "state-error"
    return "ok"


def resolve_mode():
    m = (os.environ.get("AUTONOMY_GUARD_MODE") or "").strip().lower()
    if m:
        return m
    mode_file = os.environ.get("AUTONOMY_GUARD_MODE_FILE") \
        or os.path.expanduser("~/.claude/cache/autonomy/mode")
    try:
        with open(mode_file) as fh:
            m = fh.read().strip().lower()
        if m:
            return m
    except OSError:
        pass
    return "advisory"


def maybe_housekeep(audit_path):
    """Rotação + GC (convenção dos hooks irmãos: stop-notify GC diário,
    supply-chain rota por tamanho — code-review 2026-07-01, V4). Custo típico
    por evento: 2 stats. Rotação: audit acima de AUTONOMY_GUARD_AUDIT_MAX_BYTES
    (default 10 MiB) vira <audit>.1 (mantém 1 histórico). GC diário (marcador
    .last-gc): remove block-budget-*.count com mtime > 30d."""
    try:
        d = os.path.dirname(audit_path)
        if not d or not os.path.isdir(d):
            return  # 1º evento cria o dir no append; housekeeping fica pro próximo
        try:
            max_bytes = int(os.environ.get("AUTONOMY_GUARD_AUDIT_MAX_BYTES")
                            or 10 * 1024 * 1024)
        except ValueError:
            max_bytes = 10 * 1024 * 1024
        try:
            if os.path.getsize(audit_path) > max_bytes:
                os.replace(audit_path, audit_path + ".1")
        except OSError:
            pass  # audit ainda não existe → nada a rotacionar
        now = time.time()
        mark = os.path.join(d, ".last-gc")
        try:
            if now - os.path.getmtime(mark) < 86400:
                return  # GC já rodou hoje
        except OSError:
            pass  # marcador ausente → 1º GC
        for name in os.listdir(d):
            if name.startswith("block-budget-") and name.endswith(".count"):
                p = os.path.join(d, name)
                try:
                    if now - os.path.getmtime(p) > 30 * 86400:
                        os.remove(p)
                except OSError:
                    pass
        with open(mark, "w"):
            pass
    except Exception as e:  # noqa: BLE001 — housekeeping nunca derruba o turno
        _dbg("housekeeping falhou: %s" % e)


def append_audit(audit_path, rec):
    try:
        maybe_housekeep(audit_path)
        d = os.path.dirname(audit_path)
        if d:
            os.makedirs(d, exist_ok=True)
        with open(audit_path, "a") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError as e:
        _dbg("falha anexando audit: %s" % e)  # fail-open: não derruba o turno


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception as e:
        fail_open("JSON parse error: %s" % e)
    if not isinstance(payload, dict):
        fail_open("payload não-dict")
    if payload.get("stop_hook_active"):
        fail_open("stop_hook_active=true → no-op (anti-loop best-effort)")

    session_id = payload.get("session_id") or ""
    tpath = payload.get("transcript_path") or ""
    if not tpath or not os.path.exists(tpath):
        fail_open("transcript ausente: %r" % tpath)

    try:
        text, tools = last_assistant_turn(tpath)
    except Exception as e:
        fail_open("falha parseando transcript: %s" % e)

    kind, detail = classify(text, tools)
    if kind == "cold":
        fail_open("cold: turno sem pergunta auto-aprovável")

    audit_path = os.environ.get("AUTONOMY_GUARD_AUDIT") \
        or os.path.expanduser("~/.claude/cache/autonomy/audit.jsonl")
    mode = resolve_mode()

    # Block só em hot (allowlist SEMPRE vence block) + modo block + marcador VM
    # + orçamento disponível; qualquer condição ausente degrada a advisory.
    decision = "advisory" if kind == "hot" else None
    event = None
    if kind == "hot" and mode == "block":
        if not vm_marker_present():
            event = "host-never-blocks"
        else:
            budget = consume_block_budget(os.path.dirname(audit_path), session_id)
            if budget == "ok":
                decision = "block"
            elif budget == "exhausted":
                event = "BLOCK_BUDGET_EXHAUSTED"
            else:
                event = "budget-state-error"

    append_audit(audit_path, {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "session_id": session_id,
        "mode": mode,
        "match": detail if kind == "hot" else None,
        "allowlist_reason": detail if kind == "allowlist" else None,
        "decision": decision,
        "event": event,
    })
    if decision == "block":
        # Contrato Stop hook: JSON no stdout + exit 0 → harness re-apresenta
        # o reason ao modelo e o turno continua (Revisão Adversária, SUPOSIÇÃO 2).
        print(json.dumps({"decision": "block", "reason": BLOCK_REASON},
                         ensure_ascii=False))
    sys.exit(0)


try:
    main()
except SystemExit:
    raise  # exit 0 intencional (fail_open / fim do fluxo) — propaga
except BaseException as e:  # noqa: BLE001 — fail-open: NUNCA derruba o turno
    _dbg("exceção não-tratada no main: %s" % e)
    sys.exit(0)
PYEOF
)

# Guard fail-open: python ausente (seam AUTONOMY_GUARD_PY) → no-op exit 0.
PYBIN="${AUTONOMY_GUARD_PY:-python3}"
command -v "$PYBIN" >/dev/null 2>&1 || exit 0
exec "$PYBIN" -c "$PYCODE"
