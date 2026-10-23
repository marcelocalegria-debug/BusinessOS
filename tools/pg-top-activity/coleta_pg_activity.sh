#!/usr/bin/env bash
# Coleta amostras periodicas do pg_stat_activity em CSV, no estilo do ASH do Oracle.
# O CSV gerado e aberto no painel index.html ("Abrir amostras...").
#
# Uso:
#   INTERVALO=15 ./coleta_pg_activity.sh "host=db1 dbname=postgres user=monitor" [saida.csv]
#
# Variaveis:
#   INTERVALO   segundos entre amostras (padrao 15)
#   DURACAO     segundos totais de coleta; vazio = ate Ctrl+C
#
# Permissao: o usuario precisa de pg_read_all_stats (ou ser superusuario) para
# ver o texto das SQLs de outros usuarios:  GRANT pg_read_all_stats TO monitor;
set -euo pipefail

CONN="${1:?informe a string de conexao, ex.: \"host=db1 dbname=postgres user=monitor\"}"
OUT="${2:-pg_activity_$(date +%Y%m%d_%H%M%S).csv}"
INTERVALO="${INTERVALO:-15}"
DURACAO="${DURACAO:-}"

psql_() { psql "$CONN" -X -q -v ON_ERROR_STOP=1 "$@"; }

VER="$(psql_ -At -c 'SHOW server_version_num')"
if [ "$VER" -lt 100000 ]; then
  echo "PostgreSQL 10 ou superior e necessario (encontrado $VER)." >&2
  exit 1
fi

COLS="now() AS sample_time, pid"
[ "$VER" -ge 130000 ] && COLS+=", leader_pid"
COLS+=", datname, usename, application_name, client_addr, backend_type, backend_start, xact_start,
        query_start, state_change, state, wait_event_type, wait_event"
[ "$VER" -ge 140000 ] && COLS+=", query_id"
COLS+=", query"

# Sessoes ativas + sessoes que terminaram uma SQL desde a ultima amostra
# (estas dao a duracao exata de execucoes curtas: query_start -> state_change).
SQL="SELECT $COLS
       FROM pg_stat_activity
      WHERE pid <> pg_backend_pid()
        AND query <> ''
        AND (state = 'active' OR state_change >= now() - interval '${INTERVALO} seconds')"

echo "Coletando a cada ${INTERVALO}s em ${OUT} (PostgreSQL ${VER}). Ctrl+C para parar." >&2
[ "$VER" -ge 140000 ] && [ "$(psql_ -At -c 'SHOW compute_query_id')" = "off" ] &&
  echo "Aviso: compute_query_id=off; as SQLs serao agrupadas pelo texto normalizado." >&2

INICIO=$(date +%s)
while :; do
  if [ -s "$OUT" ]; then OPTS="FORMAT csv"; else OPTS="FORMAT csv, HEADER"; fi
  psql_ -c "COPY ($SQL) TO STDOUT WITH ($OPTS)" >>"$OUT" || echo "$(date '+%F %T') falha na amostra" >&2
  if [ -n "$DURACAO" ] && [ $(( $(date +%s) - INICIO )) -ge "$DURACAO" ]; then break; fi
  sleep "$INTERVALO"
done
