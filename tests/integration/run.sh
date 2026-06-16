#!/bin/bash
# Integration tests for diffbandit.nvim using tmux
# Usage: ./run.sh [test_name]
#   test_name: 'extreme', 'pure', 'deletions', 'mixed', 'comprehensive',
#              'scroll-additions', 'scroll-deletions', 'scroll-mixed',
#              'scroll-changes', or 'all' (default: stable non-scroll suite)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMUX_SESSION="diffbandit_test_$$"
CAPTURE_ROOT="/tmp/diffbandit_visual"

# Cleanup function
cleanup() {
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}
trap cleanup EXIT

# Function to run a single test
run_test() {
    local test_name="$1"
    local left_file="$2"
    local right_file="$3"
    local case_dir="$CAPTURE_ROOT/$test_name"
    local plain_capture="$case_dir/capture.txt"
    local ansi_capture="$case_dir/capture.ansi"

    echo "Running integration test: $test_name"
    mkdir -p "$case_dir"

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

    # Capture both plain text and ANSI-coded output for visual/color checks.
    tmux capture-pane -t "$TMUX_SESSION" -p > "$plain_capture"
    tmux capture-pane -t "$TMUX_SESSION" -e -p > "$ansi_capture"

    # Kill the session before verification
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    # Verify the capture
    lua "$SCRIPT_DIR/verify.lua" "$plain_capture" "$test_name" "$ansi_capture"

    echo "  PASSED: $test_name"
    echo "  Captures: $case_dir"
}

run_scroll_test() {
    local test_name="$1"
    local left_file="$2"
    local right_file="$3"
    local case_dir="$CAPTURE_ROOT/$test_name"

    echo "Running integration test: $test_name"
    mkdir -p "$case_dir"

    start_phase_session() {
        tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
        tmux new-session -d -s "$TMUX_SESSION" -x 120 -y 14
        tmux send-keys -t "$TMUX_SESSION" "nvim -u '$SCRIPT_DIR/init.lua'" Enter
        sleep 1
        tmux send-keys -t "$TMUX_SESSION" ":DiffBandit $left_file $right_file" Enter
        sleep 2
    }

    capture_scroll_phase() {
        local phase="$1"
        local left_top="$2"
        local right_top="$3"
        local plain_capture="$case_dir/${phase}.txt"
        local ansi_capture="$case_dir/${phase}.ansi"

        echo "  phase: $phase ($left_top,$right_top)"
        start_phase_session
        tmux send-keys -t "$TMUX_SESSION" Escape
        sleep 0.2
        tmux send-keys -t "$TMUX_SESSION" ":DBViewport $left_top $right_top" C-m
        sleep 1

        tmux capture-pane -t "$TMUX_SESSION" -p > "$plain_capture"
        tmux capture-pane -t "$TMUX_SESSION" -e -p > "$ansi_capture"
        tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
        lua "$SCRIPT_DIR/verify.lua" "$plain_capture" "$test_name:$phase" "$ansi_capture"
    }

    case "$test_name" in
        scroll-additions)
            capture_scroll_phase "initial" 1 1
            capture_scroll_phase "target-above" 1 58
            capture_scroll_phase "target-aligned" 1 2
            capture_scroll_phase "target-flipped" 1 3
            capture_scroll_phase "target-spanning" 1 4
            capture_scroll_phase "lower-target-below" 1 45
            capture_scroll_phase "lower-target-approach" 1 50
            capture_scroll_phase "same-row-upper" 1 51
            capture_scroll_phase "upper-target-exiting" 1 52
            capture_scroll_phase "lower-target-entering" 1 53
            capture_scroll_phase "pre-overlap-inner" 1 54
            capture_scroll_phase "lower-target-anchor" 1 55
            capture_scroll_phase "pre-collision-inner" 1 59
            capture_scroll_phase "upper-target-clipped" 1 60
            capture_scroll_phase "overlap-stepped" 1 61
            capture_scroll_phase "hidden-overlap-inner" 1 64
            capture_scroll_phase "origin-offscreen" 10 25
            capture_scroll_phase "clamped-end" 13 69
            capture_scroll_phase "overscroll-end" 20 76
            ;;
        scroll-deletions)
            capture_scroll_phase "initial" 1 1
            capture_scroll_phase "target-above" 58 1
            capture_scroll_phase "target-spanning" 4 1
            capture_scroll_phase "origin-offscreen" 25 10
            capture_scroll_phase "clamped-end" 69 13
            ;;
        scroll-mixed)
            capture_scroll_phase "initial" 1 1
            capture_scroll_phase "right-diverged" 1 22
            capture_scroll_phase "left-diverged" 7 1
            capture_scroll_phase "origin-offscreen" 12 25
            capture_scroll_phase "clamped-end" 13 56
            ;;
        scroll-changes)
            capture_scroll_phase "initial" 1 1
            capture_scroll_phase "right-diverged" 1 5
            capture_scroll_phase "left-diverged" 5 1
            capture_scroll_phase "both-diverged" 4 6
            capture_scroll_phase "clamped-end" 20 20
            ;;
    esac

    capture_key_scroll_phase() {
        local phase="$1"
        local side="$2"
        local count="$3"
        local plain_capture="$case_dir/${phase}.txt"
        local ansi_capture="$case_dir/${phase}.ansi"

        echo "  phase: $phase ($side j x$count)"
        start_phase_session
        tmux send-keys -t "$TMUX_SESSION" Escape
        sleep 0.2
        tmux send-keys -t "$TMUX_SESSION" ":DBViewport 1 1" C-m
        sleep 0.2
        tmux send-keys -t "$TMUX_SESSION" ":DBFocus $side" C-m
        sleep 1

        for _ in $(seq 1 "$count"); do
            tmux send-keys -t "$TMUX_SESSION" j
        done
        sleep 1

        tmux capture-pane -t "$TMUX_SESSION" -p > "$plain_capture"
        tmux capture-pane -t "$TMUX_SESSION" -e -p > "$ansi_capture"
        tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
        lua "$SCRIPT_DIR/verify.lua" "$plain_capture" "$test_name:$phase" "$ansi_capture"
    }

    case "$test_name" in
        scroll-additions)
            capture_key_scroll_phase "right-j-scroll" "right" 25
            capture_key_scroll_phase "right-j-scroll-line39" "right" 38
            capture_key_scroll_phase "right-j-scroll-line41" "right" 40
            ;;
        scroll-deletions)
            capture_key_scroll_phase "left-j-scroll" "left" 25
            ;;
        scroll-mixed)
            capture_key_scroll_phase "right-j-scroll" "right" 25
            capture_key_scroll_phase "left-j-scroll" "left" 8
            ;;
        scroll-changes)
            capture_key_scroll_phase "right-j-scroll" "right" 12
            capture_key_scroll_phase "left-j-scroll" "left" 12
            ;;
    esac

    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    echo "  PASSED: $test_name"
    echo "  Captures: $case_dir"
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
    deletions)
        run_test "deletions" \
            "$PROJECT_ROOT/tests/files/left_deletions.txt" \
            "$PROJECT_ROOT/tests/files/right_deletions.txt"
        ;;
    mixed)
        run_test "mixed" \
            "$PROJECT_ROOT/tests/files/left_mixed.txt" \
            "$PROJECT_ROOT/tests/files/right_mixed.txt"
        ;;
    comprehensive)
        run_test "comprehensive" \
            "$PROJECT_ROOT/tests/files/left_comprehensive.txt" \
            "$PROJECT_ROOT/tests/files/right_comprehensive.txt"
        ;;
    scroll-additions)
        run_scroll_test "scroll-additions" \
            "$PROJECT_ROOT/tests/files/left_scroll_additions.txt" \
            "$PROJECT_ROOT/tests/files/right_scroll_additions.txt"
        ;;
    scroll-deletions)
        run_scroll_test "scroll-deletions" \
            "$PROJECT_ROOT/tests/files/left_scroll_deletions.txt" \
            "$PROJECT_ROOT/tests/files/right_scroll_deletions.txt"
        ;;
    scroll-mixed)
        run_scroll_test "scroll-mixed" \
            "$PROJECT_ROOT/tests/files/left_scroll_mixed.txt" \
            "$PROJECT_ROOT/tests/files/right_scroll_mixed.txt"
        ;;
    scroll-changes)
        run_scroll_test "scroll-changes" \
            "$PROJECT_ROOT/tests/files/left_scroll_changes.txt" \
            "$PROJECT_ROOT/tests/files/right_scroll_changes.txt"
        ;;
    all)
        run_test "extreme" \
            "$PROJECT_ROOT/tests/files/left_extreme.txt" \
            "$PROJECT_ROOT/tests/files/right_extreme.txt"

        run_test "pure" \
            "$PROJECT_ROOT/tests/files/left_additions.txt" \
            "$PROJECT_ROOT/tests/files/right_additions.txt"

        run_test "deletions" \
            "$PROJECT_ROOT/tests/files/left_deletions.txt" \
            "$PROJECT_ROOT/tests/files/right_deletions.txt"

        run_test "mixed" \
            "$PROJECT_ROOT/tests/files/left_mixed.txt" \
            "$PROJECT_ROOT/tests/files/right_mixed.txt"

        run_test "comprehensive" \
            "$PROJECT_ROOT/tests/files/left_comprehensive.txt" \
            "$PROJECT_ROOT/tests/files/right_comprehensive.txt"

        ;;
    *)
        echo "Unknown test: $TEST_TO_RUN"
        echo "Usage: $0 [extreme|pure|deletions|mixed|comprehensive|scroll-additions|scroll-deletions|scroll-mixed|scroll-changes|all]"
        exit 1
        ;;
esac

echo ""
echo "All integration tests passed!"
