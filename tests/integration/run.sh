#!/bin/bash
# Integration tests for diffbandit.nvim using tmux
# Usage: ./run.sh [test_name]
#   test_name: 'extreme', 'pure', or 'all' (default: all)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMUX_SESSION="diffbandit_test_$$"
CAPTURE_FILE="/tmp/diffbandit_capture_$$.txt"

# Cleanup function
cleanup() {
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    rm -f "$CAPTURE_FILE"
}
trap cleanup EXIT

# Function to run a single test
run_test() {
    local test_name="$1"
    local left_file="$2"
    local right_file="$3"

    echo "Running integration test: $test_name"

    # Create tmux session with fixed dimensions
    tmux new-session -d -s "$TMUX_SESSION" -x 120 -y 40

    # Start neovim with minimal config
    tmux send-keys -t "$TMUX_SESSION" "nvim -u '$SCRIPT_DIR/init.lua'" Enter

    # Wait for nvim to start
    sleep 1

    # Run DiffBandit command after nvim is fully initialized
    tmux send-keys -t "$TMUX_SESSION" ":DiffBandit $left_file $right_file" Enter

    # Wait for render
    sleep 2

    # Capture the pane with ANSI codes
    tmux capture-pane -t "$TMUX_SESSION" -e -p > "$CAPTURE_FILE"

    # Kill the session before verification
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    # Verify the capture
    lua "$SCRIPT_DIR/verify.lua" "$CAPTURE_FILE" "$test_name"

    echo "  PASSED: $test_name"
}

# Parse arguments
TEST_TO_RUN="${1:-all}"

case "$TEST_TO_RUN" in
    extreme)
        run_test "extreme" \
            "$PROJECT_ROOT/tests/files/left_extreme.txt" \
            "$PROJECT_ROOT/tests/files/right_extreme.txt"
        ;;
    pure)
        run_test "pure" \
            "$PROJECT_ROOT/tests/files/left_additions.txt" \
            "$PROJECT_ROOT/tests/files/right_additions.txt"
        ;;
    all)
        run_test "extreme" \
            "$PROJECT_ROOT/tests/files/left_extreme.txt" \
            "$PROJECT_ROOT/tests/files/right_extreme.txt"

        run_test "pure" \
            "$PROJECT_ROOT/tests/files/left_additions.txt" \
            "$PROJECT_ROOT/tests/files/right_additions.txt"
        ;;
    *)
        echo "Unknown test: $TEST_TO_RUN"
        echo "Usage: $0 [extreme|pure|all]"
        exit 1
        ;;
esac

echo ""
echo "All integration tests passed!"
