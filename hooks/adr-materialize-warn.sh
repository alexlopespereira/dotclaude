#!/usr/bin/env bash
# hooks/adr-materialize-warn.sh — Stop hook BEST-EFFORT: avisa quando um plano
# promete ADRs ('## ADRs propostos') mas eles não foram materializados.
#
# POR QUÊ: backstop determinístico da ressalva Alta #1 da revisão adversária do
# ciclo domain-docs — os gates de materialização (aceite no /plan, veredito no
# /full-planning-cycle, início da execução no /full-cycle*) são prompt-driven e
# podem ser esquecidos. Este hook tira o LLM do loop p/ a DETECÇÃO: enquanto o
# plano persistido tiver a seção e ainda não tiver o marcador de quitação nem
# mudança correspondente em docs/adr/, ele emite 1 aviso ao encerrar a sessão.
#
# CONTRATO (igual ao dod-usage-log.sh): nunca bloqueia, SEMPRE exit 0. O aviso
# vai como mensagem; qualquer falha interna (git ausente, JSON inválido, sem
# checkout) degrada p/ silêncio. NÃO há efeito colateral além do stdout.
#
# DETECÇÃO (todas precisam ser verdade p/ avisar; senão silêncio):
#   1. existe plano mais recente em <proj>/.claude/plans/*.md;
#   2. ele contém a seção '## ADRs propostos';
#   3. ele NÃO contém o marcador <!-- adr-materialized -->;
#   4. git status --porcelain -- docs/adr/ não mostra NENHUMA mudança.
#
# SEAMS (env): CLAUDE_PROJECT_DIR (default $PWD — projeto da sessão),
# ADR_WARN_PLANS_DIR (override do dir de planos), ADR_WARN_GIT (binário git —
# default `git`; permite injetar git ausente nos testes), ADR_WARN_DEBUG (1 →
# traços em stderr).
#
# Registrado como Stop hook (timeout 5000ms) em ~/.claude/settings.json via
# sync.sh (register_adr_warn_hook).

set -u

_dbg() { [ -n "${ADR_WARN_DEBUG:-}" ] && printf 'adr-materialize-warn: %s\n' "$*" >&2 || true; }

# ── Drena stdin + guard stop_hook_active (re-entrância → no-op) ──────────────
payload="$(cat 2>/dev/null || true)"
if command -v jq >/dev/null 2>&1; then
  active="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)"
else
  if printf '%s' "$payload" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    active=true; else active=false; fi
fi
[ "$active" = "true" ] && { _dbg "stop_hook_active=true → no-op"; exit 0; }

# ── Projeto da sessão + dir de planos ───────────────────────────────────────
PROJ="${CLAUDE_PROJECT_DIR:-$PWD}"
PLANS_DIR="${ADR_WARN_PLANS_DIR:-$PROJ/.claude/plans}"
[ -d "$PLANS_DIR" ] || { _dbg "sem dir de planos em $PLANS_DIR → no-op"; exit 0; }

# ── Plano mais recente (por mtime; ls -t portável macOS+linux) ──────────────
PLAN="$(ls -t "$PLANS_DIR"/*.md 2>/dev/null | head -1)"
[ -n "$PLAN" ] && [ -f "$PLAN" ] || { _dbg "nenhum *.md em $PLANS_DIR → no-op"; exit 0; }

# ── Condições do plano: tem a seção E não tem o marcador de quitação ────────
grep -qF '## ADRs propostos' "$PLAN" 2>/dev/null \
  || { _dbg "plano sem '## ADRs propostos' → silêncio"; exit 0; }
grep -qF '<!-- adr-materialized -->' "$PLAN" 2>/dev/null \
  && { _dbg "plano já quitado (<!-- adr-materialized -->) → silêncio"; exit 0; }

# ── docs/adr/ sem mudança? (git ausente / não-repo → falha interna silenciosa)
GIT="${ADR_WARN_GIT:-git}"
adr_status="$("$GIT" -C "$PROJ" status --porcelain -- docs/adr/ 2>/dev/null)"
rc=$?
[ "$rc" -ne 0 ] && { _dbg "git status rc=$rc (ausente/não-repo) → silêncio"; exit 0; }
[ -n "$adr_status" ] && { _dbg "docs/adr/ com mudança → materialização em curso, silêncio"; exit 0; }

# ── Todas as condições batem → emite aviso (nunca bloqueia) ──────────────────
msg="⚠ ADR proposto não materializado: o plano mais recente $PLAN tem a seção '## ADRs propostos', mas falta o marcador <!-- adr-materialized --> e docs/adr/ está sem mudanças. Materialize os ADRs (ou marque o plano como quitado) antes de encerrar."
if command -v jq >/dev/null 2>&1; then
  jq -nc --arg m "$msg" '{systemMessage: $m}' 2>/dev/null || printf '%s\n' "$msg"
else
  printf '%s\n' "$msg"
fi
exit 0
