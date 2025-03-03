#!/bin/bash

# Configuration and log files
CONFIG="/etc/spamguard/spam_dirs.txt"
STAGING_ROOT="/var/spam_processing"
LOG="/var/log/spamguard.log"
LOCKFILE="/var/run/spamguard_update.lock"

# Function to generate user ID (considering sub-users)
generate_user_id() {
  USER_PATH="$1"

  # Check if a sub-user exists
  if [[ "$USER_PATH" =~ /home/([^/]+)/homes/([^/]+)/Maildir ]]; then
    # If a sub-user exists, extract the sub-user
    USER="${BASH_REMATCH[2]}"
  elif [[ "$USER_PATH" =~ /home/([^/]+)/Maildir ]]; then
    # Otherwise, extract the main user
    USER="${BASH_REMATCH[1]}"
  else
    echo "Invalid path: $USER_PATH"
    exit 1
  fi

  # Return the user ID
  echo "$USER"
}

# Process existing spam files on startup
while IFS= read -r dir; do
  if [[ -d "$dir" ]]; then
    # Find spam files that are not yet in the staging directory
    find "$dir" -type f | while read -r spam_file; do
      USER=$(generate_user_id "$spam_file")

      # Staging directory for the user
      STAGING_DIR="$STAGING_ROOT/$USER"

      # Ensure the staging directory exists
      if [[ ! -d "$STAGING_DIR" ]]; then
        mkdir -p "$STAGING_DIR"
        echo "$(date): Created staging directory $STAGING_DIR" >> "$LOG"
      fi

      # Check if the file is already linked in the staging directory
      if [[ ! -e "$STAGING_DIR/$(basename "$spam_file")" ]]; then
	setfacl -R -m u:spamguard:rwx "$dir"
	setfacl -R -m d:u:spamguard:rwx "$dir"
        echo "$(date): Creating hardlink for $spam_file" >> "$LOG"
	ln -v "$spam_file" "$STAGING_DIR/$(basename "$spam_file")" >> "$LOG" 2>&1 || cp -v "$spam_file" "$STAGING_DIR/" >> "$LOG" 2>&1
      fi
    done
  fi
done < "$CONFIG"

# Main process to monitor mailboxes
xargs -a "$CONFIG" -d '\n' inotifywait -m -e create,delete --format "%w%f" |
while read -r file; do
  # Extract user ID
  USER=$(generate_user_id "$file")

  # Staging directory for the user
  STAGING_DIR="$STAGING_ROOT/$USER"

  # Ensure the staging directory exists
  if [[ ! -d "$STAGING_DIR" ]]; then
    mkdir -p "$STAGING_DIR"
    echo "$(date): Created staging directory $STAGING_DIR" >> "$LOG"
  fi

  # Handle create event
  if [[ -e "$file" ]]; then
    # Check if the file is already linked in the staging directory
    if [[ ! -e "$STAGING_DIR/$(basename "$file")" ]]; then
      echo "$(date): Creating hardlink for $file" >> "$LOG"
        setfacl -R -m u:spamguard:rwx "$(dirname "$file")"
        setfacl -R -m d:u:spamguard:rwx "$(dirname "$file")"
	ln -v "$spam_file" "$STAGING_DIR/$(basename "$spam_file")" >> "$LOG" 2>&1 || cp -v "$spam_file" "$STAGING_DIR/" >> "$LOG" 2>&1

    fi
  else
    # Handle delete event
    FILENAME=$(basename "$file" | sed 's/[,:].*//')

    # Search for the file in the staging directory
    STAGING_FILE=$(find "$STAGING_DIR" -name "$FILENAME" -print -quit)

    # If a file is found in the staging, process it
    if [[ -f "$STAGING_FILE" ]]; then
      echo "$(date): Processing $STAGING_FILE" >> "$LOG"      
      # Check if the file already contains SpamAssassin headers
      if ! grep -q "X-Spam-Flag: YES" "$STAGING_FILE"; then
        # Pass the file to sa-learn if it does not have spam headers
        sa-learn --spam "$STAGING_FILE" >> "$LOG" 2>&1
      else
        echo "$(date): File $STAGING_FILE already contains Spam headers, skipping." >> "$LOG"
      fi

      # Delete the hardlink
      rm -f "$STAGING_FILE"
    fi
  fi

  # Check if the Maildir for the user still exists
  if [[ ! -d "/home/$USER/Maildir" ]]; then
    echo "$(date): Maildir for $USER is missing, triggering update_spam_dirs." >> "$LOG"

    # Ensure update_spam_dirs does not run in parallel
    if [[ ! -f "$LOCKFILE" ]]; then
      touch "$LOCKFILE"
      /usr/local/sbin/spamguard/update_spam_dirs.sh
      rm -f "$LOCKFILE"
    else
      echo "$(date): update_spam_dirs is already running, skipping." >> "$LOG"
    fi

    # Delete the mailbox directory from the staging and exit the loop
    rm -rf "$STAGING_DIR"
    echo "$(date): Directory $STAGING_DIR deleted, exiting loop." >> "$LOG"
    break
  fi
done
