#!/bin/bash
##################################################
# Name: disk-space-check.sh
# Description: Checks Disk Space, Emails when low
# Script Maintainer: Jacob Amey
#
# Last Updated: July 22th 2013
#
# Common Disk Option Page out Figures
# 1048576 KB  = 1 GB
# 2097152 KB  = 2 GB
# 5242880 KB  = 5 GB
# 10485760 KB = 10 GB
##################################################
# Set Sys Variables
HOSTNAME=$(hostname)
IP=$(hostname -I 2>/dev/null || echo "unknown")
##################################################
# Command paths (overridable for testing)
#
DF=${DF:-/bin/df}
AWK=${AWK:-/usr/bin/awk}
##################################################
# Mail Settings
#
MAIL=${MAIL:-$(which mailx 2>/dev/null || echo "mailx")}
MAILTO="${MAILTO:-user@email.com}"
##################################################
# Devices to Monitor
#
Disk[1]="/dev/sda1"
Disk[2]="/dev/sdb1"
##################################################
# Disk Space Page out point
#
MinDisk[1]=5242880 # 5 GB
MinDisk[2]=5242880 # 5 GB
##################################################
# Message Function
#
# Usage: message <disk_device> <human_readable_space>
function message {
    local disk_dev="$1"
    local space_human="$2"
    echo "
------------: Sys Info :---------------

Hostname : $HOSTNAME
IP : $IP
Date-Time : $(date)

---------------------------------------

Warning: Disk $disk_dev has $space_human left on

"
}
# End message Function
##################################################
# Main Script
#
for i in $(seq 1 ${#Disk[@]}); do
    disk_device="${Disk[$i]}"

    # Skip if device is not configured
    if [ -z "$disk_device" ]; then
        echo "Warning: Disk[$i] is not configured, skipping." >&2
        continue
    fi

    # Check if the device exists
    if [ ! -e "$disk_device" ]; then
        echo "Warning: Device $disk_device does not exist, skipping." >&2
        continue
    fi

    # Get disk space in KB
    SPACEK=$("$DF" -k "$disk_device" 2>/dev/null | "$AWK" '{print $4}' | tail -n 1)

    # Validate SPACEK is a non-empty integer
    if [ -z "$SPACEK" ] || ! [[ "$SPACEK" =~ ^[0-9]+$ ]]; then
        echo "Warning: Could not get valid disk space for $disk_device (got: '$SPACEK'), skipping." >&2
        continue
    fi

    # Get human-readable space for the alert message
    SPACEG=$("$DF" -h "$disk_device" 2>/dev/null | "$AWK" '{print $4}' | tail -n 1)
    if [ -z "$SPACEG" ]; then
        SPACEG="unknown"
    fi

    # Get threshold, default to 0 if not set
    threshold="${MinDisk[$i]:-0}"
    if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
        echo "Warning: Invalid threshold for $disk_device (got: '$threshold'), skipping." >&2
        continue
    fi

    SUBJECT="Warning: low Disk Space for $HOSTNAME"

    if [ "$SPACEK" -le "$threshold" ]; then
        message "$disk_device" "$SPACEG" | "$MAIL" -s "$SUBJECT" "$MAILTO"
    fi
done
#EOF
