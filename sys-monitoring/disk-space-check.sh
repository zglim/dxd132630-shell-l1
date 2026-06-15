#!/bin/bash
##################################################
# Name: disk-space-check.sh
# Description: Checks Disk Space, Emails when low
# Script Maintainer: Jacob Amey
#
# Last Updated: 2026-06-15
#
# Common Disk Option Page out Figures
# 1048576 KB  = 1 GB
# 2097152 KB  = 2 GB
# 5242880 KB  = 5 GB
# 10485760 KB = 10 GB
##################################################

# Set Sys Variables
HOSTNAME=$(hostname)
IP=$(hostname -I 2>/dev/null | awk '{print $1}')

##################################################
# Mail Settings
#
MAIL=$(which mailx 2>/dev/null)
MAILTO="user@email.com"
SUBJECT="Warning: low Disk Space for $HOSTNAME"

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
function message {
    local disk_name="$1"
    local space_human="$2"

    echo "
------------: Sys Info :---------------

Hostname : $HOSTNAME
IP : $IP
Date-Time : $(date)

---------------------------------------

Warning: Disk ${disk_name} has ${space_human} left on


"
}
# End message Function
##################################################

##################################################
# is_integer: validate that a value is a non-negative integer
#
function is_integer {
    local val="$1"
    # Must be non-empty and contain only digits
    [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]
}
##################################################

##################################################
# Main Script
#
# Track how many alerts were sent and any errors encountered
ALERTS_SENT=0
ERRORS=0

for i in $(/usr/bin/seq 1 ${#Disk[@]}); do
    current_disk="${Disk[$i]}"
    current_min="${MinDisk[$i]}"

    # --- Validate threshold configuration ---
    if ! is_integer "$current_min"; then
        echo "[ERROR] Invalid threshold for ${current_disk}: '${current_min}' (not a valid integer). Skipping." >&2
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # --- Check if device exists ---
    if [ ! -e "$current_disk" ]; then
        echo "[WARN] Device ${current_disk} does not exist on this host. Skipping." >&2
        continue
    fi

    # --- Get available space via df ---
    SPACEK=$(/bin/df -k "$current_disk" 2>/dev/null | /usr/bin/awk 'NR==2 {print $4}')
    SPACEG=$(/bin/df -h "$current_disk" 2>/dev/null | /usr/bin/awk 'NR==2 {print $4}')

    # --- Validate df output ---
    if [ -z "$SPACEK" ]; then
        echo "[ERROR] Failed to get available space (KB) for ${current_disk}. df may have failed. Skipping." >&2
        ERRORS=$((ERRORS + 1))
        continue
    fi

    if ! is_integer "$SPACEK"; then
        echo "[ERROR] Non-numeric available space value for ${current_disk}: '${SPACEK}'. Skipping." >&2
        ERRORS=$((ERRORS + 1))
        continue
    fi

    if [ -z "$SPACEG" ]; then
        # Fallback: if human-readable output is empty, use the KB value
        SPACEG="${SPACEK}K"
    fi

    # --- Compare and alert ---
    if [ "$SPACEK" -le "$current_min" ]; then
        msg=$(message "$current_disk" "$SPACEG")
        echo "[ALERT] ${current_disk}: ${SPACEG} available (threshold: ${current_min} KB)" >&2

        if [ -n "$MAIL" ] && [ -x "$MAIL" ]; then
            echo "$msg" | "$MAIL" -s "$SUBJECT" "$MAILTO"
            if [ $? -eq 0 ]; then
                ALERTS_SENT=$((ALERTS_SENT + 1))
            else
                echo "[ERROR] Failed to send alert email for ${current_disk}." >&2
                ERRORS=$((ERRORS + 1))
            fi
        else
            echo "[WARN] mailx not found or not executable. Alert not sent for ${current_disk}." >&2
            echo "$msg"
            ALERTS_SENT=$((ALERTS_SENT + 1))
        fi
    fi
done

# Summary
echo "[INFO] Check complete. Alerts sent: ${ALERTS_SENT}, Errors: ${ERRORS}." >&2

exit 0
#EOF
