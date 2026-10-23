# PG Top Activity

Painel offline, num único HTML, para amostras do `pg_stat_activity`. Lembra a tela
"Top Activity" do Oracle Enterprise Manager:

- **Sessões ativas médias ao longo do tempo**, empilhadas por SQL ou por classe de espera
  (CPU, IO, Lock, LWLock…). Clique numa barra para abrir a SQL daquele trecho; arraste
  para selecionar um intervalo.
- **Mapa de calor dia × hora**: mostra quando o banco sofre. Clique numa célula para
  filtrar aquela hora.
- **Top SQL** do período ou da seleção: tempo de BD, % da atividade, execuções, média,
  máximo, esperas, banco e usuário.
- **Detalhe da SQL** (gaveta lateral): texto formatado, atividade só dela, eventos de
  espera, origem (banco/usuário/aplicação/cliente), execuções observadas e, quando a SQL
  espera muito por lock, as sessões `idle in transaction` que podem estar bloqueando.
- **Plano de execução**: lido de logs do `auto_explain` (JSON ou texto) ou colado à mão
  (saída de `EXPLAIN`, texto ou JSON). Mostra a árvore com o % de tempo de cada nó, o nó
  mais caro em destaque e alertas (estimativa de linhas errada, filtro que descarta milhões
  de linhas, ordenação em disco, arquivos temporários). Também gera o comando `EXPLAIN`
  certo para a SQL (com `GENERIC_PLAN` quando ela tem `$1`, e `BEGIN/ROLLBACK` quando
  `ANALYZE` rodaria um DML).

Não tem dependências nem servidor: abra `index.html` no navegador. Nada sai da máquina.
Ao abrir, o painel mostra dados de exemplo (uma loja fictícia) até você carregar os seus.

## Como funciona o cálculo

O `pg_stat_activity` é uma foto instantânea, então o painel trabalha como o ASH do Oracle:

- Com **várias amostras** (coluna `sample_time`), cada sessão `active` numa amostra vale
  o intervalo entre amostras como tempo de banco. Somando, temos o **tempo de BD** de cada
  SQL e as **sessões ativas médias** (tempo de BD ÷ tempo de relógio). É uma estimativa
  estatística: funciona bem tanto para SQLs longas quanto para SQLs curtas e frequentes.
- **Execuções observadas** são deduplicadas por `(pid, backend_start, query_start)`. A
  duração vai do `query_start` até o `state_change` (se a sessão já terminou) ou até a
  última amostra em que estava ativa.
- Com **uma foto só** (sem `sample_time`), o custo é o tempo decorrido de cada execução.
- As SQLs são agrupadas pelo `query_id` (PostgreSQL 14+ com `compute_query_id`) ou, sem
  ele, pelo texto normalizado (literais trocados por `?`). O "SQL ID" é um hash disso.

## Coletando

### Opção 1: script com psql

```bash
INTERVALO=15 ./coleta_pg_activity.sh "host=db1 dbname=postgres user=monitor" amostras.csv
```

Detecta a versão do servidor (10+) e escolhe as colunas. Use um usuário com
`pg_read_all_stats` para ver o texto das SQLs de todos os usuários. Para um dia de
coleta: `DURACAO=86400`.

### Opção 2: dentro do banco, com pg_cron

Veja `coleta_pg_activity.sql`: cria a tabela `ash_amostras`, agenda a amostra a cada 15 s
e a limpeza diária. Depois exporte com `\copy ... TO 'ash.csv' WITH (FORMAT csv, HEADER)`.

### Aurora / RDS numa EC2

Veja [`aurora/README.md`](aurora/README.md): coleta contínua com systemd, download dos logs
do Aurora pela AWS (planos do auto_explain e SQLs lentas com binds) e envio semanal por email.

### Planos com auto_explain

```ini
session_preload_libraries = 'auto_explain'
auto_explain.log_min_duration = '2s'
auto_explain.log_analyze = on
auto_explain.log_buffers = on
auto_explain.log_timing = off      # reduz o overhead do analyze
auto_explain.log_verbose = on      # inclui o Query Identifier (PG 14+)
auto_explain.log_format = json
```

Abra o `postgresql-*.log` (pode ser `.gz`) em **Abrir planos…**. Os planos são ligados às
SQLs pelo `Query Identifier` ou pelo texto normalizado. Logs `stderr`, `jsonlog` e saídas
de `EXPLAIN` coladas do psql são reconhecidos. Do mesmo log saem as SQLs lentas do
`log_min_duration_statement` com seus binds (`DETAIL: parameters:`) e os
`Query Parameters` do auto_explain (PostgreSQL 16+). Na aba **Plano**, **Usar no EXPLAIN**
troca `$1, $2…` por esses valores para rodar o `EXPLAIN ANALYZE` com o caso real.

## Formatos de amostras aceitos

CSV (de `COPY`/`\copy`), TSV, JSON (array, `json_agg` ou um objeto por linha), saída do
psql em tabela ou em modo `\x`, e `.gz` de qualquer um deles. Só `query` é obrigatória;
as demais colunas reconhecidas são `sample_time`, `pid`, `leader_pid`, `datname`,
`usename`, `application_name`, `client_addr`, `backend_type`, `backend_start`,
`xact_start`, `query_start`, `state_change`, `state`, `wait_event_type`, `wait_event` e
`query_id`.

## Limitações

- Execuções que começam e terminam entre duas amostras só aparecem se forem a última SQL
  da conexão. O tempo de BD continua correto em média; a contagem de execuções não é exata.
  Para contagens e tempos exatos, use `pg_stat_statements`.
- O texto da SQL é cortado em `track_activity_query_size` (padrão 1024 bytes). O painel
  marca SQLs cortadas como "cortado".
- "CPU*" é a sessão ativa sem evento de espera: está em CPU ou numa espera que o PostgreSQL
  não instrumenta.
