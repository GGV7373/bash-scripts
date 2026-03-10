#!/usr/bin/env bash
###############################################################################
# lib/common.sh - Shared utilities and logging functions
###############################################################################

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# ── Colours and logging utilities ─────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { err "$@"; exit 1; }

# ── Progress tracking ────────────────────────────────────────────────────
TOTAL_PHASES=8
CURRENT_PHASE=0

show_progress() {
    local label="$1"
    local percent filled empty bar_fill bar_empty
    ((++CURRENT_PHASE))
    percent=$(( CURRENT_PHASE * 100 / TOTAL_PHASES ))
    filled=$(( percent / 5 ))
    empty=$(( 20 - filled ))
    printf -v bar_fill '%*s' "${filled}" ''
    printf -v bar_empty '%*s' "${empty}" ''
    bar_fill=${bar_fill// /#}
    bar_empty=${bar_empty// /-}
    info "Progress [${bar_fill}${bar_empty}] ${percent}% (${CURRENT_PHASE}/${TOTAL_PHASES}) - ${label}"
}

# ── Curl helpers ────────────────────────────────────────────────────────
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

download_file() {
    local url="$1"
    local output="$2"
    curl "${CURL_COMMON_OPTS[@]}" --output "${output}" "${url}"
}

# ── Command execution helpers ────────────────────────────────────────────
# Run a command quietly and report timing
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

# ── Check if running as root ────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

# ── Detect CRLF line endings ────────────────────────────────────────────
check_line_endings() {
    if od -An -tx1 -N 200 "$0" 2>/dev/null | tr -d ' \n' | grep -q '0d0a'; then
        echo "ERROR: This script has Windows (CRLF) line endings." >&2
        echo "Fix with:  sed -i 's/\r\$//' $0" >&2
        exit 1
    fi
}

# ── Verify required tools ────────────────────────────────────────────────
require_commands() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "Required command '${cmd}' not found."
    done
}

# ── Setup logging to file ────────────────────────────────────────────────
setup_logging() {
    LOG_FILE="/var/log/freescout-install-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    trap 'err "Script failed at line $LINENO. See output above or ${LOG_FILE} for details."; sync' ERR
}

export LOG_FILE
