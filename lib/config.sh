#!/usr/bin/env bash
###############################################################################
# lib/config.sh - Configuration management and interactive prompts
###############################################################################

# ── Configuration constants ──────────────────────────────────────────────
SCRIPT_VERSION="3.0.0"
INSTALL_DIR="/opt/freescout"
PHP_VERSION="8.2"
FREESCOUT_VERSION="latest"

# ── Resolve FreeScout version from GitHub ────────────────────────────────
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

# ── Preflight checks ─────────────────────────────────────────────────────
check_os() {
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
}

check_internet() {
    if ! curl "${CURL_COMMON_OPTS[@]}" --max-time 15 -o /dev/null https://www.google.com 2>/dev/null && \
        ! curl "${CURL_COMMON_OPTS[@]}" --max-time 15 -o /dev/null https://github.com 2>/dev/null; then
        die "No internet connectivity. Please check your network."
    fi
}

check_disk_space() {
    local required_mb=4000
    local available_mb
    available_mb=$(df -BM --output=avail / | tail -1 | tr -d ' M')
    if [[ "${available_mb}" -lt "${required_mb}" ]]; then
        die "Insufficient disk space. Need ${required_mb}MB, have ${available_mb}MB free."
    fi
    info "Disk space check passed (${available_mb}MB available)."
}

check_port_80() {
    if ss -tlnp 2>/dev/null | grep -q ':80 '; then
        local port80_info
        port80_info=$(ss -tlnp 2>/dev/null | grep ':80 ' | head -1)
        warn "Port 80 is already in use:"
        warn "  ${port80_info}"
        die "Stop the conflicting service or change the port mapping before running this script."
    fi
    info "Port 80 is available."
}

run_preflight_checks() {
    info "Running pre-flight checks …"
    show_progress "Pre-flight checks"

    require_commands curl openssl awk ss timeout
    check_os
    check_internet
    check_disk_space
    check_port_80

    FREESCOUT_VERSION=$(resolve_freescout_version "${FREESCOUT_VERSION}") || \
        die "Could not resolve a valid FreeScout release version from GitHub API."
    info "Using FreeScout version: ${FREESCOUT_VERSION}"
}

# ── Interactive configuration ────────────────────────────────────────────
get_user_config() {
    show_progress "Collecting configuration"
    echo ""
    info "=== FreeScout Docker Installer v${SCRIPT_VERSION} ==="
    echo ""

    # Domain / IP
    local default_ip
    default_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    default_ip="${default_ip:-127.0.0.1}"
    read -rp "Enter domain or IP for FreeScout [${default_ip}]: " FREESCOUT_DOMAIN
    FREESCOUT_DOMAIN="${FREESCOUT_DOMAIN:-$default_ip}"

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

    export FREESCOUT_DOMAIN ADMIN_EMAIL ADMIN_PASSWORD
    export DB_ROOT_PASSWORD DB_PASSWORD FRESH_INSTALL
}

export SCRIPT_VERSION INSTALL_DIR PHP_VERSION FREESCOUT_VERSION
