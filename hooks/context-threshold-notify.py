#!/usr/bin/env python3
"""Hook de contexto v2: Stop (notificação macOS escalonada) + UserPromptSubmit (gate visível ao agente).

Lê o payload JSON do hook em stdin, abre o transcript JSONL e soma
input_tokens + cache_creation + cache_read da última `usage` (lida de trás
pra frente — seek-from-end, para na 1ª usage). Ramifica por `hook_event_name`:

  - UserPromptSubmit → injeta `hookSpecificOutput.additionalContext` imperativo
    instruindo /handoff-continue em dois tiers (advisory >= 128K, crítico >= 160K)
    e carimba <session>.emitted (telemetria de compliance).
  - Stop / evento ausente / casing divergente (default defensivo) → notificação
    macOS escalonada por nível (128K + k*50K), com flag por sessão para não
    repetir dentro do mesmo nível.

Guarda de /compact: qualquer `usage` anterior à última entrada
isCompactSummary/compact_boundary é ignorada (a usage crua pré-compact persiste
até a próxima resposta e provocaria falso positivo).

LIMITAÇÃO DELIBERADA (gate interativo-only): a injeção do UserPromptSubmit só
tem efeito onde há um humano para rodar `/clear` — /handoff-continue destila o
estado mas a quebra final da janela é built-in sem tool. Em claude -p/headless
(Ralph, VMs) a injeção é inócua (sem humano para /clear); lá a economia vem da
higiene de sessão do P16 (contexto fresco por story) e da guarda de /compact.

Exit 0 em todo caminho: hook não-bloqueante, nunca usa exit 2.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

# Thresholds (constantes nomeadas — sem literais mágicos repetidos no corpo).
THRESHOLD_ADVISORY = 128_000   # tier advisory e base dos níveis de escalonamento do Stop
THRESHOLD_CRITICAL = 160_000   # tier crítico do UserPromptSubmit ("AGORA")
LEVEL_STEP = 50_000            # degrau de re-notificação escalonada do Stop
_CHUNK = 65_536               # bloco do leitor seek-from-end

FLAG_DIR = Path.home() / ".claude" / "cache" / "context-notify"


def level_of(total: int) -> int:
    """Nível de escalonamento: -1 abaixo do advisory, 0 em 128K, 1 em 178K, …."""
    if total < THRESHOLD_ADVISORY:
        return -1
    return (total - THRESHOLD_ADVISORY) // LEVEL_STEP


def form_value(level: int) -> int:
    """Forma-valor gravada na flag para um nível (base, base+degrau, base+2·degrau, …).

    Ler a flag de volta via level_of() torna o formato legado (valor total cru,
    ex. '144907') e o novo (forma-valor) indistinguíveis — sem passo de migração.
    """
    return THRESHOLD_ADVISORY + level * LEVEL_STEP


def _gc(dirpath: Path) -> None:
    """GC diário: flags >30d são removidas (195 arquivos observados sem limpeza).

    Marcador .last-gc evita varrer a cada evento (custo típico = 1 stat); o
    marcador nunca se auto-apaga. Fail-open: qualquer erro vira no-op.
    """
    try:
        if not dirpath.is_dir():
            return
        mark = dirpath / ".last-gc"
        now = time.time()
        if mark.exists() and now - mark.stat().st_mtime < 86400:
            return
        for p in dirpath.iterdir():
            if p.name == ".last-gc" or not p.is_file():
                continue
            try:
                if now - p.stat().st_mtime > 30 * 86400:
                    p.unlink()
            except Exception:
                pass
        mark.touch()
    except Exception:
        pass


def _read_lines_reversed(path: str):
    """Itera as linhas do arquivo de trás pra frente (seek-from-end), sem carregar tudo."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        pos = f.tell()
        remainder = b""
        while pos > 0:
            size = min(_CHUNK, pos)
            pos -= size
            f.seek(pos)
            block = f.read(size) + remainder
            parts = block.split(b"\n")
            remainder = parts[0]
            for ln in reversed(parts[1:]):
                yield ln
        yield remainder


def _is_compact_boundary(entry: dict) -> bool:
    """Entrada que delimita um /compact: qualquer usage anterior é pré-compact."""
    return bool(entry.get("isCompactSummary")) or entry.get("type") == "compact_boundary"


def _sum_usage(usage: dict) -> int:
    return (
        int(usage.get("input_tokens", 0) or 0)
        + int(usage.get("cache_creation_input_tokens", 0) or 0)
        + int(usage.get("cache_read_input_tokens", 0) or 0)
    )


def _compute_total(path: str) -> int:
    """Total da última usage (seek-from-end). Guarda de /compact: retorna 0 se a
    entrada isCompactSummary/compact_boundary for cruzada antes de achar uma usage."""
    for raw in _read_lines_reversed(path):
        raw = raw.strip()
        if not raw:
            continue
        try:
            entry = json.loads(raw)
        except Exception:
            continue
        if _is_compact_boundary(entry):
            return 0
        if entry.get("type") != "assistant":
            continue
        usage = (entry.get("message") or {}).get("usage")
        if usage:
            return _sum_usage(usage)
    return 0


def _handle_stop(session_id: str, total: int) -> int:
    """Notificação macOS escalonada por nível, com flag por sessão anti-repetição."""
    cur = level_of(total)
    if cur < 0:
        return 0
    FLAG_DIR.mkdir(parents=True, exist_ok=True)
    flag = FLAG_DIR / f"{session_id}.flag"
    prev = -1
    if flag.exists():
        try:
            prev = level_of(int(flag.read_text().strip()))
        except Exception:
            prev = -1
    if cur <= prev:
        return 0
    flag.write_text(str(form_value(cur)))

    title = "Claude Code: contexto alto"
    body = (
        f"Sessao atingiu {total:,} tokens "
        f"(limite {THRESHOLD_ADVISORY:,}). Considere /handoff-continue, /compact ou /clear."
    )
    try:
        subprocess.run(
            [
                "osascript",
                "-e",
                f'display notification "{body}" with title "{title}" sound name "Glass"',
            ],
            check=False,
            timeout=5,
        )
    except Exception:
        pass
    return 0


def _handle_ups(session_id: str, total: int) -> int:
    """Injeta additionalContext imperativo (dois tiers) + carimba compliance."""
    if total < THRESHOLD_ADVISORY:
        return 0
    if total >= THRESHOLD_CRITICAL:
        tier = "critico"
        context = (
            f"Contexto da sessão cruzou {THRESHOLD_CRITICAL // 1000}K tokens (crítico). "
            "Execute /handoff-continue AGORA, antes de atender este pedido — a janela "
            "precisa ser fechada. Higiene de contexto (P16)."
        )
    else:
        tier = "advisory"
        context = (
            f"Contexto da sessão cruzou {THRESHOLD_ADVISORY // 1000}K tokens (advisory). "
            "Feche a fatia atual e proponha /handoff-continue; não inicie fatia nova. "
            "Higiene de contexto (P16)."
        )
    try:
        FLAG_DIR.mkdir(parents=True, exist_ok=True)
        (FLAG_DIR / f"{session_id}.emitted").write_text(f"{tier} {total}\n")
    except Exception:
        pass
    out = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": context,
        }
    }
    print(json.dumps(out, ensure_ascii=False))
    return 0


def main() -> int:
    _gc(FLAG_DIR)
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    if not isinstance(payload, dict):
        return 0

    session_id = payload.get("session_id") or "unknown"
    transcript_path = payload.get("transcript_path")
    if not transcript_path or not os.path.exists(transcript_path):
        return 0

    try:
        total = _compute_total(transcript_path)
    except Exception:
        return 0

    # Branch por hook_event_name com default defensivo (R5): evento ausente /
    # desconhecido / casing divergente cai no ramo Stop legado (nunca pula o Stop).
    if payload.get("hook_event_name") == "UserPromptSubmit":
        return _handle_ups(session_id, total)
    return _handle_stop(session_id, total)


if __name__ == "__main__":
    sys.exit(main())
