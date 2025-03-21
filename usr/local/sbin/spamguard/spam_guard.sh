#!/bin/bash
set -e

# Set debug level (0=INFO, 5=DEBUG)
DEBUG=0

# Source common functions and configurations
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "$SCRIPT_DIR/common.sh"

# Ensure log file exists and is writable
touch "$LOG_FILE" 2>/dev/null || {
    log 0 "Cannot create or access log file at $LOG_FILE"
    exit 1
}

# Test data structures
declare -A WATCH_PIDS        # Track watch processes
declare -A MAILBOX_USERS     # Map mailbox paths to preferred usernames

# Update interval (from environment or default to 6 hours)
UPDATE_INTERVAL=${UPDATE_INTERVAL:-21600}

# Mock systemd functions for testing
mock_systemd_notify() {
    log 0 "systemd: $1"
}

# Setup watches for a mailbox
setup_mailbox_watches() {
    local username="$1"
    local maildir="$2"
    
    log 0 "Setting up watches for $username ($maildir)"
    
    # Clean up any existing watches for this mailbox
    cleanup_mailbox_watches "$username"
    
    # Watch main Maildir
    if ! is_valid_maildir "$maildir"; then
        log 0 "Invalid Maildir structure for $maildir"
        handle_permissions "$maildir"
        return 1
    fi

    # Set permissions for main Maildir and its subdirectories
    handle_permissions "$maildir"
    # Handle permissions for the main Maildir and all subdirectories' cur/new directories
    while IFS= read -r dir; do
        handle_permissions "$dir"
    done < <(find "$maildir" -type d \( -name cur -o -name new \) -exec dirname {} \;)
    log 0 "$watch_dirs"
    # Pipe for watch process communication
    local pipe="/tmp/watch_${username}_pipe"
    [[ -p "$pipe" ]] || mkfifo "$pipe"
    handle_permissions "$pipe"

    # Start a single inotifywait process to monitor both main and subdirectories
    (
        set +e
        trap 'exit 0' SIGTERM SIGINT SIGHUP
        exec 2>"$pipe"
find "$maildir" -type d \
    -exec bash -c "
        $is_trash_folder_logic
        [ -d \"\$0/cur\" ] && [ -d \"\$0/new\" ] && ! is_trash_folder \"\$0\" && printf '%s\0%s\0' \"\$0/cur\" \"\$0/new\"
    " {} \; | xargs -0 inotifywait -m -e create -e moved_to --format '%w%f' | while read -r file; do
              if [[ -f "$file" ]]; then
                # Determine if the file is in a spam directory
		parent_dir=$(dirname "$file")
               parent_dir=$(dirname "$parent_dir")
parent_dir=$(echo "$parent_dir" | tr '[:upper:]' '[:lower:]')
                if [[ "$parent_dir" =~ $SPAM_DIR_REGEX ]]; then
                    log 0 "SPAM file detected: $file for $username"
                    handle_permissions "$file"
                    mark_email_as "spam" "$file"
elif is_trash_folder "$parent_dir"; then
    log 0 "File is in a trash folder: $file for $username. Skipping processing."
                else
                    log 0 "HAM file detected: $file for $username"
                    handle_permissions "$file"
                    mark_email_as "ham" "$file"
                fi
            fi
        done
    ) &
    local pid=$!
    WATCH_PIDS["${username}_mailbox"]=$pid
    log 5 "Started mailbox watch for $username (PID: $pid)"
    
    # Monitor pipe for errors from the watch process
    (
        set +e
        trap 'exit 0' SIGTERM SIGINT SIGHUP
        while read -r message; do
            # Filter out known inotifywait setup messages
            if [[ "$message" != "Setting up watches." && "$message" != "Watches established." ]]; then
                log 0 " Watch error for $username: $message"
                # Instead of full recovery, restart only the affected user's watch
                cleanup_mailbox_watches "$username"
                setup_mailbox_watches "$username" "$maildir"
            else
                log 5 "$username: $message"
            fi
        done < "$pipe"
    ) &
    pid=$!
    WATCH_PIDS["${username}_monitor"]=$pid
    log 5 "Setup complete for $username"

    # Mark this mailbox as processed
    MAILBOX_USERS[$username]="$maildir"
    return 0
}
# Cleanup watches for a mailbox or a specific process
cleanup_mailbox_watches() {
    local target="$1"
    local graceful="${2:-true}"
    
    if [[ -v WATCH_PIDS["${target}_inbox"] ]]; then
        local username="$target"
        log 0 "Cleaning up watches for $username (graceful=$graceful)"
        
        local pids_to_kill=()
        for key in "${!WATCH_PIDS[@]}"; do
            if [[ $key == ${username}_* ]]; then
                local pid="${WATCH_PIDS[$key]}"
                pids_to_kill+=("$pid")
                unset WATCH_PIDS[$key]
            fi
        done
        
        for pid in "${pids_to_kill[@]}"; do
            cleanup_mailbox_watches "$pid" "$graceful"
        done
        
        log 5 "Removing pipe for $username"
        rm -f "/tmp/watch_${username}_pipe"
    else
        local pid="$target"
        local process_info=$(get_process_info "$pid")
        if [[ "$process_info" == "Process not found" ]]; then
            log 5 "Process $pid not found, skipping..."
            return 0
        fi
        log 5 "Cleaning up process $pid (graceful=$graceful) - $process_info"
        
        local children=$(ps -o pid= --ppid "$pid" 2>/dev/null)
        
        for child in $children; do
            cleanup_mailbox_watches "$child" "$graceful"
        done
        
        if [[ "$graceful" == "true" ]]; then
            if ps -p "$pid" > /dev/null 2>&1; then
                log 5 "Attempting graceful termination for PID: $pid - $process_info"
                kill -TERM "$pid" 2>/dev/null || true
                
                local timeout=10
                local end=$((SECONDS + timeout))
                while ((SECONDS < end)) && kill -0 "$pid" 2>/dev/null; do
                    sleep 0.1
                done
            fi
            if kill -0 "$pid" 2>/dev/null; then
                log 0 "Graceful termination failed for PID: $pid - $process_info, forcing..."
                cleanup_mailbox_watches "$pid" "false"
            else
                log 5 "Process $pid terminated gracefully - $process_info"
            fi
        else
            if ps -p "$pid" > /dev/null 2>&1; then
                log 0 "Force killing process $pid - $process_info"
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
    fi
}

# Get process information (name and command)
get_process_info() {
    local pid="$1"
    local info=""
    
    if ps -p "$pid" > /dev/null 2>&1; then
        local process_name=$(ps -o comm= -p "$pid")
        local process_cmd=$(ps -o args= -p "$pid")
        info="Process: $process_name, Command: $process_cmd"
    else
        info="Process not found"
    fi
    
    echo "$info"
}

# Watch recovery handler
handle_watch_recovery() {
    local username
    log 0 "Starting watch recovery"
    for username in "${!MAILBOX_USERS[@]}"; do
        local maildir="${MAILBOX_USERS[$username]}"
        if [[ -d "$maildir" ]]; then
            log 0 "Recovering watches for $username ($maildir)"
            handle_permissions "$maildir"
            setup_mailbox_watches "$username" "$maildir"
        else
            log 0 "Mailbox no longer exists: $maildir"
            cleanup_mailbox_watches "$username"
            unset MAILBOX_USERS[$username]
        fi
    done
}

# Update mailbox watches
update_mailbox_watches() {
    log 0 "Checking for mailbox changes"
    
    declare -A current_mailboxes
    for username in "${!MAILBOX_USERS[@]}"; do
        current_mailboxes[$username]="${MAILBOX_USERS[$username]}"
    done
    
    mapfile -t mailbox_lines < <(get_maildirs)
    
    local mailbox_count=0
    log 5 "Processing ${#mailbox_lines[@]} mailboxes"
    
    for line in "${mailbox_lines[@]}"; do
        IFS=: read -r username maildir <<< "$line"
        if [[ -n "$maildir" && -n "$username" ]]; then

            log 5 "Found mailbox: $username -> $maildir"
            ((mailbox_count++))
            
            if [[ -v current_mailboxes[$username] ]]; then
                if [[ "${current_mailboxes[$username]}" != "$maildir" ]]; then
                    log 0 "Mailbox path changed for $username"
                    setup_mailbox_watches "$username" "$maildir"
                else
                    log 5 "Mailbox unchanged for $username"
                fi
                unset current_mailboxes[$username]
            else
                log 0 "Mailbox found for $username"
                setup_mailbox_watches "$username" "$maildir"
            fi
        fi
    done
    
    for username in "${!current_mailboxes[@]}"; do
        log 0 "Removing watches for disappeared mailbox: $username"
        cleanup_mailbox_watches "$username"
        unset MAILBOX_USERS[$username]
    done
    
    log 0 "Mailbox check complete (processed $mailbox_count mailboxes)"
}

# Signal handlers
cleanup_all() {
    log 0 "Received shutdown signal, cleaning up all watches..."
    
    if [[ -v WATCH_PIDS["update_timer"] ]]; then
        log 5 "Stopping update timer (PID: ${WATCH_PIDS["update_timer"]})"
        kill -TERM ${WATCH_PIDS["update_timer"]} 2>/dev/null || true
        unset WATCH_PIDS["update_timer"]
    fi
    
    for username in "${!MAILBOX_USERS[@]}"; do
        cleanup_mailbox_watches "$username" "true"
    done
    
    local remaining_pids=$(ps -o pid= -g $$ | grep -v "^$$\$")
    if [[ -n "$remaining_pids" ]]; then
        log 0 "Found remaining processes in our group, force killing..."
        for pid in $remaining_pids; do
            log 0 "Force killing remaining process: $pid"
            kill -9 "$pid" 2>/dev/null || true
        done
    fi
    
    find /tmp -maxdepth 1 -name 'watch_*_pipe' -exec rm -f {} \;
    
    log 0 "Cleanup complete, exiting"
    exit 0
}

mark_email_as() {
    local type_to_set=$1
    local email_file=$2
    local opposite_type=""
    log 5 "Entering mark_email_as: type_to_set=$type_to_set, email_file=$email_file"

    # Resolve the Maildir filename before any file operation
    email_file=$(resolve_maildir_filename "$email_file")
    if [[ -z "$email_file" || ! -f "$email_file" ]]; then
        log 0 "Email file $email_file does not exist. Skipping."
        return 0
    fi

    # Additional condition for spam type
    if [[ "$type_to_set" == "spam" ]]; then
        email_file=$(resolve_maildir_filename "$email_file")
        if [[ -z "$email_file" || ! -f "$email_file" ]]; then
            log 0 "Email file $email_file does not exist. Skipping."
            return 0
        fi
        local x_spam_status=$(grep -i "^X-Spam-Status:" "$email_file")
        if [[ -n "$x_spam_status" && ! "$x_spam_status" =~ ^X-Spam-Status:\ No ]]; then
            log 0 "Email $email_file was already marked as spam."
            return 0
        fi
        opposite_type="ham"
    elif [[ "$type_to_set" == "ham" ]]; then
        opposite_type="spam"
    else
        log 0 "Invalid email type provided: $type_to_set. Must be either 'ham' or 'spam'."
        return 0
    fi

    # Check if the file has already been learned
    email_file=$(resolve_maildir_filename "$email_file")
    if [[ -z "$email_file" || ! -f "$email_file" ]]; then
        log 0 "Email file $email_file does not exist. Skipping."
        return 0
    fi
    if getfattr -n "user.$type_to_set" -- "$email_file" &>/dev/null; then
        log 0 "Email $email_file has already been learned as $type_to_set. Skipping processing."
        return 0
    fi

    # Remove the opposite type attribute if it exists
    email_file=$(resolve_maildir_filename "$email_file")
    if [[ -z "$email_file" || ! -f "$email_file" ]]; then
        log 0 "Email file $email_file does not exist. Skipping."
        return 0
    fi
    if getfattr -n "user.$opposite_type" -- "$email_file" &>/dev/null; then
        email_file=$(resolve_maildir_filename "$email_file")
        if [[ -z "$email_file" || ! -f "$email_file" ]]; then
            log 0 "Email file $email_file does not exist. Skipping."
            return 0
        fi
        setfattr -x "user.$opposite_type" "$email_file"
        log 5 "Removed user.$opposite_type attribute from $email_file."
    fi

    log 0 "Processing $email_file as $type_to_set."

    # Use run_and_log to execute sa-learn and log its output
    email_file=$(resolve_maildir_filename "$email_file")
    if [[ -z "$email_file" || ! -f "$email_file" ]]; then
        log 0 "Email file $email_file does not exist. Skipping."
        return 0
    fi
    if ! run_and_log 0 sa-learn --$type_to_set "$email_file"; then
        log 0 "Error processing $email_file with sa-learn. File may be inaccessible or corrupted."
        return 0
    fi

    # Set the attribute to mark the file as learned
    email_file=$(resolve_maildir_filename "$email_file")
    if [[ -z "$email_file" || ! -f "$email_file" ]]; then
        log 0 "Email file $email_file does not exist. Skipping."
        return 0
    fi
    if setfattr -n "user.$type_to_set" -v "1" "$email_file" &>/dev/null; then
        log 5 "Added user.$type_to_set attribute to $email_file."
    else
        log 0 "Failed to add user.$type_to_set attribute to $email_file."
    fi

    return 0
}

resolve_maildir_filename() {
    local original_file="$1"
    local maildir_path
    local original_inode
    local found_file

    # If the file still exists, return it as-is
    if [[ -f "$original_file" ]]; then
        echo "$original_file"
        return 0
    fi

    # Get the parent directory of the file
    maildir_path="$(dirname "$original_file")"

    # Get the inode of the original file (if it exists)
    if original_inode=$(stat -c %i "$original_file" 2>/dev/null); then
        # Search for a file with the same inode in the maildir directory
        found_file=$(find "$maildir_path" -inum "$original_inode" -print -quit 2>/dev/null)

        if [[ -n "$found_file" && -f "$found_file" ]]; then
            log 0 "File $original_file was renamed to $found_file (same inode: $original_inode)."
            echo "$found_file"
            return 0
        fi
    fi

    # If no file with the same inode is found, fall back to the filename-based search
    found_file=$(ls "$maildir_path"/$(basename "$original_file" | cut -d':' -f1)* 2>/dev/null | head -n1)

    if [[ -n "$found_file" && -f "$found_file" ]]; then
        log 0 "File $original_file was renamed to $found_file."
        echo "$found_file"
        return 0
    fi

    # If no file is found, return an empty string
    log 0 "File $original_file can no longer be found at this path."
    echo ""
    return 1
}


# Set up signal handlers
trap cleanup_all SIGTERM SIGINT SIGHUP
trap handle_watch_recovery SIGUSR1
trap update_mailbox_watches SIGUSR2

# Main test function
main() {
    log 0 "Starting watch_mail test"
    mock_systemd_notify "READY=1"
    
    log 0 "Performing initial mailbox setup"
    update_mailbox_watches
    
    log 0 "Setting up update timer"
    (
        set +e
        trap 'exit 0' SIGTERM SIGINT SIGHUP
        while true; do
            sleep "$UPDATE_INTERVAL"
            kill -USR2 $$
        done
    ) &
    WATCH_PIDS["update_timer"]=$!
    log 0 "Watch_mail test initialization complete"
    
    while true; do
        sleep 60 &
        wait $!
    done
}

# Run tests if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set +e
    main "$@"
fi
