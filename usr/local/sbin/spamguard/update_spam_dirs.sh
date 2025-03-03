#!/bin/bash
CONFIG="/etc/spamguard/spam_dirs.txt"
LOG="/var/log/spamguard.log"
USER="spamguard"

# log with timestamps 
exec > >(awk '{ print strftime("%Y-%m-%d %H:%M:%S"), $0 }' | tee -a "$LOG") 2>&1

echo "Updating spam directories..."

# Clear temporary file
> "$CONFIG.tmp"

getent passwd | while IFS=: read -r username _ _ _ _ home _; do
  if [[ "$home" =~ ^/home ]]; then
    echo "Fix ACL for '$username' : '$home'"
    setfacl  -m d:u:spamguard:rwx -m d:m:rwx "$home"
    setfacl  -m u:spamguard:rwx -m m:rwx "$home"
getfacl "$home"

echo "Fix ACL for '$username' : '$home' EOF"
    if [ "$(stat -c %U "$home/Maildir" 2>/dev/null)" == "$username" ]; then
echo "Set ACL for Maildir of $username."
      setfacl  -m d:u:spamguard:rwx -m d:m:rwx "$home/Maildir"
      setfacl  -m u:spamguard:rwx -m m:rwx "$home/Maildir"
getfacl "$home/Maildir"
      echo "Set ACL for Maildir of $username. EOF"

      # Find spam directories and write paths (without quotes) to temp file
      find "$home/Maildir" -type d -regextype posix-extended \
          -iregex '.*/(\.)?(spam|junk|junk[-._ ]*e[-._ ]*mail)/(cur|new)' |
      while read -r dir; do
echo "Set ACL for ${dir%???} of $username."
setfacl -R -m d:u:spamguard:rwx -m d:m:rwx "${dir%???}"
setfacl -R -m u:spamguard:rwx -m m:rwx "${dir%???}"
getfacl "${dir%???}"
echo "Set ACL for ${dir%???} of $username. EOF"

echo "Set ACL for $dir of $username."
        setfacl -R -m d:u:spamguard:rwx -m d:m:rwx "$dir"
        setfacl -R -m u:spamguard:rwx -m m:rwx "$dir"
getfacl "$dir"
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
  echo "Spam directory list updated."
else
  rm "$CONFIG.tmp"
  echo "No changes detected in spam directory list."
fi
