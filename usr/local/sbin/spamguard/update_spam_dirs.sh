#!/bin/bash
CONFIG="/etc/spamguard/spam_dirs.txt"
LOG="/var/log/spamguard.log"
USER="spamguard"

echo "$(date): Updating spam directories..." >> "$LOG"

# Clear temporary file
> "$CONFIG.tmp"

getent passwd | while IFS=: read -r username _ _ _ _ home _; do
  if [[ "$home" =~ ^/home ]]; then
    echo "'$username' : '$home'"
    setfacl -R -m d:u:spamguard:rwx -m d:m:rwx "$home" &>/dev/null
    setfacl -R -m u:spamguard:rwx -m m:rwx "home" &>/dev/null

    if [ "$(stat -c %U "$home/Maildir" 2>/dev/null)" == "$username" ]; then
      setfacl -R -m d:u:spamguard:rwx -m d:m:rwx "$home/Maildir" &>/dev/null
      setfacl -R -m u:spamguard:rwx -m m:rwx "$home/Maildir" &>/dev/null

      echo "$(date): Set ACL for Maildir of $username." >> "$LOG"

      # Find spam directories and write paths (without quotes) to temp file
      find "$home/Maildir" -type d -regextype posix-extended \
          -iregex '.*/(\.)?(spam|junk|junk[-._ ]*e[-._ ]*mail)/(cur|new)' |
      while read -r dir; do
	setfacl -R -m d:u:spamguard:rwx -m d:m:rwx "$dir" &>/dev/null
	setfacl -R -m u:spamguard:rwx -m m:rwx "$dir" &>/dev/null

        echo "$dir" >> "$CONFIG.tmp"  # Write paths without quotes or \r\n
        echo "Found spam dir: $dir"  
      done
    else
      echo "No Maildir found for $username or stat failed"
    fi
  fi
done

# Update config only if changes detected
if ! cmp -s "$CONFIG" "$CONFIG.tmp"; then
  mv "$CONFIG.tmp" "$CONFIG"  # Replace config file with new paths
  echo "$(date): Spam directory list updated." >> "$LOG"
else
  rm "$CONFIG.tmp"
fi
