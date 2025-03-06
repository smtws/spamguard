#!/bin/bash
set -e

# Source common functions and configurations
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
source "$SCRIPT_DIR/common.sh"

# Output function for capturing Maildir paths
output_maildir() {
    local maildir="$1"
    printf "%s\n" "$maildir"
}

# Find Maildir locations
find_mail_locations() {
    # Process each user from passwd database
    while IFS=: read -r username _ _ _ _ home_dir _; do
        maildir="$home_dir/Maildir"
        if is_valid_maildir "$maildir"; then
            ensure_staging_directories "$username"
            log 5 "Found Maildir for user $username: $maildir"
            output_maildir "$maildir"
        fi
        
        # Check for virtual users in homes directory
        if [[ -d "$home_dir/homes" ]]; then
            while IFS= read -r vuser_dir; do
                vuser=$(basename "$vuser_dir")
                vmaildir="$vuser_dir/Maildir"
                if is_valid_maildir "$vmaildir"; then
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
# Create temporary files
tmp_raw=$(mktemp)
tmp_dedup=$(mktemp)

# Get the mail locations and remove duplicates
find_mail_locations > "$tmp_raw"
sort -u "$tmp_raw" > "$tmp_dedup"

if [[ -f "$MAIL_DIRS_CONFIG" ]]; then
    if ! diff -q "$MAIL_DIRS_CONFIG" "$tmp_dedup" >/dev/null 2>&1; then
        log 0 "Mail directory list has changed"
        safe_move "$tmp_dedup" "$MAIL_DIRS_CONFIG"
    else
        log 5 "No changes in mail directory list"
        rm "$tmp_dedup"
    fi
else
    log 0 "Creating initial mail directory list"
    safe_move "$tmp_dedup" "$MAIL_DIRS_CONFIG"
fi

# Cleanup
rm -f "$tmp_raw"