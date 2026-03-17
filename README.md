# FreeScout Docker Installer

Automated deployment of [FreeScout](https://github.com/freescout-helpdesk/freescout) (open-source help desk) on **Ubuntu 24.04 Server** using Docker.

Sets up:
- PHP 8.2 + Apache (Docker container)
- MariaDB 10.11 (Docker container)
- Laravel queue worker for email processing
- Cron scheduler for `artisan schedule:run`

## Requirements

- Ubuntu 24.04 Server
- 2 GB RAM, 4 GB free disk space
- Internet access
- Root / sudo
- Port 80 available

## Quick Start

```bash
git clone https://github.com/yourusername/bash-scripts.git
cd bash-scripts
sudo bash install-freescout-docker.sh
```

The installer will prompt you for:
- Domain or server IP
- Admin email and password (min 8 characters)
- Fresh install vs. keep existing database

Installation takes 5-15 minutes depending on network speed.

## File Locations

| Path | Description |
|------|-------------|
| `/opt/freescout/` | Installation directory |
| `/opt/freescout/docker-compose.yml` | Container orchestration |
| `/opt/freescout/Dockerfile` | Application image |
| `/opt/freescout/.env.freescout` | Laravel configuration |
| `/opt/freescout/credentials.txt` | Saved credentials (mode 600) |
| `/var/log/freescout-install-*.log` | Installation log |

## Common Commands

All commands run from `/opt/freescout`:

```bash
docker compose ps              # container status
docker compose logs -f         # follow all logs
docker compose logs -f freescout   # app logs only
docker compose logs -f db          # database logs only
docker compose restart freescout   # restart app
docker compose down            # stop containers
docker compose up -d           # start containers
docker compose down -v         # stop and DELETE all data
```

## Credentials

```bash
sudo cat /opt/freescout/credentials.txt
```

## What the Installer Does

The installer runs 8 phases automatically:

1. **Pre-flight checks** -- verifies OS, internet, disk space (4 GB min), port 80
2. **Version resolution** -- resolves the FreeScout release tag from the GitHub API
3. **User prompts** -- asks for domain/IP, admin email, password, fresh vs. upgrade
4. **Docker installation** -- installs Docker Engine + Compose plugin (skips if present)
5. **File generation** -- creates Dockerfile, apache config, entrypoint, .env, docker-compose.yml
6. **Image build** -- builds the PHP/Apache image with all FreeScout dependencies
7. **Bootstrap** -- starts containers, runs migrations, creates admin user, clears caches
8. **Health check** -- verifies FreeScout responds on HTTP

## Troubleshooting

### Check the install log

```bash
tail -100 /var/log/freescout-install-*.log
```

### Docker build fails

Retry manually with visible output:

```bash
cd /opt/freescout
docker compose build --progress=plain
docker compose up -d
```

### App not responding

```bash
cd /opt/freescout
docker compose logs freescout
docker compose logs db
```

Common causes: database still starting (wait 30-60s), low memory, port conflict.

### Database connection issues

Verify the database is healthy and accessible:

```bash
cd /opt/freescout
docker compose ps                    # check health status
docker inspect freescout-db | grep -A5 Health   # detailed health info
docker compose exec db mariadb -ufreescout -p -e "SELECT 1" freescout
```

When prompted for a password, use the value from `credentials.txt`.

### Reset admin password

```bash
cd /opt/freescout
docker compose exec freescout php artisan freescout:update-user \
  --email=your@email.com --password=newpassword123
```

### Containers not starting after reboot

Containers use `restart: unless-stopped`, so they should start automatically. If not:

```bash
cd /opt/freescout
docker compose up -d
```

### CRLF line ending errors

If the script was edited on Windows, fix with:

```bash
sed -i 's/\r$//' install-freescout-docker.sh lib/*.sh
```

## HTTPS Setup

The installer configures HTTP only. Add HTTPS with a reverse proxy:

**Caddy** (recommended -- automatic certificates):
```bash
apt-get install -y caddy
# /etc/caddy/Caddyfile:
# example.com {
#     reverse_proxy 127.0.0.1:80
# }
systemctl restart caddy
```

**nginx + Certbot**:
```bash
apt-get install -y nginx certbot python3-certbot-nginx
# Follow certbot prompts for your domain
```

**Traefik** (Docker-native):
Add Traefik labels and a Traefik service to `docker-compose.yml`. See the [Traefik docs](https://doc.traefik.io/traefik/).

After setting up HTTPS, update `APP_URL` in `.env.freescout`:
```bash
# Change http:// to https://
nano /opt/freescout/.env.freescout
cd /opt/freescout && docker compose restart freescout
```

## Backup & Restore

```bash
cd /opt/freescout

# Backup
docker compose exec -T db mariadb-dump -ufreescout -p --all-databases > backup.sql

# Restore
docker compose exec -T db mariadb -ufreescout -p < backup.sql
```

The installer also creates an automatic backup before a fresh install over an existing deployment.

## Custom Port

To use a different port instead of 80, edit `docker-compose.yml`:

```yaml
freescout:
  ports:
    - "8080:80"   # access on port 8080
```

Then restart: `docker compose up -d`

## Scaling Resources

Edit `docker-compose.yml` to increase memory limits:

```yaml
freescout:
  mem_limit: 1g          # default 512m
  memswap_limit: 1g

db:
  mem_limit: 1g          # default 512m
  memswap_limit: 1g
```

Then restart: `docker compose up -d`

## Updating FreeScout

1. Check releases at https://github.com/freescout-helpdesk/freescout/releases
2. Edit `docker-compose.yml` and update `FREESCOUT_VERSION`
3. Rebuild:
   ```bash
   cd /opt/freescout
   docker compose down
   docker compose build --progress=plain
   docker compose up -d
   ```

## Uninstalling

Remove everything (containers, volumes, files):
```bash
cd /opt/freescout
docker compose down -v              # stop and delete volumes
cd /
sudo rm -rf /opt/freescout          # remove files
```

Keep the database but remove containers:
```bash
cd /opt/freescout
docker compose down                 # volumes are preserved
```

## Security Notes

- Credentials file is created with mode `600` (root-only readable)
- Database passwords are generated with `openssl rand`
- Admin password is entered interactively, never stored in scripts
- HTTPS is strongly recommended for production -- see [HTTPS Setup](#https-setup)
- Keep your system and Docker images updated regularly

## Project Structure

See [ARCHITECTURE.md](ARCHITECTURE.md) for module details.

```
install-freescout-docker.sh      # entry point
lib/
  common.sh                      # logging, progress, curl helpers
  config.sh                      # configuration, preflight checks, prompts
  docker-setup.sh                # Docker installation
  deployment-files.sh            # generates Dockerfile, configs, docker-compose
  bootstrap.sh                   # container build, DB setup, app init
```

## License

This installer is under MIT. FreeScout itself is [AGPL-3.0](https://github.com/freescout-helpdesk/freescout).
