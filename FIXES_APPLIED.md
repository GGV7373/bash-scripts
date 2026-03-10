# Docker Build Fixes - Final Summary

## Issues Fixed

### Issue 1: Bash Variables Not Expanded in Dockerfile Generation

**Problem**: The `${PHP_VERSION}` variable was being escaped in the heredoc, preventing bash from expanding it to the actual value (8.2).

**Symptom**: Docker build error: `failed to parse stage name "php:-apache-bookworm": invalid reference format`

**Root Cause**: Using escaped bash variables `\${PHP_VERSION}` in an unquoted heredoc converted them to literal `${PHP_VERSION}`, which Docker doesn't understand as a valid base image.

**Files Modified**: `lib/deployment-files.sh`

**Changes Made**:
1. Line 29: `FROM php:\${PHP_VERSION}-apache-bookworm` → `FROM php:${PHP_VERSION}-apache-bookworm`
2. Line 45: `"\$(nproc)"` → `"$(nproc)"`
3. Lines 47, 49, 50: Removed escaping from `$(curl ...)` and `${EXPECTED_CHECKSUM}`, `${ACTUAL_CHECKSUM}`
4. Line 58: `ARG FREESCOUT_VERSION=\${FREESCOUT_VERSION}` → `ARG FREESCOUT_VERSION=${FREESCOUT_VERSION}`
5. Lines 60, 64: Removed escaping from `${FREESCOUT_VERSION}` in git clone command

**Variables Now Properly Expanded**:
- `${PHP_VERSION}` → expands to `8.2`
- `${FREESCOUT_VERSION}` → expands to version like `1.8.208`
- `$(nproc)` → expands to number of processors
- `$(curl ...)` → expands to checksum value

### Issue 2: Docker Variables Escaped Correctly

**Variables Kept Escaped** (for Docker container execution):
- `\${attempt}` → stays as `${attempt}` in Dockerfile → expanded by Docker's shell at runtime

**Variables Already Properly Escaped** (single-quoted PHP code):
- `\$f`, `\$raw`, `\$entry`, etc. → stay escaped in single quotes → available for PHP code

### Issue 3: Docker Compose Warning - Progress Flag Position

**Problem**: `docker compose build --progress=plain` generates warning about `--progress` being a global flag.

**Solution**: Moved flag before subcommand: `docker compose --progress=plain build`

**Files Modified**: `lib/bootstrap.sh`

**Changes Made**: Line 9: `docker compose build --progress=plain` → `docker compose --progress=plain build`

## Verification

All scripts pass syntax validation:
- ✓ install-freescout-docker.sh
- ✓ lib/bootstrap.sh
- ✓ lib/common.sh
- ✓ lib/config.sh
- ✓ lib/deployment-files.sh
- ✓ lib/docker-setup.sh

## Testing

The updated scripts are ready to deploy:

```bash
cd ~/bash-scripts
sudo bash install-freescout-docker.sh
```

Expected behavior:
1. Dockerfile generation will have correct `FROM php:8.2-apache-bookworm`
2. Docker build will proceed without "invalid reference format" error
3. Docker Compose progress warning will not appear
4. Installation should complete successfully

## Technical Explanation

### Bash Heredoc Variable Expansion Rules

**Unquoted heredoc** (`<<TAG`):
- Bash expands variables: `${VAR}`, `$(command)`, backticks
- Allows control flow and variable substitution

**Quoted heredoc** (`<<'TAG'`):
- Bash treats everything literally - no expansion
- Used when you want literal variable syntax

**Escaping in Heredocs**:
- `\${VAR}` in unquoted heredoc → becomes literal `${VAR}` (needs escaping if you don't want expansion)
- `${VAR}` in unquoted heredoc → expanded to variable value (for bash variables)
- `\$` → becomes literal `$` when processed by bash
- Everything in single quotes is literal to the shell context it's evaluated in

### Our Use Case

The Dockerfile heredoc needs:
1. **Bash variables expanded** (once at generation time): `${PHP_VERSION}`, `${FREESCOUT_VERSION}`
2. **Docker variables escaped** (for runtime expansion): `\${attempt}` (for Docker's shell)
3. **PHP variables escaped** (for PHP): `\$f`, `\$entry` (inside single-quoted PHP code)

Solution: Use unquoted heredoc with selective escaping:
- NO escape on bash variables that should be expanded immediately
- YES escape on variables that need runtime expansion by Docker/PHP
