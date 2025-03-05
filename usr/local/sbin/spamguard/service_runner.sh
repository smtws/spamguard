#!/bin/bash
set -e

# Path to the configuration and timestamp file
CONFIG_FILE="/etc/spamguard/spamguard.conf"
LAST_RUN_FILE="/etc/spamguard/last_run"

# Default update interval (6 hours)
DEFAULT_UPDATE_INTERVAL=21600

# Read the configuration file if it exists
if [[ -f "$CONFIG_FILE" ]]; then
    # Attempt to read the UPDATE_INTERVAL from the config file
    source "$CONFIG_FILE"
else
    # Use the default interval if the config file is not found
    UPDATE_INTERVAL="${UPDATE_INTERVAL:-$DEFAULT_UPDATE_INTERVAL}"
fi

# Ensure the directory exists for the timestamp file
mkdir -p /etc/spamguard

# Initialize the last run timestamp if it doesn't exist
if [[ ! -f "$LAST_RUN_FILE" ]]; then
    echo 0 > "$LAST_RUN_FILE"
fi

# Get the last run timestamp
LAST_RUN_TIMESTAMP=$(cat "$LAST_RUN_FILE")

# Get the current timestamp
CURRENT_TIMESTAMP=$(date +%s)

# Check if the last run was older than the update interval
if (( CURRENT_TIMESTAMP - LAST_RUN_TIMESTAMP >= UPDATE_INTERVAL )); then
    # Run the update_mail_dirs.sh script
    /usr/local/sbin/spamguard/update_mail_dirs.sh

    # Update the timestamp of the last run
    echo "$CURRENT_TIMESTAMP" > "$LAST_RUN_FILE"
fi

# Now, run spam_guard.sh and let the service restart it as needed
/usr/local/sbin/spamguard/spam_guard.sh