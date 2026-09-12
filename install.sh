#!/bin/bash
# ============================================================
#  Archiver Installer v1.0.0
#  https://github.com/s7net/archiver
#
#  - Installs to ~/bin  (jailed shell / cPanel / DirectAdmin)
#  - Installs to /usr/local/bin  (root / standard Linux)
#  - Prompts before overwriting an existing installation
#  - Checks required and optional dependencies
#  - Adds ~/bin to PATH automatically if needed
# ============================================================

set -uo pipefail

ARCHIVER_VERSION="1.0.0"
REPO_URL="https://raw.githubusercontent.com/s7net/archiver/refs/heads/main/archiver.sh"
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

# ── Step 1: Detect privilege level ───────────────────────────
IS_ROOT=false
if [[ "$(id -u)" -eq 0 ]]; then
    IS_ROOT=true
fi

# ── Step 2: Pick install directory ───────────────────────────
if [[ "$IS_ROOT" == "true" ]] && [[ -d /usr/local/bin ]] && [[ -w /usr/local/bin ]]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="${HOME}/bin"
fi

DEST="${INSTALL_DIR}/${SCRIPT_NAME}"

info "Install directory : $INSTALL_DIR"
info "Target            : $DEST"
echo ""

# ── Step 3: Ask before overwriting ───────────────────────────
if [[ -f "$DEST" ]]; then
    EXISTING_VER=$("$DEST" version 2>/dev/null || echo "unknown")
    echo -e "${YELLOW}Archiver is already installed.${NC}"
    echo -e "  Installed version : ${BOLD}${EXISTING_VER}${NC}"
    echo -e "  Latest version    : ${BOLD}${ARCHIVER_VERSION}${NC}"
    echo ""
    read -rp "$(echo -e "${CYAN}?${NC} Update to the latest version? [y/N]: ")" _confirm </dev/tty
    if [[ ! "$_confirm" =~ ^[Yy]$ ]]; then
        echo "Cancelled. No changes made."
        exit 0
    fi
    echo ""
fi

# ── Step 4: Create install directory ─────────────────────────
if [[ ! -d "$INSTALL_DIR" ]]; then
    info "Creating $INSTALL_DIR ..."
    mkdir -p "$INSTALL_DIR" || die "Could not create $INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"
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

# ── Step 6: Download or copy ──────────────────────────────────
_download_or_copy() {
    # If archiver.sh sits next to this installer, use it directly (no network needed)
    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    local local_script="${self_dir}/archiver.sh"

    if [[ -f "$local_script" ]]; then
        info "Found local archiver.sh — copying ..."
        cp "$local_script" "$DEST" || die "Copy failed."
        return 0
    fi

    info "Downloading from GitHub ..."

    if command -v curl &>/dev/null; then
        curl -fsSL --max-time 60 "$REPO_URL" -o "$DEST" \
            || die "Download failed. Check your connection, or place archiver.sh next to install.sh and re-run."
    elif command -v wget &>/dev/null; then
        wget -q --timeout=60 "$REPO_URL" -O "$DEST" \
            || die "Download failed. Check your connection, or place archiver.sh next to install.sh and re-run."
    else
        die "Neither curl nor wget is available. Place archiver.sh next to install.sh and re-run."
    fi
}

_download_or_copy
chmod +x "$DEST"

# ── Step 7: Verify installed file ────────────────────────────
[[ -x "$DEST" ]] || die "Installed file is not executable: $DEST"

if ! grep -q "ARCHIVER_VERSION" "$DEST" 2>/dev/null; then
    die "Downloaded file does not look like a valid Archiver script. Aborting."
fi

success "File installed: $DEST"
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

if [[ "$INSTALL_DIR" == "${HOME}/bin" ]]; then
    echo -e "  ${YELLOW}Tip:${NC} If 'archiver' is not found, run:"
    echo -e "       ${BOLD}source ~/.bashrc${NC}  (or open a new terminal)\n"
fi
