#!/bin/bash

# Logging levels:
# 0 = error
# 1 = warn
# 2 = info
# 3 = debug
# 4 = trace
# 5 = trace with data dumps
LOG_LEVEL=5

# Global Maildir path variants
MAILDIR_PATHS=(
    "Maildir"           # Standard Maildir in home
    "mail"              # Common alternate location
    ".mail"             # Hidden mail directory
    "Mail"              # Another common variant
)

# Log a message with a specific log level
log() {
    local level="$1"
    shift
    local message="$*"
    
    if [[ $level -le $LOG_LEVEL ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message"
    fi
}

# Run a command and log its output
run_and_log() {
    local level="$1"
    shift
    local command="$*"
    
    log "$level" "Running: $command"
    if [[ $level -le $LOG_LEVEL ]]; then
        "$@" 2>&1 | while read line; do
            log "$level" "$line"
        done
    else
        "$@" >/dev/null 2>&1
    fi
}

# Find all Maildir-style mail directories under a path
get_maildirs() {
    local path="$1"
    local result=()
    local dir
    
    # Look for Maildir variants in the given path
    for maildir_name in "${MAILDIR_PATHS[@]}"; do
        if [[ -d "$path/$maildir_name" ]] && 
           [[ -d "$path/$maildir_name/new" ]] && 
           [[ -d "$path/$maildir_name/cur" ]]; then
            result+=("$path/$maildir_name")
        fi
    done
    
    # If we found any Maildirs, return them
    if [[ ${#result[@]} -gt 0 ]]; then
        printf '%s\n' "${result[@]}"
        return 0
    fi
    
    # Otherwise, look in subdirectories
    for dir in "$path"/*/; do
        [[ -d "$dir" ]] || continue
        get_maildirs "$dir"
    done
}

# Set appropriate ACLs on a path
handle_permissions() {
    local path="$1"
    
    if [[ ! -e "$path" ]]; then
        log 0 "Error: Path does not exist: $path"
        return 1
    }

    if ! getfacl "$path" 2>/dev/null | grep -q "user:$USER:rwx"; then
        log 0 "Setting ACL for: $path"
        # Set ACL just for this directory/file
        run_and_log 0 setfacl -m u:$USER:rwx "$path"
        # If it's a directory, set default ACLs
        if [[ -d "$path" ]]; then
            run_and_log 0 setfacl -m d:u:$USER:rwx "$path"
            # Check if it's any of our Maildir variants
            local basename=$(basename "$path")
            if [[ " ${MAILDIR_PATHS[@]} " =~ " ${basename} " ]]; then
                log 5 "Setting ACL for Maildir subdirectories"
                run_and_log 0 setfacl -m u:$USER:rwx "$path/cur"
                run_and_log 0 setfacl -m d:u:$USER:rwx "$path/cur"
                run_and_log 0 setfacl -m u:$USER:rwx "$path/new"
                run_and_log 0 setfacl -m d:u:$USER:rwx "$path/new"
            fi
        fi
        run_and_log 5 getfacl "$path"
    else
        log 5 "ACL for $USER already exists on $path"
    fi
}