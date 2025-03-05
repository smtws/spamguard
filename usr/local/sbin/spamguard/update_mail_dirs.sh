#!/bin/bash
set -e

# Debug configuration
DEBUG=0

# Log level matrix
declare -A LOG_LEVELS=(
    [0]="INFO"
    [5]="DEBUG"
)

# Configuration
CONFIG="/etc/spamguard/mail_dirs.txt"
SPAM_DIR_REGEX=".*(/(\.)?(spam|junk|junk[-._ ]*e[-._ ]*mail))"
STAGING_ROOT="/var/spam_processing"
HAM_STAGING="$STAGING_ROOT/ham_staging"
SPAM_STAGING="$STAGING_ROOT/spam_staging"

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

# Output function for capturing Maildir paths
output_maildir() {
    local maildir="$1"
    printf "%s\n" "$maildir"
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

# Create staging directories
ensure_staging_directories() {
    local user="$1"
    local ham_dir="$HAM_STAGING/$user"
    local spam_dir="$SPAM_STAGING/$user"
    
    mkdir -p "$ham_dir" "$spam_dir"
    log 5 "Created staging directories for $user: $ham_dir, $spam_dir"
}

# Find Maildir locations
find_mail_locations() {
    # Process each user from passwd database
    while IFS=: read -r username _ _ _ _ home_dir _; do
        maildir="$home_dir/Maildir"
        if [[ -d "$maildir" ]]; then
            ensure_staging_directories "$username"
            log 5 "Found Maildir for user $username: $maildir"
            output_maildir "$maildir"
        fi
        
        # Check for virtual users in homes directory
        if [[ -d "$home_dir/homes" ]]; then
            while IFS= read -r vuser_dir; do
                vuser=$(basename "$vuser_dir")
                vmaildir="$vuser_dir/Maildir"
                if [[ -d "$vmaildir" ]]; then
                    ensure_staging_directories "$vuser"
                    log 5 "Found Maildir for virtual user $vuser: $vmaildir"
                    output_maildir "$vmaildir"
                fi
            done < <(find "$home_dir/homes" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        fi
    done < <(getent passwd)
}

# Main process
log 0 "Updating mail directory list"
find_mail_locations > "$CONFIG.tmp"

if [[ -f "$CONFIG" ]]; then
    if ! diff -q "$CONFIG" "$CONFIG.tmp" >/dev/null 2>&1; then
        log 0 "Mail directory list has changed"
        mv "$CONFIG.tmp" "$CONFIG"
    else
        log 5 "No changes in mail directory list"
        rm "$CONFIG.tmp"
    fi
else
    log 0 "Creating initial mail directory list"
    mv "$CONFIG.tmp" "$CONFIG"
fi
