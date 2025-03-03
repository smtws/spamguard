#!/bin/bash
CONFIG="/etc/spamguard/spam_dirs.txt"
LOG="/var/log/spamguard.log"
USER="spamguard"

# Log with timestamps 
exec > >(awk '{ print strftime("%Y-%m-%d %H:%M:%S"), $0 }' | tee -a "$LOG") 2>&1

echo "Updating spam directories..."

# Clear temporary file
> "$CONFIG.tmp"

# Retrieve user information and iterate over each entry
getent passwd | while IFS=: read -r username _ _ _ _ home _; do
  # Skip if no home directory
  if [ -z "$home" ] || [ ! -d "$home" ]; then
    continue
  fi

  # Check for Maildir and set ACLs if it exists
  maildir="$home/Maildir"
  if [ -d "$maildir" ]; then
  echo "Fix ACL for '$username' : '$home'"
  setfacl -m d:u:$USER:rwx -m d:m:rwx "$home" 
  setfacl -m u:$USER:rwx -m m:rwx "$home"  
  getfacl "$home"
  echo "Fix ACL for '$username' : '$home' EOF"

    echo "Set ACL for Maildir of $username."
    setfacl -m d:u:$USER:rwx -m d:m:rwx "$maildir" 
    setfacl -m u:$USER:rwx -m m:rwx "$maildir"
    getfacl "$maildir"
    echo "Set ACL for Maildir of $username. EOF"

    # Find spam directories within Maildir
    find "$maildir" -type d -regextype posix-extended -iregex '.*/(\.)?(spam|junk|junk[-._ ]*e[-._ ]*mail)' |
    while read -r spamdir; do
      parentdir=$(dirname "$spamdir")
      echo "Set ACL for parent directory: $parentdir"
      setfacl -R -m d:u:$USER:rwx -m d:m:rwx "$parentdir"
      setfacl -R -m u:$USER:rwx -m m:rwx "$parentdir" 
      getfacl "$parentdir"

      echo "Set ACL for spam directory: $spamdir"
      setfacl -R -m d:u:$USER:rwx -m d:m:rwx "$spamdir"
      setfacl -R -m u:$USER:rwx -m m:rwx "$spamdir"
      getfacl "$spamdir"
      
      echo "$spamdir" >> "$CONFIG.tmp"
      echo "Found spam directory: $spamdir"
    done
  fi
done

# Update config only if changes detected
if ! cmp -s "$CONFIG" "$CONFIG.tmp"; then
  mv "$CONFIG.tmp" "$CONFIG"
  echo "Spam directory list updated."
else
  rm "$CONFIG.tmp"
  echo "No changes detected in spam directory list."
fi
