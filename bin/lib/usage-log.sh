#!/usr/bin/env bash
# bin/lib/usage-log.sh — Writer append-only de eventos de uso de DoD (schema v1).
#
# Sourced pelos consumidores (US-02 fold, US-03 migração, US-05 skill auto-grill-me)
# e também executável diretamente como CLI:
#   usage-log.sh <kind> <dod_id> --sha <S> [--prefix P] [--count N]
#                                          [--migrated-from M] [--ts ISO]
#
# Fundação da telemetria DoD append-only per-machine (plano F1/M1).
# Decisões-chave do plano (2026-05-25):
#   • 1 arquivo por machine-id (não hostname — Adv #3): paths disjuntos nunca
#     colidem no merge git. machine-id = uuid persistido em ~/.claude/.machine-id.
#   • sha obrigatório em TODOS os kinds (Adv #2): o fold (US-02) é content-based
#     (por sha), imune a clock-skew cross-host — não depende de ordenação por ts.
#   • Append atômico via O_APPEND (>>): o kernel faz seek-to-end + write como
#     operação atômica sob o lock do inode (POSIX, FS local). Dispensa o lock
#     `mkdir` que o edit-in-place exigia. NUNCA reescreve o arquivo.
#   • Sem jq na escrita (printf + date + uuidgen) — mantém o append trivial.
#
# Test seam: USAGE_LOG_HOME sobrescreve a base ~/.claude (usado pelos testes p/
# não poluir o ~/.claude real). Opções de usuário ficam em flags CLI.

# Base dir da telemetria (test seam). Default: ~/.claude.
_usage_log_home() {
  printf '%s' "${USAGE_LOG_HOME:-$HOME/.claude}"
}

# Lê o machine-id de <home>/.machine-id; gera (uuidgen) e persiste se ausente.
# Idempotente: 2a invocação reusa o mesmo id. Nunca usa hostname (Adv #3).
# Criação atômica via `ln` (hard-link create-or-noop) — se 2 processos correrem
# na 1a vez, só um vence o link e ambos leem o mesmo id.
_usage_log_machine_id() {
  local home idfile new tmp
  home="$(_usage_log_home)"
  idfile="$home/.machine-id"
  if [ -s "$idfile" ]; then
    tr -d ' \t\r\n' < "$idfile"
    return 0
  fi
  mkdir -p "$home"
  new="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  tmp="$idfile.$$.$RANDOM.tmp"
  printf '%s\n' "$new" > "$tmp"
  # ln falha se o destino já existe → vencedor da corrida cria, perdedores leem.
  ln "$tmp" "$idfile" 2>/dev/null || true
  rm -f "$tmp"
  tr -d ' \t\r\n' < "$idfile"
}

# log_event <kind> <dod_id> --sha <S> [--prefix P] [--count N]
#                                      [--migrated-from M] [--ts ISO]
#   kind   : use | revision | baseline
#   dod_id : slug do DoD ([A-Za-z0-9._-]+)
#   --sha  : obrigatório (hash dos bullets do DoD) — todos os kinds (Adv #2)
#   --prefix : namespace do log (default dod; test-spec p/ o twin testing US-06)
#   --count  : obrigatório SOMENTE p/ kind=baseline (piso de usos na migração)
#   --migrated-from : marca de proveniência (US-03 AC2). Quando presente, anexa
#                     "migrated_from":"<M>" ao evento — sentinela de idempotência
#                     do seeder (rodar 2x não duplica baseline).
#   --ts ISO : sobrescreve o timestamp (default `date -u`). Usado pelo seeder
#              US-03 p/ replay fiel de eventos históricos (preserva last_seen do
#              snapshot — AC3 reconcilia o .json). Formato ISO-8601 UTC `...Z`.
# Faz append de exatamente 1 linha JSONL (schema v1) em
#   <home>/telemetry/<prefix>-usage.<machine-id>.jsonl
# Retorna 2 em erro de uso; 0 em sucesso.
log_event() {
  local kind dod_id sha prefix count migrated_from ts_override
  kind="${1:-}"; [ $# -gt 0 ] && shift
  dod_id="${1:-}"; [ $# -gt 0 ] && shift
  sha=""; prefix="dod"; count=""; migrated_from=""; ts_override=""

  # Guard contra flag-sem-valor: `shift 2` com só 1 arg restante falha e NÃO
  # consome o flag → o while reprocessaria o mesmo flag pra sempre (loop infinito,
  # Adv P1). `[ $# -ge 2 ]` antes de cada shift 2 fail-fecha com return 2.
  while [ $# -gt 0 ]; do
    case "$1" in
      --sha)             [ $# -ge 2 ] || { echo "usage-log: --sha exige valor" >&2; return 2; };           sha="$2";           shift 2 ;;
      --sha=*)           sha="${1#*=}";   shift ;;
      --prefix)          [ $# -ge 2 ] || { echo "usage-log: --prefix exige valor" >&2; return 2; };         prefix="$2";        shift 2 ;;
      --prefix=*)        prefix="${1#*=}"; shift ;;
      --count)           [ $# -ge 2 ] || { echo "usage-log: --count exige valor" >&2; return 2; };          count="$2";         shift 2 ;;
      --count=*)         count="${1#*=}"; shift ;;
      --migrated-from)   [ $# -ge 2 ] || { echo "usage-log: --migrated-from exige valor" >&2; return 2; };  migrated_from="$2"; shift 2 ;;
      --migrated-from=*) migrated_from="${1#*=}"; shift ;;
      --ts)              [ $# -ge 2 ] || { echo "usage-log: --ts exige valor" >&2; return 2; };             ts_override="$2";   shift 2 ;;
      --ts=*)            ts_override="${1#*=}"; shift ;;
      *) echo "usage-log: argumento desconhecido '$1'" >&2; return 2 ;;
    esac
  done

  # ── Validação (fail-closed; garante JSON sempre bem-formado) ──────────────
  case "$kind" in
    use|revision|baseline) ;;
    *) echo "usage-log: kind inválido '$kind' (use|revision|baseline)" >&2; return 2 ;;
  esac
  if [[ ! "$dod_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "usage-log: dod_id inválido '$dod_id'" >&2; return 2
  fi
  if [[ ! "$sha" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "usage-log: --sha obrigatório e alfanumérico (Adv #2)" >&2; return 2
  fi
  if [[ ! "$prefix" =~ ^[A-Za-z0-9-]+$ ]]; then
    echo "usage-log: --prefix inválido '$prefix'" >&2; return 2
  fi
  if [ "$kind" = "baseline" ]; then
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
      echo "usage-log: baseline exige --count <inteiro>" >&2; return 2
    fi
  elif [ -n "$count" ]; then
    echo "usage-log: --count só é válido para kind=baseline" >&2; return 2
  fi
  if [ -n "$migrated_from" ] && [[ ! "$migrated_from" =~ ^[A-Za-z0-9._:-]+$ ]]; then
    echo "usage-log: --migrated-from inválido '$migrated_from'" >&2; return 2
  fi
  if [ -n "$ts_override" ] && \
     [[ ! "$ts_override" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "usage-log: --ts inválido '$ts_override' (esperado ISO-8601 UTC YYYY-MM-DDThh:mm:ssZ)" >&2
    return 2
  fi

  local home dir logfile mid ts line mf_field
  home="$(_usage_log_home)"
  dir="$home/telemetry"
  mid="$(_usage_log_machine_id)"
  ts="${ts_override:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  logfile="$dir/${prefix}-usage.${mid}.jsonl"

  # Campo de proveniência opcional (sufixo antes do `}` — mantém a ordem dos
  # campos v1 estável; eventos sem --migrated-from ficam byte-idênticos ao schema
  # original, então os testes US-01/US-02 não regridem).
  mf_field=""
  [ -n "$migrated_from" ] && printf -v mf_field ',"migrated_from":"%s"' "$migrated_from"

  mkdir -p "$dir"

  # printf -v: monta a linha sem fork (rápido p/ o teste de atomicidade).
  if [ "$kind" = "baseline" ]; then
    printf -v line '{"v":1,"ts":"%s","machine":"%s","dod_id":"%s","kind":"%s","count":%s,"sha":"%s"%s}\n' \
      "$ts" "$mid" "$dod_id" "$kind" "$count" "$sha" "$mf_field"
  else
    printf -v line '{"v":1,"ts":"%s","machine":"%s","dod_id":"%s","kind":"%s","sha":"%s"%s}\n' \
      "$ts" "$mid" "$dod_id" "$kind" "$sha" "$mf_field"
  fi

  # Append atômico: 1 write() da linha completa sob O_APPEND. NUNCA reescreve.
  printf '%s' "$line" >> "$logfile"
}

# Dual-mode: executado diretamente → despacha p/ log_event com os args do CLI.
# Sourced → só define as funções (não roda nada).
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  log_event "$@"
  exit $?
fi
