#!/bin/bash
# Test script to validate macOS poll() false POLLIN issue

set -e

echo "=== Building zmx with diagnostic logging ==="
zig build

UNAME=$(uname -s)
if [ "$UNAME" != "Darwin" ]; then
    echo "ERROR: This test must be run on macOS"
    exit 1
fi

echo ""
echo "=== Creating test session ==="
SESSION_NAME="zmx_poll_test_$$"
ZMX="./zig-out/bin/zmx"

echo "Starting zmx session: $SESSION_NAME"
$ZMX attach "$SESSION_NAME" bash -c 'echo "Session started"; sleep 2; echo "Ready for testing"' &
DAEMON_PID=$!

sleep 1

# Get daemon PID
DAEMON_PROCESS_PID=$($ZMX list --short | head -1)
if [ -z "$DAEMON_PROCESS_PID" ]; then
    echo "ERROR: Could not get daemon PID"
    exit 1
fi

echo "Session daemon running with PID (from zmx list): $DAEMON_PROCESS_PID"

echo ""
echo "=== Checking logs for diagnostic messages ==="
LOG_FILE="${HOME}/.local/zmx-${DAEMON_PROCESS_PID}/logs/${SESSION_NAME}.log"
if [ ! -f "$LOG_FILE" ]; then
    LOG_FILE="/tmp/zmx-${UID}/logs/${SESSION_NAME}.log"
fi

if [ ! -f "$LOG_FILE" ]; then
    echo "ERROR: Log file not found at $LOG_FILE"
    $ZMX list
    exit 1
fi

echo "Log file: $LOG_FILE"

echo ""
echo "=== Running heavy I/O test ==="
echo "Sending large amount of data to trigger scrolling-like behavior..."

# Send command that generates lots of output
$ZMX run "$SESSION_NAME" cat << 'EOF' > /tmp/zmx_test_output.txt
for i in {1..100}; do 
  echo "Line $i: Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore."
done
EOF

sleep 1

echo ""
echo "=== Checking for WouldBlock diagnostics ==="
if grep -i "poll reported POLLIN but read got WouldBlock" "$LOG_FILE" 2>/dev/null | head -5; then
    echo ""
    echo "✓ FOUND FALSE POLLIN CONDITION!"
    echo "  This confirms the macOS poll() false readiness issue."
    COUNT=$(grep -c "poll reported POLLIN but read got WouldBlock" "$LOG_FILE")
    echo "  Occurrences: $COUNT"
    
    if [ "$COUNT" -gt 10 ]; then
        echo "  ⚠️  High frequency of false POLLIN - likely spin-loop condition"
    fi
else
    echo "✗ No WouldBlock diagnostics found"
    echo "  Either issue is not present or logs aren't being written"
fi

echo ""
echo "=== Checking overall log for macOS diagnostic ==="
if grep -i "macOS detected" "$LOG_FILE" 2>/dev/null; then
    echo "✓ macOS-specific code path is being used"
else
    echo "? macOS diagnostic not found in log"
fi

echo ""
echo "=== Cleanup ==="
$ZMX kill "$SESSION_NAME" 2>/dev/null || true
wait $DAEMON_PID 2>/dev/null || true

echo "Test complete. Full log available at: $LOG_FILE"
