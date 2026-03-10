#!/usr/bin/env bash
###############################################################################
# lib/deployment-files.sh - Generate deployment files
###############################################################################

backup_existing_db() {
    if [[ "${FRESH_INSTALL}" =~ ^[Yy]$ ]]; then
        if [[ -f docker-compose.yml ]]; then
            if docker compose ps --quiet db 2>/dev/null | grep -q .; then
                local backup_file
                backup_file="${INSTALL_DIR}/freescout-backup-$(date +%Y%m%d-%H%M%S).sql"
                info "Attempting to backup existing database to ${backup_file} …"
                if docker compose exec -T db mariadb-dump -uroot -p"${DB_ROOT_PASSWORD}" --all-databases > "${backup_file}" 2>/dev/null; then
                    chmod 600 "${backup_file}"
                    info "Database backed up to ${backup_file}"
                else
                    warn "Could not backup existing database. Proceeding with fresh install."
                    rm -f "${backup_file}"
                fi
            fi
            info "Removing previous FreeScout containers and volumes (old database will be deleted) …"
            docker compose down -v --remove-orphans >/dev/null 2>&1 || true
        fi
    fi
}

generate_dockerfile() {
    cat > Dockerfile <<DOCKERFILE
FROM php:${PHP_VERSION}-apache-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# OS dependencies (including unzip for Composer, imap libs for email)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpng-dev libjpeg62-turbo-dev libfreetype6-dev \
    libxml2-dev libzip-dev libonig-dev \
    libcurl4-openssl-dev \
    libc-client-dev libkrb5-dev \
    cron git unzip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# PHP extensions (including imap for email fetching) & Composer
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-configure imap --with-kerberos --with-imap-ssl \
    && docker-php-ext-install -j "\$(nproc)" \
       bcmath exif gd imap mbstring opcache pdo_mysql xml zip \
    && EXPECTED_CHECKSUM="\$(curl -fsSL --connect-timeout 15 --max-time 120 --retry 5 --retry-delay 2 --retry-all-errors https://composer.github.io/installer.sig)" \
    && curl -fsSL --connect-timeout 15 --max-time 120 --retry 5 --retry-delay 2 --retry-all-errors https://getcomposer.org/installer -o /tmp/composer-setup.php \
    && ACTUAL_CHECKSUM="\$(sha384sum /tmp/composer-setup.php | cut -d ' ' -f 1)" \
    && [ "\${EXPECTED_CHECKSUM}" = "\${ACTUAL_CHECKSUM}" ] \
    && php /tmp/composer-setup.php --install-dir=/usr/bin --filename=composer \
    && rm -f /tmp/composer-setup.php

# Apache modules
RUN a2enmod rewrite headers

# Clone FreeScout (pinned version, with retry logic)
ARG FREESCOUT_VERSION=${FREESCOUT_VERSION}
RUN for attempt in 1 2 3; do \
        git clone --depth 1 --branch "${FREESCOUT_VERSION}" \
            -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 \
            https://github.com/freescout-helpdesk/freescout.git /var/www/freescout \
        && break || { \
            echo "Git clone attempt \${attempt} failed, retrying in 10s..."; \
            rm -rf /var/www/freescout; \
            sleep 10; \
        }; \
    done && [ -d /var/www/freescout ]

WORKDIR /var/www/freescout

# Install PHP dependencies
RUN COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_MEMORY_LIMIT=-1 \
    composer install --no-dev --no-interaction \
        --prefer-dist --no-scripts --no-autoloader \
        --ignore-platform-req=php \
    && composer clear-cache

# Fix missing classmap paths (case-mismatch symlinks or empty placeholders)
# Composer 2 reads autoload entries from installed.json, so we fix the
# filesystem instead of patching JSON files.
RUN php -r '\$todo=[];\$ij="vendor/composer/installed.json";if(file_exists(\$ij)){\$i=json_decode(file_get_contents(\$ij),true);foreach((\$i["packages"]??[]) as \$pkg){\$n=\$pkg["name"]??"";if(\$n==="")continue;\$d="vendor/".\$n;if(!is_dir(\$d))continue;\$cm=\$pkg["autoload"]["classmap"]??[];if(!is_array(\$cm))continue;foreach(\$cm as \$p){\$p=rtrim((string)\$p,"/");if(\$p!==""){\$todo[\$d."/".\$p]=1;}}}}foreach(glob("vendor/*/*/composer.json")?:[] as \$f){\$c=json_decode(file_get_contents(\$f),true);if(!is_array(\$c))continue;\$d=dirname(\$f);\$cm=\$c["autoload"]["classmap"]??[];if(!is_array(\$cm))continue;foreach(\$cm as \$p){\$p=rtrim((string)\$p,"/");if(\$p!==""){\$todo[\$d."/".\$p]=1;}}}foreach(array_keys(\$todo) as \$full){if(file_exists(\$full))continue;\$parent=dirname(\$full);\$base=basename(\$full);\$fixed=false;if(is_dir(\$parent)){foreach(scandir(\$parent)?:[] as \$e){if(\$e==="."||\$e==="..")continue;if(strtolower(\$e)===strtolower(\$base)){@symlink(\$e,\$full);echo"Symlinked: \$full -> \$e\n";\$fixed=true;break;}}}if(!\$fixed){@mkdir(\$full,0755,true);echo"Created placeholder: \$full\n";}}' \
    && COMPOSER_ALLOW_SUPERUSER=1 composer dump-autoload --no-dev

RUN COMPOSER_ALLOW_SUPERUSER=1 php artisan package:discover --ansi 2>&1 || true

# Set ownership and permissions
RUN chown -R www-data:www-data /var/www/freescout \
    && chmod -R u=rwX,g=rX,o=rX /var/www/freescout

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

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]
DOCKERFILE
}

generate_apache_config() {
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
}

generate_entrypoint() {
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
if [ ! -f /var/www/freescout/.env ]; then
    echo "ERROR: .env file not found at /var/www/freescout/.env"
    exit 1
fi
DB_PASSWORD=$(grep '^DB_PASSWORD=' /var/www/freescout/.env | cut -d= -f2)
if [ -z "$DB_PASSWORD" ]; then
    echo "ERROR: DB_PASSWORD not found in .env file"
    exit 1
fi
echo "Waiting for database connection..."
for i in $(seq 1 60); do
    if DB_PASSWORD="$DB_PASSWORD" php -r 'new PDO("mysql:host=db;port=3306;dbname=freescout", "freescout", getenv("DB_PASSWORD"));' 2>/dev/null; then
        echo "Database connection established."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "WARNING: Could not connect to database after 60 attempts. Starting anyway..."
    fi
    sleep 2
done

# Re-run package:discover at runtime
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
}

generate_env_file() {
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
}

generate_docker_compose() {
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
      test: ["CMD", "bash", "-c", "mariadb -ufreescout -p\$\$MYSQL_PASSWORD -e 'SELECT 1' freescout"]
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
}

generate_all_files() {
    show_progress "Generating deployment files"
    info "Setting up FreeScout under ${INSTALL_DIR} …"

    # Validate required variables
    local required_vars=(FREESCOUT_DOMAIN PHP_VERSION FREESCOUT_VERSION DB_ROOT_PASSWORD DB_PASSWORD)
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            die "Required variable '$var' is not set. Cannot generate deployment files."
        fi
    done

    mkdir -p "${INSTALL_DIR}"
    cd "${INSTALL_DIR}"

    backup_existing_db
    generate_dockerfile
    generate_apache_config
    generate_entrypoint
    generate_env_file
    generate_docker_compose

    info "All deployment files generated."
}

export -f generate_all_files backup_existing_db
