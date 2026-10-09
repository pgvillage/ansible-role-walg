# pgvillage.walg API

This document describes all variables of the `pgvillage.walg` role. Defaults live in
[`defaults/main.yml`](../defaults/main.yml).

The role installs wal-g, deploys the helper scripts into `{{ walg_home }}/scripts`, and
for every cluster in [`walg_clusters`](#clusters) it writes a configuration file
`/etc/default/wal-g-<cluster>` and a backup cron job. The configuration file is built
by merging these maps (later maps win):

1. [`walg_bucket_defaults`](#s3-bucket) (with `WALG_S3_PREFIX` taken from the cluster's `s3_prefix`)
2. PostgreSQL settings (`PGDATA`, `PGBIN`, `PGHOST`, `PGPORT`, `PGPASSWORD`) from the cluster or the [global defaults](#postgresql-connection)
3. [`walg_generic_defaults`](#wal-g-tuning)
4. [`walg_retention_defaults`](#backup-retention)
5. [`walg_log_defaults`](#logging) (with `WALG_LOG_FOLDER` taken from the cluster's `logfolder`)
6. `WALG_CLUSTER_NAME`, set to the cluster name

## Installation

| Variable | Default | Description |
|---|---|---|
| `walg_release` | `"1.1"` | wal-g release. The install tasks (folder creation and package installation) only run when this is a non-empty string; set to `""` to skip installation. |
| `walg_home` | `/opt/wal-g` | Base folder for wal-g. The helper scripts are deployed into `{{ walg_home }}/scripts`. |
| `walg_user` | `postgres` | OS user that runs wal-g (owns the cron jobs, log folder, certificates and shell profile). |
| `walg_group` | `postgres` | OS group of `walg_user`, used for the log folder and shell profile. |
| `walg_binary_owner` | `root` | Owner of `walg_home`. |
| `walg_package_state` | `present` | State passed to the package module for `walg_packages` (e.g. `present`, `latest`, `absent`). |
| `walg_packages` | `[wal-g-pg]` | OS packages that provide wal-g (the scripts call `/usr/local/bin/wal-g-pg`). When empty, installation is only allowed on x86_64 and aarch64. |

## Backup scheduling (cron)

The `walg_cron_*` schedule variables are the defaults for all clusters; each can be
overridden per cluster through `walg_clusters.<cluster>.cron`.

| Variable | Default | Description |
|---|---|---|
| `walg_cron_enabled` | `true` | Enable the backup cron job. Also controls whether `walg_cronvars` are set in the cron file. |
| `walg_cron_minute` | `"0"` | Cron minute of the backup job. |
| `walg_cron_hour` | `"20"` | Cron hour of the backup job. |
| `walg_cron_dom` | `"*"` | Cron day-of-month of the backup job. |
| `walg_cron_dow` | `"*"` | Cron day-of-week of the backup job. |
| `walg_cron_month` | `"*"` | Cron month of the backup job. |
| `walg_cron_command` | `{{ walg_home }}/scripts/backup_locked.sh` | Command run by cron. The cluster name is appended as argument. |
| `walg_cron_mailto` | `{{ walg_user }}@{{ inventory_hostname }}` | Mail address that receives cron output (`MAILTO`), i.e. failed backups. |
| `walg_cron_path` | `/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin` | `PATH` used by the cron jobs (must contain `etcdctl` and the wal-g binary). |
| `walg_cronvars` | `MAILTO` and `PATH` | List of `name` / `value` environment variables set in the `wal-g` cron file. |

### How backups are coordinated

The default `walg_cron_command` (`backup_locked.sh`):

- uses `etcdctl lock wal-g-<cluster>` so only one backup per cluster runs at a time across all nodes;
- sleeps 10 seconds when running on a primary, so standbys get preference;
- skips the backup when one was already taken within the last `walg_backup_skip_window` hours.

So only one backup is taken every `walg_backup_skip_window` hours, and it is taken from a
standby unless only the primary is available.

## S3 bucket

| Variable | Default | Description |
|---|---|---|
| `walg_aws_access_key` | `"AWSKEY"` | S3 access key. **Set to the correct value** (preferably from a vault). |
| `walg_aws_secret_key` | `"AWSSECRET"` | S3 secret key. **Set to the correct value** (preferably from a vault). |
| `walg_aws_endpoint` | `https://{{ walg_bucket_name }}.s3.Region.amazonaws.com/{{ walg_aws_access_key }}` | S3 endpoint URL. **Set to the correct value.** |
| `walg_aws_ca_file` | `~/.wal-g/certs/minio.crt` | CA certificate used to verify the S3 endpoint (see `walg_cert_files`). |
| `walg_bucket_name` | `backup` | Name of the S3 bucket. Used for the default `WALG_S3_PREFIX` (`s3://<bucket>`). |
| `walg_bucket_defaults` | see below | S3 related environment variables written to `/etc/default/wal-g-<cluster>`. `WALG_S3_PREFIX` is overridden per cluster by `walg_clusters.<cluster>.s3_prefix`. |

```yaml
walg_bucket_defaults:
  AWS_ACCESS_KEY_ID: "{{ walg_aws_access_key }}"
  AWS_SECRET_ACCESS_KEY: "{{ walg_aws_secret_key }}"
  AWS_ENDPOINT: "{{ walg_aws_endpoint }}"
  AWS_S3_FORCE_PATH_STYLE: true
  WALG_S3_PREFIX: "s3://{{ walg_bucket_name }}"
  WALG_S3_CA_CERT_FILE: "{{ walg_aws_ca_file }}"
```

## PostgreSQL connection

These are the defaults for all clusters; each can be overridden per cluster in `walg_clusters`.

| Variable | Default | Cluster key | Env var | Description |
|---|---|---|---|---|
| `walg_pg_datadir` | `/var/lib/pgsql/12/data` | `pg_datadir` | `PGDATA` | PostgreSQL data directory. |
| `walg_pg_bindir` | `/usr/pgsql/12/bin` | `pg_bindir` | `PGBIN` | PostgreSQL binaries folder, used for `psql` and `pg_ctl` in the scripts. |
| `walg_pg_hostname` | `/var/run/postgresql` | `pg_hostname` | `PGHOST` | PostgreSQL host or unix socket directory. |
| `walg_pg_password` | `postgres_password` | `pg_password` | `PGPASSWORD` | PostgreSQL password. Values containing a `#` are dropped when the scripts load the config. |
| `walg_pg_port` | `5432` | `pg_port` | `PGPORT` | PostgreSQL port. |

## wal-g tuning

| Variable | Default | Env var | Description |
|---|---|---|---|
| `walg_delta_max_steps` | `7` | `WALG_DELTA_MAX_STEPS` | Maximum number of delta backups between full backups. |
| `walg_download_concurrency` | `2` | `WALG_DOWNLOAD_CONCURRENCY` | Number of parallel downloads. |
| `walg_upload_concurrency` | `2` | `WALG_UPLOAD_CONCURRENCY` | Number of parallel uploads. |
| `walg_upload_disk_concurrency` | `2` | `WALG_UPLOAD_DISK_CONCURRENCY` | Number of parallel disk reads during upload. |
| `walg_compression_method` | `lz4` | `WALG_COMPRESSION_METHOD` | Compression method, e.g. `lz4`, `lzma`, `zstd` or `brotli`. |
| `walg_generic_defaults` | map of the above | | Generic wal-g environment variables written to `/etc/default/wal-g-<cluster>`. |

## Backup retention

Retention is applied by `delete.sh`. Only one retention policy is used, in order of precedence:
`walg_retention_days`, then `walg_retention_full_backups`, then `walg_retention_backups`.

| Variable | Default | Env var | Description |
|---|---|---|---|
| `walg_backup_skip_window` | `23` | `WALG_BACKUP_SKIP_WINDOW` | Skip a backup when there is already a backup younger than this number of hours. |
| `walg_retention_days` | `7` | `WALG_RETENTION_DAYS` | Keep backups of the last *n* days. Takes precedence over the other retention settings. |
| `walg_retention_full_backups` | `""` | `WALG_RETENTION_FULL_BACKUPS` | Keep *n* full backups and all of their delta backups (only used when `walg_retention_days` is empty). |
| `walg_retention_backups` | `""` | `WALG_RETENTION_BACKUPS` | Keep *n* backups, either full or delta (only used when `walg_retention_days` and `walg_retention_full_backups` are empty). |
| `walg_retention_defaults` | map of the above | | Retention environment variables written to `/etc/default/wal-g-<cluster>`. |

## Logging

| Variable | Default | Env var | Description |
|---|---|---|---|
| `walg_log_retention_days` | `{{ walg_retention_days }}` | `WALG_LOG_RETENTION_DAYS` | Delete script log files older than *n* days (used by `log_cleanup.sh`). |
| `walg_log_zip_days` | `2` | `WALG_LOG_ZIP_DAYS` | Gzip script log files older than *n* days (used by `log_cleanup.sh`). |
| `walg_logfolder` | `/var/log/wal-g` | `WALG_LOG_FOLDER` | Folder for the script log files. Can be overridden per cluster with `logfolder`. |
| `walg_log_level` | `NORMAL` | `WALG_LOG_LEVEL` | wal-g log level. Set to `DEVEL` for extra logging from wal-g. |
| `walg_s3_log_level` | `NORMAL` | `S3_LOG_LEVEL` | S3 log level. Set to `DEVEL` for extra logging in S3 communication. |
| `walg_log_defaults` | map of the above | | Logging environment variables written to `/etc/default/wal-g-<cluster>`. |

## Certificates

| Variable | Default | Description |
|---|---|---|
| `walg_cert_folders` | `minio` → `~walg_user/.wal-g/certs` | Folders to create for certificates (dict of name → `path` / `owner`), created with mode `0700`. |
| `walg_bucket_src` | `walg_bucket_root.crt` | Source file (in the playbook's files lookup path) of the CA certificate of the S3 endpoint. |
| `walg_cert_files` | `minio_chain` → `<minio folder>/minio.crt` | Certificate files to deploy (dict of name → `path` / `src` / `owner`), deployed with mode `0600`. `owner` defaults to `root`. |

```yaml
walg_cert_folders:
  minio:
    path: "{{ getent_passwd[walg_user][4] }}/.wal-g/certs"
    owner: "{{ walg_user }}"

walg_cert_files:
  minio_chain:
    path: "{{ walg_cert_folders.minio.path }}/minio.crt"
    src: "{{ walg_bucket_src }}"
    owner: "{{ walg_user }}"
```

## Clusters

`walg_clusters` is a dict of cluster name → settings. For every cluster a config file
`/etc/default/wal-g-<cluster>` and a cron job `wal-g backup <cluster>` are created.
All keys are optional and fall back to the global defaults.

| Key | Falls back to | Description |
|---|---|---|
| `pg_datadir` | `walg_pg_datadir` | PostgreSQL data directory (`PGDATA`). |
| `pg_bindir` | `walg_pg_bindir` | PostgreSQL binaries folder (`PGBIN`). |
| `pg_hostname` | `walg_pg_hostname` | PostgreSQL host or socket directory (`PGHOST`). |
| `pg_port` | `walg_pg_port` | PostgreSQL port (`PGPORT`). |
| `pg_password` | `walg_pg_password` | PostgreSQL password (`PGPASSWORD`). |
| `s3_prefix` | `s3://{{ walg_bucket_name }}` | S3 prefix for this cluster's backups (`WALG_S3_PREFIX`). |
| `logfolder` | `walg_logfolder` | Log folder for this cluster (`WALG_LOG_FOLDER`). |
| `cron.enabled` | `walg_cron_enabled` | Enable the backup cron job for this cluster. |
| `cron.minute` | `walg_cron_minute` | Cron minute. |
| `cron.hour` | `walg_cron_hour` | Cron hour. |
| `cron.dom` | `walg_cron_dom` | Cron day-of-month. |
| `cron.dow` | `walg_cron_dow` | Cron day-of-week. |
| `cron.month` | `walg_cron_month` | Cron month. |

Default:

```yaml
walg_clusters:
  default:
    pg_datadir: "{{ walg_pg_datadir }}"
    pg_port: "{{ walg_pg_port }}"
    s3_prefix: "s3://{{ walg_bucket_name }}"
    logfolder: "{{ walg_logfolder }}"
    cron:
      enabled: "{{ walg_cron_enabled }}"
      minute: "{{ walg_cron_minute }}"
      hour: "{{ walg_cron_hour }}"
```

Example with two clusters on one host:

```yaml
walg_clusters:
  main:
    pg_datadir: /var/lib/pgsql/16/main
    pg_port: 5432
    s3_prefix: s3://backup/main
    cron:
      hour: "20"
  reporting:
    pg_datadir: /var/lib/pgsql/16/reporting
    pg_port: 5433
    s3_prefix: s3://backup/reporting
    logfolder: /var/log/wal-g/reporting
    cron:
      hour: "22"
```

On the host, select a cluster's environment in a shell with `walg_cluster <cluster>`
(provided by `walg_profile`, which is sourced from `~walg_user/.pgsql_profile`).
