# FreeScout Docker Installer - Modular Architecture

This is a refactored version of the FreeScout Docker installation script, broken down into smaller, manageable modules for better maintainability and reusability.

## Directory Structure

```
.
├── install-freescout-docker.sh    # Main orchestrator script (entry point)
└── lib/
    ├── common.sh                  # Shared utilities and logging
    ├── config.sh                  # Configuration and preflight checks
    ├── docker-setup.sh            # Docker installation and setup
    ├── deployment-files.sh        # Generate Dockerfile and configs
    └── bootstrap.sh               # Database setup and initialization
```

## Module Overview

### `install-freescout-docker.sh` (Main Orchestrator)
The entry point that sources all library modules and orchestrates the installation flow. It's clean and easy to follow:
- Loads all library modules
- Sets up logging
- Runs pre-flight checks
- Calls each installation phase in sequence

**Size**: ~80 lines (down from 746!)

### `lib/common.sh` (185 lines)
Shared utilities used by all modules:
- **Logging**: `info()`, `warn()`, `err()`, `die()`
- **Progress tracking**: `show_progress()`
- **Network utilities**: `download_file()`, curl options
- **Execution**: `run_quiet()` - runs commands and logs timing
- **System checks**: Root verification, CRLF detection, command validation

### `lib/config.sh` (145 lines)
Configuration management and preflight checks:
- **Constants**: `SCRIPT_VERSION`, `INSTALL_DIR`, `PHP_VERSION`, `FREESCOUT_VERSION`
- **GitHub API**: `resolve_freescout_version()`, `resolve_latest_freescout_tag()`
- **Preflight checks**: `check_os()`, `check_internet()`, `check_disk_space()`, `check_port_80()`
- **Interactive setup**: `get_user_config()` - prompts user for domain, email, passwords
- **Configuration validation**: `run_preflight_checks()`

### `lib/docker-setup.sh` (60 lines)
Docker installation and configuration:
- **Installation**: `install_docker()` - installs Docker CE, CLI, and Compose
- **Repository setup**: GPG key download and APT repository configuration
- **User configuration**: `configure_docker_user()` - adds user to docker group
- **Verification**: Checks that Docker daemon is running

### `lib/deployment-files.sh` (240 lines)
Generates all deployment files:
- **Dockerfile**: PHP + Apache with FreeScout dependencies and setup
- **Apache config**: `freescout.conf` - VirtualHost configuration
- **Entrypoint script**: Container startup script with cron and queue workers
- **.env file**: FreeScout Laravel configuration
- **Docker Compose**: Multi-container orchestration (app + database)
- **Backup logic**: `backup_existing_db()` for fresh installs

### `lib/bootstrap.sh` (190 lines)
Database setup and application initialization:
- **Container management**: `build_and_start_containers()`
- **Health checks**: `wait_for_healthy_database()`, `verify_database_access()`
- **Setup commands**: `generate_app_key()`, `run_migrations()`, `create_admin_user()`
- **Cleanup**: `clear_caches()`, `restart_application()`
- **Summary**: `print_summary()`, `save_credentials()`
- **Orchestration**: `bootstrap_freescout()` - calls all steps in order

## Usage

The installation process works exactly as before from the user's perspective:

```bash
sudo bash install-freescout-docker.sh
```

The main script automatically sources all modules and runs them in order:

1. **Preflight checks** (config module)
2. **User prompts** (config module)
3. **Docker installation** (docker-setup module)
4. **File generation** (deployment-files module)
5. **Build and bootstrap** (bootstrap module)
6. **Final checks and summary** (bootstrap module)

## Benefits of This Modular Approach

| Aspect | Before | After |
|--------|--------|-------|
| **Main script size** | 746 lines | 80 lines |
| **Code reusability** | None | Each module can be sourced independently |
| **Testability** | Difficult | Easy - test each function individually |
| **Debuggability** | Monolithic | Clear separation of concerns |
| **Maintenance** | Hard to navigate | Easy to find and modify specific functionality |
| **Documentation** | All mixed together | Each module is focused on one area |

## Examples of Reusing Modules

You can now use these modules in your own scripts:

### Example 1: Just install Docker
```bash
source lib/common.sh
source lib/config.sh
source lib/docker-setup.sh

setup_logging
require_root
install_docker
```

### Example 2: Generate files without installation
```bash
source lib/common.sh
export INSTALL_DIR="/opt/my-freescout"
export PHP_VERSION="8.2"
export FREESCOUT_VERSION="latest"
export FREESCOUT_DOMAIN="example.com"
export DB_PASSWORD="secret123"
export DB_ROOT_PASSWORD="rootsecret"

cd "$INSTALL_DIR"
source lib/deployment-files.sh
generate_all_files
```

### Example 3: Custom installation flow
```bash
source lib/common.sh
source lib/config.sh

# Use only the preflight checks you need
check_os
check_internet
check_disk_space
```

## Sourcing Modules in Other Scripts

All modules are designed to be sourced:

```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/deployment-files.sh"

# Now you can use functions from both modules
info "Starting setup..."
generate_dockerfile
```

## Environment Variables

Required environment variables when sourcing modules:

### For `config.sh`:
- None (sets `SCRIPT_VERSION`, `INSTALL_DIR`, etc.)

### For `deployment-files.sh`:
- `INSTALL_DIR` - Installation directory
- `PHP_VERSION` - PHP version (e.g., "8.2")
- `FREESCOUT_VERSION` - FreeScout version
- `FREESCOUT_DOMAIN` - Domain or IP
- `DB_PASSWORD` - Database password
- `DB_ROOT_PASSWORD` - Root password
- `FRESH_INSTALL` - "Y" or "N"

### For `bootstrap.sh`:
- `ADMIN_EMAIL` - Admin email
- `ADMIN_PASSWORD` - Admin password
- `DB_PASSWORD` - Database password
- `DB_ROOT_PASSWORD` - Root password
- `FREESCOUT_DOMAIN` - Domain or IP

## Adding New Features

To add a new feature, you have two options:

### Option 1: Add to existing module
If it logically fits with existing functionality, add it to the appropriate module's function.

### Option 2: Create a new module
For significant features, create a new module in `lib/`:

```bash
# lib/feature-xyz.sh
my_new_feature() {
    info "Doing something special..."
}

export -f my_new_feature
```

Then source it in the main script:

```bash
source "${SCRIPT_DIR}/lib/feature-xyz.sh"
my_new_feature
```

## Final Notes

- All modules follow the same patterns for logging and error handling
- Functions are exported for reuse in subshells
- Variables are exported to make them available to sourced modules
- The modular structure makes the code easier to test and maintain
- The main script remains clean and easy to understand
