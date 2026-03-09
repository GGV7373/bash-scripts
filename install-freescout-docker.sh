#!/usr/bin/env bash
###############################################################################
# install-freescout-docker.sh  v3.0.0
#
# Installs Docker and deploys FreeScout in containers
# (PHP 8.2 + Apache  |  MariaDB 10.11)
#
# Target: Ubuntu 24.04 Server
# Usage:  sudo bash install-freescout-docker.sh
#
# IMPORTANT: This file MUST use Unix (LF) line endings.
#            If edited on Windows, run:  sed -i 's/\r$//' install-freescout-docker.sh
###############################################################################

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="3.0.0"
INSTALL_DIR="/opt/freescout"
PHP_VERSION="8.2"
FREESCOUT_VERSION="latest"

# Shared curl options for resilient downloads.
CURL_COMMON_OPTS=(
    --fail
    --show-error
    --silent
    --location
    --connect-timeout 15
    --max-time 600
    --retry 5
    --retry-delay 2
    --retry-all-errors
)

# ── Colours / helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

TOTAL_PHASES=8
CURRENT_PHASE=0

show_progress() {
    local label="$1"
    local percent filled empty bar_fill bar_empty
    ((CURRENT_PHASE++))
    percent=$(( CURRENT_PHASE * 100 / TOTAL_PHASES ))
    filled=$(( percent / 5 ))
    empty=$(( 20 - filled ))
    printf -v bar_fill '%*s' "${filled}" ''
    printf -v bar_empty '%*s' "${empty}" ''
    bar_fill=${bar_fill// /#}
    bar_empty=${bar_empty// /-}
    info "Progress [${bar_fill}${bar_empty}] ${percent}% (${CURRENT_PHASE}/${TOTAL_PHASES}) - ${label}"
}

# Download a URL to a file with retry/timeout defaults.
download_file() {
    local url="$1"
    local output="$2"
    curl "${CURL_COMMON_OPTS[@]}" --output "${output}" "${url}"
}

resolve_latest_freescout_tag() {
    local latest_tag
    latest_tag=$(curl "${CURL_COMMON_OPTS[@]}" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: freescout-installer" \
        "https://api.github.com/repos/freescout-helpdesk/freescout/releases/latest" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n1 || true)

    [[ -n "${latest_tag}" ]] || return 1
    echo "${latest_tag}"
}

resolve_freescout_version() {
    local requested="$1"
    local resolved

    if [[ "${requested}" == "latest" ]]; then
        resolved=$(resolve_latest_freescout_tag) || return 1
        echo "${resolved}"
        return 0
    fi

    if curl "${CURL_COMMON_OPTS[@]}" -o /dev/null \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: freescout-installer" \
        "https://api.github.com/repos/freescout-helpdesk/freescout/git/ref/tags/${requested}"; then
        echo "${requested}"
        return 0
    fi

    warn "Requested FreeScout version '${requested}' not found. Falling back to latest release tag."
    resolved=$(resolve_latest_freescout_tag) || return 1
    echo "${resolved}"
}

# Run noisy commands quietly and print a compact timed status line.
run_quiet() {
    local step="$1"
    shift
    local started_at elapsed
    started_at=$(date +%s)
    info "${step} ..."

    if "$@" >>"${LOG_FILE}" 2>&1; then
        elapsed=$(( $(date +%s) - started_at ))
        info "DONE: ${step} (${elapsed} sec)"
    else
        elapsed=$(( $(date +%s) - started_at ))
        err "FAILED: ${step} (${elapsed} sec). See ${LOG_FILE}"
        tail -n 40 "${LOG_FILE}" >&2 || true
        exit 1
    fi
}

###############################################################################
# 1. Pre-flight checks
###############################################################################

# ── CRLF detection ───────────────────────────────────────────────────────────
# If this script has Windows line endings it will fail with "bad interpreter"
# or produce subtle errors. Detect and abort with clear instructions.
if od -An -tx1 -N 200 "$0" 2>/dev/null | tr -d ' \n' | grep -q '0d0a'; then
    echo "ERROR: This script has Windows (CRLF) line endings." >&2
    echo "Fix with:  sed -i 's/\r\$//' $0" >&2
    exit 1
fi

[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."

# ── Logging (requires root for /var/log) ─────────────────────────────────────
LOG_FILE="/var/log/freescout-install-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'err "Script failed at line $LINENO. See output above or ${LOG_FILE} for details."; sync' ERR

info "FreeScout Docker Installer v${SCRIPT_VERSION}"
info "Logging to ${LOG_FILE}"
info "Running pre-flight checks …"
show_progress "Pre-flight checks"

# Check Ubuntu 24.04
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "This script is designed for Ubuntu. Detected: ${ID:-unknown}"
    fi
    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "Designed for Ubuntu 24.04, detected ${VERSION_ID:-unknown}. Continuing anyway …"
    fi
else
    die "Cannot determine OS — /etc/os-release not found."
fi

# Check required tools
for cmd in curl openssl awk ss; do
    command -v "$cmd" &>/dev/null || die "Required command '${cmd}' not found. Install it first."
done

# Check internet (HTTP, not ICMP — ping is blocked on many VPS/cloud hosts)
if ! curl "${CURL_COMMON_OPTS[@]}" --max-time 15 -o /dev/null https://www.google.com 2>/dev/null && \
    ! curl "${CURL_COMMON_OPTS[@]}" --max-time 15 -o /dev/null https://github.com 2>/dev/null; then
    die "No internet connectivity. Please check your network."
fi

FREESCOUT_VERSION=$(resolve_freescout_version "${FREESCOUT_VERSION}") || \
    die "Could not resolve a valid FreeScout release version from GitHub API."
info "Using FreeScout version: ${FREESCOUT_VERSION}"

# Check disk space (Docker build needs several GB)
REQUIRED_SPACE_MB=4000
AVAILABLE_MB=$(df -BM --output=avail / | tail -1 | tr -d ' M')
if [[ "${AVAILABLE_MB}" -lt "${REQUIRED_SPACE_MB}" ]]; then
    die "Insufficient disk space. Need ${REQUIRED_SPACE_MB}MB, have ${AVAILABLE_MB}MB free."
fi
info "Disk space check passed (${AVAILABLE_MB}MB available)."

# Check if port 80 is already in use
if ss -tlnp 2>/dev/null | grep -q ':80 '; then
    PORT80_INFO=$(ss -tlnp 2>/dev/null | grep ':80 ' | head -1)
    warn "Port 80 is already in use:"
    warn "  ${PORT80_INFO}"
    die "Stop the conflicting service or change the port mapping before running this script."
fi
info "Port 80 is available."

###############################################################################
# 2. Interactive prompts
###############################################################################
show_progress "Collecting configuration"
echo ""
info "=== FreeScout Docker Installer v${SCRIPT_VERSION} ==="
echo ""

# Domain / IP
DEFAULT_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
DEFAULT_IP="${DEFAULT_IP:-127.0.0.1}"
read -rp "Enter domain or IP for FreeScout [${DEFAULT_IP}]: " FREESCOUT_DOMAIN
FREESCOUT_DOMAIN="${FREESCOUT_DOMAIN:-$DEFAULT_IP}"

# Admin email
read -rp "Enter admin email address: " ADMIN_EMAIL
while [[ -z "$ADMIN_EMAIL" ]]; do
    read -rp "Admin email cannot be empty. Enter admin email: " ADMIN_EMAIL
done

# Admin password
while true; do
    read -rsp "Enter admin password (min 8 chars): " ADMIN_PASSWORD
    echo ""
    if [[ ${#ADMIN_PASSWORD} -ge 8 ]]; then
        break
    fi
    warn "Password must be at least 8 characters."
done

# Database passwords — reuse existing credentials when re-running so persistent
# DB volumes keep working with the same authentication details.
# Passwords are generated with openssl rand -hex 16 (hex-only, YAML-safe).
DB_ROOT_PASSWORD=""
DB_PASSWORD=""
if [[ -f "${INSTALL_DIR}/credentials.txt" ]]; then
    DB_ROOT_PASSWORD=$(sed -n 's/^DB Root Password:[[:space:]]*//p' "${INSTALL_DIR}/credentials.txt" | head -n1)
    DB_PASSWORD=$(sed -n 's/^Database Password:[[:space:]]*//p' "${INSTALL_DIR}/credentials.txt" | head -n1)
    if [[ -n "${DB_ROOT_PASSWORD}" && -n "${DB_PASSWORD}" ]]; then
        info "Reusing existing database credentials from ${INSTALL_DIR}/credentials.txt"
    else
        DB_ROOT_PASSWORD=""
        DB_PASSWORD=""
    fi
fi

if [[ -z "${DB_ROOT_PASSWORD}" || -z "${DB_PASSWORD}" ]]; then
    DB_ROOT_PASSWORD=$(openssl rand -hex 16)
    DB_PASSWORD=$(openssl rand -hex 16)
fi

echo ""
info "Configuration:"
info "  Domain/IP     : ${FREESCOUT_DOMAIN}"
info "  Admin email   : ${ADMIN_EMAIL}"
info "  Install dir   : ${INSTALL_DIR}"
info "  FreeScout ver : ${FREESCOUT_VERSION}"
echo ""
read -rp "Fresh install (delete old database)? [Y/n]: " FRESH_INSTALL
FRESH_INSTALL="${FRESH_INSTALL:-Y}"
echo ""
read -rp "Proceed with installation? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    info "Installation cancelled."
    exit 0
fi

###############################################################################
# 3. Install Docker Engine + Compose Plugin
###############################################################################
show_progress "Installing Docker runtime"
info "Installing Docker …"

# Skip Docker installation if already installed
if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    info "Docker and Docker Compose already installed. Skipping installation."
else
    # Remove old / conflicting packages (with timeout to prevent hangs)
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        timeout 30 apt-get remove -y "$pkg" 2>/dev/null || true
    done

    run_quiet "APT update (Docker prerequisites)" apt-get update
    run_quiet "Install Docker prerequisites" apt-get install -y ca-certificates curl

    # Docker GPG key (download .asc directly per current Docker docs)
    install -m 0755 -d /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.asc
    run_quiet "Download Docker GPG key" download_file https://download.docker.com/linux/ubuntu/gpg /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Verify Docker repository was added successfully
    if [[ ! -s /etc/apt/sources.list.d/docker.list ]]; then
        die "Failed to create Docker APT repository file."
    fi

    run_quiet "APT update (Docker repository)" apt-get update

    # Verify docker-ce package is available before installing
    if ! apt-cache show docker-ce &>/dev/null; then
        die "docker-ce package not found. Docker APT repository may not be configured correctly."
    fi

    run_quiet "Install Docker Engine and Compose" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    run_quiet "Enable and start Docker service" systemctl enable --now docker

    # Verify Docker daemon is actually running
    if ! docker info &>/dev/null; then
        die "Docker installed but daemon is not responding. Check: systemctl status docker"
    fi

    info "Docker installed successfully."
fi

# Add invoking user to docker group (if run via sudo)
if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER" 2>/dev/null || true
    info "Added user '${SUDO_USER}' to docker group (re-login to take effect)."
fi

###############################################################################
# 4. Generate deployment files
###############################################################################
show_progress "Generating deployment files"
info "Setting up FreeScout under ${INSTALL_DIR} …"

mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# Backup existing database before fresh install destroys volumes
if [[ "${FRESH_INSTALL}" =~ ^[Yy]$ ]]; then
    if [[ -f docker-compose.yml ]]; then
        # Attempt backup of existing database before destruction
        if docker compose ps --quiet db 2>/dev/null | grep -q .; then
            BACKUP_FILE="${INSTALL_DIR}/freescout-backup-$(date +%Y%m%d-%H%M%S).sql"
            info "Attempting to backup existing database to ${BACKUP_FILE} …"
            if docker compose exec -T db mariadb-dump -uroot -p"${DB_ROOT_PASSWORD}" --all-databases > "${BACKUP_FILE}" 2>/dev/null; then
                chmod 600 "${BACKUP_FILE}"
                info "Database backed up to ${BACKUP_FILE}"
            else
                warn "Could not backup existing database. Proceeding with fresh install."
                rm -f "${BACKUP_FILE}"
            fi
        fi
        info "Removing previous FreeScout containers and volumes (old database will be deleted) …"
        docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    fi
fi

# ── 4a. Dockerfile ───────────────────────────────────────────────────────────
cat > Dockerfile <<DOCKERFILE
FROM php:${PHP_VERSION}-apache-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# OS dependencies (including unzip for Composer, imap libs for email)
RUN apt-get update && apt-get install -y --no-install-recommends \\
    libpng-dev libjpeg62-turbo-dev libfreetype6-dev \\
    libxml2-dev libzip-dev libonig-dev \\
    libcurl4-openssl-dev \\
    libc-client-dev libkrb5-dev \\
    cron git unzip \\
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# PHP extensions (including imap for email fetching) & Composer
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \\
    && docker-php-ext-configure imap --with-kerberos --with-imap-ssl \\
    && docker-php-ext-install -j "\$(nproc)" \\
       bcmath exif gd imap mbstring opcache pdo_mysql xml zip \\
    && EXPECTED_CHECKSUM="\$(curl -fsSL --connect-timeout 15 --max-time 120 --retry 5 --retry-delay 2 --retry-all-errors https://composer.github.io/installer.sig)" \\
    && curl -fsSL --connect-timeout 15 --max-time 120 --retry 5 --retry-delay 2 --retry-all-errors https://getcomposer.org/installer -o /tmp/composer-setup.php \\
    && ACTUAL_CHECKSUM="\$(sha384sum /tmp/composer-setup.php | cut -d ' ' -f 1)" \\
    && [ "\${EXPECTED_CHECKSUM}" = "\${ACTUAL_CHECKSUM}" ] \\
    && php /tmp/composer-setup.php --install-dir=/usr/bin --filename=composer \
    && rm -f /tmp/composer-setup.php

# Apache modules
RUN a2enmod rewrite headers

# Clone FreeScout (pinned version, with retry logic)
ARG FREESCOUT_VERSION=${FREESCOUT_VERSION}
RUN for attempt in 1 2 3; do \\
        git clone --depth 1 --branch "\${FREESCOUT_VERSION}" \\
            -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \\
            https://github.com/freescout-helpdesk/freescout.git /var/www/freescout \\
        && break || { \\
            echo "Git clone attempt \${attempt} failed, retrying in 10s..."; \\
            rm -rf /var/www/freescout; \\
            sleep 10; \\
        }; \\
    done && [ -d /var/www/freescout ]

WORKDIR /var/www/freescout

# Install PHP dependencies (--no-scripts: post-install hooks run at runtime via entrypoint)
RUN COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1 \\
    composer install --no-dev --no-interaction \\
        --prefer-dist --optimize-autoloader --no-scripts \\
    && composer clear-cache

# package:discover may fail at build time (no .env/APP_KEY yet) — re-run at runtime
RUN COMPOSER_ALLOW_SUPERUSER=1 php artisan package:discover --ansi 2>&1 || true

# Set ownership and permissions (single-pass, no slow find -exec)
RUN chown -R www-data:www-data /var/www/freescout \\
    && chmod -R u=rwX,g=rX,o=rX /var/www/freescout

# Apache vhost
COPY freescout.conf /etc/apache2/sites-available/000-default.conf

# PHP production settings
RUN { \\
    echo 'opcache.enable=1'; \\
    echo 'opcache.memory_consumption=256'; \\
    echo 'opcache.max_accelerated_files=20000'; \\
    echo 'opcache.validate_timestamps=0'; \\
    echo 'upload_max_filesize=20M'; \\
    echo 'post_max_size=25M'; \\
    echo 'memory_limit=256M'; \\
    echo 'max_execution_time=120'; \\
} > /usr/local/etc/php/conf.d/freescout.ini

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]
DOCKERFILE

# ── 4b. Apache vhost ─────────────────────────────────────────────────────────
cat > freescout.conf <<'APACHECONF'
<VirtualHost *:80>
    DocumentRoot /var/www/freescout/public

    <Directory /var/www/freescout/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/freescout-error.log
    CustomLog ${APACHE_LOG_DIR}/freescout-access.log combined
</VirtualHost>
APACHECONF

# ── 4c. Entrypoint ───────────────────────────────────────────────────────────
cat > entrypoint.sh <<'ENTRYPOINT'
#!/usr/bin/env bash
set -euo pipefail

# Fix storage permissions on every start
chown -R www-data:www-data /var/www/freescout/storage
chmod -R 775 /var/www/freescout/storage

# Ensure bootstrap/cache is writable
chown -R www-data:www-data /var/www/freescout/bootstrap/cache
chmod -R 775 /var/www/freescout/bootstrap/cache

# Wait for database connectivity before starting background services
echo "Waiting for database connection..."
for i in $(seq 1 60); do
    if php -r "new PDO('mysql:host=db;port=3306;dbname=freescout', 'freescout', getenv('DB_PASSWORD'));" 2>/dev/null; then
        echo "Database connection established."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "WARNING: Could not connect to database after 60 attempts. Starting anyway..."
    fi
    sleep 2
done

# Re-run package:discover at runtime when .env with APP_KEY is available
cd /var/www/freescout
php artisan package:discover 2>/dev/null || true

# Laravel scheduler cron (runs every minute)
echo "* * * * * www-data cd /var/www/freescout && php artisan schedule:run >> /dev/null 2>&1" \
    > /etc/cron.d/freescout-scheduler
echo "" >> /etc/cron.d/freescout-scheduler
chmod 0644 /etc/cron.d/freescout-scheduler
crontab -u www-data /dev/null 2>/dev/null || true

# Start cron daemon in background
/usr/sbin/cron

# Queue worker for email processing (background)
su -s /bin/bash www-data -c \
    "cd /var/www/freescout && php artisan queue:work --sleep=3 --tries=3 --timeout=60 --daemon" &
echo "Queue worker started (PID: $!)"

exec "$@"
ENTRYPOINT

# ── 4d. .env for FreeScout (Laravel) ─────────────────────────────────────────
cat > .env.freescout <<EOF
APP_URL=http://${FREESCOUT_DOMAIN}
APP_ENV=production
APP_DEBUG=false
APP_KEY=

DB_CONNECTION=mysql
DB_HOST=db
DB_PORT=3306
DB_DATABASE=freescout
DB_USERNAME=freescout
DB_PASSWORD=${DB_PASSWORD}
EOF

# ── 4e. docker-compose.yml ───────────────────────────────────────────────────
cat > docker-compose.yml <<EOF
services:
  freescout:
    build:
      context: .
      args:
        FREESCOUT_VERSION: "${FREESCOUT_VERSION}"
    container_name: freescout-app
    ports:
      - "80:80"
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - ./.env.freescout:/var/www/freescout/.env
      - freescout-storage:/var/www/freescout/storage
    mem_limit: 512m
    memswap_limit: 512m
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped

  db:
    image: mariadb:10.11
    container_name: freescout-db
    command: >
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
    environment:
      MYSQL_ROOT_PASSWORD: "${DB_ROOT_PASSWORD}"
      MYSQL_DATABASE: "freescout"
      MYSQL_USER: "freescout"
      MYSQL_PASSWORD: "${DB_PASSWORD}"
    volumes:
      - freescout-db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mariadb", "-ufreescout", "-p${DB_PASSWORD}", "-e", "SELECT 1", "freescout"]
      interval: 10s
      timeout: 5s
      retries: 15
      start_period: 60s
    mem_limit: 512m
    memswap_limit: 512m
    stop_grace_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    restart: unless-stopped

volumes:
  freescout-db:
  freescout-storage:
EOF

info "All deployment files generated."

###############################################################################
# 5. Build & start containers
###############################################################################
show_progress "Building and starting containers"
info "Building Docker image (this may take a few minutes) …"
run_quiet "Docker image build" docker compose build --progress=plain

info "Starting containers …"
run_quiet "Start containers" docker compose up -d

###############################################################################
# 6. Wait for DB & run FreeScout setup
###############################################################################
show_progress "Bootstrapping FreeScout"
info "Waiting for database to be ready …"

DB_MAX_RETRIES=90
RETRY_INTERVAL=5
for i in $(seq 1 $DB_MAX_RETRIES); do
    DB_HEALTH=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' freescout-db 2>/dev/null || echo "unknown")
    if [[ "${DB_HEALTH}" == "healthy" ]]; then
        info "Database container is healthy."
        break
    fi
    if [[ $i -eq $DB_MAX_RETRIES ]]; then
        warn "Database health status: ${DB_HEALTH}"
        docker compose logs --tail=80 db || true
        die "Database did not become healthy after $((DB_MAX_RETRIES * RETRY_INTERVAL)) seconds."
    fi
    sleep $RETRY_INTERVAL
done

# Verify app-side database connectivity using direct mariadb client
info "Verifying application database access …"
APP_DB_MAX_RETRIES=30
for i in $(seq 1 $APP_DB_MAX_RETRIES); do
    if docker compose exec -T db mariadb -ufreescout -p"${DB_PASSWORD}" -e "SELECT 1" freescout &>/dev/null; then
        info "Database user and schema are ready."
        break
    fi
    if [[ $i -eq $APP_DB_MAX_RETRIES ]]; then
        docker compose logs --tail=80 db || true
        die "Database user/schema not ready after $((APP_DB_MAX_RETRIES * RETRY_INTERVAL)) seconds."
    fi
    sleep $RETRY_INTERVAL
done

run_quiet "Generate application key" docker compose exec -T freescout php artisan key:generate --force

# Verify APP_KEY was written to .env file
APP_KEY_CHECK=$(grep -c "^APP_KEY=base64:" "${INSTALL_DIR}/.env.freescout" 2>/dev/null || echo "0")
if [[ "${APP_KEY_CHECK}" -eq 0 ]]; then
    die "APP_KEY was not written to .env.freescout. Check file permissions on ${INSTALL_DIR}/.env.freescout"
fi
info "Application key generated and verified."

run_quiet "Run database migrations" docker compose exec -T freescout php artisan migrate --force

info "Creating admin user …"
docker compose exec -T freescout php artisan freescout:create-user \
    --role=admin \
    --email="${ADMIN_EMAIL}" \
    --password="${ADMIN_PASSWORD}" \
    --firstName="Admin" \
    --lastName="User" 2>/dev/null || {
    warn "Could not auto-create admin user via artisan."
    warn "You can create one manually at: http://${FREESCOUT_DOMAIN}/install"
}

run_quiet "Clear config cache" docker compose exec -T freescout php artisan config:clear
run_quiet "Clear view cache" docker compose exec -T freescout php artisan view:clear
run_quiet "Clear route cache" docker compose exec -T freescout php artisan route:clear

run_quiet "Restart FreeScout container" docker compose restart freescout
sleep 5

###############################################################################
# 7. Save credentials & print summary
###############################################################################
show_progress "Saving credentials and summary"
cat > "${INSTALL_DIR}/credentials.txt" <<EOF
=== FreeScout Credentials ===
Generated: $(date)

URL:            http://${FREESCOUT_DOMAIN}
Admin Email:    ${ADMIN_EMAIL}
Admin Password: (the password you entered during install)

Database Host:       db (internal Docker network)
Database Name:       freescout
Database User:       freescout
Database Password:   ${DB_PASSWORD}
DB Root Password:    ${DB_ROOT_PASSWORD}

Install Directory:   ${INSTALL_DIR}
FreeScout Version:   ${FREESCOUT_VERSION}
EOF
chmod 600 "${INSTALL_DIR}/credentials.txt"

echo ""
echo "==========================================================="
info "FreeScout installation complete!"
echo "==========================================================="
echo ""
echo "  URL:          http://${FREESCOUT_DOMAIN}"
echo "  Admin email:  ${ADMIN_EMAIL}"
echo "  Admin pass:   (the password you entered)"
echo ""
echo "  Credentials saved to: ${INSTALL_DIR}/credentials.txt"
echo "  Install log:          ${LOG_FILE}"
echo ""
echo "  Useful commands:"
echo "    cd ${INSTALL_DIR}"
echo "    docker compose ps          # container status"
echo "    docker compose logs -f     # follow logs"
echo "    docker compose down        # stop"
echo "    docker compose up -d       # start"
echo "    docker compose down -v     # stop & DELETE all data"
echo ""
echo "  For HTTPS, consider placing a reverse proxy (e.g., Caddy,"
echo "  nginx, or Traefik) in front of this stack, or use Certbot."
echo ""
echo "==========================================================="

# Final health check
show_progress "Final health check"
info "Verifying FreeScout is accessible …"
sleep 5
HTTP_CODE=$(curl -fsSL -o /dev/null -w "%{http_code}" "http://127.0.0.1" 2>/dev/null || echo "000")
if [[ "${HTTP_CODE}" =~ ^(200|302|301)$ ]]; then
    info "FreeScout is responding (HTTP ${HTTP_CODE})."
else
    warn "FreeScout returned HTTP ${HTTP_CODE}. It may still be starting up."
    warn "Check: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f freescout"
fi
