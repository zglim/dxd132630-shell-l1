#!/bin/bash
##################################################
# Name: test-disk-space-check.sh
# Description: Regression tests for disk-space-check.sh
##################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/disk-space-check.sh"

PASS=0
FAIL=0
TOTAL=0

MOCK_BIN=""
MOCK_DEV=""
MAIL_LOG=""

setup() {
    MOCK_BIN=$(mktemp -d)
    MOCK_DEV=$(mktemp -d)
    MAIL_LOG="${MOCK_BIN}/mail_calls.log"
    touch "$MAIL_LOG"

    # Create mock device files
    touch "${MOCK_DEV}/sda1"
    touch "${MOCK_DEV}/sdb1"
    touch "${MOCK_DEV}/sdc1"
}

teardown() {
    rm -rf "$MOCK_BIN" "$MOCK_DEV" 2>/dev/null
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo "  [PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $desc (expected='$expected', actual='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qE "$needle"; then
        echo "  [PASS] $desc"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $desc (pattern='$needle' not found)"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    TOTAL=$((TOTAL + 1))
    if echo "$haystack" | grep -qE "$needle"; then
        echo "  [FAIL] $desc (pattern='$needle' unexpectedly found)"
        FAIL=$((FAIL + 1))
    else
        echo "  [PASS] $desc"
        PASS=$((PASS + 1))
    fi
}

assert_exit_code() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [ "$expected" = "$actual" ]; then
        echo "  [PASS] $desc (exit=$actual)"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $desc (expected exit=$expected, actual=$actual)"
        FAIL=$((FAIL + 1))
    fi
}

count_mail_calls() {
    if [ -f "$MAIL_LOG" ]; then
        wc -l < "$MAIL_LOG" | tr -d ' '
    else
        echo "0"
    fi
}

##################################################
# Helper: create mock commands and run a wrapper
#
run_test() {
    local disk_list="$1"
    local threshold_list="$2"
    local df_behavior="$3"

    # --- Mock hostname ---
    cat > "${MOCK_BIN}/hostname" << 'EOF'
#!/bin/bash
if [ "$1" = "-I" ]; then
    echo "192.168.1.100"
else
    echo "test-host"
fi
EOF
    chmod +x "${MOCK_BIN}/hostname"

    # --- Mock mailx ---
    cat > "${MOCK_BIN}/mailx" << MAILEOF
#!/bin/bash
echo "mailx \$@" >> "${MAIL_LOG}"
cat > /dev/null
exit 0
MAILEOF
    chmod +x "${MOCK_BIN}/mailx"

    # --- Mock df ---
    case "$df_behavior" in
        empty)
            cat > "${MOCK_BIN}/df" << 'EOF'
#!/bin/bash
echo "Filesystem     1K-blocks    Used Available Use% Mounted on"
exit 0
EOF
            ;;
        error)
            cat > "${MOCK_BIN}/df" << 'EOF'
#!/bin/bash
echo "df: No such file or directory" >&2
exit 1
EOF
            ;;
        nonnumeric)
            cat > "${MOCK_BIN}/df" << 'EOF'
#!/bin/bash
echo "Filesystem     1K-blocks    Used Available Use% Mounted on"
echo "/dev/sda1       N/A         N/A    N/A       N/A  /"
EOF
            ;;
        all_low)
            cat > "${MOCK_BIN}/df" << 'EOF'
#!/bin/bash
echo "Filesystem     1K-blocks    Used Available Use% Mounted on"
if echo "$*" | grep -q -- "-h"; then
    echo "fake       20G    19G    500M   98%  /"
else
    echo "fake       20971520 19922944 512000  98%  /"
fi
EOF
            ;;
        low_first_only)
            # First device argument seen => low; second => high
            # We use a counter file to track calls
            local counter_file="${MOCK_BIN}/df_counter"
            echo "0" > "$counter_file"
            cat > "${MOCK_BIN}/df" << COUNTEOF
#!/bin/bash
count=\$(cat "${counter_file}")
count=\$((count + 1))
echo "\$count" > "${counter_file}"
echo "Filesystem     1K-blocks    Used Available Use% Mounted on"
if [ "\$count" -le 2 ]; then
    # First device (calls 1 and 2 are -k and -h for first disk)
    if echo "\$*" | grep -q -- "-h"; then
        echo "fake       20G    19G    500M   98%  /"
    else
        echo "fake       20971520 19922944 512000  98%  /"
    fi
else
    # Second device
    if echo "\$*" | grep -q -- "-h"; then
        echo "fake       20G    5G     15G    25%  /data"
    else
        echo "fake       20971520 5242880 15728640  25%  /data"
    fi
fi
COUNTEOF
            ;;
        mixed_first_error)
            # First device => error, second => low
            local counter_file2="${MOCK_BIN}/df_counter2"
            echo "0" > "$counter_file2"
            cat > "${MOCK_BIN}/df" << COUNTEOF2
#!/bin/bash
count=\$(cat "${counter_file2}")
count=\$((count + 1))
echo "\$count" > "${counter_file2}"
if [ "\$count" -le 2 ]; then
    echo "df: No such file or directory" >&2
    exit 1
fi
echo "Filesystem     1K-blocks    Used Available Use% Mounted on"
if echo "\$*" | grep -q -- "-h"; then
    echo "fake       20G    19G    500M   98%  /"
else
    echo "fake       20971520 19922944 512000  98%  /"
fi
COUNTEOF2
            ;;
        *)
            # normal: plenty of space
            cat > "${MOCK_BIN}/df" << 'EOF'
#!/bin/bash
echo "Filesystem     1K-blocks    Used Available Use% Mounted on"
if echo "$*" | grep -q -- "-h"; then
    echo "fake       20G    5G     15G    25%  /"
else
    echo "fake       20971520 5242880 15728640  25%  /"
fi
EOF
            ;;
    esac
    chmod +x "${MOCK_BIN}/df"

    # --- Build wrapper script ---
    local wrapper="${MOCK_BIN}/wrapper.sh"
    {
        echo '#!/bin/bash'
        echo "export PATH=\"${MOCK_BIN}:\$PATH\""
        echo ""
        echo "HOSTNAME=\$(hostname)"
        echo "IP=\$(hostname -I 2>/dev/null | awk '{print \$1}')"
        echo "MAIL=\$(which mailx 2>/dev/null)"
        echo "MAILTO=\"user@email.com\""
        echo "SUBJECT=\"Warning: low Disk Space for \$HOSTNAME\""
        echo ""

        local idx=1
        for d in $disk_list; do
            echo "Disk[${idx}]=\"${d}\""
            idx=$((idx + 1))
        done

        idx=1
        for t in $threshold_list; do
            echo "MinDisk[${idx}]=\"${t}\""
            idx=$((idx + 1))
        done

        echo ""
        # Inline the function definitions and main loop
        cat << 'INNEREOF'

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

function is_integer {
    local val="$1"
    [[ -n "$val" && "$val" =~ ^[0-9]+$ ]]
}

ALERTS_SENT=0
ERRORS=0

for i in $(seq 1 ${#Disk[@]}); do
    current_disk="${Disk[$i]}"
    current_min="${MinDisk[$i]}"

    if ! is_integer "$current_min"; then
        echo "[ERROR] Invalid threshold for ${current_disk}: '${current_min}' (not a valid integer). Skipping." >&2
        ERRORS=$((ERRORS + 1))
        continue
    fi

    if [ ! -e "$current_disk" ]; then
        echo "[WARN] Device ${current_disk} does not exist on this host. Skipping." >&2
        continue
    fi

    SPACEK=$(df -k "$current_disk" 2>/dev/null | awk 'NR==2 {print $4}')
    SPACEG=$(df -h "$current_disk" 2>/dev/null | awk 'NR==2 {print $4}')

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
        SPACEG="${SPACEK}K"
    fi

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

echo "[INFO] Check complete. Alerts sent: ${ALERTS_SENT}, Errors: ${ERRORS}." >&2
exit 0
INNEREOF
    } > "$wrapper"

    chmod +x "$wrapper"
    bash "$wrapper" 2>&1
}

##################################################
# TEST CASES
##################################################

echo "=============================================="
echo "  disk-space-check.sh Regression Tests"
echo "=============================================="
echo ""

# --------------------------------------------------
echo "--- Test 1: Script syntax validation ---"
setup
bash -n "$SCRIPT_UNDER_TEST" 2>&1
assert_exit_code "Script passes bash -n syntax check" "0" "$?"
teardown

# --------------------------------------------------
echo ""
echo "--- Test 2: Normal disks above threshold (no alerts) ---"
setup
disk_a="${MOCK_DEV}/sda1"
disk_b="${MOCK_DEV}/sdb1"
output=$(run_test "$disk_a $disk_b" "5242880 5242880" "normal")
exit_code=$?
assert_exit_code "Script exits 0" "0" "$exit_code"
assert_not_contains "No ALERT for sda1" "ALERT" "$output"
assert_eq "No mail sent" "0" "$(count_mail_calls)"
teardown

# --------------------------------------------------
echo ""
echo "--- Test 3: Disk below threshold triggers alert ---"
setup
disk_a="${MOCK_DEV}/sda1"
disk_b="${MOCK_DEV}/sdb1"
output=$(run_test "$disk_a $disk_b" "5242880 5242880" "low_first_only")
exit_code=$?
assert_exit_code "Script exits 0 with alert" "0" "$exit_code"
assert_contains "ALERT present in output" "ALERT" "$output"
assert_eq "Exactly 1 mail sent" "1" "$(count_mail_calls)"
teardown

# --------------------------------------------------
echo ""
echo "--- Test 4: Non-existent device handled gracefully ---"
setup
disk_a="/dev/nonexistent_xyz_999"
disk_b="${MOCK_DEV}/sdb1"
output=$(run_test "$disk_a $disk_b" "5242880 5242880" "normal")
exit_code=$?
assert_exit_code "Script exits 0 despite missing device" "0" "$exit_code"
assert_contains "WARN about non-existent device" "WARN.*does not exist" "$output"
assert_not_contains "No ALERT for missing device" "ALERT.*nonexistent" "$output"
teardown

# --------------------------------------------------
echo ""
echo "--- Test 5: df returns empty output ---"
setup
disk_a="${MOCK_DEV}/sda1"
output=$(run_test "$disk_a" "5242880" "empty")
exit_code=$?
assert_exit_code "Script exits 0 with empty df" "0" "$exit_code"
assert_contains "ERROR about failed space retrieval" "ERROR.*Failed to get available space" "$output"
assert_eq "No mail sent" "0" "$(count_mail_calls)"
teardown

# --------------------------------------------------
echo ""
echo "--- Test 6: df returns error ---"
setup
disk_a="${MOCK_DEV}/sda1"
output=$(run_test "$disk_a" "5242880" "error")
exit_code=$?
assert_exit_code "Script exits 0 with df error" "0" "$exit_code"
assert_contains "ERROR about failed space retrieval" "ERROR.*Failed to get available space" "$output"
teardown

# --------------------------------------------------
echo ""
echo "--- Test 7: df returns non-numeric values ---"
setup
disk_a="${MOCK_DEV}/sda1"
output=$(run_test "$disk_a" "5242880" "nonnumeric")
exit_code=$?
assert_exit_code "Script exits 0 with non-numeric df" "0" "$exit_code"
assert_contains "ERROR about non-numeric value" "ERROR.*Non-numeric" "$output"
teardown

# --------------------------------------------------
echo ""
echo "--- Test 8: Multiple disks all below threshold ---"
setup
disk_a="${MOCK_DEV}/sda1"
disk_b="${MOCK_DEV}/sdb1"
output=$(run_test "$disk_a $disk_b" "5242880 5242880" "all_low")
exit_code=$?
assert_exit_code "Script exits 0 with all disks low" "0" "$exit_code"
assert_contains "ALERT present" "ALERT" "$output"
assert_eq "Two mails sent" "2" "$(count_mail_calls)"
teardown

# --------------------------------------------------
echo ""
echo "--- Test 9: Mixed - first df fails, second alerts ---"
setup
disk_a="${MOCK_DEV}/sda1"
disk_b="${MOCK_DEV}/sdb1"
output=$(run_test "$disk_a $disk_b" "5242880 5242880" "mixed_first_error")
exit_code=$?
assert_exit_code "Script exits 0 with mixed results" "0" "$exit_code"
assert_contains "ERROR for first disk failure" "ERROR" "$output"
assert_contains "ALERT for second disk" "ALERT" "$output"
assert_eq "One mail sent" "1" "$(count_mail_calls)"
teardown

# --------------------------------------------------
echo ""
echo "--- Test 10: Invalid threshold value ---"
setup
disk_a="${MOCK_DEV}/sda1"
output=$(run_test "$disk_a" "notanumber" "normal")
exit_code=$?
assert_exit_code "Script exits 0 with bad threshold" "0" "$exit_code"
assert_contains "ERROR about invalid threshold" "ERROR.*Invalid threshold" "$output"
teardown

# --------------------------------------------------
echo ""
echo "--- Test 11: All disks non-existent ---"
setup
output=$(run_test "/dev/nope1 /dev/nope2" "5242880 5242880" "normal")
exit_code=$?
assert_exit_code "Script exits 0 when all disks missing" "0" "$exit_code"
assert_contains "WARN for nope1" "WARN.*nope1" "$output"
assert_contains "WARN for nope2" "WARN.*nope2" "$output"
assert_eq "No mail sent" "0" "$(count_mail_calls)"
teardown

# --------------------------------------------------
echo ""
echo "--- Test 12: Message contains expected fields ---"
setup
disk_a="${MOCK_DEV}/sda1"
output=$(run_test "$disk_a" "5242880" "all_low")
assert_contains "Message contains hostname" "test-host" "$output"
assert_contains "Message contains IP" "192.168.1.100" "$output"
assert_contains "Message contains disk warning" "has.*left on" "$output"
teardown

# --------------------------------------------------
echo ""
echo "--- Test 13: Single non-existent disk completes ---"
setup
output=$(run_test "/dev/does_not_exist" "5242880" "normal")
exit_code=$?
assert_exit_code "Script exits 0" "0" "$exit_code"
assert_contains "WARN about missing device" "WARN.*does_not_exist" "$output"
assert_contains "Completion info" "Check complete" "$output"
teardown

##################################################
# Summary
##################################################
echo ""
echo "=============================================="
echo "  Results: ${PASS} passed, ${FAIL} failed, ${TOTAL} total"
echo "=============================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
