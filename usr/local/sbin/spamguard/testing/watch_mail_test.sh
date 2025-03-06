#!/bin/bash
set -e

# Set debug level (0=INFO, 5=DEBUG)
DEBUG=5

# Source common functions and configurations
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "$SCRIPT_DIR/../usr/local/sbin/spamguard/common.sh"

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
        log 0 "Error: Invalid Maildir structure for $maildir"
        return 1
    fi

    # Pipe for watch process communication
    local pipe="/tmp/watch_${username}_pipe"
    [[ -p "$pipe" ]] || mkfifo "$pipe"

    # Start watch process with error redirection to pipe
    (
        exec 2>"$pipe"
        inotifywait -m -e create -e moved_to --format '%w%f' "${maildir}"/{new,cur} | while read file; do
            if [[ -f "$file" ]]; then
                log 5 "INBOX: New file detected: $file for $username"
            fi
        done
    ) &
    WATCH_PIDS["${username}_inbox"]=$!
    log 5 "Started inbox watch for $username (PID: ${WATCH_PIDS["${username}_inbox"]})"
    
    # Find and watch spam directories
    local spam_count=0
    while IFS= read -r spam_dir; do
        if [[ ! -d "$spam_dir" ]]; then
            continue
        fi
        log 5 "Found spam dir: $spam_dir"
        
        if ! is_valid_maildir "$spam_dir"; then
            log 0 "Error: Invalid Maildir structure for spam dir $spam_dir"
            continue
        fi
        
        # Start watch process with error redirection to pipe
        (
            exec 2>"$pipe"
            inotifywait -m -e create -e moved_to --format '%w%f' "${spam_dir}"/{new,cur} | while read file; do
                if [[ -f "$file" ]]; then
                    log 5 "SPAM: New file detected: $file for $username"
                fi
            done
        ) &
        WATCH_PIDS["${username}_spam_${spam_count}"]=$!
        log 5 "Started spam watch for $username on $spam_dir (PID: ${WATCH_PIDS["${username}_spam_${spam_count}"]})"
        ((spam_count++))
    done < <(find "$maildir" -type d -regextype posix-extended -iregex "$SPAM_DIR_REGEX")

    # Monitor pipe for errors from any watch process
    (
        while read -r error; do
            log 0 "Watch error for $username: $error"
            # Trigger watch recovery
            kill -USR1 $$
        done < "$pipe"
    ) &
    WATCH_PIDS["${username}_monitor"]=$!
}

# Cleanup watches for a mailbox
cleanup_mailbox_watches() {
    local username="$1"
    log 0 "Cleaning up watches for $username"
    for key in "${!WATCH_PIDS[@]}"; do
        if [[ $key == ${username}_* ]]; then
            log 5 "Stopping watch $key (PID: ${WATCH_PIDS[$key]})"
            kill ${WATCH_PIDS[$key]} 2>/dev/null || true
            unset WATCH_PIDS[$key]
        fi
    done
    # Clean up pipe
    rm -f "/tmp/watch_${username}_pipe"
}

# Watch recovery handler
handle_watch_recovery() {
    local username
    for username in "${!MAILBOX_USERS[@]}"; do
        local maildir="${MAILBOX_USERS[$username]}"
        if [[ -d "$maildir" ]]; then
            log 0 "Recovering watches for $username ($maildir)"
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
    while IFS=: read -r username maildir; do
        if [[ ! -v MAILBOX_USERS[$username] ]]; then
            # New mailbox found
            log 0 "Found new mailbox: $username ($maildir)"
            MAILBOX_USERS[$username]="$maildir"
            setup_mailbox_watches "$username" "$maildir"
        elif [[ "${MAILBOX_USERS[$username]}" != "$maildir" ]]; then
            # Mailbox path changed
            log 0 "Mailbox path changed for $username: ${MAILBOX_USERS[$username]} -> $maildir"
            MAILBOX_USERS[$username]="$maildir"
            setup_mailbox_watches "$username" "$maildir"
        fi
    done < <(get_maildirs)
}

# Signal handlers
cleanup_all() {
    log 0 "Received shutdown signal, cleaning up all watches..."
    for username in "${!MAILBOX_USERS[@]}"; do
        cleanup_mailbox_watches "$username"
    done
    log 0 "Cleanup complete, exiting"
    exit 0
}

trap cleanup_all SIGTERM SIGINT SIGHUP
trap handle_watch_recovery SIGUSR1
trap update_mailbox_watches SIGUSR2

# Main test function
main() {
    log 0 "Starting watch_mail test"
    mock_systemd_notify "READY=1"
    
    # Initial setup of mailbox watches
    update_mailbox_watches
    
    # Set up periodic updates using a background timer
    (
        while true; do
            sleep "$UPDATE_INTERVAL"
            kill -USR2 $$
        done
    ) &
    WATCH_PIDS["update_timer"]=$!
    
    # Wait for signals
    while true; do
        sleep infinity &
        wait $!
    done
}

# Run tests if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi  
