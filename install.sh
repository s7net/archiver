#!/bin/bash
# ============================================================
#  Archiver Installer v1.0.4
#  https://github.com/s7net/archiver
#
#  - Installs to ~/bin  (jailed shell / cPanel / DirectAdmin)
#  - Installs to /usr/local/bin  (root / standard Linux)
#  - Prompts before overwriting an existing installation
#  - Checks required and optional dependencies
#  - Adds ~/bin to PATH automatically if needed
# ============================================================

set -uo pipefail

ARCHIVER_VERSION="1.0.4"
REPO_URL="https://raw.githubusercontent.com/s7net/archiver/main/archiver.sh"
SCRIPT_NAME="archiver"

# ── Colors ────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

# ── Helpers ───────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Banner ────────────────────────────────────────────────────
echo -e "
${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}
${BOLD}${CYAN}║        Archiver Installer v${ARCHIVER_VERSION}         ║${NC}
${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}
"

# Parse optional flags
AUTO_YES=false
for arg in "${@:-}"; do
    case "$arg" in
        -y|--yes) AUTO_YES=true ;;
    esac
done

# ── Step 1: Detect privilege level ───────────────────────────
IS_ROOT=false
if [[ "$(id -u)" -eq 0 ]]; then
    IS_ROOT=true
fi

# ── Step 2: Pick install directory & detect existing install ──
if [[ "$IS_ROOT" == "true" ]] && [[ -d /usr/local/bin ]] && [[ -w /usr/local/bin ]]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="${HOME}/bin"
fi

DEST="${INSTALL_DIR}/${SCRIPT_NAME}"

# Detect if archiver is already installed anywhere accessible
EXISTING_PATH=""
if [[ -f "$DEST" ]]; then
    EXISTING_PATH="$DEST"
elif command -v "$SCRIPT_NAME" &>/dev/null; then
    _which_bin="$(command -v "$SCRIPT_NAME" 2>/dev/null || true)"
    if [[ -n "$_which_bin" && -f "$_which_bin" ]]; then
        EXISTING_PATH="$_which_bin"
    fi
elif [[ -f "/usr/local/bin/${SCRIPT_NAME}" ]]; then
    EXISTING_PATH="/usr/local/bin/${SCRIPT_NAME}"
elif [[ -f "${HOME}/bin/${SCRIPT_NAME}" ]]; then
    EXISTING_PATH="${HOME}/bin/${SCRIPT_NAME}"
fi

# If existing installation found and writable, preserve its existing location
IS_UPDATE=false
if [[ -n "$EXISTING_PATH" && -f "$EXISTING_PATH" ]]; then
    IS_UPDATE=true
    if [[ -w "$EXISTING_PATH" || -w "$(dirname "$EXISTING_PATH")" ]]; then
        INSTALL_DIR="$(dirname "$EXISTING_PATH")"
        DEST="$EXISTING_PATH"
    fi
fi

info "Install directory : $INSTALL_DIR"
info "Target            : $DEST"
echo ""

# ── Step 3: Handle Update vs Fresh Install ───────────────────
ARCHIVER_HOME="${HOME}/.archiver"
CONFIGS_DIR="${ARCHIVER_HOME}/configs"
BACKUPS_DIR="${ARCHIVER_HOME}/backups"

EXISTING_CONF_COUNT=0
EXISTING_BACKUP_COUNT=0
if [[ -d "$CONFIGS_DIR" ]]; then
    EXISTING_CONF_COUNT=$(find "$CONFIGS_DIR" -maxdepth 1 -name "*.conf" 2>/dev/null | wc -l | tr -d ' ')
fi
if [[ -d "$BACKUPS_DIR" ]]; then
    EXISTING_BACKUP_COUNT=$(find "$BACKUPS_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
fi

if [[ "$IS_UPDATE" == "true" ]]; then
    EXISTING_VER=$("$EXISTING_PATH" version 2>/dev/null || echo "unknown")
    echo -e "${YELLOW}Existing Archiver installation detected:${NC}"
    echo -e "  Location          : ${BOLD}${EXISTING_PATH}${NC}"
    echo -e "  Installed version : ${BOLD}${EXISTING_VER}${NC}"
    echo -e "  Target version    : ${BOLD}${ARCHIVER_VERSION}${NC}"
    echo ""
    info "Mode: Safe Update"
    info "All existing configurations, backups, logs, and schedules in ~/.archiver will be preserved."
    if [[ "$EXISTING_CONF_COUNT" -gt 0 ]]; then
        info "Found ${EXISTING_CONF_COUNT} existing backup configuration(s) — untouched."
    fi
    echo ""

    # If interactive and not auto-confirmed via -y, give user prompt with default YES
    if [[ "$AUTO_YES" != "true" && -t 0 && -c /dev/tty ]]; then
        if ! read -rp "$(echo -e "${CYAN}?${NC} Update to the latest version? [Y/n]: ")" _confirm </dev/tty; then
            echo -e "\n${YELLOW}Cancelled by user.${NC}"
            exit 130
        fi
        _confirm="${_confirm:-y}"
        if [[ "$_confirm" =~ ^[Nn]$ ]]; then
            echo "Cancelled by user. No changes made."
            exit 0
        fi
        echo ""
    fi
else
    info "Mode: Fresh Installation"
fi

# ── Step 4: Create install directory ─────────────────────────
if [[ ! -d "$INSTALL_DIR" ]]; then
    info "Creating $INSTALL_DIR ..."
    mkdir -p "$INSTALL_DIR" || die "Could not create $INSTALL_DIR"
    [[ "$INSTALL_DIR" == "${HOME}/bin" ]] && chmod 700 "$INSTALL_DIR" 2>/dev/null || true
fi

# ── Step 5: Add ~/bin to PATH if needed ──────────────────────
_ensure_path() {
    local dir="$1"

    if echo "$PATH" | tr ':' '\n' | grep -qxF "$dir"; then
        return 0
    fi

    warn "$dir is not in your PATH."

    local current_shell
    current_shell=$(basename "${SHELL:-sh}")
    local shell_rc
    case "$current_shell" in
        bash) shell_rc="${HOME}/.bashrc"  ;;
        zsh)  shell_rc="${HOME}/.zshrc"   ;;
        *)    shell_rc="${HOME}/.profile" ;;
    esac

    if [[ -f "$shell_rc" ]] && grep -qF 'HOME/bin' "$shell_rc" 2>/dev/null; then
        info "PATH entry already present in $shell_rc — re-login may be needed."
        return 0
    fi

    info "Adding $dir to PATH in $shell_rc ..."
    {
        echo ""
        echo "# Added by Archiver installer"
        echo 'export PATH="$HOME/bin:$PATH"'
    } >> "$shell_rc"

    success "PATH updated in $shell_rc"
    warn "Run  ${BOLD}source $shell_rc${NC}  or open a new terminal to activate."
}

if [[ "$INSTALL_DIR" == "${HOME}/bin" ]]; then
    _ensure_path "$INSTALL_DIR"
    echo ""
fi

# ── Step 6: Atomic Download or copy via staging file ──────────
TMP_DEST="${INSTALL_DIR}/.${SCRIPT_NAME}.tmp.$$$RANDOM"
cleanup_staging() {
    rm -f "$TMP_DEST" 2>/dev/null || true
}
on_install_interrupt() {
    trap - INT TERM EXIT
    cleanup_staging
    echo -e "\n${YELLOW}[CANCELLED] Installation cancelled by user.${NC}" >&2
    exit 130
}
trap cleanup_staging EXIT
trap on_install_interrupt INT TERM

_get_github_raw_url() {
    local file="${1:-archiver.sh}"
    local sha=""
    if command -v curl &>/dev/null; then
        sha=$(curl -fsSL -H "Accept: application/vnd.github.v3+json" -H "Cache-Control: no-cache" --max-time 5 "https://api.github.com/repos/s7net/archiver/commits/main" 2>/dev/null | grep -m1 '"sha":' | cut -d'"' -f4 || true)
    elif command -v wget &>/dev/null; then
        sha=$(wget -qO- --header="Accept: application/vnd.github.v3+json" --header="Cache-Control: no-cache" --timeout=5 "https://api.github.com/repos/s7net/archiver/commits/main" 2>/dev/null | grep -m1 '"sha":' | cut -d'"' -f4 || true)
    fi
    if [[ -n "$sha" && ${#sha} -ge 40 ]]; then
        echo "https://raw.githubusercontent.com/s7net/archiver/${sha}/${file}"
    else
        echo "https://raw.githubusercontent.com/s7net/archiver/main/${file}"
    fi
}

_download_or_copy() {
    local target="$1"
    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    local local_script="${self_dir}/archiver.sh"

    if [[ -f "$local_script" ]]; then
        info "Found local archiver.sh — copying to staging..."
        cp "$local_script" "$target" || die "Copy failed."
        return 0
    fi

    info "Downloading from GitHub ..."

    local download_url
    download_url="$(_get_github_raw_url "archiver.sh")"

    if command -v curl &>/dev/null; then
        curl -fsSL -H "Cache-Control: no-cache" -H "Pragma: no-cache" --max-time 60 "$download_url" -o "$target" \
            || die "Download failed. Check your connection, or place archiver.sh next to install.sh and re-run."
    elif command -v wget &>/dev/null; then
        wget -q --header="Cache-Control: no-cache" --header="Pragma: no-cache" --timeout=60 "$download_url" -O "$target" \
            || die "Download failed. Check your connection, or place archiver.sh next to install.sh and re-run."
    else
        die "Neither curl nor wget is available. Place archiver.sh next to install.sh and re-run."
    fi
}

_download_or_copy "$TMP_DEST"
chmod +x "$TMP_DEST"

# ── Step 7: Verify staged file before replacing live binary ───
[[ -x "$TMP_DEST" ]] || die "Staged file is not executable. Existing files were not modified."

if ! bash -n "$TMP_DEST" 2>/dev/null; then
    die "Downloaded script failed syntax check. Existing files were not modified."
fi

if ! grep -q "ARCHIVER_VERSION" "$TMP_DEST" 2>/dev/null; then
    die "Downloaded file does not look like a valid Archiver script. Existing files were not modified."
fi

if ! "$TMP_DEST" version &>/dev/null; then
    die "Downloaded script failed self-test execution. Existing files were not modified."
fi

# ── Step 8: Safe binary backup & atomic replacement ──────────
if [[ -f "$DEST" ]]; then
    cp -p "$DEST" "${DEST}.bak" 2>/dev/null || warn "Could not create backup of previous binary at ${DEST}.bak"
    if [[ -f "${DEST}.bak" ]]; then
        info "Previous executable safely backed up to: ${DEST}.bak"
    fi
fi

mv -f "$TMP_DEST" "$DEST" || die "Failed to install executable to $DEST"
chmod 755 "$DEST"
trap - EXIT INT TERM

if [[ "$IS_UPDATE" == "true" ]]; then
    success "Archiver executable updated: $DEST"
else
    success "File installed: $DEST"
fi
echo ""

# ── Step 8: Dependency check ─────────────────────────────────
info "Checking dependencies ..."
echo ""

MISSING_REQUIRED=()
MISSING_OPTIONAL=()

for cmd in curl tar gzip stat date; do
    if command -v "$cmd" &>/dev/null; then
        success "${cmd}"
    else
        error "${cmd}  ← REQUIRED, not found"
        MISSING_REQUIRED+=("$cmd")
    fi
done

echo ""

for cmd in openssl mysqldump mysql sqlite3 pg_dump psql flock crontab; do
    if command -v "$cmd" &>/dev/null; then
        success "${cmd}"
    else
        warn "${cmd}  (optional, not found)"
        MISSING_OPTIONAL+=("$cmd")
    fi
done

echo ""

if [[ ${#MISSING_REQUIRED[@]} -gt 0 ]]; then
    error "Missing required tools: ${MISSING_REQUIRED[*]}"
    if [[ "$IS_ROOT" == "true" ]]; then
        warn "Install with:  apt install ${MISSING_REQUIRED[*]}"
        warn "           or: yum install ${MISSING_REQUIRED[*]}"
    else
        warn "Contact your hosting provider to make these tools available."
    fi
    echo ""
fi

if [[ ${#MISSING_OPTIONAL[@]} -gt 0 ]]; then
    warn "Missing optional tools: ${MISSING_OPTIONAL[*]}"
    warn "Some features (encryption, DB backup, scheduling) will be unavailable."
    echo ""
fi

# ── Step 9: Self-test ─────────────────────────────────────────
INVOKE_PATH="$DEST"
if command -v "$SCRIPT_NAME" &>/dev/null; then
    INVOKE_PATH="$SCRIPT_NAME"
fi

if "$INVOKE_PATH" version &>/dev/null; then
    INSTALLED_VER=$("$INVOKE_PATH" version 2>/dev/null || echo "unknown")
    success "Archiver is working — ${BOLD}${INSTALLED_VER}${NC}"
else
    warn "Could not self-test. Try opening a new terminal."
fi

# ── Summary ───────────────────────────────────────────────────
if [[ "$IS_UPDATE" == "true" ]]; then
    echo -e "
${BOLD}${GREEN}══════════════════════════════════════════${NC}
${BOLD}${GREEN}  Archiver update complete!               ${NC}
${BOLD}${GREEN}══════════════════════════════════════════${NC}

  ${BOLD}Updated to:${NC}          v${ARCHIVER_VERSION}
  ${BOLD}Executable:${NC}          $DEST
  ${BOLD}Backup executable:${NC}   ${DEST}.bak

  ${BOLD}Data & Configuration Safety Summary:${NC}
  ✓ Backup configurations : ${EXISTING_CONF_COUNT} configuration(s) preserved in ~/.archiver/configs/
  ✓ Backup archives       : ${EXISTING_BACKUP_COUNT} archive(s) preserved in ~/.archiver/backups/
  ✓ Crontab schedules     : Active cron schedules remained untouched
  ✓ Logs and state        : Maintained safely in ~/.archiver/

  ${BOLD}Quick check:${NC}
    archiver doctor     — verify system health & configs
    archiver list       — list active backup profiles
    archiver help       — full command reference
"
else
    echo -e "
${BOLD}${GREEN}══════════════════════════════════════════${NC}
${BOLD}${GREEN}  Installation complete!${NC}
${BOLD}${GREEN}══════════════════════════════════════════${NC}

  ${BOLD}Installed to:${NC}  $DEST

  ${BOLD}Quick start:${NC}
    archiver add        — set up your first backup
    archiver run        — run all backups now
    archiver doctor     — check environment health
    archiver help       — full command reference
"
fi

if [[ "$INSTALL_DIR" == "${HOME}/bin" ]]; then
    echo -e "  ${YELLOW}Tip:${NC} If 'archiver' is not found, run:"
    echo -e "       ${BOLD}source ~/.bashrc${NC}  (or open a new terminal)\n"
fi
