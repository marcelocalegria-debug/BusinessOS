#!/usr/bin/env bash
# =============================================================================
# ash_aurora.sh — coleta "estilo ASH" do pg_stat_activity de um Aurora PostgreSQL,
# baixa os planos do auto_explain dos logs da AWS e envia tudo por email para
# abrir no painel PG Top Activity (index.html).
#
# Subcomandos:
#   teste            confere conexao, versao e parametros uteis
#   coletar          loop permanente: uma amostra a cada INTERVALO segundos,
#                    um arquivo CSV por dia (dias anteriores sao compactados)
#   logs             baixa da AWS os logs do Aurora ainda nao processados e
#                    guarda so os planos do auto_explain e as SQLs lentas com binds
#   enviar [dias]    junta os ultimos N dias (padrao 7) e envia por email
#
# A conexao vem do backup_env_aurora.sh (mesma pasta), que e carregado antes
# de tudo. Veja o bloco "Conexao" abaixo se ele nao usa as variaveis do libpq.
# O resto da configuracao fica em ash_aurora.env (copie de ash_aurora.env.exemplo).
# =============================================================================
set -euo pipefail

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin"   # cron roda com PATH minimo (aws fica em /usr/local/bin)
ENV_FILE="${ENV_FILE:-$DIR_SCRIPT/backup_env_aurora.sh}"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
# Configuracao propria da coleta (email, instancia RDS, intervalo): ash_aurora.env
[ -f "$DIR_SCRIPT/ash_aurora.env" ] && source "$DIR_SCRIPT/ash_aurora.env"

# --- Conexao -----------------------------------------------------------------
# Se o backup_env_aurora.sh ja exporta PGHOST, PGPORT, PGUSER, PGDATABASE e
# PGPASSWORD (ou usa ~/.pgpass), nada precisa mudar aqui. Se ele usa outros
# nomes, mapeie nas linhas abaixo, por exemplo:
#   PGHOST="${AURORA_ENDPOINT:-}"
export PGHOST="${PGHOST:-}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-}"
export PGDATABASE="${PGDATABASE:-postgres}"
[ -n "${PGPASSWORD:-}" ] && export PGPASSWORD
export PGAPPNAME="ash_coleta"
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="${PGOPTIONS:-} -c statement_timeout=10000"
# Horarios do CSV no fuso de Brasilia (o Aurora roda em UTC).
export PGTZ="${PGTZ:-America/Sao_Paulo}"

# --- Configuracao (todas podem vir do ambiente ou do backup_env_aurora.sh) ----
INSTANCIA="${INSTANCIA:-${PGHOST%%.*}}"          # rotulo dos arquivos
DIR_DADOS="${DIR_DADOS:-$DIR_SCRIPT/ash_dados}"
INTERVALO="${INTERVALO:-15}"                     # segundos entre amostras
RETENCAO_DIAS="${RETENCAO_DIAS:-10}"
# 1 = inclui tambem as sessoes que terminaram uma SQL desde a ultima amostra
# (da contagem/duracao de execucoes curtas, mas multiplica o volume).
INCLUIR_FINALIZADAS="${INCLUIR_FINALIZADAS:-0}"

# Logs do Aurora (subcomando "logs"): identificador da INSTANCIA RDS (nao do cluster).
RDS_INSTANCIA="${RDS_INSTANCIA:-}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-sa-east-1}}"

# Email (subcomando "enviar").
MAIL_PARA="${MAIL_PARA:-}"                       # varios: "a@x.com,b@y.com"
MAIL_DE="${MAIL_DE:-ash-aurora@$(hostname -f 2>/dev/null || hostname)}"
MAIL_METODO="${MAIL_METODO:-sendmail}"           # sendmail | ses
MAX_ANEXO_MB="${MAX_ANEXO_MB:-15}"               # Gmail/Outlook aceitam ~20 MB apos base64
S3_DESTINO="${S3_DESTINO:-}"                     # ex.: s3://meu-bucket/ash (opcional)

mkdir -p "$DIR_DADOS/amostras" "$DIR_DADOS/planos" "$DIR_DADOS/envio"

log() { echo "$(date '+%F %T') $*" >&2; }
psql_() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

# -----------------------------------------------------------------------------
cmd_teste() {
  command -v psql >/dev/null || { log "psql nao encontrado: sudo apt-get install -y postgresql-client"; exit 1; }
  log "Conectando em ${PGHOST:-<PGHOST vazio>}:$PGPORT db=$PGDATABASE user=${PGUSER:-<vazio>}"
  psql_ -P pager=off -c "
    SELECT version() AS versao;
    SELECT name, setting FROM pg_settings
     WHERE name IN ('compute_query_id','track_activity_query_size','shared_preload_libraries',
                    'auto_explain.log_min_duration','auto_explain.log_analyze','auto_explain.log_format',
                    'auto_explain.log_parameter_max_length','log_min_duration_statement',
                    'rds.log_retention_period','log_rotation_age')
     ORDER BY name;
    SELECT pg_has_role(current_user, 'pg_read_all_stats', 'MEMBER') AS le_sql_de_todos,
           count(*) FILTER (WHERE state = 'active') AS sessoes_ativas_agora,
           count(*) AS sessoes
      FROM pg_stat_activity;"
  if [ -n "$RDS_INSTANCIA" ]; then
    command -v aws >/dev/null || { log "aws cli nao encontrado (necessario para o subcomando logs)"; return; }
    log "Logs disponiveis na AWS para $RDS_INSTANCIA:"
    aws rds describe-db-log-files --region "$AWS_REGION" --db-instance-identifier "$RDS_INSTANCIA" \
      --query 'DescribeDBLogFiles[-5:].[LogFileName,Size]' --output table
  fi
}

# -----------------------------------------------------------------------------
sql_amostra() {
  local ver="$1" cols filtro
  cols="now() AS sample_time, pid"
  [ "$ver" -ge 130000 ] && cols+=", leader_pid"
  cols+=", datname, usename, application_name, client_addr, backend_type, backend_start, xact_start,
          query_start, state_change, state, wait_event_type, wait_event"
  [ "$ver" -ge 140000 ] && cols+=", query_id"
  cols+=", query"
  # Sessoes ativas e transacoes abertas paradas (candidatas a bloqueadoras).
  filtro="state = 'active' OR state LIKE 'idle in transaction%'"
  [ "$INCLUIR_FINALIZADAS" = 1 ] && filtro+=" OR state_change >= now() - interval '${INTERVALO} seconds'"
  # A linha da propria coleta marca o instante mesmo com o banco ocioso; sem ela o
  # painel nao sabe que houve amostra vazia e superestima as sessoes ativas medias.
  echo "SELECT $cols FROM pg_stat_activity
         WHERE pid = pg_backend_pid() OR (query <> '' AND ($filtro))"
}

cmd_coletar() {
  exec 9>"$DIR_DADOS/.coleta.lock"
  flock -n 9 || { log "Ja existe uma coleta rodando para $DIR_DADOS"; exit 1; }
  local ver sql hoje arq ultimo_dia=""
  ver="$(psql_ -At -c 'SHOW server_version_num')"
  sql="$(sql_amostra "$ver" | tr -s ' \n' '  ')"   # uma linha: menor no CSV
  log "Coletando $INSTANCIA (PostgreSQL $ver) a cada ${INTERVALO}s em $DIR_DADOS/amostras"
  while :; do
    hoje="$(date +%Y%m%d)"
    arq="$DIR_DADOS/amostras/ash_${INSTANCIA}_${hoje}.csv"
    if [ "$hoje" != "$ultimo_dia" ]; then
      # virada do dia: compacta os anteriores e aplica a retencao
      find "$DIR_DADOS/amostras" -name "ash_${INSTANCIA}_*.csv" ! -name "$(basename "$arq")" -exec gzip -9f {} \;
      find "$DIR_DADOS/amostras" "$DIR_DADOS/planos" -type f -mtime +"$RETENCAO_DIAS" -delete
      ultimo_dia="$hoje"
    fi
    local opts="FORMAT csv"; [ -s "$arq" ] || opts="FORMAT csv, HEADER"
    # 9>&-: os filhos nao herdam a trava, que se solta assim que o loop morre
    psql_ -c "COPY ($sql) TO STDOUT WITH ($opts)" >>"$arq" 9>&- || log "falha na amostra (segue tentando)"
    sleep "$INTERVALO" 9>&-
  done
}

# -----------------------------------------------------------------------------
# Mantem apenas as mensagens uteis ao painel: planos do auto_explain e SQLs lentas
# (log_min_duration_statement) com o DETAIL de parametros (binds) logo em seguida.
filtrar_log() {
  awk '
    /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9:]+/ {
      if ($0 ~ /DETAIL: +parameters:/) { keep = lastdur }
      else {
        keep = ($0 ~ /duration: [0-9.]+ ms +(plan:|statement:|execute |bind )/)
        lastdur = keep && ($0 !~ /plan:/)
      }
    }
    keep { print }'
}

cmd_logs() {
  [ -n "$RDS_INSTANCIA" ] || { log "Defina RDS_INSTANCIA (identificador da instancia no RDS)"; exit 1; }
  command -v aws >/dev/null || { log "aws cli nao encontrado"; exit 1; }
  local feitos="$DIR_DADOS/planos/.processados" lista atual nome dia saida n=0
  touch "$feitos"
  lista="$(aws rds describe-db-log-files --region "$AWS_REGION" --db-instance-identifier "$RDS_INSTANCIA" \
            --query 'sort_by(DescribeDBLogFiles,&LastWritten)[].LogFileName' --output text | tr '\t' '\n')"
  atual="$(echo "$lista" | tail -1)"                # ainda sendo escrito: fica para a proxima
  while IFS= read -r nome; do
    [ -z "$nome" ] || [ "$nome" = "$atual" ] && continue
    grep -qxF "$nome" "$feitos" && continue
    dia="$(echo "$nome" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 | tr -d -)"
    saida="$DIR_DADOS/planos/planos_${INSTANCIA}_${dia:-$(date +%Y%m%d)}_$(echo "$nome" | tr '/.' '__').log.gz"
    if aws rds download-db-log-file-portion --region "$AWS_REGION" --db-instance-identifier "$RDS_INSTANCIA" \
         --log-file-name "$nome" --starting-token 0 --output text | filtrar_log | gzip -9 >"$saida"; then
      echo "$nome" >>"$feitos"; n=$((n + 1))
    else
      rm -f "$saida"; log "falha ao baixar $nome"
    fi
  done <<<"$lista"
  find "$DIR_DADOS/planos" -name '*.log.gz' -size -30c -delete   # arquivos sem nenhum plano
  log "$n arquivo(s) de log processado(s) de $RDS_INSTANCIA"
}

# -----------------------------------------------------------------------------
b64_header() { printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | base64 -w0)"; }

montar_email() {   # montar_email <assunto> <arquivo_corpo> [anexos...]
  local assunto="$1" corpo="$2"; shift 2
  local b="=_ash_$(date +%s)_$$"
  echo "From: $MAIL_DE"
  echo "To: $MAIL_PARA"
  echo "Subject: $(b64_header "$assunto")"
  echo "MIME-Version: 1.0"
  echo "Content-Type: multipart/mixed; boundary=\"$b\""
  echo
  echo "--$b"
  echo "Content-Type: text/plain; charset=UTF-8"
  echo "Content-Transfer-Encoding: base64"
  echo
  base64 -w 76 "$corpo"
  local f
  for f in "$@"; do
    echo "--$b"
    echo "Content-Type: application/gzip; name=\"$(basename "$f")\""
    echo "Content-Transfer-Encoding: base64"
    echo "Content-Disposition: attachment; filename=\"$(basename "$f")\""
    echo
    base64 -w 76 "$f"
  done
  echo "--$b--"
}

enviar_email() {   # enviar_email <arquivo_eml>
  case "$MAIL_METODO" in
    sendmail) "${SENDMAIL:-/usr/sbin/sendmail}" -t -oi <"$1" ;;
    ses)      aws ses send-raw-email --region "$AWS_REGION" --raw-message "Data=fileb://$1" >/dev/null ;;
    *)        log "MAIL_METODO invalido: $MAIL_METODO"; return 1 ;;
  esac
}

cmd_enviar() {
  local dias="${1:-7}"
  [ -n "$MAIL_PARA" ] || { log "Defina MAIL_PARA"; exit 1; }
  local ini fim env amostras planos corpo eml lista_a lista_p d
  ini="$(date -d "-$((dias - 1)) days" +%Y%m%d)"; fim="$(date +%Y%m%d)"
  env="$DIR_DADOS/envio"; rm -f "$env"/*
  amostras="$env/ash_${INSTANCIA}_${ini}_${fim}.csv.gz"
  planos="$env/planos_${INSTANCIA}_${ini}_${fim}.log.gz"
  lista_a=(); lista_p=()
  for ((i = dias - 1; i >= 0; i--)); do
    d="$(date -d "-$i days" +%Y%m%d)"
    for f in "$DIR_DADOS/amostras/ash_${INSTANCIA}_${d}.csv"{,.gz}; do [ -f "$f" ] && lista_a+=("$f"); done
    for f in "$DIR_DADOS/planos/planos_${INSTANCIA}_${d}_"*.log.gz; do [ -f "$f" ] && lista_p+=("$f"); done
  done
  [ ${#lista_a[@]} -gt 0 ] || { log "Nenhuma amostra entre $ini e $fim em $DIR_DADOS/amostras"; exit 1; }
  # um unico CSV com um so cabecalho
  zcat -f "${lista_a[@]}" | awk 'NR == 1 || !/^sample_time,/' | gzip -9 >"$amostras"
  local anexos=("$amostras")
  if [ ${#lista_p[@]} -gt 0 ]; then zcat -f "${lista_p[@]}" | gzip -9 >"$planos"; anexos+=("$planos"); fi

  local linhas snaps planos_n binds_n bytes tam_total
  # registros comecam com o sample_time; o texto das SQLs pode ter quebras de linha
  linhas="$(zcat "$amostras" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' || true)"
  snaps="$(zcat "$amostras" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:.]+[-+][0-9:]+,' | sort -u | wc -l)"
  planos_n=0; binds_n=0
  if [ -f "$planos" ]; then
    planos_n="$(zcat "$planos" | grep -c 'ms  plan:' || true)"
    binds_n="$(zcat "$planos" | grep -c 'DETAIL:  parameters:' || true)"
  fi
  bytes="$(cat "${anexos[@]}" | wc -c)"
  tam_total="$(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1048576 }')"

  corpo="$env/corpo.txt"
  {
    echo "Coleta ASH do Aurora: $INSTANCIA"
    echo "Periodo: $(date -d "$ini" +%d/%m/%Y) a $(date -d "$fim" +%d/%m/%Y) ($dias dias)"
    echo "Amostras: $snaps instantes, $linhas linhas"
    echo "Planos do auto_explain: $planos_n"
    echo "SQLs lentas com binds: $binds_n"
    echo
  } >"$corpo"

  if [ "$bytes" -gt $((MAX_ANEXO_MB * 1048576)) ]; then
    if [ -n "$S3_DESTINO" ]; then
      {
        echo "Os arquivos (${tam_total} MB) passaram do limite de anexo e foram para o S3:"
        for f in "${anexos[@]}"; do
          aws s3 cp --only-show-errors "$f" "$S3_DESTINO/$(basename "$f")"
          echo; echo "$(basename "$f"):"
          aws s3 presign "$S3_DESTINO/$(basename "$f")" --expires-in 604800
        done
        echo
        echo "Obs.: links gerados com credenciais temporarias (role da EC2) expiram junto com elas."
        echo "Se expirar: aws s3 cp $S3_DESTINO/<arquivo> ."
      } >>"$corpo"
    else
      {
        echo "Os arquivos (${tam_total} MB) passaram do limite de ${MAX_ANEXO_MB} MB e ficaram no servidor:"
        for f in "${anexos[@]}"; do echo "  $(hostname):$f"; done
        echo "Copie com scp, ou reduza: INTERVALO maior, menos dias, ou defina S3_DESTINO."
      } >>"$corpo"
    fi
    anexos=()
  fi
  echo "Para analisar: abra o index.html do PG Top Activity, use 'Abrir amostras...' com o .csv.gz e 'Abrir planos...' com o .log.gz." >>"$corpo"

  eml="$env/mensagem.eml"
  montar_email "ASH Aurora $INSTANCIA - $(date -d "$ini" +%d/%m) a $(date -d "$fim" +%d/%m)" "$corpo" "${anexos[@]}" >"$eml"
  enviar_email "$eml"
  log "Email enviado para $MAIL_PARA ($tam_total MB, $snaps amostras, $planos_n planos, $binds_n com binds)"
}

# -----------------------------------------------------------------------------
case "${1:-}" in
  teste)   cmd_teste ;;
  coletar) cmd_coletar ;;
  logs)    cmd_logs ;;
  enviar)  shift; cmd_enviar "${1:-7}" ;;
  *) echo "Uso: $0 {teste|coletar|logs|enviar [dias]}" >&2; exit 2 ;;
esac
