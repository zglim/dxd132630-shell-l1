#!/bin/bash
##################################################
# Regression tests for disk-space-check.sh
##################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/disk-space-check.sh"

PASS=0
FAIL=0

setup() {
    TMPDIR=$(mktemp -d)
    MOCK_BIN="$TMPDIR/bin"
    MOCK_DEVICES="$TMPDIR/dev"
    MAIL_LOG="$TMPDIR/mail.log"
    STDERR_LOG="$TMPDIR/stderr.log"
    mkdir -p "$MOCK_BIN" "$MOCK_DEVICES"

    # Create mock mailx that logs calls
    cat > "$MOCK_BIN/mock_mail" <<'MAILEOF'
#!/bin/bash
echo "MAIL_CALL: subject=[$2] to=[$3]" >> "$MAIL_LOG_FILE"
cat >> "$MAIL_LOG_FILE"
echo "---END_MAIL---" >> "$MAIL_LOG_FILE"
MAILEOF
    chmod +x "$MOCK_BIN/mock_mail"

    # Create mock awk (just use real awk)
    AWK_PATH=$(which awk 2>/dev/null || which gawk 2>/dev/null || echo "awk")
    export AWK_PATH
}

teardown() {
    rm -rf "$TMPDIR"
}

# Create a mock df script with configurable output per device
# Usage: create_mock_df <device> <kb_value> <human_value>
#   Call multiple times for multiple devices
create_mock_df() {
    local df_script="$MOCK_BIN/mock_df"
    # Start fresh if first call
    if [ ! -f "$df_script" ]; then
        cat > "$df_script" <<'DFHEADER'
#!/bin/bash
# Mock df - returns configured values based on device
device=""
mode=""
for arg in "$@"; do
    case "$arg" in
        -k) mode="k" ;;
        -h) mode="h" ;;
        -*) ;;
        *) device="$arg" ;;
    esac
done
DFHEADER
        chmod +x "$df_script"
    fi

    local device="$1"
    local kb_val="$2"
    local human_val="$3"

    cat >> "$df_script" <<DFENTRY
if [ "\$device" = "$device" ]; then
    if [ "\$mode" = "k" ]; then
        echo "Filesystem     1K-blocks  Used      Available Use% Mounted"
        echo "/dev/xxx       100000000  50000000  $kb_val   50% /mnt/data"
    else
        echo "Filesystem     Size  Used  Avail Use% Mounted"
        echo "/dev/xxx       100G  50G   $human_val  50% /mnt/data"
    fi
    exit 0
fi
DFENTRY
}

# Add a "device not found" fallback to mock df
finalize_mock_df() {
    cat >> "$MOCK_BIN/mock_df" <<'DFFOOTER'
# Device not recognized - simulate df failure
echo "df: $device: No such file or directory" >&2
exit 1
DFFOOTER
}

# Create a mock df that returns garbage output
create_mock_df_garbage() {
    cat > "$MOCK_BIN/mock_df" <<'DFGARBAGE'
#!/bin/bash
device=""
for arg in "$@"; do
    case "$arg" in
        -*) ;;
        *) device="$arg" ;;
    esac
done
echo "Some unexpected output"
echo "No numeric data here at all"
exit 0
DFGARBAGE
    chmod +x "$MOCK_BIN/mock_df"
}

# Create a mock df that outputs empty
create_mock_df_empty() {
    cat > "$MOCK_BIN/mock_df" <<'DFEMPTY'
#!/bin/bash
exit 1
DFEMPTY
    chmod +x "$MOCK_BIN/mock_df"
}

# Generate a test version of the script with custom disk config
# Usage: generate_test_script <disk1> <min1> [<disk2> <min2> ...]
generate_test_script() {
    local test_script="$TMPDIR/test_disk_check.sh"

    cat > "$test_script" <<HEADER
#!/bin/bash
HOSTNAME="testhost"
IP="192.168.1.100"
DF="$MOCK_BIN/mock_df"
AWK="$AWK_PATH"
MAIL="$MOCK_BIN/mock_mail"
MAILTO="test@example.com"
export MAIL_LOG_FILE="$MAIL_LOG"
HEADER

    # Add disk and threshold arrays
    local idx=1
    while [ $# -ge 2 ]; do
        echo "Disk[$idx]=\"$1\"" >> "$test_script"
        echo "MinDisk[$idx]=$2" >> "$test_script"
        shift 2
        idx=$((idx + 1))
    done

    # Append the function and main loop from the original script
    # (extract from Message Function onwards)
    sed -n '/^# Message Function/,/^#EOF/p' "$SCRIPT_UNDER_TEST" >> "$test_script"

    chmod +x "$test_script"
    echo "$test_script"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local msg="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $msg"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $msg"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo "  PASS: $msg"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $msg"
        echo "    Expected to contain: $needle"
        echo "    Got: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="$3"
    if ! echo "$haystack" | grep -q "$needle"; then
        echo "  PASS: $msg"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $msg"
        echo "    Expected NOT to contain: $needle"
        echo "    Got: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local file="$1"
    local msg="$2"
    if [ -f "$file" ]; then
        echo "  PASS: $msg"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $msg (file not found: $file)"
        FAIL=$((FAIL + 1))
    fi
}

##################################################
# TEST 1: Normal disk - space above threshold, no alert
##################################################
test_normal_disk_no_alert() {
    echo "TEST 1: Normal disk above threshold - no alert sent"
    setup

    # Create fake device
    touch "$MOCK_DEVICES/sda1"

    # Mock df returns 10GB free (10485760 KB) - above 5GB threshold
    create_mock_df "$MOCK_DEVICES/sda1" "10485760" "10G"
    finalize_mock_df

    local test_script
    test_script=$(generate_test_script "$MOCK_DEVICES/sda1" "5242880")

    # Run
    bash "$test_script" >"$TMPDIR/stdout.log" 2>"$STDERR_LOG"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Script exits successfully"
    # No mail should be sent
    if [ -f "$MAIL_LOG" ]; then
        local mail_content
        mail_content=$(cat "$MAIL_LOG")
        assert_equals "" "$mail_content" "No mail sent for normal disk"
    else
        echo "  PASS: No mail log created (no mail sent)"
        PASS=$((PASS + 1))
    fi

    teardown
}

##################################################
# TEST 2: Disk device does not exist - warning, no crash
##################################################
test_missing_device() {
    echo "TEST 2: Disk device does not exist - warning, continue"
    setup

    # Do NOT create the device file
    create_mock_df "/nonexistent/device" "10485760" "10G"
    finalize_mock_df

    local test_script
    test_script=$(generate_test_script "/nonexistent/device" "5242880")

    # Run
    bash "$test_script" >"$TMPDIR/stdout.log" 2>"$STDERR_LOG"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Script exits successfully despite missing device"

    local stderr_content
    stderr_content=$(cat "$STDERR_LOG")
    assert_contains "$stderr_content" "does not exist" "Warning about missing device is logged"

    # No mail should be sent
    if [ -f "$MAIL_LOG" ]; then
        local mail_count
        mail_count=$(grep -c "MAIL_CALL" "$MAIL_LOG" 2>/dev/null || echo "0")
        assert_equals "0" "$mail_count" "No mail sent for missing device"
    else
        echo "  PASS: No mail sent for missing device"
        PASS=$((PASS + 1))
    fi

    teardown
}

##################################################
# TEST 3: df returns non-numeric/garbage output
##################################################
test_df_garbage_output() {
    echo "TEST 3: df returns non-numeric output - warning, no crash"
    setup

    # Create fake device
    touch "$MOCK_DEVICES/sda1"

    # Mock df that returns garbage
    create_mock_df_garbage

    local test_script
    test_script=$(generate_test_script "$MOCK_DEVICES/sda1" "5242880")

    # Run
    bash "$test_script" >"$TMPDIR/stdout.log" 2>"$STDERR_LOG"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Script exits successfully despite garbage df output"

    local stderr_content
    stderr_content=$(cat "$STDERR_LOG")
    assert_contains "$stderr_content" "Could not get valid disk space" "Warning about invalid df output"

    # No mail should be sent
    if [ -f "$MAIL_LOG" ]; then
        local mail_count
        mail_count=$(grep -c "MAIL_CALL" "$MAIL_LOG" 2>/dev/null || echo "0")
        assert_equals "0" "$mail_count" "No mail sent for garbage df output"
    else
        echo "  PASS: No mail sent for garbage df output"
        PASS=$((PASS + 1))
    fi

    teardown
}

##################################################
# TEST 4: df returns empty output
##################################################
test_df_empty_output() {
    echo "TEST 4: df returns empty output - warning, no crash"
    setup

    # Create fake device
    touch "$MOCK_DEVICES/sda1"

    # Mock df that returns nothing
    create_mock_df_empty

    local test_script
    test_script=$(generate_test_script "$MOCK_DEVICES/sda1" "5242880")

    # Run
    bash "$test_script" >"$TMPDIR/stdout.log" 2>"$STDERR_LOG"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Script exits successfully despite empty df output"

    local stderr_content
    stderr_content=$(cat "$STDERR_LOG")
    assert_contains "$stderr_content" "Could not get valid disk space" "Warning about empty df output"

    teardown
}

##################################################
# TEST 5: Disk below threshold - alert sent
##################################################
test_disk_below_threshold_alert() {
    echo "TEST 5: Disk below threshold - alert sent"
    setup

    # Create fake device
    touch "$MOCK_DEVICES/sda1"

    # Mock df returns 2GB free (2097152 KB) - below 5GB threshold
    create_mock_df "$MOCK_DEVICES/sda1" "2097152" "2.0G"
    finalize_mock_df

    local test_script
    test_script=$(generate_test_script "$MOCK_DEVICES/sda1" "5242880")

    # Run
    bash "$test_script" >"$TMPDIR/stdout.log" 2>"$STDERR_LOG"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Script exits successfully"

    assert_file_exists "$MAIL_LOG" "Mail log file created"

    local mail_content
    mail_content=$(cat "$MAIL_LOG" 2>/dev/null || echo "")
    assert_contains "$mail_content" "MAIL_CALL" "Mail was sent"
    assert_contains "$mail_content" "testhost" "Alert contains hostname"
    assert_contains "$mail_content" "192.168.1.100" "Alert contains IP"
    assert_contains "$mail_content" "2.0G" "Alert contains human-readable space"
    assert_contains "$mail_content" "$MOCK_DEVICES/sda1" "Alert identifies which disk"

    teardown
}

##################################################
# TEST 6: Multiple disks below threshold - all get alerts
##################################################
test_multiple_disks_alert() {
    echo "TEST 6: Multiple disks below threshold - all get alerts"
    setup

    # Create fake devices
    touch "$MOCK_DEVICES/sda1"
    touch "$MOCK_DEVICES/sdb1"

    # Both disks below threshold
    create_mock_df "$MOCK_DEVICES/sda1" "1048576" "1.0G"
    create_mock_df "$MOCK_DEVICES/sdb1" "2097152" "2.0G"
    finalize_mock_df

    local test_script
    test_script=$(generate_test_script \
        "$MOCK_DEVICES/sda1" "5242880" \
        "$MOCK_DEVICES/sdb1" "5242880")

    # Run
    bash "$test_script" >"$TMPDIR/stdout.log" 2>"$STDERR_LOG"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Script exits successfully"

    local mail_count
    mail_count=$(grep -c "MAIL_CALL" "$MAIL_LOG" 2>/dev/null || echo "0")
    assert_equals "2" "$mail_count" "Two alerts sent for two disks"

    local mail_content
    mail_content=$(cat "$MAIL_LOG")
    assert_contains "$mail_content" "$MOCK_DEVICES/sda1" "Alert for first disk"
    assert_contains "$mail_content" "$MOCK_DEVICES/sdb1" "Alert for second disk"
    assert_contains "$mail_content" "1.0G" "First disk space in alert"
    assert_contains "$mail_content" "2.0G" "Second disk space in alert"

    teardown
}

##################################################
# TEST 7: Mixed - one disk missing, one below threshold
#          Ensures missing disk doesn't prevent other checks
##################################################
test_mixed_missing_and_alert() {
    echo "TEST 7: Mixed scenario - missing disk doesn't block later checks"
    setup

    # Only create the second device, first is missing
    touch "$MOCK_DEVICES/sdb1"

    create_mock_df "$MOCK_DEVICES/sdb1" "2097152" "2.0G"
    finalize_mock_df

    local test_script
    test_script=$(generate_test_script \
        "$MOCK_DEVICES/sda1_missing" "5242880" \
        "$MOCK_DEVICES/sdb1" "5242880")

    # Run
    bash "$test_script" >"$TMPDIR/stdout.log" 2>"$STDERR_LOG"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Script exits successfully"

    local stderr_content
    stderr_content=$(cat "$STDERR_LOG")
    assert_contains "$stderr_content" "does not exist" "Warning for missing first disk"

    # Second disk should still get an alert
    local mail_count
    mail_count=$(grep -c "MAIL_CALL" "$MAIL_LOG" 2>/dev/null || echo "0")
    assert_equals "1" "$mail_count" "Alert still sent for second disk"

    local mail_content
    mail_content=$(cat "$MAIL_LOG")
    assert_contains "$mail_content" "$MOCK_DEVICES/sdb1" "Alert for second disk present"

    teardown
}

##################################################
# TEST 8: Mixed - one garbage df, one valid below threshold
##################################################
test_mixed_garbage_and_alert() {
    echo "TEST 8: Mixed - garbage df for one disk, valid alert for another"
    setup

    touch "$MOCK_DEVICES/sda1"
    touch "$MOCK_DEVICES/sdb1"

    # Custom df: first device returns garbage, second returns valid low value
    cat > "$MOCK_BIN/mock_df" <<DFMIXED
#!/bin/bash
device=""
mode=""
for arg in "\$@"; do
    case "\$arg" in
        -k) mode="k" ;;
        -h) mode="h" ;;
        -*) ;;
        *) device="\$arg" ;;
    esac
done
if [ "\$device" = "$MOCK_DEVICES/sda1" ]; then
    echo "garbage output no numbers"
    exit 0
elif [ "\$device" = "$MOCK_DEVICES/sdb1" ]; then
    if [ "\$mode" = "k" ]; then
        echo "Filesystem     1K-blocks  Used      Available Use% Mounted"
        echo "/dev/xxx       100000000  50000000  3145728   50% /mnt/data"
    else
        echo "Filesystem     Size  Used  Avail Use% Mounted"
        echo "/dev/xxx       100G  50G   3.0G  50% /mnt/data"
    fi
    exit 0
fi
exit 1
DFMIXED
    chmod +x "$MOCK_BIN/mock_df"

    local test_script
    test_script=$(generate_test_script \
        "$MOCK_DEVICES/sda1" "5242880" \
        "$MOCK_DEVICES/sdb1" "5242880")

    # Run
    bash "$test_script" >"$TMPDIR/stdout.log" 2>"$STDERR_LOG"
    local exit_code=$?

    assert_equals "0" "$exit_code" "Script exits successfully"

    local stderr_content
    stderr_content=$(cat "$STDERR_LOG")
    assert_contains "$stderr_content" "Could not get valid disk space" "Warning for garbage df on first disk"

    local mail_count
    mail_count=$(grep -c "MAIL_CALL" "$MAIL_LOG" 2>/dev/null || echo "0")
    assert_equals "1" "$mail_count" "Alert sent only for valid second disk"

    local mail_content
    mail_content=$(cat "$MAIL_LOG")
    assert_contains "$mail_content" "$MOCK_DEVICES/sdb1" "Alert is for the correct disk"

    teardown
}

##################################################
# Run all tests
##################################################
echo "=========================================="
echo " disk-space-check.sh Regression Tests"
echo "=========================================="
echo ""

test_normal_disk_no_alert
echo ""
test_missing_device
echo ""
test_df_garbage_output
echo ""
test_df_empty_output
echo ""
test_disk_below_threshold_alert
echo ""
test_multiple_disks_alert
echo ""
test_mixed_missing_and_alert
echo ""
test_mixed_garbage_and_alert

echo ""
echo "=========================================="
echo " Results: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
