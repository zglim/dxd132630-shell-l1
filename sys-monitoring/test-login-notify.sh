#!/bin/bash
##################################################
# Test suite for login-notify
##################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/login-notify"
TMPDIR_BASE=$(mktemp -d)
PASS=0
FAIL=0

cleanup() {
    rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

# ---- helpers ------------------------------------------------

setup_mocks() {
    local mock_dir="$TMPDIR_BASE/mocks"
    mkdir -p "$mock_dir"

    # mock hostname
    cat > "$mock_dir/hostname" <<'MOCK'
#!/bin/bash
echo "testhost"
MOCK
    chmod +x "$mock_dir/hostname"

    # mock whoami
    cat > "$mock_dir/whoami" <<'MOCK'
#!/bin/bash
echo "testuser"
MOCK
    chmod +x "$mock_dir/whoami"

    # mock date
    cat > "$mock_dir/date" <<'MOCK'
#!/bin/bash
echo "Mon Jan 1 00:00:00 UTC 2024"
MOCK
    chmod +x "$mock_dir/date"

    # mock w
    cat > "$mock_dir/w" <<'MOCK'
#!/bin/bash
echo "testuser  pts/0  10.0.0.1  00:00  0.00s  bash"
MOCK
    chmod +x "$mock_dir/w"

    echo "$mock_dir"
}

# Create a mock mail that records calls
setup_mail_mock() {
    local mock_dir="$1"
    local mail_log="$2"
    cat > "$mock_dir/mail" <<MOCK
#!/bin/bash
cat > "$mail_log"
echo "ARGS: \$@" >> "$mail_log.args"
MOCK
    chmod +x "$mock_dir/mail"
}

# Create a mock mail that always fails
setup_mail_mock_fail() {
    local mock_dir="$1"
    cat > "$mock_dir/mail" <<'MOCK'
#!/bin/bash
exit 1
MOCK
    chmod +x "$mock_dir/mail"
}

# Remove mail from mocks so command -v mail fails
remove_mail_mock() {
    local mock_dir="$1"
    rm -f "$mock_dir/mail"
}

run_script() {
    # $1 = mock_dir, rest = env overrides passed before the script
    local mock_dir="$1"
    shift
    # Run with restricted PATH so only mocks + essentials are found
    env -i \
        PATH="$mock_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME="$HOME" \
        TERM="${TERM:-dumb}" \
        "$@" \
        bash "$SCRIPT"
}

assert_contains() {
    local label="$1" file="$2" pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo "  PASS: $label"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $label  (pattern '$pattern' not found in $file)"
        [ -f "$file" ] && echo "    --- file contents ---" && cat "$file" && echo "    ---"
    fi
}

assert_not_contains() {
    local label="$1" file="$2" pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
        echo "  PASS: $label"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $label  (pattern '$pattern' unexpectedly found in $file)"
    fi
}

assert_file_exists() {
    local label="$1" file="$2"
    if [ -f "$file" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $label"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $label  (file '$file' does not exist)"
    fi
}

assert_file_not_exists() {
    local label="$1" file="$2"
    if [ ! -f "$file" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $label"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $label  (file '$file' should not exist)"
    fi
}

assert_exit_zero() {
    local label="$1" code="$2"
    if [ "$code" -eq 0 ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $label"
    else
        FAIL=$((FAIL + 1))
        echo "  FAIL: $label  (exit code $code, expected 0)"
    fi
}

# ---- tests --------------------------------------------------

echo "=== Test 1: Authorized (whitelist) login ==="
(
    td="$TMPDIR_BASE/t1"
    mkdir -p "$td"
    mock_dir=$(setup_mocks)
    mail_log="$td/mail.log"
    setup_mail_mock "$mock_dir" "$mail_log"
    log_file="$td/login.log"

    # Run with an IP that IS in the whitelist
    run_script "$mock_dir" \
        SSH_CLIENT="127.0.0.1 12345 22" \
        KNOWN_IPS="127.0.0.1" \
        LOG_FILE="$log_file" \
        Logging="true" \
        EMAIL="test@example.com" \
        ; rc=$?

    assert_exit_zero "script exits 0" "$rc"
    assert_file_exists "log file created" "$log_file"
    assert_contains "log says Authorized" "$log_file" "Authorized Login"
    assert_contains "log has login IP" "$log_file" "127.0.0.1"
    assert_contains "log has hostname" "$log_file" "testhost"
    assert_contains "log has user" "$log_file" "testuser"
    # mail should NOT have been sent for authorized login
    assert_file_not_exists "no mail sent for authorized login" "$mail_log.args"
)

echo ""
echo "=== Test 2: Unauthorized (non-whitelist) login ==="
(
    td="$TMPDIR_BASE/t2"
    mkdir -p "$td"
    mock_dir=$(setup_mocks)
    mail_log="$td/mail.log"
    setup_mail_mock "$mock_dir" "$mail_log"
    log_file="$td/login.log"

    # Run with an IP that is NOT in the whitelist
    run_script "$mock_dir" \
        SSH_CLIENT="192.168.1.100 54321 22" \
        KNOWN_IPS="127.0.0.1 10.0.0.1" \
        LOG_FILE="$log_file" \
        Logging="true" \
        EMAIL="test@example.com" \
        ; rc=$?

    assert_exit_zero "script exits 0" "$rc"
    assert_file_exists "log file created" "$log_file"
    assert_contains "log says Unauthorized" "$log_file" "Unauthorized Login"
    assert_contains "log has login IP" "$log_file" "192.168.1.100"
    # mail SHOULD have been sent
    assert_file_exists "mail was sent" "$mail_log.args"
    assert_contains "mail args include subject" "$mail_log.args" "Root Login Alert"
)

echo ""
echo "=== Test 3: Missing SSH_CLIENT (local login) ==="
(
    td="$TMPDIR_BASE/t3"
    mkdir -p "$td"
    mock_dir=$(setup_mocks)
    mail_log="$td/mail.log"
    setup_mail_mock "$mock_dir" "$mail_log"
    log_file="$td/login.log"

    # Run with NO SSH_CLIENT or SSH_CONNECTION set
    run_script "$mock_dir" \
        KNOWN_IPS="127.0.0.1" \
        LOG_FILE="$log_file" \
        Logging="true" \
        EMAIL="test@example.com" \
        ; rc=$?

    assert_exit_zero "script exits 0 without SSH_CLIENT" "$rc"
    assert_file_exists "log file created" "$log_file"
    assert_contains "loginip shows local" "$log_file" "Login IP : local"
)

echo ""
echo "=== Test 4: mail command not available ==="
(
    td="$TMPDIR_BASE/t4"
    mkdir -p "$td"
    mock_dir=$(setup_mocks)
    log_file="$td/login.log"

    # Remove mail mock so command -v mail fails
    remove_mail_mock "$mock_dir"

    # Unauthorized login, but no mail command
    run_script "$mock_dir" \
        SSH_CLIENT="192.168.1.100 54321 22" \
        KNOWN_IPS="127.0.0.1" \
        LOG_FILE="$log_file" \
        Logging="true" \
        EMAIL="test@example.com" \
        ; rc=$?

    assert_exit_zero "script exits 0 even without mail" "$rc"
    assert_file_exists "log still written" "$log_file"
    assert_contains "log says Unauthorized" "$log_file" "Unauthorized Login"
)

echo ""
echo "=== Test 5: Log write failure (unwritable directory) ==="
(
    td="$TMPDIR_BASE/t5"
    mkdir -p "$td"
    mock_dir=$(setup_mocks)
    mail_log="$td/mail.log"
    setup_mail_mock "$mock_dir" "$mail_log"

    # Point log to a non-existent/unwritable path
    log_file="/no/such/directory/login.log"

    run_script "$mock_dir" \
        SSH_CLIENT="192.168.1.100 54321 22" \
        KNOWN_IPS="127.0.0.1" \
        LOG_FILE="$log_file" \
        Logging="true" \
        EMAIL="test@example.com" \
        ; rc=$?

    assert_exit_zero "script exits 0 even with unwritable log" "$rc"
    # mail should still be sent
    assert_file_exists "mail still sent despite log failure" "$mail_log.args"
)

echo ""
echo "=== Test 6: Multiple whitelist IPs with spaces ==="
(
    td="$TMPDIR_BASE/t6"
    mkdir -p "$td"
    mock_dir=$(setup_mocks)
    mail_log="$td/mail.log"
    setup_mail_mock "$mock_dir" "$mail_log"
    log_file="$td/login.log"

    # KNOWN_IPS with extra spaces and the matching IP in the middle
    run_script "$mock_dir" \
        SSH_CLIENT="10.0.0.5 12345 22" \
        KNOWN_IPS="  127.0.0.1   10.0.0.5   192.168.0.1  " \
        LOG_FILE="$log_file" \
        Logging="true" \
        EMAIL="test@example.com" \
        ; rc=$?

    assert_exit_zero "script exits 0" "$rc"
    assert_contains "log says Authorized" "$log_file" "Authorized Login"
    assert_file_not_exists "no mail for whitelisted IP in multi-list" "$mail_log.args"
)

echo ""
echo "=== Test 7: mail command fails (non-zero exit) ==="
(
    td="$TMPDIR_BASE/t7"
    mkdir -p "$td"
    mock_dir=$(setup_mocks)
    log_file="$td/login.log"

    # mail mock that always fails
    setup_mail_mock_fail "$mock_dir"

    run_script "$mock_dir" \
        SSH_CLIENT="192.168.1.100 54321 22" \
        KNOWN_IPS="127.0.0.1" \
        LOG_FILE="$log_file" \
        Logging="true" \
        EMAIL="test@example.com" \
        ; rc=$?

    assert_exit_zero "script exits 0 even when mail returns error" "$rc"
    assert_file_exists "log still written" "$log_file"
)

# ---- summary ------------------------------------------------
echo ""
echo "========================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
