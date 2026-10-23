-- Coleta de amostras do pg_stat_activity dentro do proprio banco, com pg_cron.
-- Alternativa ao coleta_pg_activity.sh quando nao ha uma maquina para rodar o loop.
-- Requer pg_cron 1.5+ (agendamento em segundos) e permissao para criar a extensao.

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Tabela com as mesmas colunas da view da versao instalada, mais o instante da amostra.
CREATE TABLE IF NOT EXISTS ash_amostras AS
  SELECT now() AS sample_time, * FROM pg_stat_activity WITH NO DATA;
CREATE INDEX IF NOT EXISTS ash_amostras_sample_time_idx ON ash_amostras (sample_time);

-- Amostra a cada 15 s: sessoes ativas + as que terminaram uma SQL desde a ultima amostra.
SELECT cron.schedule('ash-amostra', '15 seconds', $$
  INSERT INTO ash_amostras
  SELECT now(), * FROM pg_stat_activity
   WHERE pid = pg_backend_pid()   -- marca o instante mesmo com o banco ocioso
      OR (query <> '' AND (state = 'active' OR state_change >= now() - interval '15 seconds'))
$$);

-- Retencao de 14 dias.
SELECT cron.schedule('ash-limpeza', '17 3 * * *', $$
  DELETE FROM ash_amostras WHERE sample_time < now() - interval '14 days'
$$);

-- Exportar para o painel (rodar no psql da sua maquina):
--   \copy (SELECT * FROM ash_amostras WHERE sample_time >= now() - interval '7 days' ORDER BY sample_time) TO 'ash.csv' WITH (FORMAT csv, HEADER)

-- Para parar:
--   SELECT cron.unschedule('ash-amostra');
--   SELECT cron.unschedule('ash-limpeza');
