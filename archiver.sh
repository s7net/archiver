#!/bin/bash
# ============================================================
#  Archiver - Production-grade backup tool for cPanel/DirectAdmin/Linux
#  Pure Bash 4+, no jq, no python, no node
#  https://github.com/s7net/archiver
# ============================================================

set -uo pipefail

ARCHIVER_VERSION="1.0.0"

ARCHIVER_HOME="${HOME}/.archiver"
CONFIGS_DIR="${ARCHIVER_HOME}/configs"
BACKUP_OUT="${ARCHIVER_HOME}/backups"
BACKUP_TMP="${ARCHIVER_HOME}/tmp"
LOG_DIR="${ARCHIVER_HOME}/logs"
LOCK_DIR="${ARCHIVER_HOME}/lock"
CACHE_DIR="${ARCHIVER_HOME}/cache"
METADATA_DIR="${ARCHIVER_HOME}/metadata"
RESTORE_DIR="${ARCHIVER_HOME}/restore"

LOG_FILE="${LOG_DIR}/archiver.log"
LOCK_FILE="${LOCK_DIR}/archiver.lock"
LOG_MAX_SIZE=$(( 5 * 1024 * 1024 ))   # 5 MB

TELEGRAM_MAX=$(( 45 * 1024 * 1024 ))  # 45 MB (Telegram bot limit is 50MB, leave margin)
DISCORD_MAX=$(( 8 * 1024 * 1024 ))    # 8 MB (default Discord webhook limit)

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; BOLD=''; NC=''
fi

_bootstrap_dirs() {
    local d
    for d in "$ARCHIVER_HOME" "$CONFIGS_DIR" "$BACKUP_OUT" "$BACKUP_TMP" \
             "$LOG_DIR" "$LOCK_DIR" "$CACHE_DIR" "$METADATA_DIR" "$RESTORE_DIR"; do
        mkdir -p "$d"
        chmod 700 "$d"
    done
    find "$CONFIGS_DIR" -name "*.conf" -exec chmod 600 {} \; 2>/dev/null || true
    [[ -f "$LOG_FILE" ]] && chmod 600 "$LOG_FILE" 2>/dev/null || true
}
_bootstrap_dirs

# ============================================================
#  LOGGING
# ============================================================

rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local sz
        sz=$(get_file_size "$LOG_FILE")
        if (( sz >= LOG_MAX_SIZE )); then
            local ts
            ts=$(date '+%Y%m%d_%H%M%S')
            mv "$LOG_FILE" "${LOG_FILE}.${ts}"
            chmod 600 "${LOG_FILE}.${ts}" 2>/dev/null || true
            # Keep only last 5 rotated logs
            local rotated=( "${LOG_DIR}"/archiver.log.* )
            if [[ -e "${rotated[0]:-}" ]]; then
                local count=${#rotated[@]}
                if (( count > 5 )); then
                    local sorted=()
                    while IFS= read -r line; do
                        sorted+=("$line")
                    done < <(ls -1t "${LOG_DIR}"/archiver.log.* 2>/dev/null)
                    local i
                    for (( i=5; i<${#sorted[@]}; i++ )); do
                        rm -f "${sorted[$i]}"
                    done
                fi
            fi
        fi
    fi
}

# mask_secret <value> -> returns masked version for logging
mask_secret() {
    local val="$1"
    if [[ -z "$val" ]]; then
        echo ""
    else
        echo "********"
    fi
}

_log_write() {
    local level="$1" msg="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[$ts] [$level] $msg"
    rotate_log
    echo "$line" >> "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

log_info()  { _log_write "INFO"  "$1"; echo -e "${CYAN}[INFO]${NC}  $1"; }
log_warn()  { _log_write "WARN"  "$1"; echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { _log_write "ERROR" "$1"; echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_debug() {
    _log_write "DEBUG" "$1"
    [[ "${ARCHIVER_DEBUG:-0}" == "1" ]] && echo -e "${BLUE}[DEBUG]${NC} $1"
    return 0
}
# Generic "log" used by backup routines = INFO
log() { log_info "$1"; }

# ============================================================
#  DEPENDENCY CHECKS
# ============================================================

check_deps() {
    local missing=()
    local cmd
    for cmd in curl tar gzip stat split date mkdir; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi
}
check_deps

# ============================================================
#  UTILITY HELPERS
# ============================================================

trim() {
    local val="$*"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    printf '%s' "$val"
}

# parse_host_port <input> [default_host] [default_port]
# Outputs: host|port
parse_host_port() {
    local input="$1" default_host="${2:-localhost}" default_port="${3:-3306}"
    input=$(trim "$input")
    local host port
    if [[ -z "$input" ]]; then
        echo "${default_host}|${default_port}"
        return
    fi
    if [[ "$input" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$input" =~ ^([^:]+):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        host="$input"
        port="$default_port"
    fi
    echo "${host}|${port}"
}

get_file_size() {
    local f="$1"
    [[ -e "$f" ]] || { echo 0; return; }
    stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0
}

human_size() {
    local bytes="$1"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    if (( bytes >= 1073741824 )); then
        awk -v b="$bytes" 'BEGIN{printf "%.2fGB", b/1073741824}'
    elif (( bytes >= 1048576 )); then
        awk -v b="$bytes" 'BEGIN{printf "%.2fMB", b/1048576}'
    elif (( bytes >= 1024 )); then
        awk -v b="$bytes" 'BEGIN{printf "%.2fKB", b/1024}'
    else
        printf "%dB" "$bytes"
    fi
}

# Disk free in bytes for a path's filesystem
disk_free_bytes() {
    local path="$1"
    df -Pk "$path" 2>/dev/null | awk 'NR==2 {print $4*1024}'
}

timestamp() { date '+%Y-%m-%d_%H-%M-%S'; }

random_id() {
    if command -v openssl &>/dev/null; then
        openssl rand -hex 8
    else
        head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# ============================================================
#  CONFIG SYSTEM (KEY=VALUE, safe handling)
# ============================================================
#
# Values are stored base64-encoded on disk to safely support
# any characters (&, |, \, /, =, spaces, unicode, quotes, etc.)
# without breaking sed/grep parsing. cfg_get/cfg_set decode/encode
# transparently so callers always work with raw plaintext values.
#
# File format per line:  KEY=<base64>
#

_b64_encode() {
    if base64 --help 2>&1 | grep -q -- '-w'; then
        base64 -w0
    else
        base64 | tr -d '\n'
    fi
}

_b64_decode() {
    local in
    in=$(cat)
    printf '%s' "$in" | base64 -d 2>/dev/null || printf '%s' "$in" | base64 -D 2>/dev/null || printf '%s' "$in"
}

cfg_validate_key() {
    local key="$1"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]
}

# cfg_normalize_key <key_or_alias> -> maps user-friendly names to canonical config keys
cfg_normalize_key() {
    local k="$1"
    k=$(echo "$k" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_')
    k="${k%_}"
    case "$k" in
        HOST|DATABASE_HOST) echo "DB_HOST" ;;
        PORT|DATABASE_PORT) echo "DB_PORT" ;;
        USER|USERNAME|DATABASE_USER) echo "DB_USER" ;;
        PASS|PASSWORD|DATABASE_PASSWORD|DATABASE_PASS) echo "DB_PASS" ;;
        NAME|DATABASE_NAME) echo "DB_NAME" ;;
        TYPE|DATABASE_TYPE) echo "DB_TYPE" ;;
        PATH|DIRECTORY|FILE_PATH|FILES_PATH) echo "FILES_PATH" ;;
        EXCLUDE|EXCLUDES|EXCLUDE_PATTERNS) echo "EXCLUDE_PATTERNS" ;;
        LABEL) echo "FILES_LABEL" ;;
        KEEP_LOCAL|KEEPLOCAL) echo "KEEP_LOCAL" ;;
        RETENTION|RETENTION_COUNT) echo "RETENTION_COUNT" ;;
        COMPRESSION|COMPRESS) echo "COMPRESSION" ;;
        ENCRYPTION|ENCRYPT) echo "ENCRYPTION" ;;
        ENC_PASS|ENC_PASSWORD|ENCRYPTION_PASSWORD) echo "ENC_PASSWORD" ;;
        TELEGRAM|TG) echo "TG_ENABLED" ;;
        TELEGRAM_TOKEN|TG_TOKEN) echo "TG_TOKEN" ;;
        TELEGRAM_CHAT|TELEGRAM_CHAT_ID|TG_CHAT|TG_CHAT_ID) echo "TG_CHAT_ID" ;;
        TELEGRAM_TOPIC|TELEGRAM_TOPIC_ID|TG_TOPIC|TG_TOPIC_ID) echo "TG_TOPIC_ID" ;;
        DISCORD|DC) echo "DC_ENABLED" ;;
        DISCORD_URL|DISCORD_WEBHOOK|DC_URL|DC_WEBHOOK) echo "DC_URL" ;;
        *) echo "$k" ;;
    esac
}

# cfg_get <file> <key> [default]
cfg_get() {
    local file="$1" key="$2" default="${3:-}"
    [[ -f "$file" ]] || { echo "$default"; return; }
    local line val
    line=$(grep -m1 "^${key}=" "$file" 2>/dev/null) || true
    if [[ -z "$line" ]]; then
        echo "$default"
        return
    fi
    val="${line#*=}"
    if [[ -z "$val" ]]; then
        echo "$default"
        return
    fi

    # Check if this config file uses CONFIG_VERSION 2 (where values are base64 encoded)
    local ver_line ver_val
    ver_line=$(grep -m1 "^CONFIG_VERSION=" "$file" 2>/dev/null || true)
    ver_val="${ver_line#*=}"

    if [[ "$ver_val" == "Mg==" || "$ver_val" == "2" ]]; then
        # v2 config: values are base64 encoded
        local decoded
        decoded=$(printf '%s' "$val" | _b64_decode)
        echo "$decoded"
    else
        # Legacy/plaintext format:
        # If val is strictly valid base64 (length multiple of 4, valid chars) and decodes to printable text
        if [[ "$val" =~ ^[A-Za-z0-9+/=]+$ ]] && (( ${#val} % 4 == 0 )) && [[ "$val" =~ [+=] || ${#val} -gt 16 ]]; then
            local decoded
            decoded=$(printf '%s' "$val" | _b64_decode)
            if [[ -n "$decoded" ]] && ! LC_ALL=C grep -q '[^[:print:][:space:]]' <<< "$decoded"; then
                echo "$decoded"
                return
            fi
        fi
        echo "$val"
    fi
}

# cfg_set <file> <key> <value>  (creates file if missing)
cfg_set() {
    local file="$1" key="$2" val="$3"
    cfg_validate_key "$key" || { log_error "Invalid config key: $key"; return 1; }
    local encoded
    encoded=$(printf '%s' "$val" | _b64_encode)
    touch "$file"
    chmod 600 "$file"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        local tmp
        tmp=$(mktemp "${file}.XXXXXX")
        awk -v k="$key" -v v="${key}=${encoded}" \
            'BEGIN{FS="="} { if ($1==k) print v; else print $0 }' "$file" > "$tmp"
        mv "$tmp" "$file"
        chmod 600 "$file"
    else
        echo "${key}=${encoded}" >> "$file"
    fi
}

# cfg_delete <file> <key>
cfg_delete() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    local tmp
    tmp=$(mktemp "${file}.XXXXXX")
    awk -v k="$key" 'BEGIN{FS="="} { if ($1!=k) print $0 }' "$file" > "$tmp"
    mv "$tmp" "$file"
    chmod 600 "$file"
}

# cfg_write <file> KEY1 VAL1 KEY2 VAL2 ...
cfg_write() {
    local file="$1"; shift
    : > "$file"
    chmod 600 "$file"
    while [[ $# -ge 2 ]]; do
        cfg_set "$file" "$1" "$2"
        shift 2
    done
}

# cfg_validate <file> -> checks required keys based on BACKUP_TYPE
cfg_validate() {
    local file="$1"
    [[ -f "$file" ]] || { echo "Config file not found"; return 1; }

    local btype
    btype=$(cfg_get "$file" BACKUP_TYPE)
    local errors=0

    case "$btype" in
        database)
            local dtype
            dtype=$(cfg_get "$file" DB_TYPE)
            case "$dtype" in
                mysql|mariadb|postgres|postgresql)
                    local k
                    for k in DB_NAME DB_USER DB_HOST DB_PORT; do
                        if [[ -z "$(cfg_get "$file" "$k")" ]]; then
                            echo "Missing $k"
                            (( errors++ )) || true
                        fi
                    done
                    ;;
                sqlite)
                    local k
                    for k in DB_NAME DB_PATH; do
                        if [[ -z "$(cfg_get "$file" "$k")" ]]; then
                            echo "Missing $k"
                            (( errors++ )) || true
                        fi
                    done
                    if [[ ! -f "$(cfg_get "$file" DB_PATH)" ]]; then
                        echo "DB_PATH does not exist"
                        (( errors++ )) || true
                    fi
                    ;;
                *)
                    echo "Unknown DB_TYPE: $dtype"
                    (( errors++ )) || true
                    ;;
            esac
            ;;
        files)
            local path
            path=$(cfg_get "$file" FILES_PATH)
            if [[ -z "$path" ]]; then
                echo "Missing FILES_PATH"
                (( errors++ )) || true
            elif [[ ! -e "$path" ]]; then
                echo "FILES_PATH does not exist: $path"
                (( errors++ )) || true
            fi
            ;;
        *)
            echo "Unknown BACKUP_TYPE: $btype"
            (( errors++ )) || true
            ;;
    esac

    # Encryption validity check
    if [[ "$(cfg_get "$file" ENCRYPTION)" == "true" ]]; then
        if [[ -z "$(cfg_get "$file" ENC_PASSWORD)" ]]; then
            echo "Missing ENC_PASSWORD (ENCRYPTION is true)"
            (( errors++ )) || true
        fi
    fi

    # Telegram notification validity check
    if [[ "$(cfg_get "$file" TG_ENABLED)" == "true" ]]; then
        local k
        for k in TG_TOKEN TG_CHAT_ID; do
            if [[ -z "$(cfg_get "$file" "$k")" ]]; then
                echo "Missing $k (TG_ENABLED is true)"
                (( errors++ )) || true
            fi
        done
    fi

    # Discord notification validity check
    if [[ "$(cfg_get "$file" DC_ENABLED)" == "true" ]]; then
        if [[ -z "$(cfg_get "$file" DC_URL)" ]]; then
            echo "Missing DC_URL (DC_ENABLED is true)"
            (( errors++ )) || true
        fi
    fi

    (( errors == 0 ))
}

# ============================================================
#  PROMPT HELPERS
# ============================================================

_read_line() {
    local prompt="$1" secret="${2:-false}"
    local input=""
    local has_tty=false
    if [[ -r /dev/tty && -w /dev/tty && -t 0 ]]; then
        has_tty=true
    fi

    if [[ "$has_tty" == "true" ]]; then
        if [[ "$secret" == "true" ]]; then
            IFS= read -r -s -p "$prompt" input </dev/tty
            echo >/dev/tty
        else
            IFS= read -r -p "$prompt" input </dev/tty
        fi
    else
        if [[ "$secret" == "true" ]]; then
            IFS= read -r -s input || input=""
        else
            echo -ne "$prompt" >&2
            IFS= read -r input || input=""
        fi
    fi
    echo "$input"
}

ask() {
    local prompt="$1" default="${2:-}" raw_input input
    if [[ -n "$default" ]]; then
        raw_input=$(_read_line "$(echo -e "${CYAN}?${NC} ${prompt} [${default}]: ")")
    else
        raw_input=$(_read_line "$(echo -e "${CYAN}?${NC} ${prompt}: ")")
    fi
    input=$(trim "$raw_input")
    echo "${input:-$default}"
}

ask_optional() {
    local prompt="$1" raw_input input
    raw_input=$(_read_line "$(echo -e "${CYAN}?${NC} ${prompt} (Enter to skip): ")")
    input=$(trim "$raw_input")
    echo "$input"
}

ask_secret() {
    local prompt="$1" raw_input input
    raw_input=$(_read_line "$(echo -e "${CYAN}?${NC} ${prompt}: ")" true)
    input=$(trim "$raw_input")
    echo "$input"
}

ask_yn() {
    local prompt="$1" default="${2:-y}" raw_input input
    raw_input=$(_read_line "$(echo -e "${CYAN}?${NC} ${prompt} [y/n] (${default}): ")")
    input=$(trim "$raw_input")
    input="${input:-$default}"
    [[ "$input" =~ ^[Yy]$ ]]
}

ask_choice() {
    local prompt="$1"; shift
    local options=("$@")

    if [[ -w /dev/tty ]]; then
        echo -e "${CYAN}?${NC} $prompt" >/dev/tty
        local i
        for i in "${!options[@]}"; do
            echo -e "  ${BOLD}$((i+1)))${NC} ${options[$i]}" >/dev/tty
        done
    else
        echo -e "${CYAN}?${NC} $prompt" >&2
        local i
        for i in "${!options[@]}"; do
            echo -e "  ${BOLD}$((i+1)))${NC} ${options[$i]}" >&2
        done
    fi

    local choice
    while true; do
        choice=$(_read_line "  Enter number: ")
        choice=$(trim "$choice")
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
            echo "${options[$((choice-1))]}"
            return
        fi
        if [[ -w /dev/tty ]]; then
            echo -e "  ${RED}Invalid choice, try again.${NC}" >/dev/tty
        else
            echo -e "  ${RED}Invalid choice, try again.${NC}" >&2
        fi
    done
}

# ============================================================
#  LOCKING (prevent concurrent execution)
# ============================================================

LOCK_FD=""
LOCK_HELD=0

acquire_lock() {
    if command -v flock &>/dev/null; then
        exec {LOCK_FD}>"$LOCK_FILE"
        if ! flock -n "$LOCK_FD"; then
            log_error "Another archiver instance is already running (flock). Exiting."
            exit 1
        fi
        LOCK_HELD=1
    else
        if [[ -f "$LOCK_FILE" ]]; then
            local old_pid
            old_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
            if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
                log_error "Another archiver instance is already running (PID $old_pid). Exiting."
                exit 1
            fi
        fi
        echo $$ > "$LOCK_FILE"
        LOCK_HELD=1
    fi
}

release_lock() {
    if (( LOCK_HELD == 1 )); then
        if command -v flock &>/dev/null && [[ -n "$LOCK_FD" ]]; then
            flock -u "$LOCK_FD" 2>/dev/null || true
            exec {LOCK_FD}>&- 2>/dev/null || true
        else
            rm -f "$LOCK_FILE"
        fi
        LOCK_HELD=0
    fi
}

# ============================================================
#  CLEANUP
# ============================================================

CLEANUP_PATHS=()

register_cleanup() {
    CLEANUP_PATHS+=("$1")
}

cleanup() {
    local p
    for p in "${CLEANUP_PATHS[@]:-}"; do
        [[ -n "$p" && -e "$p" ]] && rm -rf "$p" 2>/dev/null || true
    done
    find "$BACKUP_TMP" -maxdepth 1 -name ".my_*.cnf"  -type f -mmin +60 -exec rm -f {} + 2>/dev/null || true
    find "$BACKUP_TMP" -maxdepth 1 -name ".pgpass_*"  -type f -mmin +60 -exec rm -f {} + 2>/dev/null || true
    find "$BACKUP_TMP" -maxdepth 1 -name "split_*"    -type d -mmin +60 -exec rm -rf {} + 2>/dev/null || true
    find "$BACKUP_TMP" -maxdepth 1 -name "_dc_resp_*" -type f -mmin +60 -exec rm -f {} + 2>/dev/null || true
    find "$BACKUP_TMP" -maxdepth 1 -name "_val_*"     -type f -mmin +60 -exec rm -f {} + 2>/dev/null || true
    find /tmp -maxdepth 1 -name "_archiver_resp_*" -type f -mmin +60 -exec rm -f {} + 2>/dev/null || true
    release_lock
}
trap cleanup EXIT INT TERM

# ============================================================
#  SPLIT / CHUNKING
# ============================================================

# split_file <file> <max_bytes> <prefix> -> echoes dir containing parts on success
split_file() {
    local file="$1" max_bytes="$2" prefix="$3"
    local name dir n
    name=$(basename "$file")
    dir="$BACKUP_TMP/split_${prefix}_$$_$(random_id)"
    mkdir -p "$dir"
    chmod 700 "$dir"

    if ! split -b "$max_bytes" -d -a 3 "$file" "$dir/chunk_"; then
        log_error "split failed for $file"
        rm -rf "$dir"
        return 1
    fi

    n=0
    local part
    for part in "$dir"/chunk_*; do
        [[ -f "$part" ]] || continue
        n=$(( n + 1 ))
        mv "$part" "$dir/${name}.part$(printf "%03d" "$n")"
    done

    local count
    count=$(find "$dir" -maxdepth 1 -name "*.part*" | wc -l)
    if (( count == 0 )); then
        log_error "split produced no parts for $file"
        rm -rf "$dir"
        return 1
    fi

    echo "$dir"
}

# ============================================================
#  COMPRESSION
# ============================================================

# compression_level <name> -> gzip flag
compression_level() {
    case "$1" in
        fast)   echo "-1" ;;
        best)   echo "-9" ;;
        normal|*) echo "-6" ;;
    esac
}

# tar_create <output.tar.gz> <compression> <basedir> <items...>
tar_create() {
    local out="$1" comp="$2" basedir="$3"; shift 3
    local level
    level=$(compression_level "$comp")
    GZIP="$level" tar czf "$out" -C "$basedir" "$@" 2>/dev/null
}

# tar_verify <archive.tar.gz> -> 0 if listing succeeds
tar_verify() {
    local archive="$1"
    tar tzf "$archive" >/dev/null 2>&1
}

# ============================================================
#  ENCRYPTION
# ============================================================

# encrypt_file <infile> <outfile.enc> <password>
encrypt_file() {
    local infile="$1" outfile="$2" password="$3"
    ARCHIVER_ENC_PASS="$password" openssl enc -aes-256-cbc -pbkdf2 -salt -in "$infile" -out "$outfile" -pass env:ARCHIVER_ENC_PASS 2>/dev/null
}

# decrypt_file <infile.enc> <outfile> <password>
decrypt_file() {
    local infile="$1" outfile="$2" password="$3"
    ARCHIVER_ENC_PASS="$password" openssl enc -aes-256-cbc -pbkdf2 -d -salt -in "$infile" -out "$outfile" -pass env:ARCHIVER_ENC_PASS 2>/dev/null
}

# ============================================================
#  METADATA
# ============================================================

# write_metadata_file <dest_path> <type> <profile> <dbname> <compression> <encryption>
write_metadata_file() {
    local dest="$1" btype="$2" profile="$3" dbname="$4" comp="$5" enc="$6"
    {
        echo "Archiver Version: $ARCHIVER_VERSION"
        echo "Hostname: $(hostname 2>/dev/null || echo unknown)"
        echo "Username: $(whoami 2>/dev/null || echo unknown)"
        echo "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "Backup Type: $btype"
        echo "Profile: $profile"
        echo "Database Name: $dbname"
        echo "Compression: $comp"
        echo "Encryption: $enc"
    } > "$dest"
}

# ============================================================
#  HEALTH / METADATA TRACKING (per-profile)
# ============================================================

meta_file_for() {
    echo "${METADATA_DIR}/$1.meta"
}

meta_record_success() {
    local profile="$1"
    local f
    f=$(meta_file_for "$profile")
    local total_runs total_success
    total_runs=$(cfg_get "$f" TOTAL_RUNS "0")
    total_success=$(cfg_get "$f" TOTAL_SUCCESS "0")
    [[ "$total_runs" =~ ^[0-9]+$ ]] || total_runs=0
    [[ "$total_success" =~ ^[0-9]+$ ]] || total_success=0
    cfg_set "$f" LAST_SUCCESS "$(date '+%Y-%m-%d %H:%M:%S')"
    cfg_set "$f" CONSEC_FAILURES "0"
    cfg_set "$f" TOTAL_RUNS "$(( total_runs + 1 ))"
    cfg_set "$f" TOTAL_SUCCESS "$(( total_success + 1 ))"
}

meta_record_failure() {
    local profile="$1"
    local f
    f=$(meta_file_for "$profile")
    local total_runs consec
    total_runs=$(cfg_get "$f" TOTAL_RUNS "0")
    consec=$(cfg_get "$f" CONSEC_FAILURES "0")
    [[ "$total_runs" =~ ^[0-9]+$ ]] || total_runs=0
    [[ "$consec" =~ ^[0-9]+$ ]] || consec=0
    cfg_set "$f" LAST_FAILURE "$(date '+%Y-%m-%d %H:%M:%S')"
    cfg_set "$f" CONSEC_FAILURES "$(( consec + 1 ))"
    cfg_set "$f" TOTAL_RUNS "$(( total_runs + 1 ))"

    local new_consec
    new_consec=$(( consec + 1 ))
    if (( new_consec >= 3 )); then
        log_warn "Profile '$profile' has failed $new_consec consecutive times!"
    fi
}

# ============================================================
#  RETENTION
# ============================================================

# apply_retention <profile> <retention_count>
apply_retention() {
    local profile="$1" count="$2"
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    (( count <= 0 )) && return 0

    shopt -s nullglob
    local files=( "$BACKUP_OUT/${profile}-"*.tar.gz "$BACKUP_OUT/${profile}-"*.tar.gz.enc )
    shopt -u nullglob

    [[ ${#files[@]} -eq 0 ]] && return 0

    local sorted=()
    while IFS= read -r line; do
        sorted+=("$line")
    done < <(ls -1t "${files[@]}" 2>/dev/null)

    local total=${#sorted[@]}
    if (( total > count )); then
        local i
        for (( i=count; i<total; i++ )); do
            log_info "Retention: removing old backup $(basename "${sorted[$i]}")"
            rm -f "${sorted[$i]}"
            rm -f "${sorted[$i]}".part* 2>/dev/null || true
        done
    fi
}

# ============================================================
#  UPLOAD VERIFICATION
# ============================================================

UPLOAD_ERR=""

verify_telegram_response() {
    local body="$1"
    if echo "$body" | grep -q '"ok":[[:space:]]*true'; then
        UPLOAD_ERR=""
        return 0
    fi
    UPLOAD_ERR=$(echo "$body" | grep -o '"description"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:[[:space:]]*"(.*)"/\1/')
    [[ -z "$UPLOAD_ERR" ]] && UPLOAD_ERR="Unknown Telegram error"
    return 1
}

verify_discord_response() {
    local body="$1" http_code="$2"
    if [[ "$http_code" =~ ^[0-9]+$ ]] && (( http_code >= 200 && http_code < 300 )); then
        UPLOAD_ERR=""
        return 0
    fi
    UPLOAD_ERR="Discord HTTP ${http_code}"
    local msg
    msg=$(echo "$body" | grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:[[:space:]]*"(.*)"/\1/')
    [[ -n "$msg" ]] && UPLOAD_ERR="Discord ($http_code): $msg"
    return 1
}

# ============================================================
#  UPLOAD - TELEGRAM
# ============================================================

send_telegram_file() {
    local file="$1" token="$2" chat_id="$3" topic_id="$4" caption="$5"
    local args=(-s -F "chat_id=${chat_id}" -F "document=@${file}" -F "caption=${caption}")
    [[ -n "$topic_id" ]] && args+=(-F "message_thread_id=${topic_id}")

    local body
    body=$(curl --max-time 600 "${args[@]}" "https://api.telegram.org/bot${token}/sendDocument" 2>&1)
    local curl_exit=$?

    if (( curl_exit != 0 )); then
        UPLOAD_ERR="curl failed (exit $curl_exit)"
        return 1
    fi
    verify_telegram_response "$body"
}

# send_telegram <file> <token> <chat_id> <topic_id>
send_telegram() {
    local file="$1" token="$2" chat_id="$3" topic_id="$4"
    local size all_ok=true
    size=$(get_file_size "$file")

    local split_dir=""
    local files_to_send=()

    if (( size > TELEGRAM_MAX )); then
        log_info "Splitting for Telegram ($(human_size "$size") > $(human_size "$TELEGRAM_MAX"))..."
        split_dir=$(split_file "$file" "$TELEGRAM_MAX" "tg") || return 1
        files_to_send=( "$split_dir"/*.part* )
    else
        files_to_send=( "$file" )
    fi

    local total=${#files_to_send[@]}
    local idx=1
    for part in "${files_to_send[@]}"; do
        [[ -f "$part" ]] || continue
        local caption="Backup [${idx}/${total}]: $(basename "$part")"
        log_info "  -> Telegram ${idx}/${total}: $(basename "$part")"

        if upload_with_retry send_telegram_file "$part" "$token" "$chat_id" "$topic_id" "$caption"; then
            log_info "    OK"
        else
            log_error "    Telegram upload failed: $UPLOAD_ERR"
            all_ok=false
        fi
        idx=$(( idx + 1 ))
    done

    [[ -n "$split_dir" ]] && rm -rf "$split_dir"
    [[ "$all_ok" == "true" ]]
}

# ============================================================
#  UPLOAD - DISCORD
# ============================================================

send_discord_file() {
    local file="$1" webhook="$2" content="$3"
    local resp_file="$BACKUP_TMP/_dc_resp_$$_$(random_id)"
    local http_code

    http_code=$(curl --max-time 600 -s -o "$resp_file" -w "%{http_code}" \
        -X POST \
        -F "content=${content}" \
        -F "file=@${file}" \
        "$webhook" 2>/dev/null)
    local curl_exit=$?

    local body
    body=$(cat "$resp_file" 2>/dev/null || echo "")
    rm -f "$resp_file"

    if (( curl_exit != 0 )); then
        UPLOAD_ERR="curl failed (exit $curl_exit)"
        return 1
    fi
    verify_discord_response "$body" "$http_code"
}

# send_discord <file> <webhook>
send_discord() {
    local file="$1" webhook="$2"
    local size all_ok=true
    size=$(get_file_size "$file")

    local split_dir=""
    local files_to_send=()

    if (( size > DISCORD_MAX )); then
        log_info "Splitting for Discord ($(human_size "$size") > $(human_size "$DISCORD_MAX"))..."
        split_dir=$(split_file "$file" "$DISCORD_MAX" "dc") || return 1
        files_to_send=( "$split_dir"/*.part* )
    else
        files_to_send=( "$file" )
    fi

    local total=${#files_to_send[@]}
    local idx=1
    for part in "${files_to_send[@]}"; do
        [[ -f "$part" ]] || continue
        log_info "  -> Discord ${idx}/${total}: $(basename "$part")"

        if upload_with_retry send_discord_file "$part" "$webhook" "Backup [${idx}/${total}]: $(basename "$part")"; then
            log_info "    OK"
        else
            log_error "    Discord upload failed: $UPLOAD_ERR"
            all_ok=false
        fi
        idx=$(( idx + 1 ))
    done

    [[ -n "$split_dir" ]] && rm -rf "$split_dir"
    [[ "$all_ok" == "true" ]]
}

# ============================================================
#  RETRY ENGINE
# ============================================================

# upload_with_retry <function> <args...>
upload_with_retry() {
    local fn="$1"; shift
    local delays=(2 5 10)
    local attempt=1
    local max_attempts=$(( ${#delays[@]} + 1 ))

    while true; do
        if "$fn" "$@"; then
            return 0
        fi

        if (( attempt >= max_attempts )); then
            return 1
        fi

        local delay="${delays[$((attempt-1))]}"
        log_warn "    Attempt ${attempt} failed (${UPLOAD_ERR}). Retrying in ${delay}s..."
        sleep "$delay"
        attempt=$(( attempt + 1 ))
    done
}

# ============================================================
#  DISPATCH UPLOAD
# ============================================================

# dispatch_send <file> <config>
dispatch_send() {
    local file="$1" config="$2"
    local all_ok=true
    local any_enabled=false

    local tg_enabled tg_token tg_chat tg_topic dc_enabled dc_url keep_local
    tg_enabled=$(cfg_get "$config" TG_ENABLED  "false")
    tg_token=$(cfg_get   "$config" TG_TOKEN    "")
    tg_chat=$(cfg_get    "$config" TG_CHAT_ID  "")
    tg_topic=$(cfg_get   "$config" TG_TOPIC_ID "")
    dc_enabled=$(cfg_get "$config" DC_ENABLED  "false")
    dc_url=$(cfg_get     "$config" DC_URL      "")
    keep_local=$(cfg_get "$config" KEEP_LOCAL  "true")

    if [[ "$tg_enabled" == "true" ]]; then
        any_enabled=true
        send_telegram "$file" "$tg_token" "$tg_chat" "$tg_topic" || all_ok=false
    fi
    if [[ "$dc_enabled" == "true" ]]; then
        any_enabled=true
        send_discord "$file" "$dc_url" || all_ok=false
    fi

    if [[ "$any_enabled" == "false" ]]; then
        log_info "No upload destinations enabled; archive kept locally: $file"
        return 0
    fi

    if [[ "$all_ok" == "true" ]]; then
        if [[ "$keep_local" == "true" ]]; then
            log_info "All uploads confirmed. Local copy retained: $(basename "$file")"
        else
            log_info "All uploads confirmed. Removing local copy: $(basename "$file")"
            rm -f "$file"
        fi
    else
        log_error "One or more uploads failed. Local file KEPT: $file"
        return 1
    fi
}

# notify_failure <config> <profile> <reason>
notify_failure() {
    local config="$1" profile="$2" reason="${3:-Backup failed}"
    local host_name ts alert_msg
    host_name=$(hostname 2>/dev/null || echo "server")
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)

    local tg_enabled tg_token tg_chat tg_topic dc_enabled dc_url
    tg_enabled=$(cfg_get "$config" TG_ENABLED  "false")
    tg_token=$(cfg_get   "$config" TG_TOKEN    "")
    tg_chat=$(cfg_get    "$config" TG_CHAT_ID  "")
    tg_topic=$(cfg_get   "$config" TG_TOPIC_ID "")
    dc_enabled=$(cfg_get "$config" DC_ENABLED  "false")
    dc_url=$(cfg_get     "$config" DC_URL      "")

    alert_msg="⚠️ [Archiver Alert] Backup failed!
• Profile: ${profile}
• Server: ${host_name}
• Time: ${ts}
• Reason: ${reason}"

    if [[ "$tg_enabled" == "true" && -n "$tg_token" && -n "$tg_chat" ]]; then
        local args=( -s --max-time 15 --data-urlencode "chat_id=${tg_chat}" --data-urlencode "text=${alert_msg}" )
        [[ -n "$tg_topic" ]] && args+=( --data-urlencode "message_thread_id=${tg_topic}" )
        curl "${args[@]}" "https://api.telegram.org/bot${tg_token}/sendMessage" >/dev/null 2>&1 || true
    fi

    if [[ "$dc_enabled" == "true" && -n "$dc_url" ]]; then
        local escaped_msg="${alert_msg//\\/\\\\}"
        escaped_msg="${escaped_msg//\"/\\\"}"
        escaped_msg="${escaped_msg//$'\n'/\\n}"
        curl -s --max-time 15 -H "Content-Type: application/json" \
            -d "{\"content\": \"${escaped_msg}\"}" "$dc_url" >/dev/null 2>&1 || true
    fi
}

# ============================================================
#  BACKUP: MySQL / MariaDB
# ============================================================

run_db_backup() {
    local config="$1" profile="$2"

    if ! command -v mysqldump &>/dev/null; then
        log_error "mysqldump not found. Cannot backup database."
        return 1
    fi

    local db_name db_type db_host db_port db_user db_pass comp encrypt enc_pass
    db_name=$(cfg_get "$config" DB_NAME)
    db_type=$(cfg_get "$config" DB_TYPE)
    db_host=$(cfg_get "$config" DB_HOST "localhost")
    db_port=$(cfg_get "$config" DB_PORT "3306")
    db_user=$(cfg_get "$config" DB_USER)
    db_pass=$(cfg_get "$config" DB_PASS)
    comp=$(cfg_get "$config" COMPRESSION "normal")
    encrypt=$(cfg_get "$config" ENCRYPTION "false")
    enc_pass=$(cfg_get "$config" ENC_PASSWORD "")

    local run_id ts sql_file work_dir file_name full_path meta_file
    run_id="$$_$(random_id)"
    ts=$(timestamp)
    work_dir="$BACKUP_TMP/work_${run_id}"
    mkdir -p "$work_dir"
    chmod 700 "$work_dir"
    register_cleanup "$work_dir"

    local parsed_hp
    parsed_hp=$(parse_host_port "$db_host" "localhost" "$db_port")
    db_host="${parsed_hp%%|*}"
    db_port="${parsed_hp##*|}"

    sql_file="$work_dir/${db_name}.sql"
    file_name="${profile}-${ts}.tar.gz"
    full_path="$BACKUP_OUT/$file_name"
    meta_file="$work_dir/backup-info.txt"

    log_info "Dumping ${db_type}: ${db_name} @ ${db_host}:${db_port}"

    local cnf
    cnf=$(mktemp "$BACKUP_TMP/.my_XXXXXX.cnf")
    chmod 600 "$cnf"
    register_cleanup "$cnf"
    {
        echo "[client]"
        echo "user=\"${db_user//\"/\\\"}\""
        echo "password=\"${db_pass//\"/\\\"}\""
        echo "host=\"${db_host//\"/\\\"}\""
        echo "port=\"${db_port//\"/\\\"}\""
        if [[ "$db_host" == "localhost" && "$db_port" != "3306" ]]; then
            echo "protocol=tcp"
        fi
    } > "$cnf"

    local dump_ok=true
    mysqldump --defaults-extra-file="$cnf" \
              --single-transaction --quick \
              --routines --triggers --events \
              "$db_name" > "$sql_file" 2>"$work_dir/mysqldump.err" || dump_ok=false

    # If failed due to lack of EVENT privilege (common on cPanel / DirectAdmin), retry without --events
    if [[ "$dump_ok" == "false" ]] && grep -qiE "(Access denied.*EVENT|SHOW EVENTS)" "$work_dir/mysqldump.err" 2>/dev/null; then
        log_warn "User lacks EVENT privilege; retrying mysqldump without --events..."
        dump_ok=true
        mysqldump --defaults-extra-file="$cnf" \
                  --single-transaction --quick \
                  --routines --triggers \
                  "$db_name" > "$sql_file" 2>"$work_dir/mysqldump.err" || dump_ok=false
    fi

    rm -f "$cnf"

    if [[ "$dump_ok" == "false" ]]; then
        log_error "mysqldump failed for $db_name: $(tail -n1 "$work_dir/mysqldump.err" 2>/dev/null)"
        rm -rf "$work_dir"
        return 1
    fi

    local dump_size
    dump_size=$(get_file_size "$sql_file")
    if (( dump_size < 100 )); then
        log_error "Dump file suspiciously small (${dump_size} bytes) - aborting"
        rm -rf "$work_dir"
        return 1
    fi

    write_metadata_file "$meta_file" "database ($db_type)" "$profile" "$db_name" "$comp" "$encrypt"

    if ! tar_create "$full_path" "$comp" "$work_dir" "$(basename "$sql_file")" "backup-info.txt"; then
        log_error "tar creation failed for $profile"
        rm -rf "$work_dir"
        return 1
    fi
    rm -rf "$work_dir"

    if ! tar_verify "$full_path"; then
        log_error "Archive integrity check FAILED for $full_path. Aborting upload."
        return 1
    fi
    log_info "Integrity check OK: $file_name"

    full_path=$(maybe_encrypt "$full_path" "$encrypt" "$enc_pass") || return 1

    log_info "Archive ready: $(basename "$full_path") ($(human_size "$(get_file_size "$full_path")"))"

    local result=0
    dispatch_send "$full_path" "$config" || result=1

    local retention
    retention=$(cfg_get "$config" RETENTION_COUNT "0")
    apply_retention "$profile" "$retention"

    return $result
}

# ============================================================
#  BACKUP: PostgreSQL
# ============================================================

run_postgres_backup() {
    local config="$1" profile="$2"

    if ! command -v pg_dump &>/dev/null; then
        log_error "pg_dump not found. Cannot backup PostgreSQL database."
        return 1
    fi

    local db_name db_type db_host db_port db_user db_pass comp encrypt enc_pass
    db_name=$(cfg_get "$config" DB_NAME)
    db_type=$(cfg_get "$config" DB_TYPE "postgres")
    db_host=$(cfg_get "$config" DB_HOST "localhost")
    db_port=$(cfg_get "$config" DB_PORT "5432")
    db_user=$(cfg_get "$config" DB_USER)
    db_pass=$(cfg_get "$config" DB_PASS)
    comp=$(cfg_get "$config" COMPRESSION "normal")
    encrypt=$(cfg_get "$config" ENCRYPTION "false")
    enc_pass=$(cfg_get "$config" ENC_PASSWORD "")

    local parsed_hp
    parsed_hp=$(parse_host_port "$db_host" "localhost" "$db_port")
    db_host="${parsed_hp%%|*}"
    db_port="${parsed_hp##*|}"

    local run_id ts sql_file work_dir file_name full_path meta_file pgpass
    run_id="$$_$(random_id)"
    ts=$(timestamp)
    work_dir="$BACKUP_TMP/work_${run_id}"
    mkdir -p "$work_dir"
    chmod 700 "$work_dir"
    register_cleanup "$work_dir"

    sql_file="$work_dir/${db_name}.sql"
    file_name="${profile}-${ts}.tar.gz"
    full_path="$BACKUP_OUT/$file_name"
    meta_file="$work_dir/backup-info.txt"

    log_info "Dumping PostgreSQL: ${db_name} @ ${db_host}:${db_port}"

    pgpass=$(mktemp "$BACKUP_TMP/.pgpass_XXXXXX")
    chmod 600 "$pgpass"
    register_cleanup "$pgpass"
    echo "${db_host}:${db_port}:${db_name}:${db_user}:${db_pass}" > "$pgpass"

    local dump_ok=true
    PGPASSFILE="$pgpass" pg_dump \
        -h "$db_host" \
        -p "$db_port" \
        -U "$db_user" \
        -Fp \
        --clean --if-exists \
        "$db_name" > "$sql_file" 2>"$work_dir/pg_dump.err" || dump_ok=false

    rm -f "$pgpass"

    if [[ "$dump_ok" == "false" ]]; then
        log_error "pg_dump failed for $db_name: $(tail -n1 "$work_dir/pg_dump.err" 2>/dev/null)"
        rm -rf "$work_dir"
        return 1
    fi

    local dump_size
    dump_size=$(get_file_size "$sql_file")
    if (( dump_size < 100 )); then
        log_error "Dump file suspiciously small (${dump_size} bytes) - aborting"
        rm -rf "$work_dir"
        return 1
    fi

    write_metadata_file "$meta_file" "database (postgres)" "$profile" "$db_name" "$comp" "$encrypt"

    if ! tar_create "$full_path" "$comp" "$work_dir" "$(basename "$sql_file")" "backup-info.txt"; then
        log_error "tar creation failed for $profile"
        rm -rf "$work_dir"
        return 1
    fi
    rm -rf "$work_dir"

    if ! tar_verify "$full_path"; then
        log_error "Archive integrity check FAILED for $full_path. Aborting upload."
        return 1
    fi
    log_info "Integrity check OK: $file_name"

    full_path=$(maybe_encrypt "$full_path" "$encrypt" "$enc_pass") || return 1

    log_info "Archive ready: $(basename "$full_path") ($(human_size "$(get_file_size "$full_path")"))"

    local result=0
    dispatch_send "$full_path" "$config" || result=1

    local retention
    retention=$(cfg_get "$config" RETENTION_COUNT "0")
    apply_retention "$profile" "$retention"

    return $result
}

# ============================================================
#  BACKUP: SQLite
# ============================================================

run_sqlite_backup() {
    local config="$1" profile="$2"

    if ! command -v sqlite3 &>/dev/null; then
        log_error "sqlite3 not found. Cannot backup SQLite database."
        return 1
    fi

    local db_name db_path comp encrypt enc_pass
    db_name=$(cfg_get "$config" DB_NAME)
    db_path=$(cfg_get "$config" DB_PATH)
    comp=$(cfg_get "$config" COMPRESSION "normal")
    encrypt=$(cfg_get "$config" ENCRYPTION "false")
    enc_pass=$(cfg_get "$config" ENC_PASSWORD "")

    if [[ ! -f "$db_path" ]]; then
        log_error "SQLite file not found: $db_path"
        return 1
    fi

    local run_id ts work_dir backup_db file_name full_path meta_file
    run_id="$$_$(random_id)"
    ts=$(timestamp)
    work_dir="$BACKUP_TMP/work_${run_id}"
    mkdir -p "$work_dir"
    chmod 700 "$work_dir"
    register_cleanup "$work_dir"

    backup_db="$work_dir/${db_name}.sqlite"
    file_name="${profile}-${ts}.tar.gz"
    full_path="$BACKUP_OUT/$file_name"
    meta_file="$work_dir/backup-info.txt"

    log_info "SQLite online backup: $db_path"

    if ! sqlite3 "$db_path" ".backup '${backup_db}'" 2>"$work_dir/sqlite.err"; then
        log_error "sqlite3 .backup failed: $(tail -n1 "$work_dir/sqlite.err" 2>/dev/null)"
        rm -rf "$work_dir"
        return 1
    fi

    if [[ ! -f "$backup_db" ]] || (( $(get_file_size "$backup_db") == 0 )); then
        log_error "SQLite backup file is empty or missing"
        rm -rf "$work_dir"
        return 1
    fi

    write_metadata_file "$meta_file" "database (sqlite)" "$profile" "$db_name" "$comp" "$encrypt"

    if ! tar_create "$full_path" "$comp" "$work_dir" "$(basename "$backup_db")" "backup-info.txt"; then
        log_error "tar creation failed for $profile"
        rm -rf "$work_dir"
        return 1
    fi
    rm -rf "$work_dir"

    if ! tar_verify "$full_path"; then
        log_error "Archive integrity check FAILED for $full_path. Aborting upload."
        return 1
    fi
    log_info "Integrity check OK: $file_name"

    full_path=$(maybe_encrypt "$full_path" "$encrypt" "$enc_pass") || return 1

    log_info "Archive ready: $(basename "$full_path") ($(human_size "$(get_file_size "$full_path")"))"

    local result=0
    dispatch_send "$full_path" "$config" || result=1

    local retention
    retention=$(cfg_get "$config" RETENTION_COUNT "0")
    apply_retention "$profile" "$retention"

    return $result
}

# ============================================================
#  BACKUP: Files / Directory / Single File
# ============================================================

run_files_backup() {
    local config="$1" profile="$2"

    local label src_path ftype comp encrypt enc_pass
    label=$(cfg_get    "$config" FILES_LABEL "$profile")
    src_path=$(cfg_get "$config" FILES_PATH)
    ftype=$(cfg_get    "$config" FILES_TYPE "directory")
    comp=$(cfg_get     "$config" COMPRESSION "normal")
    encrypt=$(cfg_get  "$config" ENCRYPTION "false")
    enc_pass=$(cfg_get "$config" ENC_PASSWORD "")

    if [[ ! -e "$src_path" ]]; then
        log_error "Source path not found: $src_path"
        return 1
    fi

    local ts work_dir file_name full_path meta_file
    ts=$(timestamp)
    work_dir="$BACKUP_TMP/work_$$_$(random_id)"
    mkdir -p "$work_dir"
    chmod 700 "$work_dir"
    register_cleanup "$work_dir"

    file_name="${profile}-${ts}.tar.gz"
    full_path="$BACKUP_OUT/$file_name"
    meta_file="$work_dir/backup-info.txt"

    log_info "Files backup [$ftype]: $label ($src_path)"

    write_metadata_file "$meta_file" "files ($ftype)" "$profile" "n/a" "$comp" "$encrypt"

    local src_dir src_base level
    src_dir=$(dirname "$src_path")
    src_base=$(basename "$src_path")
    level=$(compression_level "$comp")

    local excludes
    excludes=$(cfg_get "$config" EXCLUDE_PATTERNS "")
    local exclude_args=()
    if [[ -n "$excludes" ]]; then
        local pattern
        local IFS_SAVE="$IFS"
        IFS=','
        for pattern in $excludes; do
            pattern=$(trim "$pattern")
            if [[ -n "$pattern" ]]; then
                exclude_args+=( --exclude="$pattern" )
            fi
        done
        IFS="$IFS_SAVE"
    fi

    local tar_rc=0
    if (( ${#exclude_args[@]} > 0 )); then
        GZIP="$level" tar czf "$full_path" "${exclude_args[@]}" -C "$src_dir" "$src_base" -C "$work_dir" "backup-info.txt" 2>"$work_dir/tar.err" || tar_rc=$?
    else
        GZIP="$level" tar czf "$full_path" -C "$src_dir" "$src_base" -C "$work_dir" "backup-info.txt" 2>"$work_dir/tar.err" || tar_rc=$?
    fi

    # In GNU tar, exit code 1 means "file changed as we read it" (warning, not fatal)
    if (( tar_rc > 1 )); then
        log_error "tar failed for $src_path (exit $tar_rc): $(tail -n1 "$work_dir/tar.err" 2>/dev/null)"
        rm -rf "$work_dir"
        rm -f "$full_path"
        return 1
    elif (( tar_rc == 1 )); then
        log_warn "tar completed with warnings (some files changed during archive)"
    fi
    rm -rf "$work_dir"

    if ! tar_verify "$full_path"; then
        log_error "Archive integrity check FAILED for $full_path. Aborting upload."
        rm -f "$full_path"
        return 1
    fi
    log_info "Integrity check OK: $file_name"

    full_path=$(maybe_encrypt "$full_path" "$encrypt" "$enc_pass") || return 1

    log_info "Archive ready: $(basename "$full_path") ($(human_size "$(get_file_size "$full_path")"))"

    local result=0
    dispatch_send "$full_path" "$config" || result=1

    local retention
    retention=$(cfg_get "$config" RETENTION_COUNT "0")
    apply_retention "$profile" "$retention"

    return $result
}

# maybe_encrypt <file.tar.gz> <encrypt_flag> <password> -> echoes resulting path
maybe_encrypt() {
    local file="$1" encrypt="$2" pass="$3"
    if [[ "$encrypt" == "true" ]]; then
        if [[ -z "$pass" ]]; then
            log_error "Encryption enabled but no password set for $(basename "$file")"
            echo "$file"
            return 1
        fi
        local out="${file}.enc"
        if encrypt_file "$file" "$out" "$pass"; then
            rm -f "$file"
            log_info "Encrypted: $(basename "$out")"
            echo "$out"
            return 0
        else
            log_error "Encryption failed for $(basename "$file")"
            echo "$file"
            return 1
        fi
    else
        echo "$file"
        return 0
    fi
}

# ============================================================
#  PROFILE / DISK SPACE PRE-CHECK
# ============================================================

precheck_disk_space() {
    local config="$1" profile="$2"
    local min_free_mb=100

    local free
    free=$(disk_free_bytes "$BACKUP_OUT")
    if [[ -z "$free" ]]; then
        log_warn "[$profile] Could not determine free disk space"
        return 0
    fi

    local btype
    btype=$(cfg_get "$config" BACKUP_TYPE)
    if [[ "$btype" == "files" ]]; then
        local fpath
        fpath=$(cfg_get "$config" FILES_PATH)
        if [[ -e "$fpath" ]]; then
            local src_kb
            src_kb=$(du -sk "$fpath" 2>/dev/null | cut -f1)
            if [[ "$src_kb" =~ ^[0-9]+$ ]] && (( src_kb > 0 )); then
                local req_bytes=$(( (src_kb * 1024 * 11 / 10) + (min_free_mb * 1024 * 1024) ))
                if (( free < req_bytes )); then
                    log_error "[$profile] Insufficient disk space: estimated ~$(human_size "$req_bytes") needed, but only $(human_size "$free") free in $BACKUP_OUT"
                    return 1
                fi
                return 0
            fi
        fi
    elif [[ "$btype" == "database" ]]; then
        local dtype
        dtype=$(cfg_get "$config" DB_TYPE)
        if [[ "$dtype" == "sqlite" ]]; then
            local db_path
            db_path=$(cfg_get "$config" DB_PATH)
            if [[ -f "$db_path" ]]; then
                local db_sz
                db_sz=$(get_file_size "$db_path")
                if (( db_sz > 0 )); then
                    local req_bytes=$(( (db_sz * 11 / 10) + (min_free_mb * 1024 * 1024) ))
                    if (( free < req_bytes )); then
                        log_error "[$profile] Insufficient disk space for SQLite backup: estimated ~$(human_size "$req_bytes") needed, but only $(human_size "$free") free in $BACKUP_OUT"
                        return 1
                    fi
                    return 0
                fi
            fi
        fi
    fi

    if (( free < min_free_mb * 1024 * 1024 )); then
        log_error "[$profile] Low disk space: only $(human_size "$free") free in $BACKUP_OUT"
        return 1
    fi
    return 0
}

# ============================================================
#  WIZARD HELPERS
# ============================================================

wizard_notifications() {
    echo -e "\n${BOLD}-- Notification Settings --------------------------------${NC}"
    TG_ENABLED_W=false; TG_TOKEN_W=""; TG_CHAT_W=""; TG_TOPIC_W=""
    DC_ENABLED_W=false; DC_URL_W=""

    if ask_yn "Enable Telegram?" "n"; then
        TG_ENABLED_W=true
        TG_TOKEN_W=$(ask_secret "Bot token")
        TG_CHAT_W=$(ask "Chat ID")
        TG_TOPIC_W=$(ask_optional "Topic ID (supergroup thread)")
    fi

    if ask_yn "Enable Discord?" "n"; then
        DC_ENABLED_W=true
        DC_URL_W=$(ask_secret "Webhook URL")
    fi
}

wizard_compression() {
    COMPRESSION_W=$(ask_choice "Compression level?" "fast" "normal" "best")
}

wizard_encryption() {
    ENCRYPTION_W=false
    ENC_PASSWORD_W=""
    if ask_yn "Enable encryption (AES-256-CBC)?" "n"; then
        ENCRYPTION_W=true
        while true; do
            local p1 p2
            p1=$(ask_secret "Encryption password")
            p2=$(ask_secret "Confirm password")
            if [[ "$p1" == "$p2" && -n "$p1" ]]; then
                ENC_PASSWORD_W="$p1"
                break
            fi
            echo -e "${RED}Passwords did not match or were empty. Try again.${NC}"
        done
    fi
}

wizard_retention() {
    local r
    r=$(ask "Retention count (how many local backups to keep, 0 = unlimited)" "10")
    [[ "$r" =~ ^[0-9]+$ ]] || r=10
    RETENTION_W="$r"
    KEEP_LOCAL_W="true"
    if ask_yn "Keep local copy of backup after remote upload?" "y"; then
        KEEP_LOCAL_W="true"
    else
        KEEP_LOCAL_W="false"
    fi
}

wizard_schedule() {
    SCHEDULE_W=""
    if ask_yn "Schedule this backup with cron now?" "n"; then
        local choice
        choice=$(ask_choice "Frequency?" "hourly" "6h" "daily" "weekly" "custom")
        if [[ "$choice" == "custom" ]]; then
            SCHEDULE_W=$(ask "Cron expression (e.g. '0 */3 * * *')")
        else
            SCHEDULE_W="$choice"
        fi
    fi
}

# ============================================================
#  COMMAND: add
# ============================================================

cmd_add() {
    echo -e "\n${BOLD}${GREEN}==================================${NC}"
    echo -e "${BOLD}${GREEN}   archiver add - New Backup      ${NC}"
    echo -e "${BOLD}${GREEN}==================================${NC}\n"

    local backup_type
    backup_type=$(ask_choice "What do you want to backup?" "Database" "Directory" "Single File")

    wizard_compression
    wizard_encryption
    wizard_retention
    wizard_notifications

    local profile config_file

    if [[ "$backup_type" == "Database" ]]; then
        echo -e "\n${BOLD}-- Database Settings -------------------------------------${NC}"
        local db_type
        db_type=$(ask_choice "Database type?" "mysql" "mariadb" "postgres" "sqlite")

        if [[ "$db_type" == "sqlite" ]]; then
            local db_path db_name
            db_path=$(ask "Path to .sqlite / .db file")
            db_name=$(ask "Label / name" "$(basename "$db_path" | cut -d. -f1)")
            profile="db_${db_name}"
            config_file="$CONFIGS_DIR/${profile}.conf"

            cfg_write "$config_file" \
                CONFIG_VERSION 2 \
                BACKUP_TYPE database \
                DB_TYPE     sqlite \
                DB_NAME     "$db_name" \
                DB_PATH     "$db_path" \
                COMPRESSION "$COMPRESSION_W" \
                ENCRYPTION  "$ENCRYPTION_W" \
                ENC_PASSWORD "$ENC_PASSWORD_W" \
                RETENTION_COUNT "$RETENTION_W" \
                KEEP_LOCAL  "$KEEP_LOCAL_W" \
                TG_ENABLED  "$TG_ENABLED_W" \
                TG_TOKEN    "$TG_TOKEN_W" \
                TG_CHAT_ID  "$TG_CHAT_W" \
                TG_TOPIC_ID "$TG_TOPIC_W" \
                DC_ENABLED  "$DC_ENABLED_W" \
                DC_URL      "$DC_URL_W"
        else
            local default_p="3306"
            [[ "$db_type" == "postgres" || "$db_type" == "postgresql" ]] && default_p="5432"

            local raw_host db_host db_port db_name db_user db_pass
            raw_host=$(ask "Host (e.g. localhost or 127.0.0.1:${default_p})" "localhost")
            local parsed_hp
            parsed_hp=$(parse_host_port "$raw_host" "localhost" "$default_p")
            db_host="${parsed_hp%%|*}"
            local guessed_port="${parsed_hp##*|}"
            db_port=$(ask "Port" "$guessed_port")
            db_name=$(ask "Database name")

            local default_u=""
            [[ "$db_type" == "postgres" || "$db_type" == "postgresql" ]] && default_u="postgres"
            if [[ -n "$default_u" ]]; then
                db_user=$(ask "Username" "$default_u")
            else
                db_user=$(ask "Username")
            fi

            db_pass=$(ask_secret "Password")
            profile="db_${db_name}"
            config_file="$CONFIGS_DIR/${profile}.conf"

            cfg_write "$config_file" \
                CONFIG_VERSION 2 \
                BACKUP_TYPE database \
                DB_TYPE     "$db_type" \
                DB_NAME     "$db_name" \
                DB_HOST     "$db_host" \
                DB_PORT     "$db_port" \
                DB_USER     "$db_user" \
                DB_PASS     "$db_pass" \
                COMPRESSION "$COMPRESSION_W" \
                ENCRYPTION  "$ENCRYPTION_W" \
                ENC_PASSWORD "$ENC_PASSWORD_W" \
                RETENTION_COUNT "$RETENTION_W" \
                KEEP_LOCAL  "$KEEP_LOCAL_W" \
                TG_ENABLED  "$TG_ENABLED_W" \
                TG_TOKEN    "$TG_TOKEN_W" \
                TG_CHAT_ID  "$TG_CHAT_W" \
                TG_TOPIC_ID "$TG_TOPIC_W" \
                DC_ENABLED  "$DC_ENABLED_W" \
                DC_URL      "$DC_URL_W"
        fi
    else
        local ftype="directory"
        [[ "$backup_type" == "Single File" ]] && ftype="file"

        echo -e "\n${BOLD}-- ${backup_type} Settings -------------------------------${NC}"
        local src_path label excludes=""
        src_path=$(ask "Source path")
        label=$(ask "Label" "$(basename "$src_path")")
        label=$(echo "$label" | tr -c 'A-Za-z0-9_.-' '_')
        if [[ "$ftype" == "directory" ]]; then
            excludes=$(ask "Exclude patterns (comma-separated, e.g. node_modules, .git, cache, *.log) [empty for none]")
        fi
        profile="files_${label}"
        config_file="$CONFIGS_DIR/${profile}.conf"

        cfg_write "$config_file" \
            CONFIG_VERSION 2 \
            BACKUP_TYPE files \
            FILES_TYPE  "$ftype" \
            FILES_LABEL "$label" \
            FILES_PATH  "$src_path" \
            EXCLUDE_PATTERNS "$excludes" \
            COMPRESSION "$COMPRESSION_W" \
            ENCRYPTION  "$ENCRYPTION_W" \
            ENC_PASSWORD "$ENC_PASSWORD_W" \
            RETENTION_COUNT "$RETENTION_W" \
            KEEP_LOCAL  "$KEEP_LOCAL_W" \
            TG_ENABLED  "$TG_ENABLED_W" \
            TG_TOKEN    "$TG_TOKEN_W" \
            TG_CHAT_ID  "$TG_CHAT_W" \
            TG_TOPIC_ID "$TG_TOPIC_W" \
            DC_ENABLED  "$DC_ENABLED_W" \
            DC_URL      "$DC_URL_W"
    fi

    wizard_schedule
    if [[ -n "$SCHEDULE_W" ]]; then
        cron_install "$SCHEDULE_W" "$profile"
    fi

    echo -e "\n${GREEN}Config saved: ${BOLD}${config_file}${NC}"
    echo -e "  Run ${BOLD}archiver run${NC} to execute all backups."
    echo -e "  Run ${BOLD}archiver run $profile${NC} to run only this one.\n"
}

# ============================================================
#  COMMAND: edit
# ============================================================

cmd_edit() {
    local profile="${1:-}"
    if [[ -z "$profile" ]]; then
        profile=$(_select_profile "Which config to edit?") || return 1
    fi
    local config_file="$CONFIGS_DIR/${profile}.conf"
    if [[ ! -f "$config_file" ]]; then
        log_error "No such config: $profile"
        return 1
    fi

    echo -e "\n${BOLD}Editing: ${profile}${NC}"
    echo "Current keys:"
    grep -oE '^[A-Z_]+=' "$config_file" | sed 's/=$//' | sed 's/^/  - /'
    echo

    while true; do
        local raw_key key
        raw_key=$(ask_optional "Enter KEY to edit (or leave blank to finish)")
        [[ -z "$raw_key" ]] && break
        key=$(cfg_normalize_key "$raw_key")
        if ! cfg_validate_key "$key"; then
            echo -e "${RED}Invalid key format. Use UPPER_SNAKE_CASE (or friendly names like 'host', 'port', 'user').${NC}"
            continue
        fi
        if [[ "$key" != "$raw_key" ]]; then
            echo -e "  (Editing canonical key: ${CYAN}${key}${NC})"
        fi
        local current
        current=$(cfg_get "$config_file" "$key")
        local masked="$current"
        case "$key" in
            *PASS*|*TOKEN*|*URL|*PASSWORD*) masked=$(mask_secret "$current") ;;
        esac
        echo "  Current value: ${masked:-<empty>}"
        local newval
        if [[ "$key" =~ (PASS|TOKEN|PASSWORD)$ ]]; then
            newval=$(ask_secret "New value for $key (or 'clear' to empty)")
        else
            newval=$(ask "New value for $key (or 'clear' to empty)" "$current")
        fi

        if [[ "$newval" == "clear" || "$newval" == "none" ]]; then
            cfg_set "$config_file" "$key" ""
            echo -e "${GREEN}Cleared $key${NC}"
        else
            if [[ "$key" == "DB_HOST" ]]; then
                local current_db_type
                current_db_type="$(cfg_get "$config_file" DB_TYPE)"
                local current_port
                current_port="$(cfg_get "$config_file" DB_PORT)"
                local default_p="3306"
                if [[ "$current_db_type" == "postgres" || "$current_db_type" == "postgresql" ]]; then
                    default_p="5432"
                fi
                [[ -n "$current_port" ]] && default_p="$current_port"
                local parsed_hp
                parsed_hp=$(parse_host_port "$newval" "localhost" "$default_p")
                local h="${parsed_hp%%|*}"
                local p="${parsed_hp##*|}"
                cfg_set "$config_file" "DB_HOST" "$h"
                if [[ "$p" != "$default_p" || -z "$current_port" ]]; then
                    cfg_set "$config_file" "DB_PORT" "$p"
                    echo -e "${GREEN}Updated DB_HOST to $h and DB_PORT to $p${NC}"
                else
                    echo -e "${GREEN}Updated DB_HOST to $h${NC}"
                fi
            else
                cfg_set "$config_file" "$key" "$newval"
                echo -e "${GREEN}Updated $key${NC}"
            fi
        fi
    done

    echo -e "${GREEN}Done editing ${profile}.${NC}"
}

# ============================================================
#  COMMAND: remove
# ============================================================

_select_profile() {
    local prompt="$1"
    shopt -s nullglob
    local configs=( "$CONFIGS_DIR"/*.conf )
    shopt -u nullglob

    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No backup configs found.${NC}" >&2
        return 1
    fi

    local names=()
    local c
    for c in "${configs[@]}"; do
        names+=( "$(basename "$c" .conf)" )
    done

    ask_choice "$prompt" "${names[@]}"
}

cmd_remove() {
    local profile="${1:-}"
    if [[ -z "$profile" ]]; then
        profile=$(_select_profile "Which config to remove?") || return 1
    fi

    local config_file="$CONFIGS_DIR/${profile}.conf"
    if [[ ! -f "$config_file" ]]; then
        log_error "No such config: $profile"
        return 1
    fi

    if ask_yn "Remove '${profile}'? (backups and metadata are kept)" "n"; then
        rm -f "$config_file"
        cron_remove "$profile" >/dev/null 2>&1 || true
        echo -e "${GREEN}Removed config: ${profile}${NC}"
    else
        echo "Cancelled."
    fi
}

# ============================================================
#  COMMAND: list
# ============================================================

cmd_list() {
    shopt -s nullglob
    local configs=( "$CONFIGS_DIR"/*.conf )
    shopt -u nullglob

    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No backup configs found.${NC}"
        return
    fi

    echo -e "\n${BOLD}Saved backup configs:${NC}"
    local config
    for config in "${configs[@]}"; do
        [[ -f "$config" ]] || continue
        local name btype detail tg dc topic comp enc retention
        name=$(basename "$config" .conf)
        btype=$(cfg_get "$config" BACKUP_TYPE)
        tg=$(cfg_get "$config" TG_ENABLED "false")
        dc=$(cfg_get "$config" DC_ENABLED "false")
        topic=$(cfg_get "$config" TG_TOPIC_ID "")
        comp=$(cfg_get "$config" COMPRESSION "normal")
        enc=$(cfg_get "$config" ENCRYPTION "false")
        retention=$(cfg_get "$config" RETENTION_COUNT "0")

        if [[ "$btype" == "database" ]]; then
            local dtype dname
            dtype=$(cfg_get "$config" DB_TYPE)
            dname=$(cfg_get "$config" DB_NAME)
            detail="${dtype} -> ${dname}"
        else
            local fpath ftype
            fpath=$(cfg_get "$config" FILES_PATH)
            ftype=$(cfg_get "$config" FILES_TYPE "directory")
            detail="${ftype} -> ${fpath}"
        fi

        local tg_str dc_str enc_str topic_str=""
        [[ "$tg" == "true" ]] && tg_str="${GREEN}TG+${NC}" || tg_str="${RED}TG-${NC}"
        [[ "$dc" == "true" ]] && dc_str="${GREEN}DC+${NC}" || dc_str="${RED}DC-${NC}"
        [[ "$enc" == "true" ]] && enc_str="${GREEN}ENC+${NC}" || enc_str="${RED}ENC-${NC}"
        [[ -n "$topic" ]]     && topic_str=" topic:${topic}"

        local extra=""
        if [[ "$btype" == "files" ]]; then
            local ex
            ex=$(cfg_get "$config" EXCLUDE_PATTERNS "")
            [[ -n "$ex" ]] && extra="  excludes=${ex}"
        fi

        echo -e "  ${CYAN}${name}${NC}"
        echo -e "     ${detail}${topic_str}"
        echo -e "     compression=${comp}  retention=${retention}${extra}  [${tg_str} ${dc_str} ${enc_str}]"
    done
    echo
}

# ============================================================
#  COMMAND: run
# ============================================================

cmd_run() {
    local dry_run=false
    local only_profile=""

    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=true ;;
            *) only_profile="$arg" ;;
        esac
    done

    shopt -s nullglob
    local configs
    if [[ -n "$only_profile" ]]; then
        configs=( "$CONFIGS_DIR/${only_profile}.conf" )
        if [[ ! -f "${configs[0]}" ]]; then
            log_error "No such profile: $only_profile"
            shopt -u nullglob
            exit 1
        fi
    else
        configs=( "$CONFIGS_DIR"/*.conf )
    fi
    shopt -u nullglob

    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No backup configs found. Run 'archiver add' first.${NC}"
        return 0
    fi

    if [[ "$dry_run" == "false" ]]; then
        acquire_lock
    fi

    log_info "===== archiver run started (${#configs[@]} config(s)) dry_run=$dry_run ====="
    local success=0 failed=0 skipped=0

    local config
    for config in "${configs[@]}"; do
        [[ -f "$config" ]] || continue
        local profile btype
        profile=$(basename "$config" .conf)
        btype=$(cfg_get "$config" BACKUP_TYPE)

        echo -e "${BOLD}--- [$profile] type=$btype ---${NC}"

        local validate_tmp="$BACKUP_TMP/_val_$$_$(random_id).tmp"
        if ! cfg_validate "$config" > "$validate_tmp" 2>&1; then
            log_error "[$profile] Config invalid:"
            sed 's/^/    /' "$validate_tmp"
            rm -f "$validate_tmp"
            skipped=$(( skipped + 1 ))
            continue
        fi
        rm -f "$validate_tmp"

        if [[ "$dry_run" == "true" ]]; then
            _dry_run_describe "$config" "$profile" "$btype"
            continue
        fi

        if ! precheck_disk_space "$config" "$profile"; then
            meta_record_failure "$profile"
            notify_failure "$config" "$profile" "Insufficient disk space"
            failed=$(( failed + 1 ))
            continue
        fi

        local rc=0
        case "$btype" in
            database)
                local dtype
                dtype=$(cfg_get "$config" DB_TYPE)
                case "$dtype" in
                    mysql|mariadb)       run_db_backup "$config" "$profile" || rc=1 ;;
                    postgres|postgresql) run_postgres_backup "$config" "$profile" || rc=1 ;;
                    sqlite)              run_sqlite_backup "$config" "$profile" || rc=1 ;;
                    *) log_error "[$profile] Unknown DB type: $dtype"; rc=1 ;;
                esac
                ;;
            files)
                run_files_backup "$config" "$profile" || rc=1
                ;;
            *)
                log_error "[$profile] Unknown backup type"; rc=1 ;;
        esac

        if (( rc == 0 )); then
            meta_record_success "$profile"
            success=$(( success + 1 ))
        else
            meta_record_failure "$profile"
            notify_failure "$config" "$profile" "Backup execution or upload failed"
            failed=$(( failed + 1 ))
        fi
    done

    if [[ "$dry_run" == "true" ]]; then
        log_info "===== Dry run complete: ${#configs[@]} config(s) examined ====="
        return 0
    fi

    log_info "===== Done: $success succeeded, $failed failed, $skipped skipped ====="
    (( failed > 0 )) && return 1 || return 0
}

_dry_run_describe() {
    local config="$1" profile="$2" btype="$3"
    local comp encrypt retention
    comp=$(cfg_get "$config" COMPRESSION "normal")
    encrypt=$(cfg_get "$config" ENCRYPTION "false")
    retention=$(cfg_get "$config" RETENTION_COUNT "0")

    echo "  [DRY RUN] Would create archive for '$profile'"
    echo "    compression=$comp  encryption=$encrypt  retention=$retention"

    if [[ "$btype" == "database" ]]; then
        local dtype dname
        dtype=$(cfg_get "$config" DB_TYPE)
        dname=$(cfg_get "$config" DB_NAME)
        echo "    source: $dtype database '$dname'"
    else
        local fpath ftype
        fpath=$(cfg_get "$config" FILES_PATH)
        ftype=$(cfg_get "$config" FILES_TYPE "directory")
        echo "    source: $ftype '$fpath'"
        if [[ -e "$fpath" ]]; then
            local sz
            sz=$(du -sh "$fpath" 2>/dev/null | cut -f1)
            echo "    estimated size: ${sz:-unknown}"
        fi
        local ex
        ex=$(cfg_get "$config" EXCLUDE_PATTERNS "")
        [[ -n "$ex" ]] && echo "    excludes: $ex"
    fi

    local tg dc
    tg=$(cfg_get "$config" TG_ENABLED "false")
    dc=$(cfg_get "$config" DC_ENABLED "false")
    local dest=""
    [[ "$tg" == "true" ]] && dest+="Telegram "
    [[ "$dc" == "true" ]] && dest+="Discord "
    [[ -z "$dest" ]] && dest="(local only)"
    echo "    would upload to: $dest"
}

# ============================================================
#  COMMAND: restore
# ============================================================

cmd_restore() {
    echo -e "\n${BOLD}${GREEN}==================================${NC}"
    echo -e "${BOLD}${GREEN}    archiver restore              ${NC}"
    echo -e "${BOLD}${GREEN}==================================${NC}\n"

    shopt -s nullglob
    local archives=( "$BACKUP_OUT"/*.tar.gz "$BACKUP_OUT"/*.tar.gz.enc "$BACKUP_OUT"/*.part001 )
    shopt -u nullglob

    if [[ ${#archives[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No backup archives found in $BACKUP_OUT${NC}"
        return 0
    fi

    echo "Available backups:"
    local i
    for i in "${!archives[@]}"; do
        local f="${archives[$i]}"
        local fdate
        fdate=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)
        printf "  %2d) %-50s %8s  (%s)\n" "$((i+1))" "$(basename "$f")" \
            "$(human_size "$(get_file_size "$f")")" "$fdate"
    done
    echo

    local choice=""
    while true; do
        choice=$(_read_line "Select backup number (or q to quit)")
        [[ "$choice" == "q" ]] && return 0
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#archives[@]} )); then
            break
        fi
        echo "Invalid choice."
    done

    local selected="${archives[$((choice-1))]}"
    _restore_process "$selected"
}

# _restore_process <path-to-archive>
_restore_process() {
    local selected="$1"
    local work_dir="$RESTORE_DIR/restore_$$_$(random_id)"
    mkdir -p "$work_dir"
    chmod 700 "$work_dir"
    register_cleanup "$work_dir"

    local current="$selected"
    local base
    base=$(basename "$current")

    # Handle chunked parts: if selected file is partNNN, gather siblings
    if [[ "$base" =~ \.part[0-9]{3}$ ]]; then
        local stem="${base%.part*}"
        local dir
        dir=$(dirname "$current")
        echo "Merging chunks for $stem ..."
        local merged="$work_dir/$stem"
        local parts=()
        while IFS= read -r p; do
            parts+=("$p")
        done < <(ls -1 "$dir/${stem}".part* 2>/dev/null | sort)
        if [[ ${#parts[@]} -eq 0 ]]; then
            log_error "No chunk parts found for $stem"
            rm -rf "$work_dir"
            return 1
        fi
        cat "${parts[@]}" > "$merged"
        current="$merged"
        base="$stem"
    fi

    # Handle decryption
    if [[ "$base" =~ \.enc$ ]]; then
        local pass
        pass=$(ask_secret "Encryption password")
        local decrypted="$work_dir/${base%.enc}"
        if ! decrypt_file "$current" "$decrypted" "$pass"; then
            log_error "Decryption failed (wrong password?)"
            rm -rf "$work_dir"
            return 1
        fi
        current="$decrypted"
        base="${base%.enc}"
    fi

    # Verify it's a valid tar.gz
    if ! tar_verify "$current"; then
        log_error "Archive failed integrity check: $current"
        rm -rf "$work_dir"
        return 1
    fi

    local extract_dir="$work_dir/extracted"
    mkdir -p "$extract_dir"
    tar xzf "$current" -C "$extract_dir"

    echo
    echo "Archive extracted. Contents:"
    ls -la "$extract_dir"
    echo

    if [[ -f "$extract_dir/backup-info.txt" ]]; then
        echo "--- backup-info.txt ---"
        cat "$extract_dir/backup-info.txt"
        echo "------------------------"
    fi

    local sql_files=() sqlite_files=()
    while IFS= read -r f; do sql_files+=("$f"); done < <(ls -1 "$extract_dir"/*.sql 2>/dev/null || true)
    while IFS= read -r f; do sqlite_files+=("$f"); done < <(ls -1 "$extract_dir"/*.sqlite 2>/dev/null || true)

    if [[ ${#sql_files[@]} -gt 0 && -f "${sql_files[0]}" ]]; then
        local is_postgres=false
        if [[ -f "$extract_dir/backup-info.txt" ]] && grep -qiE "database \((postgres|postgresql)\)" "$extract_dir/backup-info.txt"; then
            is_postgres=true
        fi
        if [[ "$is_postgres" == "true" ]]; then
            _restore_postgres "${sql_files[0]}"
        else
            _restore_mysql "${sql_files[0]}"
        fi
    elif [[ ${#sqlite_files[@]} -gt 0 && -f "${sqlite_files[0]}" ]]; then
        _restore_sqlite "${sqlite_files[0]}"
    else
        _restore_files "$extract_dir"
    fi

    rm -rf "$work_dir"
}

_restore_postgres() {
    local sql_file="$1"
    echo
    echo "This appears to be a PostgreSQL dump."
    if ! ask_yn "Restore into a database now?" "n"; then
        echo "You can manually restore with:"
        echo "  psql -h HOST -p PORT -U USER -d DBNAME < '$sql_file'"
        return 0
    fi

    if ! command -v psql &>/dev/null; then
        log_error "psql client not found."
        return 1
    fi

    local raw_host host port user pass dbname default_db
    default_db="$(basename "$sql_file" .sql)"
    raw_host=$(ask "Host (e.g. localhost or 127.0.0.1:5432)" "localhost")
    local parsed_hp
    parsed_hp=$(parse_host_port "$raw_host" "localhost" "5432")
    host="${parsed_hp%%|*}"
    local guessed_port="${parsed_hp##*|}"
    port=$(ask "Port" "$guessed_port")
    user=$(ask "Username" "postgres")
    pass=$(ask_secret "Password")
    dbname=$(ask "Target database name" "$default_db")

    local pgpass
    pgpass=$(mktemp "$BACKUP_TMP/.pgpass_XXXXXX")
    chmod 600 "$pgpass"
    register_cleanup "$pgpass"
    local escaped_pass="${pass//\\/\\\\}"
    escaped_pass="${escaped_pass//:/\\:}"
    echo "${host}:${port}:${dbname}:${user}:${escaped_pass}" > "$pgpass"

    if PGPASSFILE="$pgpass" psql -h "$host" -p "$port" -U "$user" -d "$dbname" < "$sql_file"; then
        echo -e "${GREEN}Restore completed into '$dbname'.${NC}"
    else
        log_error "psql restore failed."
        rm -f "$pgpass"
        return 1
    fi
    rm -f "$pgpass"
}

_restore_mysql() {
    local sql_file="$1"
    echo
    echo "This appears to be a MySQL/MariaDB dump."
    if ! ask_yn "Restore into a database now?" "n"; then
        echo "You can manually restore with:"
        echo "  mysql -u USER -p DBNAME < '$sql_file'"
        return 0
    fi

    if ! command -v mysql &>/dev/null; then
        log_error "mysql client not found."
        return 1
    fi

    local raw_host host port user pass dbname default_db
    default_db="$(basename "$sql_file" .sql)"
    raw_host=$(ask "Host (e.g. localhost or 127.0.0.1:3306)" "localhost")
    local parsed_hp
    parsed_hp=$(parse_host_port "$raw_host" "localhost" "3306")
    host="${parsed_hp%%|*}"
    local guessed_port="${parsed_hp##*|}"
    port=$(ask "Port" "$guessed_port")
    user=$(ask "Username")
    pass=$(ask_secret "Password")
    dbname=$(ask "Target database name" "$default_db")

    local cnf
    cnf=$(mktemp "$BACKUP_TMP/.my_XXXXXX.cnf")
    chmod 600 "$cnf"
    register_cleanup "$cnf"
    {
        echo "[client]"
        echo "user=\"${user//\"/\\\"}\""
        echo "password=\"${pass//\"/\\\"}\""
        echo "host=\"${host//\"/\\\"}\""
        echo "port=\"${port//\"/\\\"}\""
        if [[ "$host" == "localhost" && "$port" != "3306" ]]; then
            echo "protocol=tcp"
        fi
    } > "$cnf"

    if mysql --defaults-extra-file="$cnf" "$dbname" < "$sql_file"; then
        echo -e "${GREEN}Restore completed into '$dbname'.${NC}"
    else
        log_error "mysql restore failed."
        rm -f "$cnf"
        return 1
    fi
    rm -f "$cnf"
}

_restore_sqlite() {
    local sqlite_file="$1"
    echo
    echo "This appears to be a SQLite database."
    local default_dest="$HOME/$(basename "$sqlite_file")"
    local dest
    dest=$(ask "Restore to path" "$default_dest")
    [[ -z "$dest" ]] && dest="$default_dest"

    mkdir -p "$(dirname "$dest")"
    if [[ -e "$dest" ]]; then
        if ! ask_yn "File '$dest' exists. Overwrite?" "n"; then
            echo "Cancelled."
            return 0
        fi
        cp "$dest" "${dest}.bak.$(timestamp)" 2>/dev/null || true
    fi

    if cp "$sqlite_file" "$dest"; then
        echo -e "${GREEN}Restored SQLite database to: $dest${NC}"
        if command -v sqlite3 &>/dev/null; then
            local check
            check=$(sqlite3 "$dest" "PRAGMA quick_check;" 2>&1 || echo "failed")
            if [[ "$check" == "ok" ]]; then
                echo -e "${GREEN}Integrity check passed (PRAGMA quick_check: ok)${NC}"
            else
                echo -e "${YELLOW}Warning: SQLite integrity check reported: $check${NC}"
            fi
        fi
    else
        log_error "Failed to copy SQLite database to: $dest"
        return 1
    fi
}

_restore_files() {
    local extract_dir="$1"
    echo
    echo "This appears to be a files/directory backup."
    local dest
    dest=$(ask "Restore destination directory" "$HOME/archiver_restore_$(timestamp)")
    mkdir -p "$dest"

    shopt -s dotglob nullglob
    local item cp_failed=0
    for item in "$extract_dir"/*; do
        [[ "$(basename "$item")" == "backup-info.txt" ]] && continue
        if ! cp -a "$item" "$dest/"; then
            cp_failed=1
        fi
    done
    shopt -u dotglob nullglob

    if (( cp_failed == 0 )); then
        echo -e "${GREEN}Restored files to: $dest${NC}"
    else
        log_error "One or more files failed to restore to: $dest"
        return 1
    fi
}

# ============================================================
#  COMMAND: cron
# ============================================================

CRON_TAG="# archiver-managed"

cron_expr_for_alias() {
    case "$1" in
        hourly)  echo "0 * * * *" ;;
        6h)      echo "0 */6 * * *" ;;
        daily)   echo "0 3 * * *" ;;
        weekly)  echo "0 3 * * 0" ;;
        *)       echo "$1" ;;
    esac
}

cron_expr_valid() {
    local expr="$1"
    local fields
    read -ra fields <<< "$expr"
    [[ ${#fields[@]} -eq 5 ]] || return 1
    local f
    for f in "${fields[@]}"; do
        [[ "$f" =~ ^[0-9A-Za-z*/,_-]+$ ]] || return 1
    done
    return 0
}

# cron_install <schedule_alias_or_expr> [profile]
cron_install() {
    local sched="$1" profile="${2:-}"
    local expr
    expr=$(cron_expr_for_alias "$sched")

    if ! cron_expr_valid "$expr"; then
        log_error "Invalid cron expression: $expr"
        return 1
    fi

    local script_path=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"
    fi
    if [[ -z "$script_path" || ! -x "$script_path" ]]; then
        script_path=$(command -v archiver 2>/dev/null || which archiver 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")
    fi
    if [[ "$script_path" != /* ]]; then
        script_path="$(pwd)/$script_path"
    fi

    local run_arg=""
    [[ -n "$profile" ]] && run_arg=" $profile"

    local cron_line="${expr} ${script_path} run${run_arg} >> ${LOG_DIR}/cron.log 2>&1 ${CRON_TAG}"

    local current
    current=$(crontab -l 2>/dev/null || true)

    local marker="run${run_arg}"
    if echo "$current" | grep -qF "$marker"; then
        log_warn "Cron entry for '${profile:-all profiles}' already exists. Skipping."
        return 0
    fi

    { echo "$current"; echo "$cron_line"; } | grep -v '^$' | crontab -
    log_info "Cron job installed: $cron_line"
}

cron_remove() {
    local profile="${1:-}"
    local current
    current=$(crontab -l 2>/dev/null || true)
    [[ -z "$current" ]] && { echo "No crontab entries."; return 0; }

    local filtered
    if [[ -n "$profile" ]]; then
        filtered=$(echo "$current" | grep -vE "(archiver.*run ${profile}(\b|[[:space:]])|${CRON_TAG}.*${profile})" || true)
    else
        filtered=$(echo "$current" | grep -vE "(${CRON_TAG}|archiver.*run)" || true)
    fi
    echo "$filtered" | grep -v '^$' | crontab -
    log_info "Removed cron entries for: ${profile:-all profiles}"
}

cron_show() {
    echo -e "${BOLD}Archiver-managed cron entries:${NC}"
    local entries
    entries=$(crontab -l 2>/dev/null | grep -E "(${CRON_TAG}|archiver.*run)" || true)
    if [[ -n "$entries" ]]; then
        echo "$entries"
    else
        echo "  (none)"
    fi
}

cmd_cron() {
    local sub="${1:-show}"; shift || true
    case "$sub" in
        install)
            local sched="${1:-daily}"
            local profile="${2:-}"
            cron_install "$sched" "$profile"
            ;;
        remove)
            cron_remove "${1:-}"
            ;;
        show)
            cron_show
            ;;
        *)
            echo "Usage: archiver cron {install <schedule> [profile]|remove [profile]|show}"
            return 1
            ;;
    esac
}

# ============================================================
#  COMMAND: doctor
# ============================================================

_doctor_check() {
    local label="$1" status="$2" detail="${3:-}"
    case "$status" in
        PASS) echo -e "  ${GREEN}[PASS]${NC} $label ${detail}" ;;
        WARN) echo -e "  ${YELLOW}[WARN]${NC} $label ${detail}" ;;
        FAIL) echo -e "  ${RED}[FAIL]${NC} $label ${detail}" ;;
    esac
}

cmd_doctor() {
    echo -e "\n${BOLD}Archiver Doctor${NC}\n"

    # Bash version
    local bmaj="${BASH_VERSINFO[0]}"
    if (( bmaj >= 4 )); then
        _doctor_check "Bash version" "PASS" "(${BASH_VERSION})"
    else
        _doctor_check "Bash version" "FAIL" "(${BASH_VERSION}, need 4+)"
    fi

    # Required tools
    local tool
    for tool in curl tar gzip; do
        if command -v "$tool" &>/dev/null; then
            _doctor_check "$tool" "PASS"
        else
            _doctor_check "$tool" "FAIL" "(not found, required)"
        fi
    done

    # Optional tools
    for tool in openssl sqlite3 mysqldump mysql pg_dump psql flock crontab; do
        if command -v "$tool" &>/dev/null; then
            _doctor_check "$tool" "PASS"
        else
            _doctor_check "$tool" "WARN" "(not found, optional)"
        fi
    done

    # Disk space
    local free
    free=$(disk_free_bytes "$BACKUP_OUT")
    if [[ -n "$free" ]] && (( free > 524288000 )); then
        _doctor_check "Disk space" "PASS" "($(human_size "$free") free in $BACKUP_OUT)"
    elif [[ -n "$free" ]]; then
        _doctor_check "Disk space" "WARN" "(only $(human_size "$free") free in $BACKUP_OUT)"
    else
        _doctor_check "Disk space" "WARN" "(could not determine)"
    fi

    # Directory permissions
    local d
    for d in "$ARCHIVER_HOME" "$CONFIGS_DIR" "$BACKUP_OUT" "$LOG_DIR"; do
        if [[ -d "$d" && -w "$d" ]]; then
            local perm
            perm=$(stat -c '%a' "$d" 2>/dev/null || stat -f '%Lp' "$d" 2>/dev/null)
            if [[ "$perm" == "700" ]]; then
                _doctor_check "Permissions: $d" "PASS" "(700)"
            else
                _doctor_check "Permissions: $d" "WARN" "(${perm}, expected 700)"
            fi
        else
            _doctor_check "Directory: $d" "FAIL" "(missing or not writable)"
        fi
    done

    # Crontab access
    if command -v crontab &>/dev/null; then
        if crontab -l &>/dev/null; then
            _doctor_check "Crontab access" "PASS"
        else
            _doctor_check "Crontab access" "WARN" "(no crontab for user yet, or access denied)"
        fi
    fi

    # Config validity summary
    shopt -s nullglob
    local configs=( "$CONFIGS_DIR"/*.conf )
    shopt -u nullglob

    if [[ ${#configs[@]} -eq 0 ]]; then
        _doctor_check "Backup configs" "WARN" "(none configured yet)"
    else
        local c bad=0
        for c in "${configs[@]}"; do
            if ! cfg_validate "$c" >/dev/null 2>&1; then
                (( bad++ )) || true
            fi
        done
        if (( bad > 0 )); then
            _doctor_check "Backup configs" "WARN" "($bad of ${#configs[@]} invalid)"
        else
            _doctor_check "Backup configs" "PASS" "(${#configs[@]} valid)"
        fi
    fi

    echo

    # â”€â”€ Per-config diagnostics â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    shopt -s nullglob
    local all_configs=( "$CONFIGS_DIR"/*.conf )
    shopt -u nullglob

    if [[ ${#all_configs[@]} -eq 0 ]]; then
        return 0
    fi

    local target="${1:-}"

    if [[ -z "$target" ]]; then
        local names=("(skip - none)")
        local c
        for c in "${all_configs[@]}"; do
            names+=( "$(basename "$c" .conf)" )
        done
        local pick
        pick=$(ask_choice "Run detailed diagnostics for a specific config?" "${names[@]}")
        [[ "$pick" == "(skip - none)" ]] && return 0
        target="$pick"
    fi

    local config_file="$CONFIGS_DIR/${target}.conf"
    if [[ ! -f "$config_file" ]]; then
        log_error "No such config: $target"
        return 1
    fi

    doctor_check_config "$config_file" "$target"
}

# ============================================================
#  PER-CONFIG DIAGNOSTICS
# ============================================================

# doctor_check_cpanel_quota
doctor_check_cpanel_quota() {
    if command -v quota &>/dev/null; then
        local out
        out=$(quota -v -s 2>/dev/null | tail -n +3 | head -1)
        if [[ -n "$out" ]]; then
            local used limit
            used=$(echo "$out" | awk '{print $2}' | tr -d '*')
            limit=$(echo "$out" | awk '{print $3}')
            if [[ "$used" =~ ^[0-9]+ && "$limit" =~ ^[0-9]+ && "$limit" -gt 0 ]]; then
                local pct
                pct=$(awk -v u="$used" -v l="$limit" 'BEGIN{printf "%.1f", (u/l)*100}')
                local pct_int
                pct_int=$(awk -v p="$pct" 'BEGIN{printf "%d", p}')
                if (( pct_int >= 95 )); then
                    _doctor_check "cPanel disk quota" "FAIL" "(${pct}% used: ${used}/${limit})"
                elif (( pct_int >= 85 )); then
                    _doctor_check "cPanel disk quota" "WARN" "(${pct}% used: ${used}/${limit})"
                else
                    _doctor_check "cPanel disk quota" "PASS" "(${pct}% used: ${used}/${limit})"
                fi
                return
            fi
        fi
    fi

    # Fallback: filesystem-level free space for $HOME
    local free
    free=$(disk_free_bytes "$HOME")
    if [[ -n "$free" ]]; then
        if (( free > 524288000 )); then
            _doctor_check "Disk space (\$HOME filesystem)" "PASS" "($(human_size "$free") free)"
        else
            _doctor_check "Disk space (\$HOME filesystem)" "WARN" "(only $(human_size "$free") free)"
        fi
    else
        _doctor_check "Disk space (\$HOME filesystem)" "WARN" "(could not determine; 'quota' command not available)"
    fi
}

# doctor_check_telegram <token> <chat_id> [topic_id]
doctor_check_telegram() {
    local token="$1" chat_id="$2" topic_id="${3:-}"

    if [[ -z "$token" || -z "$chat_id" ]]; then
        _doctor_check "Telegram bot/chat access" "WARN" "(token or chat ID not set)"
        return
    fi

    local body
    body=$(curl --max-time 30 -s "https://api.telegram.org/bot${token}/getChat?chat_id=${chat_id}" 2>&1)

    if echo "$body" | grep -q '"ok":[[:space:]]*true'; then
        local title
        title=$(echo "$body" | grep -o '"title"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"(.*)"/\1/')
        _doctor_check "Telegram bot/chat access" "PASS" "(chat: ${title:-$chat_id})"
    else
        local desc
        desc=$(echo "$body" | grep -o '"description"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:[[:space:]]*"(.*)"/\1/')
        _doctor_check "Telegram bot/chat access" "FAIL" "(${desc:-unable to reach chat $chat_id})"
        return
    fi

    # Verify send permission (with optional topic)
    local send_args=()
    send_args+=( --data-urlencode "chat_id=${chat_id}" )
    send_args+=( --data-urlencode "text=archiver doctor: connectivity check" )
    [[ -n "$topic_id" ]] && send_args+=( --data-urlencode "message_thread_id=${topic_id}" )

    local send_body
    send_body=$(curl --max-time 30 -s -X POST \
        "https://api.telegram.org/bot${token}/sendMessage" \
        "${send_args[@]}" 2>&1)

    if echo "$send_body" | grep -q '"ok":[[:space:]]*true'; then
        local check_label="Telegram send-message permission"
        [[ -n "$topic_id" ]] && check_label="Telegram topic ($topic_id) access"
        _doctor_check "$check_label" "PASS" "(test message sent)"

        local msg_id
        msg_id=$(echo "$send_body" | grep -o '"message_id"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*$')
        if [[ -n "$msg_id" ]]; then
            curl --max-time 30 -s -X POST "https://api.telegram.org/bot${token}/deleteMessage" \
                --data-urlencode "chat_id=${chat_id}" \
                --data-urlencode "message_id=${msg_id}" >/dev/null 2>&1 || true
        fi
    else
        local desc2
        desc2=$(echo "$send_body" | grep -o '"description"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:[[:space:]]*"(.*)"/\1/')
        local check_label="Telegram send-message permission"
        [[ -n "$topic_id" ]] && check_label="Telegram topic ($topic_id) access"
        _doctor_check "$check_label" "FAIL" "(${desc2:-bot cannot send messages})"
    fi
}

# doctor_check_discord <webhook_url>
doctor_check_discord() {
    local webhook="$1"

    if [[ -z "$webhook" ]]; then
        _doctor_check "Discord webhook" "WARN" "(webhook URL not set)"
        return
    fi

    local resp_file="$BACKUP_TMP/_dc_resp_$$_$(random_id)"
    local http_code
    http_code=$(curl --max-time 30 -s -o "$resp_file" -w "%{http_code}" "$webhook" 2>/dev/null)
    local body
    body=$(cat "$resp_file" 2>/dev/null || echo "")
    rm -f "$resp_file"

    if [[ "$http_code" =~ ^[0-9]+$ ]] && (( http_code >= 200 && http_code < 300 )); then
        local name
        name=$(echo "$body" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:[[:space:]]*"(.*)"/\1/')
        _doctor_check "Discord webhook access" "PASS" "(webhook: ${name:-ok})"
    else
        _doctor_check "Discord webhook access" "FAIL" "(HTTP ${http_code})"
    fi
}

# doctor_check_db_connection <config>
doctor_check_db_connection() {
    local config="$1"
    local dtype
    dtype=$(cfg_get "$config" DB_TYPE)

    case "$dtype" in
        mysql|mariadb)
            if ! command -v mysql &>/dev/null; then
                _doctor_check "Database connection ($dtype)" "WARN" "(mysql client not installed; cannot test)"
                return
            fi

            local db_host db_port db_user db_pass db_name
            db_host=$(cfg_get "$config" DB_HOST "localhost")
            db_port=$(cfg_get "$config" DB_PORT "3306")
            db_user=$(cfg_get "$config" DB_USER)
            db_pass=$(cfg_get "$config" DB_PASS)
            db_name=$(cfg_get "$config" DB_NAME)

            local parsed_hp
            parsed_hp=$(parse_host_port "$db_host" "localhost" "$db_port")
            db_host="${parsed_hp%%|*}"
            db_port="${parsed_hp##*|}"

            local cnf
            cnf=$(mktemp "$BACKUP_TMP/.my_XXXXXX.cnf")
            chmod 600 "$cnf"
            register_cleanup "$cnf"
            {
                echo "[client]"
                echo "user=\"${db_user//\"/\\\"}\""
                echo "password=\"${db_pass//\"/\\\"}\""
                echo "host=\"${db_host//\"/\\\"}\""
                echo "port=\"${db_port//\"/\\\"}\""
                if [[ "$db_host" == "localhost" && "$db_port" != "3306" ]]; then
                    echo "protocol=tcp"
                fi
            } > "$cnf"

            local err_out
            err_out=$(mysql --defaults-extra-file="$cnf" -e "SELECT 1;" "$db_name" 2>&1 >/dev/null)
            local rc=$?
            rm -f "$cnf"

            if (( rc == 0 )); then
                _doctor_check "Database connection ($dtype)" "PASS" "(connected to '${db_name}' @ ${db_host}:${db_port})"
            else
                _doctor_check "Database connection ($dtype)" "FAIL" "($(echo "$err_out" | head -1))"
            fi
            ;;
        postgres|postgresql)
            if ! command -v psql &>/dev/null; then
                _doctor_check "Database connection ($dtype)" "WARN" "(psql client not installed; cannot test)"
                return
            fi

            local db_host db_port db_user db_pass db_name
            db_host=$(cfg_get "$config" DB_HOST "localhost")
            db_port=$(cfg_get "$config" DB_PORT "5432")
            db_user=$(cfg_get "$config" DB_USER)
            db_pass=$(cfg_get "$config" DB_PASS)
            db_name=$(cfg_get "$config" DB_NAME)

            local parsed_hp
            parsed_hp=$(parse_host_port "$db_host" "localhost" "$db_port")
            db_host="${parsed_hp%%|*}"
            db_port="${parsed_hp##*|}"

            local pgpass
            pgpass=$(mktemp "$BACKUP_TMP/.pgpass_XXXXXX")
            chmod 600 "$pgpass"
            register_cleanup "$pgpass"
            local escaped_pass="${db_pass//\\/\\\\}"
            escaped_pass="${escaped_pass//:/\\:}"
            echo "${db_host}:${db_port}:${db_name}:${db_user}:${escaped_pass}" > "$pgpass"

            local err_out
            err_out=$(PGPASSFILE="$pgpass" psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" -c "SELECT 1;" 2>&1 >/dev/null)
            local rc=$?
            rm -f "$pgpass"

            if (( rc == 0 )); then
                _doctor_check "Database connection ($dtype)" "PASS" "(connected to '${db_name}' @ ${db_host}:${db_port})"
            else
                _doctor_check "Database connection ($dtype)" "FAIL" "($(echo "$err_out" | head -1))"
            fi
            ;;
        sqlite)
            local db_path
            db_path=$(cfg_get "$config" DB_PATH)

            if [[ ! -f "$db_path" ]]; then
                _doctor_check "Database file (sqlite)" "FAIL" "(not found: $db_path)"
                return
            fi
            if [[ ! -r "$db_path" ]]; then
                _doctor_check "Database file (sqlite)" "FAIL" "(not readable: $db_path)"
                return
            fi

            if command -v sqlite3 &>/dev/null; then
                local check
                check=$(sqlite3 "$db_path" "PRAGMA quick_check;" 2>&1)
                if [[ "$check" == "ok" ]]; then
                    _doctor_check "Database file (sqlite)" "PASS" "($db_path, integrity ok)"
                else
                    _doctor_check "Database file (sqlite)" "FAIL" "(integrity check: $check)"
                fi
            else
                _doctor_check "Database file (sqlite)" "WARN" "(found and readable; sqlite3 not installed to verify integrity)"
            fi
            ;;
        *)
            _doctor_check "Database connection" "WARN" "(unknown DB_TYPE: $dtype)"
            ;;
    esac
}

# doctor_check_files_path <config>
doctor_check_files_path() {
    local config="$1"
    local path ftype
    path=$(cfg_get "$config" FILES_PATH)
    ftype=$(cfg_get "$config" FILES_TYPE "directory")

    if [[ -z "$path" ]]; then
        _doctor_check "Source path" "FAIL" "(FILES_PATH not set)"
        return
    fi

    if [[ ! -e "$path" ]]; then
        _doctor_check "Source path" "FAIL" "(does not exist: $path)"
        return
    fi

    if [[ ! -r "$path" ]]; then
        _doctor_check "Source path" "FAIL" "(exists but not readable: $path)"
        return
    fi

    if [[ "$ftype" == "directory" && ! -d "$path" ]]; then
        _doctor_check "Source path" "WARN" "(configured as directory but is a file: $path)"
        return
    fi

    if [[ "$ftype" == "file" && ! -f "$path" ]]; then
        _doctor_check "Source path" "WARN" "(configured as single file but is not a regular file: $path)"
        return
    fi

    local size
    if [[ -d "$path" ]]; then
        size=$(du -sh "$path" 2>/dev/null | cut -f1)
    else
        size=$(human_size "$(get_file_size "$path")")
    fi
    _doctor_check "Source path" "PASS" "($path, ~${size:-unknown})"
}

# doctor_check_config <config_file> <profile>
doctor_check_config() {
    local config="$1" profile="$2"

    echo -e "\n${BOLD}Diagnostics for profile: ${CYAN}${profile}${NC}${BOLD} --------------------${NC}\n"

    # 1) General checks
    echo -e "${BOLD}General checks:${NC}"
    local bmaj="${BASH_VERSINFO[0]}"
    if (( bmaj >= 4 )); then
        _doctor_check "Bash version" "PASS" "(${BASH_VERSION})"
    else
        _doctor_check "Bash version" "FAIL" "(${BASH_VERSION}, need 4+)"
    fi

    local tool
    for tool in curl tar gzip; do
        if command -v "$tool" &>/dev/null; then
            _doctor_check "$tool" "PASS"
        else
            _doctor_check "$tool" "FAIL" "(not found, required)"
        fi
    done

    local free
    free=$(disk_free_bytes "$BACKUP_OUT")
    if [[ -n "$free" ]] && (( free > 524288000 )); then
        _doctor_check "Disk space (backups dir)" "PASS" "($(human_size "$free") free)"
    else
        _doctor_check "Disk space (backups dir)" "WARN" "(low or unknown: $(human_size "${free:-0}"))"
    fi

    local validate_tmp="$BACKUP_TMP/_val_$$_$(random_id).tmp"
    if ! cfg_validate "$config" > "$validate_tmp" 2>&1; then
        _doctor_check "Config validity" "FAIL" "($(tr '\n' ' ' < "$validate_tmp"))"
    else
        _doctor_check "Config validity" "PASS"
    fi
    rm -f "$validate_tmp"

    # Encryption check
    local enc_enabled
    enc_enabled=$(cfg_get "$config" ENCRYPTION "false")
    if [[ "$enc_enabled" == "true" ]]; then
        echo -e "\n${BOLD}Encryption:${NC}"
        if command -v openssl &>/dev/null; then
            local enc_pass
            enc_pass=$(cfg_get "$config" ENC_PASSWORD "")
            if [[ -n "$enc_pass" ]]; then
                _doctor_check "AES-256 encryption" "PASS" "(openssl available, password configured)"
            else
                _doctor_check "AES-256 encryption" "FAIL" "(encryption enabled but password is empty)"
            fi
        else
            _doctor_check "AES-256 encryption" "FAIL" "(openssl not found; required for encryption)"
        fi
    fi

    # 2) cPanel / hosting account disk quota
    echo -e "\n${BOLD}Account disk usage:${NC}"
    doctor_check_cpanel_quota

    # 3) Telegram connectivity
    local tg_enabled
    tg_enabled=$(cfg_get "$config" TG_ENABLED "false")
    if [[ "$tg_enabled" == "true" ]]; then
        echo -e "\n${BOLD}Telegram:${NC}"
        local tg_token tg_chat tg_topic
        tg_token=$(cfg_get "$config" TG_TOKEN)
        tg_chat=$(cfg_get "$config" TG_CHAT_ID)
        tg_topic=$(cfg_get "$config" TG_TOPIC_ID)
        doctor_check_telegram "$tg_token" "$tg_chat" "$tg_topic"
    fi

    # 4) Discord connectivity
    local dc_enabled
    dc_enabled=$(cfg_get "$config" DC_ENABLED "false")
    if [[ "$dc_enabled" == "true" ]]; then
        echo -e "\n${BOLD}Discord:${NC}"
        local dc_url
        dc_url=$(cfg_get "$config" DC_URL)
        doctor_check_discord "$dc_url"
    fi

    # 5) Source-specific checks
    local btype
    btype=$(cfg_get "$config" BACKUP_TYPE)
    if [[ "$btype" == "database" ]]; then
        echo -e "\n${BOLD}Database:${NC}"
        doctor_check_db_connection "$config"
    elif [[ "$btype" == "files" ]]; then
        echo -e "\n${BOLD}Source path:${NC}"
        doctor_check_files_path "$config"
    fi

    echo
}

# ============================================================
#  COMMAND: test
# ============================================================

cmd_test() {
    echo -e "\n${BOLD}Archiver Test${NC}\n"

    local work_dir="$BACKUP_TMP/test_$$_$(random_id)"
    mkdir -p "$work_dir"
    register_cleanup "$work_dir"

    echo "Hello from archiver test at $(date)" > "$work_dir/testfile.txt"

    # Compression test
    local archive="$work_dir/test.tar.gz"
    if tar_create "$archive" "normal" "$work_dir" "testfile.txt"; then
        _doctor_check "Compression" "PASS" "($(human_size "$(get_file_size "$archive")"))"
    else
        _doctor_check "Compression" "FAIL"
    fi

    if tar_verify "$archive"; then
        _doctor_check "Archive integrity" "PASS"
    else
        _doctor_check "Archive integrity" "FAIL"
    fi

    # Encryption test
    if command -v openssl &>/dev/null; then
        local enc="$archive.enc" dec="$work_dir/test_dec.tar.gz"
        if encrypt_file "$archive" "$enc" "testpassword123"; then
            if decrypt_file "$enc" "$dec" "testpassword123" && cmp -s "$archive" "$dec"; then
                _doctor_check "Encryption / Decryption" "PASS"
            else
                _doctor_check "Encryption / Decryption" "FAIL" "(roundtrip mismatch)"
            fi
        else
            _doctor_check "Encryption" "FAIL"
        fi
    else
        _doctor_check "Encryption" "WARN" "(openssl not available)"
    fi

    # Upload tests
    if ask_yn "Test Telegram/Discord uploads using a saved config?" "n"; then
        local profile
        profile=$(_select_profile "Which config to test uploads with?") || return 0
        local config="$CONFIGS_DIR/${profile}.conf"

        local tg_enabled dc_enabled
        tg_enabled=$(cfg_get "$config" TG_ENABLED "false")
        dc_enabled=$(cfg_get "$config" DC_ENABLED "false")

        if [[ "$tg_enabled" == "true" ]]; then
            local token chat topic
            token=$(cfg_get "$config" TG_TOKEN)
            chat=$(cfg_get "$config" TG_CHAT_ID)
            topic=$(cfg_get "$config" TG_TOPIC_ID)
            if send_telegram_file "$archive" "$token" "$chat" "$topic" "Archiver test upload"; then
                _doctor_check "Telegram upload" "PASS"
            else
                _doctor_check "Telegram upload" "FAIL" "($UPLOAD_ERR)"
            fi
        else
            _doctor_check "Telegram upload" "WARN" "(not enabled for $profile)"
        fi

        if [[ "$dc_enabled" == "true" ]]; then
            local webhook
            webhook=$(cfg_get "$config" DC_URL)
            if send_discord_file "$archive" "$webhook" "Archiver test upload"; then
                _doctor_check "Discord upload" "PASS"
            else
                _doctor_check "Discord upload" "FAIL" "($UPLOAD_ERR)"
            fi
        else
            _doctor_check "Discord upload" "WARN" "(not enabled for $profile)"
        fi
    fi

    rm -rf "$work_dir"
    echo
}

# ============================================================
#  COMMAND: stats
# ============================================================

cmd_stats() {
    echo -e "\n${BOLD}Archiver Stats${NC}\n"

    shopt -s nullglob
    local configs=( "$CONFIGS_DIR"/*.conf )
    local archives=( "$BACKUP_OUT"/*.tar.gz "$BACKUP_OUT"/*.tar.gz.enc "$BACKUP_OUT"/*.part* )
    shopt -u nullglob

    echo "Total Configs: ${#configs[@]}"
    echo "Total Backups (files): ${#archives[@]}"

    local total_size=0
    if (( ${#archives[@]} > 0 )); then
        local a
        for a in "${archives[@]}"; do
            [[ -f "$a" ]] || continue
            total_size=$(( total_size + $(get_file_size "$a") ))
        done
    fi
    echo "Disk Usage (backups dir): $(human_size "$total_size")"
    echo

    if (( ${#configs[@]} > 0 )); then
        local c
        for c in "${configs[@]}"; do
            [[ -f "$c" ]] || continue
            local profile
            profile=$(basename "$c" .conf)
            local mf
            mf=$(meta_file_for "$profile")

            local last_success last_fail consec total_runs total_success rate
            last_success=$(cfg_get "$mf" LAST_SUCCESS "never")
            last_fail=$(cfg_get "$mf" LAST_FAILURE "never")
            consec=$(cfg_get "$mf" CONSEC_FAILURES "0")
            total_runs=$(cfg_get "$mf" TOTAL_RUNS "0")
            total_success=$(cfg_get "$mf" TOTAL_SUCCESS "0")

            if [[ "$total_runs" -gt 0 ]]; then
                rate=$(awk -v s="$total_success" -v t="$total_runs" 'BEGIN{printf "%.1f", (s/t)*100}')
            else
                rate="n/a"
            fi

            echo -e "${CYAN}${profile}${NC}"
            echo "  Last Successful Backup: $last_success"
            echo "  Last Failed Backup:     $last_fail"
            echo "  Success Rate:           ${rate}% (${total_success}/${total_runs})"
            if [[ "$consec" =~ ^[0-9]+$ ]] && (( consec >= 3 )); then
                echo -e "  Consecutive Failures:   ${RED}${consec}${NC}"
            else
                echo "  Consecutive Failures:   $consec"
            fi
            echo
        done
    fi
}

# ============================================================
#  COMMAND: logs
# ============================================================

cmd_logs() {
    local n="${1:-50}"
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
        n=50
    fi

    if [[ ! -f "$LOG_FILE" ]]; then
        echo -e "${YELLOW}No log file yet.${NC}"
        return 0
    fi

    tail -n "$n" "$LOG_FILE" | while IFS= read -r line; do
        case "$line" in
            *"[ERROR]"*) echo -e "${RED}${line}${NC}" ;;
            *"[WARN]"*)  echo -e "${YELLOW}${line}${NC}" ;;
            *"[DEBUG]"*) echo -e "${BLUE}${line}${NC}" ;;
            *)           echo "$line" ;;
        esac
    done
}

# ============================================================
#  COMMAND: find
# ============================================================

cmd_find() {
    local term="${1:-}"
    if [[ -z "$term" ]]; then
        echo "Usage: archiver find <term>"
        return 1
    fi

    echo -e "\n${BOLD}Searching backups for: ${term}${NC}\n"

    shopt -s nullglob nocaseglob
    local archives=( "$BACKUP_OUT"/*"$term"* )
    shopt -u nullglob nocaseglob

    if [[ ${#archives[@]} -eq 0 ]]; then
        echo "No archive filenames matched. Checking config profiles..."
        shopt -s nullglob nocaseglob
        local configs=( "$CONFIGS_DIR"/*"$term"*.conf )
        shopt -u nullglob nocaseglob
        if [[ ${#configs[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No matches found.${NC}"
            return 0
        fi
        local c
        for c in "${configs[@]}"; do
            echo "  Config: $(basename "$c" .conf)"
        done
        return 0
    fi

    local f
    for f in "${archives[@]}"; do
        [[ -f "$f" ]] || continue
        local fdate
        fdate=$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)
        printf "  %-50s %8s  %s\n" "$(basename "$f")" "$(human_size "$(get_file_size "$f")")" "$fdate"
    done
    echo
}

# ============================================================
#  COMMAND: export / import
# ============================================================

cmd_export() {
    local out="${1:-$ARCHIVER_HOME/archiver-export-$(timestamp).tar.gz}"

    shopt -s nullglob
    local configs=( "$CONFIGS_DIR"/*.conf )
    shopt -u nullglob

    if [[ ${#configs[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No configs to export.${NC}"
        return 0
    fi

    if ask_yn "Exported configs may contain plaintext-recoverable secrets (passwords, tokens) once decoded. Continue?" "y"; then
        tar czf "$out" -C "$CONFIGS_DIR" .
        chmod 600 "$out"
        echo -e "${GREEN}Exported ${#configs[@]} config(s) to: $out${NC}"
        echo -e "${YELLOW}Keep this file secure - it contains credentials.${NC}"
    else
        echo "Cancelled."
    fi
}

cmd_import() {
    local in="${1:-}"
    if [[ -z "$in" || ! -f "$in" ]]; then
        echo "Usage: archiver import <export-file.tar.gz>"
        return 1
    fi

    if ! tar_verify "$in"; then
        log_error "Import file failed integrity check."
        return 1
    fi

    local tmp_dir="$BACKUP_TMP/import_$$_$(random_id)"
    mkdir -p "$tmp_dir"
    register_cleanup "$tmp_dir"
    tar xzf "$in" -C "$tmp_dir"

    local imported=0 skipped=0
    local f
    for f in "$tmp_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f")
        local dest="$CONFIGS_DIR/$name"
        if [[ -f "$dest" ]]; then
            if ! ask_yn "Config '$name' already exists. Overwrite?" "n"; then
                skipped=$(( skipped + 1 ))
                continue
            fi
        fi
        cp "$f" "$dest"
        chmod 600 "$dest"
        imported=$(( imported + 1 ))
    done

    rm -rf "$tmp_dir"
    echo -e "${GREEN}Imported: $imported, Skipped: $skipped${NC}"
}

# ============================================================
#  COMMAND: update-check
# ============================================================

cmd_update_check() {
    echo -e "\n${BOLD}Archiver Update Check${NC}\n"
    echo "Current version: $ARCHIVER_VERSION"
    echo
    echo "Automatic update checking is not yet configured."
    echo "To check for updates manually, visit the project repository:"
    echo "  https://github.com/s7net/archiver/releases"
    echo
    echo "(Future versions will query the GitHub Releases API automatically.)"
}

# ============================================================
#  COMMAND: version / help
# ============================================================

cmd_version() {
    echo "Archiver v${ARCHIVER_VERSION}"
}

cmd_help() {
    echo -e "
${BOLD}Archiver${NC} - backup tool for Linux / cPanel / DirectAdmin servers
Version ${ARCHIVER_VERSION}

${BOLD}USAGE${NC}
  archiver <command> [arguments]

${BOLD}COMMANDS${NC}
  ${CYAN}add${NC}                     Add a new backup configuration (interactive wizard)
  ${CYAN}edit${NC} [profile]          Edit an existing configuration
  ${CYAN}remove${NC} [profile]        Remove a configuration
  ${CYAN}list${NC}                    List all configurations

  ${CYAN}run${NC} [profile] [--dry-run]
                          Run all backups, or a single profile.
                          --dry-run shows what would happen without doing it.

  ${CYAN}restore${NC}                 Interactive restore wizard

  ${CYAN}cron install${NC} <schedule> [profile]
                          Install a cron job. schedule = hourly|6h|daily|weekly|\"cron expr\"
  ${CYAN}cron remove${NC} [profile]   Remove cron job(s)
  ${CYAN}cron show${NC}               Show archiver-managed cron entries

  ${CYAN}doctor${NC} [profile]        Run environment / health checks (optionally for a specific profile)
  ${CYAN}test${NC}                    Run a self-test (compression, encryption, uploads)
  ${CYAN}stats${NC}                   Show backup statistics
  ${CYAN}logs${NC} [n]                Show last n log lines (default 50)
  ${CYAN}find${NC} <term>             Search backups by name/date/profile

  ${CYAN}export${NC} [file]           Export all configs to a tar.gz
  ${CYAN}import${NC} <file>           Import configs from a tar.gz

  ${CYAN}version${NC}                 Show version
  ${CYAN}update-check${NC}            Check for updates
  ${CYAN}help${NC}                    Show this help

${BOLD}DIRECTORIES${NC}
  Home:     ${ARCHIVER_HOME}
  Configs:  ${CONFIGS_DIR}
  Backups:  ${BACKUP_OUT}
  Logs:     ${LOG_DIR}
"
}

# ============================================================
#  ENTRY POINT
# ============================================================

CMD="${1:-help}"
shift || true

case "$CMD" in
    add)            cmd_add "$@" ;;
    edit)           cmd_edit "$@" ;;
    remove)         cmd_remove "$@" ;;
    list)           cmd_list "$@" ;;
    run)            cmd_run "$@" ;;
    restore)        cmd_restore "$@" ;;
    cron)           cmd_cron "$@" ;;
    doctor)         cmd_doctor "$@" ;;
    test)           cmd_test "$@" ;;
    stats)          cmd_stats "$@" ;;
    logs)           cmd_logs "$@" ;;
    find)           cmd_find "$@" ;;
    export)         cmd_export "$@" ;;
    import)         cmd_import "$@" ;;
    version|-v|--version) cmd_version ;;
    update-check)   cmd_update_check ;;
    help|-h|--help|*) cmd_help ;;
esac
