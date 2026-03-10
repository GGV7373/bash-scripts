# FreeScout Docker Installer

A modular bash script that automates the installation and deployment of FreeScout (a free open-source help desk and shared mailbox) on Ubuntu 24.04 Server using Docker containers.

## Overview

This installer sets up a complete FreeScout deployment with:
- PHP 8.2 + Apache web server (in Docker)
- MariaDB 10.11 database (in Docker)
- Automated configuration and initialization
- Database backups (on fresh installs)
- Laravel queue worker for email processing
- Cron scheduler for laravel:schedule

The original monolithic 746-line script has been refactored into 5 focused modules for better maintainability and reusability.

## System Requirements

- Ubuntu 24.04 Server (other versions may work but are not officially supported)
- Minimum 2GB RAM, 4GB free disk space (for Docker image build)
- Internet connectivity (required for downloading dependencies)
- Root access via sudo
- Ports 80 available (or modify docker-compose.yml for different port)

## Prerequisites

The installer automatically checks for and installs these if missing:
- curl
- openssl
- awk
- ss (from iproute2)
- timeout (from coreutils)

If any are missing, the script will attempt to install them via apt-get. You may be asked for your sudo password.

## Quick Start

1. Download or clone the repository:
   ```bash
   git clone https://github.com/yourusername/bash-scripts.git
   cd bash-scripts
   ```

2. Make the main script executable:
   ```bash
   chmod +x install-freescout-docker.sh
   ```

3. Run the installer with sudo:
   ```bash
   sudo bash install-freescout-docker.sh
   ```

4. Follow the interactive prompts:
   - Enter your domain or server IP
   - Provide admin email address
   - Create a strong admin password (minimum 8 characters)
   - Confirm fresh install or keep existing database
   - Review configuration and proceed

5. Wait for installation to complete (5-15 minutes depending on internet speed)

6. Access FreeScout at the domain/IP you provided

## Installation Steps Explained

The installer performs these steps automatically:

### 1. Pre-flight Checks (lib/config.sh)
- Verifies running as root
- Detects CRLF line endings
- Checks OS is Ubuntu 24.04
- Verifies internet connectivity
- Checks available disk space (4GB minimum)
- Checks port 80 is available
- Resolves FreeScout version from GitHub

### 2. Interactive Configuration (lib/config.sh)
- Prompts for domain/IP
- Prompts for admin email and password
- Generates secure database passwords
- Confirms fresh install or existing database preservation

### 3. Docker Installation (lib/docker-setup.sh)
- Removes old conflicting Docker packages
- Adds Docker GPG key
- Configures Docker APT repository
- Installs Docker Engine, CLI, and Compose plugin
- Starts Docker service
- Adds sudo user to docker group

### 4. Deployment File Generation (lib/deployment-files.sh)
- Backs up existing database (if applicable)
- Generates Dockerfile with PHP extensions and FreeScout dependencies
- Creates Apache VirtualHost configuration
- Creates container entrypoint script with cron and queue worker
- Creates .env file for Laravel configuration
- Creates docker-compose.yml for multi-container orchestration

### 5. Build and Bootstrap (lib/bootstrap.sh)
- Builds Docker image (first run takes several minutes)
- Starts containers (freescout-app and freescout-db)
- Waits for database to become healthy
- Generates Laravel application key
- Runs database migrations
- Creates admin user
- Clears configuration and view caches
- Restarts application
- Performs final HTTP health check

### 6. Summary (lib/bootstrap.sh)
- Saves credentials to /opt/freescout/credentials.txt
- Displays installation summary with access URL
- Lists useful docker compose commands

## File Locations

After installation, files are located at:

- Installation Directory: /opt/freescout/
- Docker Compose Config: /opt/freescout/docker-compose.yml
- Dockerfile: /opt/freescout/Dockerfile
- FreeScout Config: /opt/freescout/.env.freescout
- Credentials: /opt/freescout/credentials.txt (mode 600, readable only by root)
- Installation Log: /var/log/freescout-install-YYYYMMDD-HHMMSS.log

## Docker Compose Commands

After installation, manage FreeScout from the /opt/freescout directory:

View running containers and status:
```bash
cd /opt/freescout
docker compose ps
```

View logs from all services:
```bash
docker compose logs -f
```

View logs from specific service (app or db):
```bash
docker compose logs -f freescout
docker compose logs -f db
```

Stop all containers:
```bash
docker compose down
```

Start all containers:
```bash
docker compose up -d
```

Restart a specific service:
```bash
docker compose restart freescout
```

Stop and delete all data (WARNING: deletes database):
```bash
docker compose down -v
```

## Accessing FreeScout

1. Open your web browser
2. Navigate to the domain or IP you specified during installation
3. Log in with the email and password you created
4. Configure your mailboxes and helpdesk

## Credentials

Credentials are saved to /opt/freescout/credentials.txt (readable only by root):
```bash
sudo cat /opt/freescout/credentials.txt
```

The file contains:
- Installation URL
- Admin email and password
- Database connection details
- Install directory path
- FreeScout version

## Troubleshooting

### Installation fails at pre-flight checks

Check the installation log:
```bash
tail -f /var/log/freescout-install-*.log
```

Common issues:
- Not running as root: Use sudo bash install-freescout-docker.sh
- No internet connectivity: Check your network connection
- Insufficient disk space: Free up at least 4GB
- Port 80 already in use: Stop the conflicting service or modify docker-compose.yml

### Docker build fails

The build log is saved to the main installation log file:
```bash
tail -100 /var/log/freescout-install-*.log
```

If the build fails, you can retry it manually:
```bash
cd /opt/freescout
docker compose build --progress=plain
docker compose up -d
```

### Application not responding after installation

Check container logs:
```bash
cd /opt/freescout
docker compose logs freescout
docker compose logs db
```

Common issues:
- Database not ready: Wait 30-60 seconds and refresh your browser
- Permission issues: Check file ownership with ls -la /opt/freescout/
- Low memory: Docker containers may need more resources

### Database connection issues

Verify database health:
```bash
cd /opt/freescout
docker compose exec db mariadb -ufreescout -p -e "SELECT 1"
```

When prompted for password, use the value from credentials.txt.

### Reset admin password

If you forget the admin password, reset it:
```bash
cd /opt/freescout
docker compose exec freescout php artisan freescout:update-user \
  --email=your-admin-email@example.com \
  --password=newpassword123
```

### Restart containers after system reboot

Containers are configured to restart automatically with restart: unless-stopped. To manually restart:
```bash
cd /opt/freescout
docker compose up -d
```

## Advanced Usage

### Using Modules in Your Own Scripts

Each module can be sourced independently for reuse in other scripts:

Example: Use only Docker setup
```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/docker-setup.sh"

setup_logging
require_root
install_docker
configure_docker_user
```

Example: Use only preflight checks
```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/config.sh"

setup_logging
check_os
check_internet
check_disk_space
info "System check passed!"
```

### Custom Port Configuration

To use a different port instead of 80:

1. Edit docker-compose.yml:
   ```yaml
   freescout:
     ports:
       - "8080:80"  # Use port 8080 instead of 80
   ```

2. Restart containers:
   ```bash
   cd /opt/freescout
   docker compose up -d
   ```

3. Access at http://your-ip:8080

### HTTPS Setup with Reverse Proxy

The installer configures HTTP only. For HTTPS, use a reverse proxy:

Option 1: Caddy (recommended, automatic certificate renewal)
```bash
# Install Caddy on host
apt-get install -y caddy

# Configure /etc/caddy/Caddyfile
example.com {
    reverse_proxy 127.0.0.1:80
}

# Start Caddy
systemctl restart caddy
```

Option 2: nginx with Certbot
```bash
apt-get install -y nginx certbot python3-certbot-nginx
# Follow Certbot instructions for your domain
```

Option 3: Traefik (Docker-native)
Modify docker-compose.yml to use Traefik labels and sidekick container.

### Database Backups and Restore

Automatic backup on fresh install is saved to:
```bash
/opt/freescout/freescout-backup-YYYYMMDD-HHMMSS.sql
```

Manual backup:
```bash
cd /opt/freescout
docker compose exec -T db mariadb-dump -ufreescout -p --all-databases > backup.sql
```

Manual restore:
```bash
cd /opt/freescout
docker compose exec -T db mariadb -ufreescout -p < backup.sql
```

### Scale Up Resources

Edit docker-compose.yml to increase memory/CPU limits:
```yaml
freescout:
  mem_limit: 1g        # Increase from 512m
  memswap_limit: 1g    # Increase from 512m

db:
  mem_limit: 1g        # Increase from 512m
  memswap_limit: 1g    # Increase from 512m
```

Then restart:
```bash
cd /opt/freescout
docker compose up -d
```

## Module Architecture

See ARCHITECTURE.md for detailed information about the modular structure and how to extend or customize the installer.

Quick overview:
- lib/common.sh: Logging, progress tracking, curl helpers, system checks
- lib/config.sh: Configuration, version resolution, preflight checks, user prompts
- lib/docker-setup.sh: Docker installation and configuration
- lib/deployment-files.sh: Generates all deployment files (Dockerfile, configs, etc.)
- lib/bootstrap.sh: Container build, database setup, FreeScout initialization

## Updating FreeScout Version

To update to a newer FreeScout version:

1. Check available versions at GitHub: https://github.com/freescout-helpdesk/freescout/releases
2. Edit docker-compose.yml and update the FREESCOUT_VERSION argument
3. Rebuild and restart:
   ```bash
   cd /opt/freescout
   docker compose down
   docker compose build --progress=plain
   docker compose up -d
   ```

## Uninstalling FreeScout

To completely remove FreeScout and all data:

```bash
cd /opt/freescout
docker compose down -v          # Stop containers and delete volumes
cd /
sudo rm -rf /opt/freescout      # Remove installation directory
sudo rm -f /etc/apt/sources.list.d/docker.list  # Optional: remove Docker repo
```

To keep the database but remove containers:

```bash
cd /opt/freescout
docker compose down              # Stop and remove containers only
                                 # Volumes (database) are preserved
```

## Security Considerations

- Credentials file is created with mode 600 (readable only by root)
- Database passwords are randomly generated using openssl
- Admin password is entered interactively (not stored in any file)
- Consider placing a reverse proxy with SSL/TLS in front of FreeScout
- Regularly update Docker images: docker pull and rebuild
- Keep your Ubuntu system updated: apt-get update && apt-get upgrade
- Monitor disk space for database growth
- Review Docker logs periodically for errors

## Performance Tuning

Default configuration is suitable for small to medium deployments.

For larger installations:
- Increase PHP memory_limit in Dockerfile
- Increase MariaDB memory allocation
- Use separate Docker network bridges for isolation
- Consider using persistent volumes for storage
- Implement caching layers (Redis) if available

See docker-compose.yml comments for additional tuning options.

## Support

For issues with:
- FreeScout: Visit https://github.com/freescout-helpdesk/freescout
- Docker: Visit https://docs.docker.com/
- This installer: Check the installation log and ARCHITECTURE.md

## License

This installer script is provided as-is for deploying the FreeScout helpdesk application on Ubuntu servers.

FreeScout itself is licensed under AGPL-3.0. See https://github.com/freescout-helpdesk/freescout for details.

## Changelog

### v3.0.0
- Refactored monolithic script into 5 focused modules
- Improved error handling and logging throughout
- Fixed PHP variable escaping in Dockerfile classmap sanitization
- Added comprehensive documentation
- Better separation of concerns for maintainability

### v2.x
- Previous versions - see git history

## Contributing

To contribute improvements:
1. Test changes thoroughly on a fresh Ubuntu 24.04 system
2. Maintain the modular structure
3. Update ARCHITECTURE.md if adding new modules
4. Test both fresh installs and upgrades
5. Document any new functions and their parameters
