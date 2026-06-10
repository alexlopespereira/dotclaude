#!/usr/bin/env python3
"""Stop hook: notifica via macOS quando o contexto cruza THRESHOLD tokens.

Lê o payload JSON do Stop hook em stdin, abre o transcript JSONL,
soma input_tokens + cache_creation + cache_read da última mensagem
assistant com `usage` e dispara osascript se >= THRESHOLD.
Usa flag por session_id para não repetir na mesma sessão.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

THRESHOLD = 128_000
FLAG_DIR = Path.home() / ".claude" / "cache" / "context-notify"


def _gc(dirpath: Path) -> None:
    """GC diário: flags >30d são removidas (195 arquivos observados sem limpeza).

    Marcador .last-gc evita varrer a cada Stop (custo típico = 1 stat); o
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


def main() -> int:
    _gc(FLAG_DIR)
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0

    session_id = payload.get("session_id") or "unknown"
    transcript_path = payload.get("transcript_path")
    if not transcript_path or not os.path.exists(transcript_path):
        return 0

    last_usage = None
    try:
        with open(transcript_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get("type") != "assistant":
                    continue
                usage = (entry.get("message") or {}).get("usage")
                if usage:
                    last_usage = usage
    except Exception:
        return 0

    if not last_usage:
        return 0

    total = (
        int(last_usage.get("input_tokens", 0) or 0)
        + int(last_usage.get("cache_creation_input_tokens", 0) or 0)
        + int(last_usage.get("cache_read_input_tokens", 0) or 0)
    )

    if total < THRESHOLD:
        return 0

    FLAG_DIR.mkdir(parents=True, exist_ok=True)
    flag = FLAG_DIR / f"{session_id}.flag"
    if flag.exists():
        return 0
    flag.write_text(str(total))

    title = "Claude Code: contexto alto"
    body = (
        f"Sessao atingiu {total:,} tokens "
        f"(limite {THRESHOLD:,}). Considere /compact ou /clear."
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


if __name__ == "__main__":
    sys.exit(main())
