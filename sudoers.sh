#!/bin/bash

# Check if the script is run as root
if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

# Get the current username
CURRENT_USER=$(who am i | awk '{print $1}')

# Add the current user to the sudoers file
echo "$CURRENT_USER ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

echo "$CURRENT_USER has been added to the sudoers list."
