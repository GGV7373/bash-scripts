#!/usr/bin/env bash
###############################################################################
# lib/docker-setup.sh - Docker Engine and Compose installation
###############################################################################

install_docker() {
    show_progress "Installing Docker runtime"
    info "Installing Docker …"

    # Skip Docker installation if already installed
    if command -v docker &> /dev/null && docker compose version &> /dev/null; then
        info "Docker and Docker Compose already installed. Skipping installation."
        return 0
    fi

    # Remove old / conflicting packages (with timeout to prevent hangs)
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        timeout 30 apt-get remove -y "$pkg" 2>/dev/null || true
    done

    run_quiet "APT update (Docker prerequisites)" apt-get update
    run_quiet "Install Docker prerequisites" apt-get install -y ca-certificates curl

    # Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    rm -f /etc/apt/keyrings/docker.asc
    run_quiet "Download Docker GPG key" download_file https://download.docker.com/linux/ubuntu/gpg /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    if [[ ! -s /etc/apt/sources.list.d/docker.list ]]; then
        die "Failed to create Docker APT repository file."
    fi

    run_quiet "APT update (Docker repository)" apt-get update

    # Verify docker-ce package is available
    if ! apt-cache show docker-ce &>/dev/null; then
        die "docker-ce package not found. Docker APT repository may not be configured correctly."
    fi

    run_quiet "Install Docker Engine and Compose" apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    run_quiet "Enable and start Docker service" systemctl enable --now docker

    # Verify Docker daemon is running
    if ! docker info &>/dev/null; then
        die "Docker installed but daemon is not responding. Check: systemctl status docker"
    fi

    info "Docker installed successfully."
}

configure_docker_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        usermod -aG docker "$SUDO_USER" 2>/dev/null || true
        info "Added user '${SUDO_USER}' to docker group (re-login to take effect)."
    fi
}

export -f install_docker configure_docker_user
