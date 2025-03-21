#!/bin/bash

# Logging levels:
# 0 = error
# 1 = warn
# 2 = info
# 3 = debug
# 4 = trace
# 5 = trace with data dumps
LOG_LEVEL=${LOG_LEVEL:5}
LOG_FILE="/var/log/spamguard.log"

# Default base directory for mailbox search
MAIL_BASE_DIR="${MAIL_BASE_DIR:-/home}"

# Global Maildir path variants
MAILDIR_PATHS=(
    "Maildir"           # Standard Maildir in home
    "mail"              # Common alternate location
    ".mail"             # Hidden mail directory
    "Mail"              # Another common variant
)
# Common regex patterns
SPAM_DIR_REGEX=".*(/(\.)?(spam|junk|junk[-._ ]*e[-._ ]*mail))"

TRASH_FOLDER_NAMES=(
    "trash"
    "deleted items"
    "deleted messages"
    "bin"
    "wastebasket"
    "inbox.trash"
    "inbox.deleted"
    "sent items"
    "drafts"
    "entwürfe"
    "entw&apw-rfe"
    "papierkorb"
    "sent"	
    "gesendet"
)
TRASH_REGEX="^($(printf "%s|" "${TRASH_FOLDER_NAMES[@]}" | sed 's/[.[\*^$(){}?+]/\\&/g' | sed 's/|$//'))$"
export TRASH_REGEX

is_trash_folder() {
    local path="$1"
    local folder_name

    # Normalize the folder name
    folder_name=$(basename "$path")                # Get the folder name
    folder_name=${folder_name#.}                  # Remove leading dot
    folder_name=${folder_name%/}                  # Remove trailing slash
    folder_name=$(echo "$folder_name" | tr '[:upper:]' '[:lower:]')  # Convert to lowercase
 folder_name=$(echo "$folder_name" | iconv -f iso-8859-1 -t utf-8//TRANSLIT 2>/dev/null)


#   echo "Checking folder: $folder_name"

    # Match against the regex
if [[ "$folder_name" =~ $TRASH_REGEX ]]; then
#        echo "Match found: $folder_name is a trash folder"
        return 0
    else
 #       echo "No match found: $folder_name is not a trash folder"
        return 1
    fi
}

is_trash_folder_logic=$(declare -f is_trash_folder)


# Log a message with a specific log level
log() {
    local level="$1"
    shift
    local message="$*"
    
    if [[ $level -le $LOG_LEVEL ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" >> "$LOG_FILE"
    fi
}

# Run a command and log its output
run_and_log() {
    local level="$1"
    shift
    local command="$*"
    
    log "$level" "Running: $command"
    if [[ $level -le $LOG_LEVEL ]]; then
        local output
        output=$("$@" 2>&1)
        while IFS= read -r line; do
            log "$level" "$line"
        done <<< "$output"
    else
        "$@" >/dev/null 2>&1
    fi
}

# Check if a path is a valid Maildir
is_valid_maildir() {
    local dir="$1"
    [[ -d "$dir" && -d "$dir/new" && -d "$dir/cur" ]]
}

# Find all Maildir-style mail directories under a path
get_maildirs() {
    local -A seen_users  # Track unique user-maildir combinations
    local found_mailboxes=()
    
    # First collect all mailboxes
    while IFS=: read -r username _ uid _ _ homedir _; do
        # Skip system users
        if [[ "$uid" -lt 1000 ]] || [[ "$homedir" == "/nonexistent" ]] || [[ "$homedir" == "/dev/null" ]]; then
            continue
        fi
        
        # Standardize username (convert @ to _)
        local std_username="${username//@/_}"
        std_username="${std_username//-/_}"
        std_username="${std_username//./_}"
        
        # Check standard Maildir locations
        for maildir_path in "${MAILDIR_PATHS[@]}"; do
            if [[ -d "$homedir/$maildir_path" ]] && is_valid_maildir "$homedir/$maildir_path"; then
                # Only add if we haven't seen this normalized username before
                if [[ -z "${seen_users[$std_username]}" ]]; then
                found_mailboxes+=("$std_username:$homedir/$maildir_path")
                    seen_users[$std_username]="$homedir/$maildir_path"
                    log 5 "Added mailbox for $username (as $std_username)"
                else
                    log 5 "Skipping duplicate $username for mailbox (as $std_username)"
                fi
                break
            fi
        done
    done < <(getent passwd)
    
    # Now output the collected mailboxes with logging
    log 5 "Found ${#found_mailboxes[@]} mailboxes"
    printf '%s\n' "${found_mailboxes[@]}"
}

# Set appropriate ACLs on a path
handle_permissions() {
    local path="$1"
    
    if [[ ! -e "$path" ]]; then
        log 0 "Path does not exist: $path"
        return 1
    fi

    if ! getfacl "$path" 2>/dev/null | grep -q "user:$USER:rwx"; then
        log 5 "Setting ACL for: $path"
        # Set ACL just for this directory/file
        run_and_log 5  setfacl -m u:$USER:rwx "$path"
        # If it's a directory, set default ACLs
        if [[ -d "$path" ]]; then
            run_and_log 5  setfacl -m d:u:$USER:rwx "$path"
            # Check if it's any of our Maildir variants
            local basename=$(basename "$path")
            if [[ " ${MAILDIR_PATHS[@]} " =~ " ${basename} " ]]; then
                log 5 "Setting ACL for Maildir subdirectories"
                run_and_log 5  setfacl -m u:$USER:rwx "$path/cur"
                run_and_log 5  setfacl -m d:u:$USER:rwx "$path/cur"
                run_and_log 5  setfacl -m u:$USER:rwx "$path/new"
                run_and_log 5  setfacl -m d:u:$USER:rwx "$path/new"
            fi
        fi
    else
        log 5 "ACL for $USER already exists on $path"
    fi
}

