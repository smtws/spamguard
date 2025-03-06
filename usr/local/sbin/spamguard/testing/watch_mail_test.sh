#!/bin/bash
set -e

# Set debug level (0=INFO, 5=DEBUG)
DEBUG=5

# Source common functions and configurations
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "$SCRIPT_DIR/common.sh"

# Ensure log file exists and is writable
touch "$LOG_FILE" 2>/dev/null || {
    log 0 "[INIT-ERR-1] Cannot create or access log file at $LOG_FILE"
    exit 1
}

# Test data structures
declare -A WATCH_PIDS        # Track watch processes
declare -A MAILBOX_USERS     # Map mailbox paths to preferred usernames

# Update interval (from environment or default to 6 hours)
UPDATE_INTERVAL=${UPDATE_INTERVAL:-21600}

# Mock systemd functions for testing
mock_systemd_notify() {
    log 0 "[MOCK-1] systemd: $1"
}

# Setup watches for a mailbox
setup_mailbox_watches() {
    local username="$1"
    local maildir="$2"
    
    log 0 "[SETUP-1] Setting up watches for $username ($maildir)"
    
    # Clean up any existing watches for this mailbox
    cleanup_mailbox_watches "$username"
    
    # Watch main Maildir
    if ! is_valid_maildir "$maildir"; then
        log 0 "[SETUP-ERR-1] Invalid Maildir structure for $maildir"
        handle_permissions "$maildir"
        return 1
    fi

    # Set permissions for main Maildir and its subdirectories
    handle_permissions "$maildir"
    handle_permissions "$maildir/new"
    handle_permissions "$maildir/cur"

    # Pipe for watch process communication
    local pipe="/tmp/watch_${username}_pipe"
    [[ -p "$pipe" ]] || mkfifo "$pipe"
    handle_permissions "$pipe"

    # Start watch process with error redirection to pipe
    (
        # Disable exit on error for the subshell
        set +e
        # Ignore parent's signals
        trap '' SIGTERM SIGINT SIGHUP
        exec 2>"$pipe"
        inotifywait -m -e create -e moved_to --format '%w%f' "${maildir}"/{new,cur} | while read file; do
            if [[ -f "$file" ]]; then
                log 5 "[WATCH-1] INBOX: New file detected: $file for $username"
                handle_permissions "$file"
            fi
        done
    ) &
    local pid=$!
    WATCH_PIDS["${username}_inbox"]=$pid
    log 5 "[SETUP-2] Started inbox watch for $username (PID: $pid)"
    
    # Find and watch spam directories
    local spam_count=0
    while IFS= read -r spam_dir; do
        if [[ ! -d "$spam_dir" ]]; then
            continue
        fi
        log 5 "[SETUP-3] Found spam dir: $spam_dir"
        
        if ! is_valid_maildir "$spam_dir"; then
            log 0 "[SETUP-ERR-2] Invalid Maildir structure for spam dir $spam_dir"
            handle_permissions "$spam_dir"
            continue
        fi
        
        # Set permissions for spam directory and its subdirectories
        handle_permissions "$spam_dir"
        handle_permissions "$spam_dir/new"
        handle_permissions "$spam_dir/cur"
        
        # Start watch process with error redirection to pipe
        (
            # Disable exit on error for the subshell
            set +e
            # Ignore parent's signals
            trap '' SIGTERM SIGINT SIGHUP
            exec 2>"$pipe"
            inotifywait -m -e create -e moved_to --format '%w%f' "${spam_dir}"/{new,cur} | while read file; do
                if [[ -f "$file" ]]; then
                    log 5 "[WATCH-2] SPAM: New file detected: $file for $username"
                    handle_permissions "$file"
                fi
            done
        ) &
        pid=$!
        WATCH_PIDS["${username}_spam_${spam_count}"]=$pid
        log 5 "[SETUP-4] Started spam watch for $username on $spam_dir (PID: $pid)"
        ((spam_count++))
    done < <(find "$maildir" -type d -regextype posix-extended -iregex "$SPAM_DIR_REGEX")

    # Monitor pipe for errors from any watch process
    (
        # Disable exit on error for the subshell
        set +e
        # Ignore parent's signals
        trap '' SIGTERM SIGINT SIGHUP
        while read -r error; do
            log 0 "[WATCH-ERR-1] Watch error for $username: $error"
            # Trigger watch recovery
            kill -USR1 $$
        done < "$pipe"
    ) &
    pid=$!
    WATCH_PIDS["${username}_monitor"]=$pid
    log 5 "[SETUP-5] Setup complete for $username"

    # Mark this mailbox as processed
    MAILBOX_USERS[$username]="$maildir"
    return 0
}

# Cleanup watches for a mailbox
cleanup_mailbox_watches() {
    local username="$1"
    log 0 "[CLEAN-1] Cleaning up watches for $username"
    for key in "${!WATCH_PIDS[@]}"; do
        if [[ $key == ${username}_* ]]; then
            log 5 "[CLEAN-2] Stopping watch $key (PID: ${WATCH_PIDS[$key]})"
            kill ${WATCH_PIDS[$key]} 2>/dev/null || true
            wait ${WATCH_PIDS[$key]} 2>/dev/null || true
            unset WATCH_PIDS[$key]
        fi
    done
    # Clean up pipe
    log 5 "[CLEAN-3] Removing pipe for $username"
    rm -f "/tmp/watch_${username}_pipe"
}

# Watch recovery handler
handle_watch_recovery() {
    local username
    log 0 "[RECOVERY-1] Starting watch recovery"
    for username in "${!MAILBOX_USERS[@]}"; do
        local maildir="${MAILBOX_USERS[$username]}"
        if [[ -d "$maildir" ]]; then
            log 0 "[RECOVERY-2] Recovering watches for $username ($maildir)"
            handle_permissions "$maildir"
            setup_mailbox_watches "$username" "$maildir"
        else
            log 0 "[RECOVERY-ERR-1] Mailbox no longer exists: $maildir"
            cleanup_mailbox_watches "$username"
            unset MAILBOX_USERS[$username]
        fi
    done
}

# Update mailbox watches
update_mailbox_watches() {
    log 0 "[UPDATE-1] Checking for mailbox changes"
    
    # Store current mailboxes for comparison
    declare -A current_mailboxes
    for username in "${!MAILBOX_USERS[@]}"; do
        current_mailboxes[$username]="${MAILBOX_USERS[$username]}"
    done
    
    # Read and store all mailboxes first
    declare -a mailbox_lines
    while IFS= read -r line; do
        mailbox_lines+=("$line")
    done < <(get_maildirs)
    
    # Process stored mailboxes
    local mailbox_count=0
    log 5 "[UPDATE-2] Processing ${#mailbox_lines[@]} mailboxes"
    
    for line in "${mailbox_lines[@]}"; do
        IFS=: read -r username maildir <<< "$line"
        if [[ -n "$maildir" && -n "$username" ]]; then
            log 5 "[UPDATE-3] Found mailbox: $username -> $maildir"
            ((mailbox_count++))
            
            if [[ -v current_mailboxes[$username] ]]; then
                if [[ "${current_mailboxes[$username]}" != "$maildir" ]]; then
                    log 0 "[UPDATE-4] Mailbox path changed for $username"
                    setup_mailbox_watches "$username" "$maildir"
                else
                    log 5 "[UPDATE-5] Mailbox unchanged for $username"
                fi
                unset current_mailboxes[$username]
            else
                log 0 "[UPDATE-6] New mailbox found for $username"
                setup_mailbox_watches "$username" "$maildir"
            fi
        fi
    done
    
    # Clean up removed mailboxes
    for username in "${!current_mailboxes[@]}"; do
        log 0 "[UPDATE-7] Removing watches for disappeared mailbox: $username"
        cleanup_mailbox_watches "$username"
        unset MAILBOX_USERS[$username]
    done
    
    log 0 "[UPDATE-8] Mailbox check complete (processed $mailbox_count mailboxes)"
}

# Signal handlers
cleanup_all() {
    log 0 "[EXIT-1] Received shutdown signal, cleaning up all watches..."
    # Clean up the update timer first
    if [[ -v WATCH_PIDS["update_timer"] ]]; then
        log 5 "[EXIT-2] Stopping update timer (PID: ${WATCH_PIDS["update_timer"]})"
        kill ${WATCH_PIDS["update_timer"]} 2>/dev/null || true
        wait ${WATCH_PIDS["update_timer"]} 2>/dev/null || true
        unset WATCH_PIDS["update_timer"]
    fi
    
    # Then clean up all mailbox watches
    for username in "${!MAILBOX_USERS[@]}"; do
        cleanup_mailbox_watches "$username"
    done
    
    log 0 "[EXIT-3] Cleanup complete, exiting"
    exit 0
}

# Set up signal handlers
trap cleanup_all SIGTERM SIGINT SIGHUP
trap handle_watch_recovery SIGUSR1
trap update_mailbox_watches SIGUSR2

# Main test function
main() {
    log 0 "[MAIN-1] Starting watch_mail test"
    mock_systemd_notify "READY=1"
    
    # Initial setup of mailbox watches
    log 0 "[MAIN-2] Performing initial mailbox setup"
    update_mailbox_watches
    
    # Set up periodic updates using a background timer
    log 0 "[MAIN-3] Setting up update timer"
    (
        # Disable exit on error for the subshell
        set +e
        # Ignore parent's signals
        trap '' SIGTERM SIGINT SIGHUP
        while true; do
            sleep "$UPDATE_INTERVAL"
            kill -USR2 $$
        done
    ) &
    WATCH_PIDS["update_timer"]=$!
    log 0 "[MAIN-4] Watch_mail test initialization complete"
    
    # Wait for signals while keeping track of processes
    while true; do
        sleep 60 &
        wait $!
    done
}

# Run tests if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Disable exit on error for main script
    set +e
    main "$@"
fi

