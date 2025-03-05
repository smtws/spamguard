#!/bin/bash
set -e
CONFIG="/etc/spamguard/spam_dirs.txt"
STAGING_ROOT="/var/spam_processing"
LOG="/var/log/spamguard.log"
LOCKFILE="/var/run/spamguard_update.lock"
USER="spamguard"
SPAM_DIR_REGEX=".*(/(\.)?(spam|junk|junk[-._ ]*e[-._ ]*mail))"

PIDFILE="/var/spam_processing/spamguard.pid"

# PID locking function
check_and_create_pid() {
    if [ -f "$PIDFILE" ]; then
        old_pid=$(cat "$PIDFILE")
        if ps -p "$old_pid" > /dev/null 2>&1; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Another instance is running with PID $old_pid"
            exit 1
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Found stale PID file, removing"
            rm -f "$PIDFILE"
        fi
    fi
    echo $$ > "$PIDFILE"
}

# Cleanup function
cleanup() {
    rm -f "$PIDFILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Removed PID file"
}

# Set up trap for cleanup
trap cleanup EXIT

# Run PID check before proceeding
check_and_create_pid

exec > >(awk '{ print strftime("%Y-%m-%d %H:%M:%S"), $0 }' | tee -a "$LOG") 2>&1

generate_user_id() {
    USER_PATH="$1"
    if [[ "$USER_PATH" =~ /home/([^/]+)/homes/([^/]+)/Maildir ]]; then
        user="${BASH_REMATCH[2]}"
    elif [[ "$USER_PATH" =~ /home/([^/]+)/Maildir ]]; then
        user="${BASH_REMATCH[1]}"
    else
        echo "Invalid path: $USER_PATH"
        exit 1
    fi
    echo "$user"
}

set_acl() {
    local dir="$1"
    local file="$2"
    if ! getfacl "$dir" | grep -q "user:$USER:rwx"; then
        echo "Setting ACL for parent directory: $dir"
        setfacl -R -m u:$USER:rwx "$dir"
        setfacl -R -m d:u:$USER:rwx "$dir"
        getfacl "$dir"
    else
        echo "ACL for $USER already exists on $dir"
    fi
    if ! getfacl "$file" | grep -q "user:$USER:rwx"; then
      echo "Setting ACL for: $file"
        setfacl -m u:$USER:rwx "$file"
        getfacl "$file"
    else
        echo "ACL for $USER already exists on $file"
    fi
}

ensure_staging_directory_exists() {
    local STAGING_DIR="$1"
    if [[ ! -d "$STAGING_DIR" ]]; then
        mkdir -p "$STAGING_DIR"
        echo "Created staging directory $STAGING_DIR"
    fi
}

process_spam_file() {
    local STAGING_FILE="$1"
    if [[ -f "$STAGING_FILE" ]]; then
        echo "Processing $STAGING_FILE"
        if ! grep -q "X-Spam-Flag: YES" "$STAGING_FILE"; then
            sa-learn --spam --no-sync  "$STAGING_FILE"
        else
            echo "File $STAGING_FILE already contains Spam headers, skipping."
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
       # echo "Checking $STAGING_DIR for orphaned files..."
        find "$STAGING_DIR" -type f | while read -r staged_file; do
            base_name=$(basename "$staged_file")
            original_file=""
            # If user is missing, we mark the file as orphaned by setting original_file to "deleted"
            if [[ -z "$user_home" ]]; then
                original_file="deleted"  # Placeholder for orphaned file
                echo "User $user not found. Treating $staged_file as orphaned."
            else
                # If user exists, check for the original in the spam directories
                for user_spam_dir in $(find "$user_home/Maildir" -type d -regextype posix-extended -iregex "$SPAM_DIR_REGEX"); do
                   # echo "searching for original file in $user_spam_dir"
                    cur_dir="$user_spam_dir/cur"
                    new_dir="$user_spam_dir/new"
                    # Check if the file exists in the cur or new directories
                    if [[ -e "$cur_dir/$base_name" ]]; then
                        original_file="$cur_dir/$base_name"
                       # echo "found $original_file"
                        break
                    elif [[ -e "$new_dir/$base_name" ]]; then
                        original_file="$new_dir/$base_name"
                       # echo "found $original_file"
                        break
                    fi
                done
            fi
            # If no original file is found (or the user is missing), process the orphaned file
            if [[ -z "$original_file" || "$original_file" == "deleted" ]]; then
               # echo "Orphaned file detected: $staged_file (original missing or user deleted)"
                process_spam_file "$staged_file"
           # else
               # echo "Original found for $staged_file: $original_file"
            fi
        done
    fi
}

echo "Running SpamGuard"
while IFS= read -r dir; do
    if [[ -d "$dir" ]]; then
        user=$(generate_user_id "$dir")
        STAGING_DIR="$STAGING_ROOT/$user"
       # echo "----------------------------------$dir gehoert $user und enthält:"
        find "$dir" -type f | while read -r spam_file; do
            if [[ "$spam_file" != *dovecot* && "$(basename "$spam_file")" != "maildirfolder" ]]; then
               # echo "################### $spam_file"
                ensure_staging_directory_exists "$STAGING_DIR"
                if [[ ! -e "$STAGING_DIR/$(basename "$spam_file")" ]]; then
                    if ln -v "$spam_file" "$STAGING_DIR/$(basename "$spam_file")"; then
                        echo "Successfully linked."
                    else
                        if cp -v "$spam_file" "$STAGING_DIR/"; then
                            echo "Successfully copied."
                        else
                            echo "Failed to copy or link!!!!!!!!!!!!!!!!!"
                        fi
                    fi
               # else
                   # echo "already exists."
                fi
            fi
        done
        clear_orphanage "$STAGING_DIR" "$user"
 sa-learn --sync
    fi
done < "$CONFIG"

