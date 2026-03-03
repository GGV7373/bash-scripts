#!/usr/bin/env bash
###############################################################################
# install-freescout-docker.sh
#
# Installs Docker and deploys FreeScout in containers
# (PHP 8.1 + Apache  |  MariaDB 10.11)
#
# Target: Ubuntu 24.04 Server
# Usage:  sudo bash install-freescout-docker.sh
###############################################################################

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── Colours / helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

trap 'err "Script failed at line $LINENO. See output above for details."' ERR

INSTALL_DIR="/opt/freescout"

###############################################################################
# 1. Pre-flight checks
###############################################################################
info "Running pre-flight checks …"

[[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."

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

# Check internet
if ! ping -c1 -W3 google.com &>/dev/null; then
    die "No internet connectivity. Please check your network."
fi

###############################################################################
# 2. Interactive prompts
###############################################################################
echo ""
info "=== FreeScout Docker Installer ==="
echo ""

# Domain / IP
DEFAULT_IP=$(hostname -I | awk '{print $1}')
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

# Database passwords
# Reuse existing credentials when re-running installer so persistent DB volumes
# keep working with the same authentication details.
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
info "Installing Docker …"

# Skip Docker installation if already installed
if command -v docker &> /dev/null && docker compose version &> /dev/null; then
    info "Docker and Docker Compose already installed. Skipping installation."
else
    # Remove old / conflicting packages
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        apt-get remove -y "$pkg" 2>/dev/null || true
    done

    apt-get update
    apt-get upgrade -y -o Dpkg::Options::="--force-confnew"
    apt-get install -y ca-certificates curl gnupg

    # Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    # Docker repo
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable --now docker

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
info "Setting up FreeScout under ${INSTALL_DIR} …"

mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# Remove previous stack and volumes if fresh install was chosen
if [[ "${FRESH_INSTALL}" =~ ^[Yy]$ ]]; then
    if [[ -f docker-compose.yml ]]; then
        info "Removing previous FreeScout containers and volumes (old database will be deleted) …"
        docker compose down -v --remove-orphans 2>/dev/null || true
    fi
fi

# ── 4a. Dockerfile ───────────────────────────────────────────────────────────
cat > Dockerfile <<'DOCKERFILE'
FROM php:8.1-apache-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# OS dependencies
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    libpng-dev libjpeg62-turbo-dev libfreetype6-dev \
    libxml2-dev libzip-dev libonig-dev \
    cron git \
    && rm -rf /var/lib/apt/lists/*

# PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg
RUN docker-php-ext-install -j "$(nproc)" bcmath
RUN docker-php-ext-install -j "$(nproc)" exif
RUN docker-php-ext-install -j "$(nproc)" gd
RUN docker-php-ext-install -j "$(nproc)" mbstring
RUN docker-php-ext-install -j "$(nproc)" opcache
RUN docker-php-ext-install -j "$(nproc)" pdo_mysql
RUN docker-php-ext-install -j "$(nproc)" xml
RUN docker-php-ext-install -j "$(nproc)" zip

# Apache modules
RUN a2enmod rewrite headers

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Clone FreeScout
RUN git clone --depth 1 \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
    https://github.com/freescout-helpdesk/freescout.git /var/www/freescout
RUN rm -rf /var/www/html && ln -s /var/www/freescout/public /var/www/html

WORKDIR /var/www/freescout
RUN composer install --no-dev --no-interaction --prefer-dist --optimize-autoloader \
    && (php artisan clear-compiled 2>/dev/null || true)
RUN php artisan package:discover --ansi 2>/dev/null || true
RUN chown -R www-data:www-data /var/www/freescout
RUN find /var/www/freescout -type d -exec chmod 755 {} \;
RUN find /var/www/freescout -type f -exec chmod 644 {} \;

# Apache vhost
COPY freescout.conf /etc/apache2/sites-available/000-default.conf

# PHP production settings
RUN { \
    echo 'opcache.enable=1'; \
    echo 'opcache.memory_consumption=256'; \
    echo 'opcache.max_accelerated_files=20000'; \
    echo 'opcache.validate_timestamps=0'; \
    echo 'upload_max_filesize=20M'; \
    echo 'post_max_size=25M'; \
    echo 'memory_limit=256M'; \
    echo 'max_execution_time=120'; \
} > /usr/local/etc/php/conf.d/freescout.ini

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /var/www/freescout
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
set -e

# Fix storage permissions on every start
chown -R www-data:www-data /var/www/freescout/storage
chmod -R 775 /var/www/freescout/storage

# Ensure bootstrap/cache is writable
chown -R www-data:www-data /var/www/freescout/bootstrap/cache
chmod -R 775 /var/www/freescout/bootstrap/cache

# Laravel scheduler cron (runs every minute)
echo "* * * * * www-data cd /var/www/freescout && php artisan schedule:run >> /dev/null 2>&1" \
    > /etc/cron.d/freescout-scheduler
chmod 0644 /etc/cron.d/freescout-scheduler
crontab -u www-data /dev/null 2>/dev/null || true

# Start cron daemon in background
service cron start 2>/dev/null || true

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
    build: .
    container_name: freescout-app
    ports:
      - "80:80"
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - ./.env.freescout:/var/www/freescout/.env
      - freescout-storage:/var/www/freescout/storage
    restart: unless-stopped

  db:
    image: mariadb:10.11
    container_name: freescout-db
    environment:
      MYSQL_ROOT_PASSWORD: "${DB_ROOT_PASSWORD}"
      MYSQL_DATABASE: "freescout"
      MYSQL_USER: "freescout"
      MYSQL_PASSWORD: "${DB_PASSWORD}"
    volumes:
      - freescout-db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    restart: unless-stopped

volumes:
  freescout-db:
  freescout-storage:
EOF

info "All deployment files generated."

###############################################################################
# 5. Build & start containers
###############################################################################
info "Building Docker image (this may take a few minutes) …"
docker compose build

info "Starting containers …"
docker compose up -d

info "Checking PHP tokenizer extension …"
if docker compose exec -T freescout php -m | grep -qi '^tokenizer$'; then
    info "PHP extension 'tokenizer' is enabled."
else
    warn "PHP extension 'tokenizer' is NOT enabled."
    warn "If FreeScout errors mention tokenizer, add it in Dockerfile and rebuild:"
    warn "  RUN docker-php-ext-install -j \"\$(nproc)\" tokenizer"
fi

###############################################################################
# 6. Wait for DB & run FreeScout setup
###############################################################################
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
    echo -n "."
    sleep $RETRY_INTERVAL
done

APP_DB_MAX_RETRIES=30
for i in $(seq 1 $APP_DB_MAX_RETRIES); do
    if docker compose exec -T freescout php artisan tinker --execute="DB::connection()->getPdo(); echo 'OK';" 2>/dev/null | grep -q "OK"; then
        info "FreeScout can connect to database."
        break
    fi
    if [[ $i -eq $APP_DB_MAX_RETRIES ]]; then
        docker compose logs --tail=80 freescout || true
        die "FreeScout could not connect to database after $((APP_DB_MAX_RETRIES * RETRY_INTERVAL)) seconds."
    fi
    echo -n "."
    sleep $RETRY_INTERVAL
done

info "Generating application key …"
docker compose exec -T freescout php artisan key:generate --force

info "Running database migrations …"
docker compose exec -T freescout php artisan migrate --force

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

info "Clearing caches …"
docker compose exec -T freescout php artisan config:cache
docker compose exec -T freescout php artisan view:cache

###############################################################################
# 7. Save credentials & print summary
###############################################################################
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
echo ""
echo "  Useful commands:"
echo "    cd ${INSTALL_DIR}"
echo "    docker compose ps          # container status"
echo "    docker compose logs -f     # follow logs"
echo "    docker compose down        # stop"
echo "    docker compose up -d       # start"
echo "    docker compose down -v     # stop & DELETE all data"
echo ""
echo "==========================================================="
