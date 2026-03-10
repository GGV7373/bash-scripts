# Architecture

## Directory Structure

```
install-freescout-docker.sh        # entry point (~76 lines)
lib/
  common.sh                        # shared utilities (~106 lines)
  config.sh                        # configuration & preflight (~177 lines)
  docker-setup.sh                  # Docker installation (~65 lines)
  deployment-files.sh              # file generation (~292 lines)
  bootstrap.sh                     # build, DB setup, app init (~172 lines)
```

## Modules

### `install-freescout-docker.sh`
Entry point. Sources all `lib/` modules, installs missing apt prerequisites, then runs the installation phases in order:

1. `run_preflight_checks` -- OS, internet, disk, port 80, resolve FreeScout version
2. `get_user_config` -- interactive prompts for domain, email, passwords
3. `install_docker` / `configure_docker_user`
4. `generate_all_files` -- Dockerfile, apache config, entrypoint, .env, docker-compose
5. `bootstrap_freescout` -- build image, start containers, migrations, create admin
6. `save_credentials` / `print_summary` / `check_final_health`

### `lib/common.sh`
Shared utilities used by every module:
- Logging: `info()`, `warn()`, `err()`, `die()`
- Progress bar: `show_progress()` (8 phases)
- Curl wrapper: `download_file()`, `CURL_COMMON_OPTS`
- `run_quiet()` -- runs a command, logs output to file, reports timing
- `require_root()`, `check_line_endings()`, `require_commands()`
- `setup_logging()` -- tee to `/var/log/freescout-install-*.log`

### `lib/config.sh`
- Constants: `SCRIPT_VERSION`, `INSTALL_DIR`, `PHP_VERSION`, `FREESCOUT_VERSION`
- `resolve_freescout_version()` -- resolves "latest" or a specific tag via GitHub API
- Preflight: `check_os()`, `check_internet()`, `check_disk_space()`, `check_port_80()`
- `get_user_config()` -- interactive prompts, generates DB passwords with `openssl rand`

### `lib/docker-setup.sh`
- `install_docker()` -- skips if already present; adds Docker APT repo, installs `docker-ce` + compose plugin
- `configure_docker_user()` -- adds `$SUDO_USER` to `docker` group

### `lib/deployment-files.sh`
Generates all files under `$INSTALL_DIR` (`/opt/freescout`):
- `generate_dockerfile()` -- PHP 8.2 + Apache, extensions, Composer, FreeScout clone, classmap fix
- `generate_apache_config()` -- VirtualHost pointing to `/var/www/freescout/public`
- `generate_entrypoint()` -- cron, queue worker, DB wait loop
- `generate_env_file()` -- Laravel `.env.freescout`
- `generate_docker_compose()` -- app + MariaDB services, healthcheck, volumes
- `backup_existing_db()` -- dumps existing DB before fresh install

Uses unquoted heredocs (`<<TAG`) for files needing bash variable expansion (Dockerfile, .env, docker-compose) and quoted heredocs (`<<'TAG'`) for literal content (apache config, entrypoint).

### `lib/bootstrap.sh`
- `build_and_start_containers()` -- `docker compose build` + `up -d`
- `wait_for_healthy_database()` -- polls Docker healthcheck (up to 450s)
- `verify_database_access()` -- confirms `freescout` user can query the DB
- `generate_app_key()` -- `artisan key:generate`, verifies it was written
- `run_migrations()`, `create_admin_user()`, `clear_caches()`, `restart_application()`
- `save_credentials()` -- writes `/opt/freescout/credentials.txt` (mode 600)
- `check_final_health()` -- HTTP request to `127.0.0.1`

## Environment Variables

Required when sourcing modules directly:

| Variable | Used by | Description |
|----------|---------|-------------|
| `INSTALL_DIR` | all | Installation directory (default `/opt/freescout`) |
| `PHP_VERSION` | deployment-files | PHP version (default `8.2`) |
| `FREESCOUT_VERSION` | config, deployment-files | Version tag or `latest` |
| `FREESCOUT_DOMAIN` | deployment-files, bootstrap | Domain or IP |
| `DB_PASSWORD` | deployment-files, bootstrap | Database user password |
| `DB_ROOT_PASSWORD` | deployment-files, bootstrap | Database root password |
| `ADMIN_EMAIL` | bootstrap | Admin email |
| `ADMIN_PASSWORD` | bootstrap | Admin password |
| `FRESH_INSTALL` | deployment-files | `Y` or `N` |

## Reusing Modules

Each module can be sourced independently:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/docker-setup.sh"

setup_logging
require_root
install_docker
```
