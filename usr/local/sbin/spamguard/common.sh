#!/bin/bash

# Debug configuration
DEBUG=${DEBUG:-0}

# Log level matrix
declare -A LOG_LEVELS=(
    [0]="INFO"
    [5]="DEBUG"
)

# Common configuration paths
CONFIG_DIR="/etc/spamguard"
MAIL_DIRS_CONFIG="$CONFIG_DIR/mail_dirs.txt"
STAGING_ROOT="/var/spam_processing"
HAM_STAGING="$STAGING_ROOT/ham_staging"
SPAM_STAGING="$STAGING_ROOT/spam_staging"

# Common regex patterns
SPAM_DIR_REGEX=".*(/(\.)?(spam|junk|junk[-._ ]*e[-._ ]*mail))"

# Logging function
log() {
    local req_level=$1
    shift
    local level_name="${LOG_LEVELS[$req_level]:-UNKNOWN}"
    
    if [ $DEBUG -ge $req_level ]; then
        local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        if [ $# -eq 0 ]; then
            while IFS= read -r line; do
                echo "$timestamp [$level_name] $line"
            done
        else
            echo "$timestamp [$level_name] $*"
        fi
    fi
}

# Run command and log its output
run_and_log() {
    local level=$1
    shift
    local cmd="$*"
    log $level "Running: $cmd"
    local output
    local tmpfile=$(mktemp)
    if "$@" > "$tmpfile" 2>&1; then
        local status=0
    else
        local status=$?
    fi
    cat "$tmpfile" | log $level
    rm -f "$tmpfile"
    return $status
}

# Create staging directories for a user
ensure_staging_directories() {
    local user="$1"
    local ham_dir="$HAM_STAGING/$user"
    local spam_dir="$SPAM_STAGING/$user"
    
    mkdir -p "$ham_dir" "$spam_dir"
    log 5 "Created staging directories for $user: $ham_dir, $spam_dir"
}

# Mail file processing functions
get_mail_subject() {
    local mail_file="$1"
    grep -i "^Subject:" "$mail_file" | sed 's/^Subject:\s*//i'
}

get_mail_from() {
    local mail_file="$1"
    grep -i "^From:" "$mail_file" | sed 's/^From:\s*//i'
}

get_mail_date() {
    local mail_file="$1"
    grep -i "^Date:" "$mail_file" | sed 's/^Date:\s*//i'
}

# Safe file operations
safe_copy() {
    local src="$1"
    local dst="$2"
    if [[ ! -f "$src" ]]; then
        log 0 "Error: Source file does not exist: $src"
        return 1
    fi
    
    cp -p "$src" "$dst.tmp"
    mv "$dst.tmp" "$dst"
}

safe_move() {
    local src="$1"
    local dst="$2"
    if [[ ! -f "$src" ]]; then
        log 0 "Error: Source file does not exist: $src"
        return 1
    fi
    
    mv "$src" "$dst.tmp"
    mv "$dst.tmp" "$dst"
}

# Check if a path is a valid Maildir
is_valid_maildir() {
    local dir="$1"
    [[ -d "$dir" && -d "$dir/new" && -d "$dir/cur" && -d "$dir/tmp" ]]
}

# Parse email headers into associative array
parse_mail_headers() {
    local mail_file="$1"
    local -n headers=$2  # Name reference to the associative array
    
    local in_headers=true
    local current_header=""
    local line
    
    while IFS= read -r line; do
        if [[ -z "$line" && "$in_headers" = true ]]; then
            in_headers=false
            break
        fi
        
        if [[ "$in_headers" = true ]]; then
            if [[ "$line" =~ ^[A-Za-z-]+: ]]; then
                current_header="${line%%:*}"
                headers["$current_header"]="${line#*: }"
            elif [[ -n "$current_header" && "$line" =~ ^[[:space:]] ]]; then
                headers["$current_header"]+=" ${line## }"
            fi
        fi
    done < "$mail_file"
}