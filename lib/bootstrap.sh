#!/usr/bin/env bash
###############################################################################
# lib/bootstrap.sh - Database setup and FreeScout initialization
###############################################################################

build_and_start_containers() {
    show_progress "Building and starting containers"
    info "Building Docker image (this may take a few minutes) …"
    run_quiet "Docker image build" docker compose --progress=plain build

    info "Starting containers …"
    run_quiet "Start containers" docker compose up -d
}

wait_for_healthy_database() {
    show_progress "Bootstrapping FreeScout"
    info "Waiting for database to be ready …"

    local db_max_retries=90
    local retry_interval=5
    local i db_health

    for i in $(seq 1 $db_max_retries); do
        db_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' freescout-db 2>/dev/null || echo "unknown")
        if [[ "${db_health}" == "healthy" ]]; then
            info "Database container is healthy."
            return 0
        fi
        if [[ $i -eq $db_max_retries ]]; then
            warn "Database health status: ${db_health}"
            docker compose logs --tail=80 db || true
            die "Database did not become healthy after $((db_max_retries * retry_interval)) seconds."
        fi
        sleep $retry_interval
    done
}

verify_database_access() {
    info "Verifying application database access …"
    local app_db_max_retries=30
    local retry_interval=5
    local i

    for i in $(seq 1 $app_db_max_retries); do
        if docker compose exec -T db mariadb -ufreescout -p"${DB_PASSWORD}" -e "SELECT 1" freescout &>/dev/null; then
            info "Database user and schema are ready."
            return 0
        fi
        if [[ $i -eq $app_db_max_retries ]]; then
            docker compose logs --tail=80 db || true
            die "Database user/schema not ready after $((app_db_max_retries * retry_interval)) seconds."
        fi
        sleep $retry_interval
    done
}

generate_app_key() {
    run_quiet "Generate application key" docker compose exec -T freescout php artisan key:generate --force

    # Verify APP_KEY was written
    local app_key_check
    app_key_check=$(grep -c "^APP_KEY=base64:" "${INSTALL_DIR}/.env.freescout" 2>/dev/null || echo "0")
    if [[ "${app_key_check}" -eq 0 ]]; then
        die "APP_KEY was not written to .env.freescout. Check file permissions on ${INSTALL_DIR}/.env.freescout"
    fi
    info "Application key generated and verified."
}

run_migrations() {
    run_quiet "Run database migrations" docker compose exec -T freescout php artisan migrate --force
}

create_admin_user() {
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
}

clear_caches() {
    run_quiet "Clear config cache" docker compose exec -T freescout php artisan config:clear
    run_quiet "Clear view cache" docker compose exec -T freescout php artisan view:clear
    run_quiet "Clear route cache" docker compose exec -T freescout php artisan route:clear
}

restart_application() {
    run_quiet "Restart FreeScout container" docker compose restart freescout
    sleep 5
}

bootstrap_freescout() {
    build_and_start_containers
    wait_for_healthy_database
    verify_database_access
    generate_app_key
    run_migrations
    create_admin_user
    clear_caches
    restart_application
}

check_final_health() {
    show_progress "Final health check"
    info "Verifying FreeScout is accessible …"
    sleep 5
    local http_code
    http_code=$(curl -fsSL -o /dev/null -w "%{http_code}" "http://127.0.0.1" 2>/dev/null || echo "000")
    if [[ "${http_code}" =~ ^(200|302|301)$ ]]; then
        info "FreeScout is responding (HTTP ${http_code})."
    else
        warn "FreeScout returned HTTP ${http_code}. It may still be starting up."
        warn "Check: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f freescout"
    fi
}

save_credentials() {
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
}

print_summary() {
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
}

export -f bootstrap_freescout check_final_health save_credentials print_summary
