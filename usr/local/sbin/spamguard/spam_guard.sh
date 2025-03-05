#!/bin/bash
set -e

# Debug configuration
DEBUG=0

# Log level matrix - maps numeric levels to labels
declare -A LOG_LEVELS=(
    [0]="INFO"      # Default level - what was previously logged
    [5]="DEBUG"     # What was previously commented out
)

# Configuration
CONFIG="/etc/spamguard/spam_dirs.txt"
STAGING_ROOT="/var/spam_processing"
LOG="/var/log/spamguard.log"
USER="spamguard"
SPAM_DIR_REGEX=".*(/(\.)?(spam|junk|junk[-._ ]*e[-._ ]*mail))"

# Enhanced logging function with level support
log() {
    local req_level=$1
    shift
    local level_name="${LOG_LEVELS[$req_level]:-UNKNOWN}"
    
    if [ $DEBUG -ge $req_level ]; then
        local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        if [ $# -eq 0 ]; then
            while IFS= read -r line; do
                echo "$timestamp [$level_name] $line" #| tee -a "$LOG"
            done
        else
            echo "$timestamp [$level_name] $*" #| tee -a "$LOG"
        fi
    fi
}

# Execute and log command output while preserving exit status
run_and_log() {
    local level=$1
    shift
    local cmd="$*"
    log $level "Running: $cmd"
    local output
    # Use temporary file to capture output while preserving set -e behavior
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

generate_user_id() {
    USER_PATH="$1"
    if [[ "$USER_PATH" =~ /home/([^/]+)/homes/([^/]+)/Maildir ]]; then
        user="${BASH_REMATCH[2]}"
    elif [[ "$USER_PATH" =~ /home/([^/]+)/Maildir ]]; then
        user="${BASH_REMATCH[1]}"
    else
        log 0 "Invalid path: $USER_PATH"
        exit 1
    fi
    echo "$user"
}

set_acl() {
    local dir="$1"
    local file="$2"
    if ! getfacl "$dir" | grep -q "user:$USER:rwx"; then
        log 0 "Setting ACL for parent directory: $dir"
        run_and_log 0 setfacl -R -m u:$USER:rwx "$dir"
        run_and_log 0 setfacl -R -m d:u:$USER:rwx "$dir"
        run_and_log 0 getfacl "$dir"
    else
        log 0 "ACL for $USER already exists on $dir"
        run_and_log 5 getfacl "$dir"
    fi
    if ! getfacl "$file" | grep -q "user:$USER:rwx"; then
        log 0 "Setting ACL for: $file"
        run_and_log 0 setfacl -m u:$USER:rwx "$file"
        run_and_log 0 getfacl "$file"
    else
        log 0 "ACL for $USER already exists on $file"
        run_and_log 5 getfacl "$file"
    fi
}

ensure_staging_directory_exists() {
    local STAGING_DIR="$1"
    if [[ ! -d "$STAGING_DIR" ]]; then
        run_and_log 0 mkdir -p "$STAGING_DIR"
        log 0 "Created staging directory $STAGING_DIR"
    fi
}

process_spam_file() {
    local STAGING_FILE="$1"
    if [[ -f "$STAGING_FILE" ]]; then
        log 0 "Processing $STAGING_FILE"
        if ! grep -q "X-Spam-Flag: YES" "$STAGING_FILE"; then
            run_and_log 0 sa-learn --spam --no-sync "$STAGING_FILE"
        else
            log 0 "File $STAGING_FILE already contains Spam headers, skipping."
        fi
        rm -f "$STAGING_FILE"
    fi
}

clear_orphanage() {
    local STAGING_DIR="$1"
    local user="$2"
    if [[ -d "$STAGING_DIR" ]]; then
        # Check if the user exists
        user_home="$(getent passwd "$user" | cut -d: -f6)"
        if [[ -z "$user_home" ]]; then
            user_home=$(find /home -type d -name "$user*")
        fi
        # Now check for orphaned files
        log 5 "Checking $STAGING_DIR for orphaned files..."
        find "$STAGING_DIR" -type f | while read -r staged_file; do
            base_name=$(basename "$staged_file")
            original_file=""
            if [[ -z "$user_home" ]]; then
                original_file="deleted"
                log 0 "User $user not found. Treating $staged_file as orphaned."
            else
                for user_spam_dir in $(find "$user_home/Maildir" -type d -regextype posix-extended -iregex "$SPAM_DIR_REGEX"); do
                    log 5 "searching for original file in $user_spam_dir"
                    cur_dir="$user_spam_dir/cur"
                    new_dir="$user_spam_dir/new"
                    if [[ -e "$cur_dir/$base_name" ]]; then
                        original_file="$cur_dir/$base_name"
                        log 5 "found $original_file"
                        break
                    elif [[ -e "$new_dir/$base_name" ]]; then
                        original_file="$new_dir/$base_name"
                        log 5 "found $original_file"
                        break
                    fi
                done
            fi
            if [[ -z "$original_file" || "$original_file" == "deleted" ]]; then
                log 5 "Orphaned file detected: $staged_file"
                process_spam_file "$staged_file"
            else
                log 5 "Original found for $staged_file: $original_file"
            fi
        done
    fi
}

log 0 "Running SpamGuard"
while IFS= read -r dir; do
    if [[ -d "$dir" ]]; then
        user=$(generate_user_id "$dir")
        STAGING_DIR="$STAGING_ROOT/$user"
        log 5 "----------------------------------$dir gehoert $user und enthält:"
        find "$dir" -type f | while read -r spam_file; do
            if [[ "$spam_file" != *dovecot* && "$(basename "$spam_file")" != "maildirfolder" ]]; then
                log 5 "################### $spam_file"
                ensure_staging_directory_exists "$STAGING_DIR"
                if [[ ! -e "$STAGING_DIR/$(basename "$spam_file")" ]]; then
                    if run_and_log 0 ln -v "$spam_file" "$STAGING_DIR/$(basename "$spam_file")"; then
                        log 0 "Successfully linked."
                    else
                        if run_and_log 0 cp -v "$spam_file" "$STAGING_DIR/"; then
                            log 0 "Successfully copied."
                        else
                            log 0 "Failed to copy or link!!!!!!!!!!!!!!!!!"
                        fi
                    fi
                else
                    log 5 "already exists."
                fi
            fi
        done
        clear_orphanage "$STAGING_DIR" "$user"
        sa-learn --sync
    fi
done < "$CONFIG"
