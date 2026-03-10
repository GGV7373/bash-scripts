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

# Guard against accidental execution with sh/dash
if [[ -z "${BASH_VERSION:-}" ]]; then
    echo "ERROR: This installer must be run with bash." >&2
    echo "Use: sudo bash install-freescout-docker.sh" >&2
    exit 1
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check for CRLF line endings early
if od -An -tx1 -N 200 "$0" 2>/dev/null | tr -d ' \n' | grep -q '0d0a'; then
    echo "ERROR: This script has Windows (CRLF) line endings." >&2
    echo "Fix with:  sed -i 's/\r\$//' $0" >&2
    exit 1
fi

# Source library modules
check_line_endings() {
    if od -An -tx1 -N 200 "$0" 2>/dev/null | tr -d ' \n' | grep -q '0d0a'; then
        echo "ERROR: This script has Windows (CRLF) line endings." >&2
        echo "Fix with:  sed -i 's/\r\$//' $0" >&2
        exit 1
    fi
}

# Source library modules
source "${SCRIPT_DIR}/lib/common.sh" || { echo "ERROR: Cannot load lib/common.sh" >&2; exit 1; }
source "${SCRIPT_DIR}/lib/config.sh" || { echo "ERROR: Cannot load lib/config.sh" >&2; exit 1; }
source "${SCRIPT_DIR}/lib/docker-setup.sh" || { echo "ERROR: Cannot load lib/docker-setup.sh" >&2; exit 1; }
source "${SCRIPT_DIR}/lib/deployment-files.sh" || { echo "ERROR: Cannot load lib/deployment-files.sh" >&2; exit 1; }
source "${SCRIPT_DIR}/lib/bootstrap.sh" || { echo "ERROR: Cannot load lib/bootstrap.sh" >&2; exit 1; }

# Setup logging
export DEBIAN_FRONTEND=noninteractive
setup_logging
info "FreeScout Docker Installer v${SCRIPT_VERSION}"
info "Logging to ${LOG_FILE}"

# Verify prerequisites
require_root
check_line_endings

# Install base prerequisites if missing
MISSING_APT_PACKAGES=()
command -v curl >/dev/null 2>&1 || MISSING_APT_PACKAGES+=(curl)
command -v openssl >/dev/null 2>&1 || MISSING_APT_PACKAGES+=(openssl)
command -v awk >/dev/null 2>&1 || MISSING_APT_PACKAGES+=(gawk)
command -v ss >/dev/null 2>&1 || MISSING_APT_PACKAGES+=(iproute2)
command -v timeout >/dev/null 2>&1 || MISSING_APT_PACKAGES+=(coreutils)

if (( ${#MISSING_APT_PACKAGES[@]} > 0 )); then
    warn "Installing missing prerequisites: ${MISSING_APT_PACKAGES[*]}"
    apt-get update >/dev/null
    apt-get install -y ca-certificates "${MISSING_APT_PACKAGES[@]}" >/dev/null
fi

# ──────────────────────────────────────────────────────────────────────────
# Main installation flow
# ──────────────────────────────────────────────────────────────────────────

run_preflight_checks
get_user_config
install_docker
configure_docker_user
generate_all_files
bootstrap_freescout
save_credentials
print_summary
check_final_health
