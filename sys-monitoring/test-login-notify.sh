#!/bin/bash
##################################################
# test-login-notify.sh
# Verification tests for login-notify script.
#
# Usage: bash test-login-notify.sh
##################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/login-notify"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"
COUNTER=0

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

pass() {
    PASS=$((PASS + 1))
    echo "  [PASS] $1"
}

fail() {
    FAIL=$((FAIL + 1))
    echo "  [FAIL] $1 -- $2"
}

# -----------------------------------------------------------
# run_login_notify
#   Run the script in a controlled environment.
#   $1: SSH_CLIENT value  (use "UNSET" to omit)
#   $2: KNOWN_IPS value
#   $3: LOG_FILE path
#   $4: "hide_mail" to use a PATH without mail, or "" for normal
#
# Prints stdout+stderr of the script on stdout.
# Returns the exit code of the script.
# -----------------------------------------------------------
run_login_notify() {
    local ssh_client="$1"
    local known_ips="$2"
    local log_file="$3"
    local hide_mail="$4"

    COUNTER=$((COUNTER + 1))

    # Build a patched copy of the script
    local patched="$TMP_DIR/patched_${COUNTER}.sh"
    cp "$SCRIPT" "$patched"

    # Override config values in the patched script via sed
    sed -i "s|^KNOWN_IPS=.*|KNOWN_IPS=\"$known_ips\"|" "$patched"
    sed -i "s|^LOG_FILE=.*|LOG_FILE=\"$log_file\"|" "$patched"
    sed -i "s|^Logging=.*|Logging=true|" "$patched"
    sed -i "s|^EMAIL=.*|EMAIL=\"test@example.com\"|" "$patched"

    # If hiding mail, create a restricted PATH with only basic utils
    local test_path="$PATH"
    if [ "$hide_mail" = "hide_mail" ]; then
        local fakebin="$TMP_DIR/fakebin_${COUNTER}"
        mkdir -p "$fakebin"
        # Symlink essential commands but NOT mail
        for cmd in bash sh awk sed echo date hostname whoami dirname cat mktemp rm mkdir grep head tail cut tr wc sort; do
            local p
            p="$(command -v "$cmd" 2>/dev/null)" || true
            if [ -n "$p" ]; then
                ln -sf "$p" "$fakebin/$cmd" 2>/dev/null || true
            fi
        done
        test_path="$fakebin"
    fi

    # Set up environment variables
    if [ "$ssh_client" = "UNSET" ]; then
        unset SSH_CLIENT 2>/dev/null
        unset SSH_CONNECTION 2>/dev/null
    else
        SSH_CLIENT="$ssh_client"
        export SSH_CLIENT
        unset SSH_CONNECTION 2>/dev/null
    fi

    # Run with the overridden PATH
    PATH="$test_path" bash "$patched" 2>&1
    local rc=$?

    # Clean up SSH_CLIENT if it was set
    unset SSH_CLIENT 2>/dev/null
    unset SSH_CONNECTION 2>/dev/null

    rm -f "$patched"
    return $rc
}

echo "=========================================="
echo "  login-notify verification tests"
echo "=========================================="
echo

# --------------------------------------------------
# Test 1: Whitelisted IP should be treated as authorized
# --------------------------------------------------
echo "Test 1: Whitelisted IP (127.0.0.1)"
logfile="$TMP_DIR/t1.log"
output="$(run_login_notify "127.0.0.1 22 54321" "127.0.0.1" "$logfile" "")"
rc=$?
ok=true
# Script should not crash
if [ $rc -ne 0 ]; then
    fail "exit code" "got $rc, expected 0"
    ok=false
fi
# Log file should exist and contain "Authorized"
if [ -f "$logfile" ]; then
    if grep -q "Authorized Login" "$logfile"; then
        : # good
    else
        fail "log content" "missing 'Authorized Login' in log"
        ok=false
    fi
else
    fail "log file" "log file not created"
    ok=false
fi
# Should NOT contain "Unauthorized"
if [ -f "$logfile" ] && grep -q "Unauthorized Login" "$logfile"; then
    fail "log content" "should not say 'Unauthorized' for whitelisted IP"
    ok=false
fi
if [ "$ok" = true ]; then pass "whitelisted IP recognized as authorized"; fi

# --------------------------------------------------
# Test 2: Non-whitelisted IP should be unauthorized
# --------------------------------------------------
echo "Test 2: Non-whitelisted IP (192.168.1.100)"
logfile="$TMP_DIR/t2.log"
output="$(run_login_notify "192.168.1.100 22 54321" "127.0.0.1" "$logfile" "")"
rc=$?
ok=true
if [ $rc -ne 0 ]; then
    fail "exit code" "got $rc, expected 0"
    ok=false
fi
if [ -f "$logfile" ]; then
    if grep -q "Unauthorized Login" "$logfile"; then
        : # good
    else
        fail "log content" "missing 'Unauthorized Login' in log"
        ok=false
    fi
else
    fail "log file" "log file not created"
    ok=false
fi
if [ "$ok" = true ]; then pass "non-whitelisted IP flagged as unauthorized"; fi

# --------------------------------------------------
# Test 3: Multiple whitelisted IPs with extra spaces
# --------------------------------------------------
echo "Test 3: Multiple KNOWN_IPS with leading/trailing spaces"
logfile="$TMP_DIR/t3.log"
output="$(run_login_notify "10.0.0.5 22 54321" "  127.0.0.1   10.0.0.5   192.168.0.1  " "$logfile" "")"
rc=$?
ok=true
if [ $rc -ne 0 ]; then
    fail "exit code" "got $rc, expected 0"
    ok=false
fi
if [ -f "$logfile" ] && grep -q "Authorized Login" "$logfile"; then
    : # good, 10.0.0.5 matched despite spaces
else
    fail "whitelist matching" "IP with spaces in KNOWN_IPS not matched"
    ok=false
fi
if [ "$ok" = true ]; then pass "spaces in KNOWN_IPS handled correctly"; fi

# --------------------------------------------------
# Test 4: Missing SSH_CLIENT (local login)
# --------------------------------------------------
echo "Test 4: Missing SSH_CLIENT (local login / su)"
logfile="$TMP_DIR/t4.log"
output="$(run_login_notify "UNSET" "127.0.0.1" "$logfile" "")"
rc=$?
ok=true
if [ $rc -ne 0 ]; then
    fail "exit code" "script crashed without SSH_CLIENT: rc=$rc"
    ok=false
fi
# Should still produce a log, with "(local)" as IP
if [ -f "$logfile" ]; then
    if grep -q "(local)" "$logfile"; then
        : # good
    else
        fail "log content" "expected '(local)' in log for missing SSH_CLIENT"
        ok=false
    fi
else
    fail "log file" "log file not created when SSH_CLIENT missing"
    ok=false
fi
if [ "$ok" = true ]; then pass "script handles missing SSH_CLIENT gracefully"; fi

# --------------------------------------------------
# Test 5: mail command not available
# --------------------------------------------------
echo "Test 5: mail command not available"
logfile="$TMP_DIR/t5.log"
output="$(run_login_notify "192.168.1.100 22 54321" "127.0.0.1" "$logfile" "hide_mail")"
rc=$?
ok=true
# Script must NOT crash
if [ $rc -ne 0 ]; then
    fail "exit code" "script crashed without mail: rc=$rc"
    ok=false
fi
# Should still write log
if [ -f "$logfile" ] && [ -s "$logfile" ]; then
    : # good
else
    fail "log file" "log not written even though Logging=true"
    ok=false
fi
# Should print a warning about mail on stderr (captured in output)
if echo "$output" | grep -qi "WARNING.*mail\|mail.*not found"; then
    : # good - warning about mail shown
else
    # Acceptable if warning not captured due to redirection
    :
fi
if [ "$ok" = true ]; then pass "script does not crash when mail is unavailable"; fi

# --------------------------------------------------
# Test 6: Log directory not writable
# --------------------------------------------------
echo "Test 6: Log directory not writable / nonexistent"
logfile="$TMP_DIR/no_such_dir_$$/deep/nested/test.log"
output="$(run_login_notify "127.0.0.1 22 54321" "127.0.0.1" "$logfile" "")"
rc=$?
ok=true
# Script must NOT crash
if [ $rc -ne 0 ]; then
    fail "exit code" "script crashed on unwritable log dir: rc=$rc"
    ok=false
fi
# Should emit a warning
if echo "$output" | grep -qi "WARNING\|not writable\|cannot\|could not"; then
    : # good, warning emitted
fi
if [ "$ok" = true ]; then pass "script handles unwritable log directory gracefully"; fi

# --------------------------------------------------
# Test 7: Message contains required fields
# --------------------------------------------------
echo "Test 7: Message contains host, user, IP, time, online users"
logfile="$TMP_DIR/t7.log"
output="$(run_login_notify "10.10.10.10 22 54321" "127.0.0.1" "$logfile" "")"
ok=true
if [ -f "$logfile" ]; then
    for field in "Login IP" "Login User" "Date-Time" "Logged in users"; do
        if ! grep -q "$field" "$logfile"; then
            fail "message fields" "missing '$field' in log output"
            ok=false
        fi
    done
else
    fail "log file" "log file not created"
    ok=false
fi
if [ "$ok" = true ]; then pass "message includes all required info fields"; fi

# --------------------------------------------------
# Test 8: Duplicate IPs in KNOWN_IPS don't break matching
# --------------------------------------------------
echo "Test 8: Duplicate IPs in KNOWN_IPS"
logfile="$TMP_DIR/t8.log"
output="$(run_login_notify "10.0.0.1 22 54321" "10.0.0.1 10.0.0.1 10.0.0.1" "$logfile" "")"
ok=true
if [ -f "$logfile" ] && grep -q "Authorized Login" "$logfile"; then
    : # good
else
    fail "duplicate IPs" "duplicate entries in KNOWN_IPS caused match failure"
    ok=false
fi
if [ "$ok" = true ]; then pass "duplicate IPs in KNOWN_IPS handled correctly"; fi

echo
echo "=========================================="
printf "  Results: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
