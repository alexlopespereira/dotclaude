#!/usr/bin/env bash
# verify-before-handoff-guard.sh — Hook PostToolUse: backstop determinístico do
# Princípio 14 / skill verify-before-handoff (US-02).
#
# POR QUÊ: a skill verify-before-handoff (US-01) é prompt-driven (depende do
# modelo reconhecer o gatilho). Este hook é o backstop determinístico nos
# caminhos QUENTES detectáveis: ações de efeito externo mutante (envio de e-mail,
# deploy, publish, criação de recurso, HTTP mutante externo). Quando o classificador
# grosso casa, injeta um REMINDER pra forçar a verificação funcional do resultado
# realizado ANTES de qualquer claim de conclusão / handoff ao usuário.
#
# CLASSIFICADOR (grosso, genérico — Finding #2, NÃO Resend-específico):
#   1. Tool MCP cujo nome (namespaced com `__`) casa o verbo send|create|delete|
#      deploy|publish (case-insensitive). Assinatura = nome da tool.
#   2. Bash com cliente HTTP (curl|wget|xh|httpie) + método/payload mutante
#      (POST|PUT|DELETE|PATCH ou --data/-d/--upload-file/-T/--json/--form) contra
#      host EXTERNO (não loopback). Assinatura = bash:<METHOD>:<host>. O host é
#      extraído da URL http(s):// no comando — httpie com host "pelado" (sem
#      esquema) não prova externalidade e cai como cold (conservador: erra p/ não
#      disparar, nunca p/ falso-bloqueio).
#   Tudo o mais (Read, git status, GET, POST p/ localhost) → COLD → no-op.
#
# MECANISMO DE INJEÇÃO (Finding #3 — provado contra a doc oficial de hooks):
#   PostToolUse entrega contexto ao modelo por DOIS campos do JSON de stdout:
#     - soft → {"hookSpecificOutput":{"hookEventName":"PostToolUse",
#               "additionalContext":"<reminder>"}}  (injetado junto ao tool result,
#               NÃO-bloqueante — cobre o cold-start, espelha o handoff-resume.sh).
#     - hard → {"decision":"block","reason":"<reminder>", ...additionalContext...}
#               ("block leve": a tool JÁ rodou — PostToolUse não desfaz —, mas o
#               reason é re-apresentado ao modelo, forçando endereçar a verificação).
#   exit 2 também mostraria stderr ao modelo, mas é redundante com decision:block;
#   usamos JSON (mais rico) e mantemos exit 0 sempre (best-effort, fail-open).
#
# TIERS / AUTO-PROMOÇÃO (via audit.jsonl):
#   - soft (candidato): assinatura vista < N vezes. Reminder curto, additionalContext.
#   - hard (promovido): assinatura vista >= N vezes (N=VERIFY_HANDOFF_PROMOTE_N,
#     default 2). Reminder forte, decision:block. Endurece o falso-positivo do soft
#     só sob evidência de recorrência real. Intervenção humana = 1 constante (N).
#
# CONTRATO: best-effort, fail-open, SEMPRE exit 0 (parse error / cold → no-op).
#   Lê o JSON do evento PostToolUse via stdin. Anexa 1 linha JSON por decisão hot em
#   audit.jsonl (campos: ts, tool, signature, tier, decision).
#
# SEAMS (env, p/ teste e tuning):
#   VERIFY_HANDOFF_AUDIT     → path do audit.jsonl
#                              (default ~/.claude/cache/verify-handoff/audit.jsonl)
#   VERIFY_HANDOFF_PROMOTE_N → N de promoção soft→hard (default 2)
#   VERIFY_HANDOFF_DEBUG     → 1 → traços em stderr
#
# REGISTRO (machine-local — Finding #4): este script PROPAGA pra ~/.claude/hooks/
# via `sync.sh install` (hooks/ está em DIRS), mas o REGISTRO em
# ~/.claude/settings.json sob PostToolUse NÃO viaja no sync (settings.json não é
# arquivo sincronizado). Cada máquina registra à mão pós-install. Snippet canônico
# (matcher + timeout 5000ms): skills/verify-before-handoff/references/settings-registration.json.
# VMs Linux: substituir o prefixo /Users/<user> por /home/<user> no command.

PYCODE=$(cat <<'PYEOF'
import json
import os
import re
import sys
from datetime import datetime, timezone


def _dbg(msg):
    if os.environ.get("VERIFY_HANDOFF_DEBUG"):
        sys.stderr.write("verify-before-handoff-guard: %s\n" % msg)


def fail_open(msg=None):
    if msg:
        _dbg(msg)
    sys.exit(0)


VERBS = ("send", "create", "delete", "deploy", "publish")
LOOPBACK = ("localhost", "127.0.0.1", "0.0.0.0", "::1")
PAYLOAD_FLAGS = (
    r"--data\b", r"--data-raw\b", r"--data-binary\b", r"\s-d\b",
    r"--upload-file\b", r"\s-T\b", r"--json\b", r"--form\b", r"\s-F\b",
)


def extract_external_hosts(cmd):
    hosts = []
    for m in re.finditer(r"https?://([^/\s'\"]+)", cmd, re.I):
        host = m.group(1).split("@")[-1].split(":")[0].lower()
        if host and host not in LOOPBACK and not host.startswith("127."):
            hosts.append(host)
    return hosts


def classify_bash(cmd):
    """Bash → (is_hot, signature). Hot = cliente HTTP + mutação + host externo."""
    low = cmd.lower()
    client = re.search(r"\b(curl|wget|xh)\b", low) or re.search(r"\bhttps?\b(?!://)", low)
    if not client:
        return False, ""
    method = None
    m = re.search(r"-X\s*['\"]?(POST|PUT|DELETE|PATCH)", cmd, re.I)
    if m:
        method = m.group(1).upper()
    elif re.search(r"\b(POST|PUT|DELETE|PATCH)\b", cmd):  # httpie style verb token
        method = re.search(r"\b(POST|PUT|DELETE|PATCH)\b", cmd).group(1).upper()
    elif any(re.search(f, cmd) for f in PAYLOAD_FLAGS):
        method = "POST"
    if method is None:
        return False, ""
    hosts = extract_external_hosts(cmd)
    if not hosts:
        return False, ""
    return True, "bash:%s:%s" % (method, hosts[0])


def classify(tool, tool_input):
    """→ (is_hot, signature). Classificador grosso de efeito externo mutante."""
    name = (tool or "").lower()
    # 1. Tool MCP por verbo no nome namespaced (`__`)
    if "__" in name:
        for v in VERBS:
            if v in name:
                return True, tool
    # 2. Bash HTTP mutante externo
    if tool == "Bash":
        cmd = ""
        if isinstance(tool_input, dict):
            cmd = str(tool_input.get("command") or "")
        return classify_bash(cmd)
    return False, ""


def prior_count(audit_path, signature):
    n = 0
    if not audit_path or not os.path.exists(audit_path):
        return 0
    try:
        with open(audit_path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("signature") == signature:
                    n += 1
    except OSError as e:
        _dbg("falha lendo audit: %s" % e)
    return n


def append_audit(audit_path, rec):
    try:
        d = os.path.dirname(audit_path)
        if d:
            os.makedirs(d, exist_ok=True)
        with open(audit_path, "a") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError as e:
        _dbg("falha anexando audit: %s" % e)  # fail-open: não derruba o turn


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception as e:
        fail_open("JSON parse error: %s" % e)
    if not isinstance(payload, dict):
        fail_open("payload não-dict")

    tool = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}

    is_hot, signature = classify(tool, tool_input)
    if not is_hot:
        fail_open("cold: %s" % tool)

    audit_path = os.environ.get("VERIFY_HANDOFF_AUDIT") \
        or os.path.expanduser("~/.claude/cache/verify-handoff/audit.jsonl")
    try:
        n = int(os.environ.get("VERIFY_HANDOFF_PROMOTE_N", "2") or "2")
    except ValueError:
        n = 2
    if n < 1:
        n = 1

    seen = prior_count(audit_path, signature)
    count = seen + 1  # esta visão inclusa
    tier = "hard" if count >= n else "soft"

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    append_audit(audit_path, {
        "ts": ts, "tool": tool, "signature": signature,
        "tier": tier, "decision": "hot",
    })

    soft_msg = (
        "[verify-before-handoff] Ação de efeito externo detectada (%s). Antes de "
        "declarar concluído OU pedir ao usuário pra olhar: OBSERVE o resultado "
        "realizado (abra o e-mail enviado, faça GET do recurso criado, leia o "
        "arquivo). Ausência de erro NÃO é evidência funcional. Skill: "
        "verify-before-handoff." % signature
    )
    hard_msg = (
        "[verify-before-handoff] HARD: assinatura '%s' já vista %d× — caminho "
        "quente recorrente. NÃO afirme 'feito/enviei/funciona' nem peça "
        "verificação ao usuário sem antes CONFIRMAR FUNCIONALMENTE o resultado "
        "realizado (padrão de evidência da skill verify-before-handoff). Se a "
        "verificação pegar falha mecânica: auto-fix até 3×, re-verificando a cada "
        "tentativa; ambíguo/destrutivo → escala." % (signature, count)
    )

    if tier == "soft":
        out = {"hookSpecificOutput": {
            "hookEventName": "PostToolUse",
            "additionalContext": soft_msg,
        }}
    else:
        out = {
            "decision": "block",
            "reason": hard_msg,
            "hookSpecificOutput": {
                "hookEventName": "PostToolUse",
                "additionalContext": hard_msg,
            },
        }
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    sys.exit(0)


try:
    main()
except SystemExit:
    raise  # exit 0 intencional (fail_open / fim do hot path) — propaga
except BaseException as e:  # noqa: BLE001 — fail-open: NUNCA derruba o turn
    _dbg("exceção não-tratada no main: %s" % e)
    sys.exit(0)
PYEOF
)

# Guard fail-open: python3 ausente → no-op exit 0 (nunca 127). Contrato "SEMPRE exit 0".
command -v python3 >/dev/null 2>&1 || exit 0
exec python3 -c "$PYCODE"
