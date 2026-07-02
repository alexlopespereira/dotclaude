#!/usr/bin/env bash
# secrets-expiry.sh — inventário de expiração de credenciais (METADADOS apenas).
#
# O QUE FAZ: mantém ~/.claude/cache/secrets/expiry.jsonl (override --file) com
# metadados de credenciais — key_name, provider, expires_at, renewal_method,
# tier, consumers. NUNCA armazena valores de secrets: não existe flag de valor;
# flag desconhecida → usage + exit 2 sem append.
#
# SEMÂNTICA: append-only + fold last-wins (mesma garantia da telemetria DoD —
# append é atômico por linha em FS local, escrita concorrente de slots Boris
# não corrompe; update/remove sem lock). `add` appenda upsert; `remove`
# appenda tombstone; `list`/`due` fazem fold por key_name e a última linha
# vence. O arquivo nunca é reescrito in-place.
#
# QUANDO USAR: registrar toda credencial provisionada/renovada (passo do fluxo
# da skill browser-secrets); `due` alimenta o aviso proativo do auto-morning e
# o advisory do auth-preflight (US-02 do plano R9).
#
# PORTABILIDADE: aritmética de datas 100% via perl Time::Local — nenhuma flag
# de plataforma do utilitário date (ressalva #2 da revisão adversária do R9).
#
# Exit: 0 ok/sem due; 1 (só `due`) há vencida/vencendo; 2 uso inválido;
# 3 falha de escrita ou inventário corrompido (review 2026-07-02: escrita
# falha e parse do fold nunca podem degradar para exit 0 silencioso).

set -u

usage() {
  cat <<'EOF'
Uso: secrets-expiry.sh <subcomando> [opções]
  add    --key NAME --provider P [--expires-at YYYY-MM-DD|never]
         [--renewal-method M] [--tier free-low|paid|zona3] [--consumers a,b]
         appenda upsert (last-wins) no inventário
  remove --key NAME
         appenda tombstone (a key some do list/due; histórico preservado)
  list   fold last-wins, tab-separated:
         key_name provider expires_at renewal_method tier consumers
  due    [--days N] [--json]
         vencidas/vencendo em ≤N dias (default 14); exit 1 quando há due
Opção comum: --file PATH (default ~/.claude/cache/secrets/expiry.jsonl)
Metadados apenas — valores de secrets nunca são aceitos nem gravados.
EOF
}

INV_FILE="$HOME/.claude/cache/secrets/expiry.jsonl"

[ $# -ge 1 ] || { usage >&2; exit 2; }
SUB="$1"; shift
case "$SUB" in
  -h|--help) usage; exit 0 ;;
  add|remove|list|due) ;;
  *) echo "subcomando desconhecido: $SUB" >&2; usage >&2; exit 2 ;;
esac

KEY=""; PROVIDER=""; EXPIRES="never"; RENEWAL=""; TIER=""; CONSUMERS=""
DAYS=14; JSON=false
# provided-ness por flag: add é MERGE-upsert — campo omitido herda do registro
# folded atual (code-review R9: add parcial de renovação clobberava
# expires_at→never e apagava tier/consumers, sumindo a key dos avisos)
EXPIRES_SET=false; RENEWAL_SET=false; TIER_SET=false; CONSUMERS_SET=false

need_val() {  # need_val <flag> <$#> — flag de valor sem valor → uso inválido
  [ "$2" -ge 2 ] || { echo "faltando valor para $1" >&2; usage >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$SUB:$1" in
    due:--json)           JSON=true; shift ;;
    add:--file|remove:--file|list:--file|due:--file)
                          need_val "$1" $#; INV_FILE="$2"; shift 2 ;;
    add:--key|remove:--key) need_val "$1" $#; KEY="$2"; shift 2 ;;
    add:--provider)       need_val "$1" $#; PROVIDER="$2"; shift 2 ;;
    add:--expires-at)     need_val "$1" $#; EXPIRES="$2"; EXPIRES_SET=true; shift 2 ;;
    add:--renewal-method) need_val "$1" $#; RENEWAL="$2"; RENEWAL_SET=true; shift 2 ;;
    add:--tier)           need_val "$1" $#; TIER="$2"; TIER_SET=true; shift 2 ;;
    add:--consumers)      need_val "$1" $#; CONSUMERS="$2"; CONSUMERS_SET=true; shift 2 ;;
    due:--days)           need_val "$1" $#; DAYS="$2"; shift 2 ;;
    *) echo "opção desconhecida para '$SUB': $1" >&2; usage >&2; exit 2 ;;
  esac
done

# valid_date <YYYY-MM-DD> — data de calendário real (Time::Local croca em
# 2026-02-30/mês 13; o eval converte o croak em exit 1)
valid_date() {
  perl -MTime::Local -e '
    my ($y, $m, $d) = $ARGV[0] =~ /^(\d{4})-(\d{2})-(\d{2})$/ or exit 1;
    eval { timegm(0, 0, 0, $d, $m - 1, $y) }; exit($@ ? 1 : 0)' "$1"
}

# fold — inventário folded (last-wins por key_name, tombstones filtrados),
# 1 objeto JSON compacto por linha; inventário ausente = vazio
fold() {
  [ -f "$INV_FILE" ] || return 0
  jq -cs 'group_by(.key_name) | map(.[-1] | select(.deleted != true)) | .[]' "$INV_FILE"
}

# append_line <filtro jq> — appenda 1 linha JSONL (nunca rewrite); falha de
# mkdir/escrita sobe pro caller (write_or_die), nunca degrada pra exit 0
append_line() {
  mkdir -p "$(dirname "$INV_FILE")" || return 1
  jq -cn --arg k "$KEY" --arg p "$PROVIDER" --arg x "$EXPIRES" \
    --arg r "$RENEWAL" --arg t "$TIER" --arg c "$CONSUMERS" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$INV_FILE"
}

write_or_die() {  # write_or_die <filtro jq> — append_line ou exit 3
  append_line "$1" || {
    echo "falha ao gravar no inventário: $INV_FILE" >&2; exit 3
  }
}

fold_or_die() {  # FOLDED=<fold last-wins> ou exit 3 (jq falhou = corrompido)
  FOLDED=$(fold) || {
    echo "inventário corrompido (JSON inválido): $INV_FILE" >&2; exit 3
  }
}

case "$SUB" in
  add)
    [ -n "$KEY" ]      || { echo "add exige --key" >&2; usage >&2; exit 2; }
    [ -n "$PROVIDER" ] || { echo "add exige --provider" >&2; usage >&2; exit 2; }
    if [ "$EXPIRES" != "never" ] && ! valid_date "$EXPIRES"; then
      echo "--expires-at inválido (YYYY-MM-DD ou 'never'): $EXPIRES" >&2
      usage >&2; exit 2
    fi
    case "$TIER" in
      ''|free-low|paid|zona3) ;;
      *) echo "--tier inválido (free-low|paid|zona3): $TIER" >&2; usage >&2; exit 2 ;;
    esac
    # MERGE-upsert: herda do registro folded os campos NÃO passados nesta
    # invocação (inventário corrompido → fold_or_die exit 3, alto e claro)
    fold_or_die
    PREV=$(printf '%s\n' "$FOLDED" | jq -c --arg k "$KEY" 'select(.key_name == $k)' | tail -1)
    if [ -n "$PREV" ]; then
      [ "$EXPIRES_SET" = true ]   || EXPIRES=$(printf '%s' "$PREV" | jq -r '.expires_at // "never"')
      [ "$RENEWAL_SET" = true ]   || RENEWAL=$(printf '%s' "$PREV" | jq -r '.renewal_method // ""')
      [ "$TIER_SET" = true ]      || TIER=$(printf '%s' "$PREV" | jq -r '.tier // ""')
      [ "$CONSUMERS_SET" = true ] || CONSUMERS=$(printf '%s' "$PREV" | jq -r '.consumers // [] | join(",")')
    fi
    write_or_die '{key_name: $k, provider: $p, expires_at: $x,
      renewal_method: $r, tier: $t,
      consumers: ($c | split(",") | map(select(length > 0))), ts: $ts}'
    ;;
  remove)
    [ -n "$KEY" ] || { echo "remove exige --key" >&2; usage >&2; exit 2; }
    write_or_die '{key_name: $k, deleted: true, ts: $ts}'
    ;;
  list)
    fold_or_die
    [ -z "$FOLDED" ] || printf '%s\n' "$FOLDED" | jq -r '[.key_name,
      (.provider // ""), (.expires_at // "never"),
      (.renewal_method // ""), (.tier // ""),
      (.consumers // [] | join(","))] | @tsv'
    ;;
  due)
    case "$DAYS" in
      ''|*[!0-9]*) echo "--days exige inteiro: $DAYS" >&2; usage >&2; exit 2 ;;
    esac
    # fold (validado — jq falhou = exit 3, nunca [] silencioso) → perl:
    # data-serial à meia-noite via Time::Local; entradas com data
    # inaproveitável (só possíveis por edição manual — add valida) são puladas
    fold_or_die
    { [ -z "$FOLDED" ] || printf '%s\n' "$FOLDED"; } | perl -MTime::Local -MJSON::PP -e '
      my ($days, $json_mode) = @ARGV;
      my @n = localtime;
      my $today = timegm(0, 0, 0, $n[3], $n[4], $n[5] + 1900);
      my @due;
      while (my $line = <STDIN>) {
        my $e = decode_json($line);
        my $x = $e->{expires_at} // "never";
        next if $x eq "never";
        my $exp = eval {
          my ($y, $m, $d) = $x =~ /^(\d{4})-(\d{2})-(\d{2})$/ or die "formato";
          timegm(0, 0, 0, $d, $m - 1, $y);
        };
        next unless defined $exp;
        my $left = ($exp - $today) / 86400;
        next if $left > $days;
        $e->{days_left} = $left;
        push @due, $e;
      }
      if ($json_mode eq "true") {
        print JSON::PP->new->canonical->encode(\@due), "\n";
      } else {
        printf "%s\t%s\t%s\t%dd\n", $_->{key_name} // "", $_->{provider} // "",
          $_->{expires_at}, $_->{days_left} for @due;
      }
      exit(@due ? 1 : 0);
    ' "$DAYS" "$JSON"
    exit $?
    ;;
esac
exit 0
