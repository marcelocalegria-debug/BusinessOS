# Coleta do Aurora PostgreSQL a partir de uma EC2

`ash_aurora.sh` roda na EC2 (Debian) que já conecta no Aurora. Ele faz três coisas:

1. **`coletar`**: amostra o `pg_stat_activity` a cada 15 s, sem parar. Grava um CSV por dia
   e compacta os dias anteriores.
2. **`logs`**: baixa da AWS os logs do Aurora e guarda só o que interessa ao painel: os
   planos do `auto_explain` e as SQLs lentas com os **binds** (`DETAIL: parameters:`).
3. **`enviar [dias]`**: junta os últimos 7 dias num `.csv.gz` (amostras) e num `.log.gz`
   (planos e binds) e manda por email.

Ao receber o email, abra o `index.html` do PG Top Activity: o `.csv.gz` vai em **Abrir
amostras…** e o `.log.gz` em **Abrir planos…**. Na aba **Plano** de cada SQL aparecem o plano
real e as execuções lentas com binds; o botão **Usar no EXPLAIN** monta o `EXPLAIN ANALYZE`
com aqueles valores, dentro de `BEGIN … ROLLBACK` quando é DML.

## Arquivos

| Arquivo | Para quê |
|---|---|
| `ash_aurora.sh` | o script (subcomandos `teste`, `coletar`, `logs`, `enviar`) |
| `ash_aurora.env.exemplo` | configuração da coleta: copie para `ash_aurora.env` |
| `ash-aurora-coleta.service` | unit do systemd para a coleta contínua |

A conexão vem do `backup_env_aurora.sh` da mesma pasta. O script espera as variáveis padrão
do libpq (`PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGPASSWORD` ou `~/.pgpass`). Se o seu
arquivo usa outros nomes, mapeie no bloco **Conexão** do início do `ash_aurora.sh`.

## Instalação na EC2

```bash
cd ~/scripts_manut_postgres_18          # a pasta onde está o backup_env_aurora.sh
chmod +x ash_aurora.sh
cp ash_aurora.env.exemplo ash_aurora.env && nano ash_aurora.env
sudo apt-get install -y postgresql-client   # se ainda não tiver o psql
./ash_aurora.sh teste                    # conexão, versão e parâmetros relevantes
```

Coleta contínua (sobrevive a reboot):

```bash
nano ash-aurora-coleta.service           # User= e caminhos
sudo cp ash-aurora-coleta.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now ash-aurora-coleta
```

Logs de hora em hora e email toda segunda às 7h30 (`crontab -e`):

```cron
15 * * * *  $HOME/scripts_manut_postgres_18/ash_aurora.sh logs      >> $HOME/scripts_manut_postgres_18/ash_dados/cron.log 2>&1
30 7 * * 1  $HOME/scripts_manut_postgres_18/ash_aurora.sh enviar 7  >> $HOME/scripts_manut_postgres_18/ash_dados/cron.log 2>&1
```

Para mandar na hora: `./ash_aurora.sh enviar 7`.

## Pré-requisitos

**Usuário do banco.** Para ver o texto das SQLs de todos os usuários:
`GRANT pg_read_all_stats TO <usuario>;` (o usuário master do Aurora já pode).

**Email.** A AWS bloqueia a porta 25 nas EC2. Escolha um caminho:
- `MAIL_METODO=sendmail` com o `msmtp-mta` apontando para um SMTP na porta 587 (o SMTP da
  empresa, o do SES ou o do Gmail com senha de app): `sudo apt-get install -y msmtp-mta` e
  configure `/etc/msmtprc`.
- `MAIL_METODO=ses`, que usa o `aws ses send-raw-email`. Precisa de remetente verificado no
  SES e da permissão `ses:SendRawEmail`. Essa API aceita até 10 MB por mensagem.

Gmail e Outlook aceitam ~25 MB por email, e o base64 aumenta o tamanho em 33%. Por isso, acima de
`MAX_ANEXO_MB` (padrão 15) os arquivos vão para o S3 (se `S3_DESTINO` estiver definido) com
um link no email, ou ficam no servidor com o caminho no corpo do email.

**Logs da AWS (subcomando `logs`).** AWS CLI instalado e a role da EC2 com
`rds:DescribeDBLogFiles` e `rds:DownloadDBLogFilePortion` na instância. `RDS_INSTANCIA` é o
identificador da **instância** (ex.: `aurora-prod-instance-1`), não do cluster.

## Parâmetros do Aurora para ter planos e binds

No **DB cluster parameter group** (os marcados com * exigem reboot):

| Parâmetro | Valor | Por quê |
|---|---|---|
| `shared_preload_libraries` * | acrescentar `auto_explain` (manter `pg_stat_statements`) | carrega o auto_explain |
| `auto_explain.log_min_duration` | `2000` | registra o plano das SQLs acima de 2 s |
| `auto_explain.log_analyze` | `1` | linhas reais por nó |
| `auto_explain.log_timing` | `0` | evita o custo de cronometrar cada nó |
| `auto_explain.log_buffers` | `1` | leituras de bloco por nó |
| `auto_explain.log_verbose` | `1` | inclui o Query Identifier, usado para ligar o plano à SQL |
| `auto_explain.log_format` | `json` | o formato mais fácil de ler sem ambiguidade |
| `auto_explain.log_parameter_max_length` | `-1` | binds dentro do plano (PostgreSQL 16+) |
| `log_min_duration_statement` | `2000` | SQL lenta com `DETAIL: parameters:` (binds) |
| `compute_query_id` | `on` | agrupa as SQLs pelo `query_id` |
| `track_activity_query_size` * | `4096` | o padrão de 1024 bytes corta SQLs grandes |
| `rds.log_retention_period` | `10080` | 7 dias de log na AWS (o `logs` de hora em hora já guarda localmente) |

Com `log_analyze` ligado, toda SQL é instrumentada, porque não dá para saber de antemão quais
vão passar de 2 s. Com `log_timing = 0` o overhead costuma ser pequeno, mas teste antes em
homologação. Sob carga alta, `auto_explain.sample_rate = 0.1` instrumenta 10% das SQLs.

## Observações

- No Aurora, cada instância tem o seu `pg_stat_activity`. O endpoint do cluster aponta para a
  writer; para olhar uma reader, rode outro coletor pelo **endpoint da instância**, com outro
  `INSTANCIA` e outro `DIR_DADOS`. No painel, abra os arquivos de uma instância por vez.
- Depois de um failover, a writer muda de instância: ajuste `RDS_INSTANCIA`.
- Os horários do CSV saem no fuso de Brasília (`PGTZ`); os logs do Aurora vêm em UTC. O painel
  converte os dois, e o seletor **Fuso horário** escolhe como exibir.
- Volume típico: uma linha por amostra para marcar o instante, mais uma por sessão ativa.
  Com média de 5 sessões ativas, 7 dias a 15 s dão ~240 mil linhas, alguns MB compactados.
