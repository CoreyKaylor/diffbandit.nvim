#!/bin/bash
# Integration tests for diffbandit.nvim using tmux
# Usage: ./run.sh [test_name]
#   test_name: 'extreme', 'pure', 'deletions', 'mixed', 'dense-mixed',
#              'theme-default', 'comprehensive', 'listchars',
#              'navigation', 'git', 'git-merge', 'git-scroll-perf',
#              'scroll-additions', 'scroll-deletions', 'scroll-mixed', 'scroll-dense-mixed',
#              'scroll-changes', or 'all' (default: stable non-scroll suite)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMUX_SESSION="diffbandit_test_$$"
CAPTURE_ROOT="/tmp/diffbandit_visual"
TEST_TERM="screen-256color"
TEST_COLORTERM="truecolor"

# Cleanup function
cleanup() {
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}
trap cleanup EXIT

start_test_nvim() {
    local command="$1"
    tmux send-keys -t "$TMUX_SESSION" "TERM=$TEST_TERM COLORTERM=$TEST_COLORTERM $command" Enter
}

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
    tmux new-session -d -s "$TMUX_SESSION" -x 120 -y 48

    # Start neovim with minimal config
    start_test_nvim "nvim -u '$SCRIPT_DIR/init.lua'"

    # Wait for nvim to start
    sleep 1

    # Run DiffBandit command after nvim is fully initialized
    tmux send-keys -t "$TMUX_SESSION" ":DiffBandit $left_file $right_file" C-m

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
        start_test_nvim "nvim -u '$SCRIPT_DIR/init.lua'"
        sleep 1
        tmux send-keys -t "$TMUX_SESSION" ":DiffBandit $left_file $right_file" C-m
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

    capture_tall_scroll_phase() {
        local phase="$1"
        local left_top="$2"
        local right_top="$3"
        local plain_capture="$case_dir/${phase}.txt"
        local ansi_capture="$case_dir/${phase}.ansi"

        echo "  phase: $phase ($left_top,$right_top tall)"
        tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
        tmux new-session -d -s "$TMUX_SESSION" -x 120 -y 40
        start_test_nvim "nvim -u '$SCRIPT_DIR/init.lua'"
        sleep 1
        tmux send-keys -t "$TMUX_SESSION" ":DiffBandit $left_file $right_file" C-m
        sleep 2
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
            capture_scroll_phase "target-aligned" 2 1
            capture_scroll_phase "target-flipped" 3 1
            capture_scroll_phase "target-spanning" 4 1
            capture_scroll_phase "lower-target-below" 50 1
            capture_scroll_phase "lower-target-approach" 52 1
            capture_scroll_phase "same-row-upper" 53 1
            capture_scroll_phase "upper-target-exiting" 54 1
            capture_scroll_phase "lower-target-entering" 55 1
            capture_scroll_phase "pre-overlap-inner" 56 1
            capture_scroll_phase "pre-collision-inner" 57 1
            capture_scroll_phase "target-above" 58 1
            capture_scroll_phase "upper-target-clipped" 59 1
            capture_scroll_phase "overlap-stepped" 60 1
            capture_scroll_phase "hidden-overlap-inner" 63 1
            capture_scroll_phase "origin-offscreen" 25 10
            capture_scroll_phase "clamped-end" 69 13
            ;;
        scroll-mixed)
            capture_scroll_phase "initial" 1 1
            capture_scroll_phase "right-overlap-first" 1 2
            capture_scroll_phase "right-overlap-exit" 1 3
            capture_scroll_phase "right-overlap-past" 1 4
            capture_scroll_phase "right-overlap-clipped" 1 5
            capture_scroll_phase "right-overlap-middle" 1 10
            capture_scroll_phase "right-tail-approach" 1 47
            capture_scroll_phase "right-tail-aligned" 1 49
            capture_scroll_phase "right-diverged" 1 22
            capture_scroll_phase "left-diverged" 7 1
            capture_scroll_phase "origin-offscreen" 12 25
            capture_scroll_phase "clamped-end" 13 56
            ;;
        scroll-dense-mixed)
            capture_scroll_phase "initial" 1 1
            capture_scroll_phase "top-route-separation" 1 4
            capture_scroll_phase "pre-conflict" 1 38
            capture_scroll_phase "lower-route-separation" 1 42
            capture_scroll_phase "lower-route-entering" 1 43
            capture_scroll_phase "four-lane-conflict" 1 46
            capture_scroll_phase "post-conflict" 1 53
            capture_scroll_phase "lane-reuse" 8 46
            capture_tall_scroll_phase "initial-tall" 1 1
            capture_tall_scroll_phase "top-route-separation-tall" 1 4
            capture_tall_scroll_phase "lower-route-separation-tall" 1 42
            capture_tall_scroll_phase "lower-route-entering-tall" 1 43
            capture_tall_scroll_phase "lower-four-lane-tall" 1 46
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
            capture_key_scroll_phase "left-j-scroll-line39" "left" 38
            capture_key_scroll_phase "left-j-scroll-line41" "left" 40
            ;;
        scroll-mixed)
            capture_key_scroll_phase "right-j-scroll" "right" 25
            capture_key_scroll_phase "left-j-scroll" "left" 8
            ;;
        scroll-dense-mixed)
            capture_key_scroll_phase "right-j-scroll" "right" 45
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

run_listchars_test() {
    local test_name="listchars"
    local case_dir="$CAPTURE_ROOT/$test_name"
    local left_file="$case_dir/left.txt"
    local right_file="$case_dir/right.txt"
    local plain_capture="$case_dir/capture.txt"

    echo "Running integration test: $test_name"
    rm -rf "$case_dir"
    mkdir -p "$case_dir"
    printf "same  \nleft\n" > "$left_file"
    printf "same  \nright\n" > "$right_file"

    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    tmux new-session -d -s "$TMUX_SESSION" -x 120 -y 24
    start_test_nvim "nvim -u '$SCRIPT_DIR/init.lua'"
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":set list listchars=trail:·" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":DiffBandit $left_file $right_file" C-m
    sleep 2
    tmux capture-pane -t "$TMUX_SESSION" -p > "$plain_capture"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    if ! grep -q "same··" "$plain_capture"; then
        echo "Listchars test failed: source panes did not retain trailing-space markers"
        cat "$plain_capture"
        exit 1
    fi
    if grep -q "····" "$plain_capture"; then
        echo "Listchars test failed: connector or gutter panes rendered trailing-space markers"
        cat "$plain_capture"
        exit 1
    fi

    echo "  PASSED: $test_name"
    echo "  Captures: $case_dir"
}

run_navigation_test() {
    local test_name="navigation"
    local left_file="$PROJECT_ROOT/tests/files/left_navigation.txt"
    local right_file="$PROJECT_ROOT/tests/files/right_navigation.txt"
    local case_dir="$CAPTURE_ROOT/$test_name"
    local initial_state="$case_dir/initial.state"
    local next_state="$case_dir/after-next.state"
    local final_state="$case_dir/after-final.state"
    local prev_delete_state="$case_dir/after-prev-delete.state"
    local prev_add_state="$case_dir/after-prev-add.state"
    local prev_change_state="$case_dir/after-prev-change.state"
    local top_state="$case_dir/after-doc-top.state"
    local top_next_state="$case_dir/after-doc-top-next.state"
    local bottom_state="$case_dir/after-doc-bottom.state"
    local bottom_prev_state="$case_dir/after-doc-bottom-prev.state"

    echo "Running integration test: $test_name"
    mkdir -p "$case_dir"

    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    tmux new-session -d -s "$TMUX_SESSION" -x 120 -y 8
    start_test_nvim "nvim -u '$SCRIPT_DIR/init.lua'"
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DiffBandit $left_file $right_file" C-m
    sleep 2

    tmux send-keys -t "$TMUX_SESSION" ":DBWriteState $initial_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteState $next_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteState $final_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "[" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteState $prev_delete_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "[" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteState $prev_add_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "[" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteState $prev_change_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":DBViewport 5 7" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "[" "d"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteState $top_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteState $top_next_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "]" "d"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteState $bottom_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "[" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteState $bottom_prev_state" C-m
    sleep 0.2
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    local initial
    local next
    local final
    local prev_delete
    local prev_add
    local prev_change
    local doc_top
    local doc_top_next
    local doc_bottom
    local doc_bottom_prev
    initial="$(cat "$initial_state")"
    next="$(cat "$next_state")"
    final="$(cat "$final_state")"
    prev_delete="$(cat "$prev_delete_state")"
    prev_add="$(cat "$prev_add_state")"
    prev_change="$(cat "$prev_change_state")"
    doc_top="$(cat "$top_state")"
    doc_top_next="$(cat "$top_next_state")"
    doc_bottom="$(cat "$bottom_state")"
    doc_bottom_prev="$(cat "$bottom_prev_state")"

    if [[ "$initial" != *"focus=right"* || "$initial" != *"left_top=1"* || "$initial" != *"right_top=1"* || "$initial" != *"chunk=1"* ]]; then
        echo "Navigation initial state failed: $initial"
        exit 1
    fi
    if [[ "$next" != *"focus=right"* || "$next" != *"left_top=6"* || "$next" != *"right_top=6"* || "$next" != *"left_cursor=6"* || "$next" != *"right_cursor=7"* || "$next" != *"chunk=2"* ]]; then
        echo "Navigation next-change state failed: $next"
        exit 1
    fi
    if [[ "$final" != *"focus=right"* || "$final" != *"left_top=12"* || "$final" != *"right_top=12"* || "$final" != *"chunk=4"* ]]; then
        echo "Navigation final-change state failed: $final"
        exit 1
    fi
    if [[ "$prev_delete" != *"focus=right"* || "$prev_delete" != *"left_top=9"* || "$prev_delete" != *"right_top=9"* || "$prev_delete" != *"left_cursor=9"* || "$prev_delete" != *"right_cursor=9"* || "$prev_delete" != *"chunk=3"* ]]; then
        echo "Navigation prev-delete state failed: $prev_delete"
        exit 1
    fi
    if [[ "$prev_add" != *"focus=right"* || "$prev_add" != *"left_top=6"* || "$prev_add" != *"right_top=6"* || "$prev_add" != *"left_cursor=6"* || "$prev_add" != *"right_cursor=7"* || "$prev_add" != *"chunk=2"* ]]; then
        echo "Navigation prev-add state failed: $prev_add"
        exit 1
    fi
    if [[ "$prev_change" != *"focus=right"* || "$prev_change" != *"left_top=3"* || "$prev_change" != *"right_top=3"* || "$prev_change" != *"left_cursor=3"* || "$prev_change" != *"right_cursor=3"* || "$prev_change" != *"chunk=1"* ]]; then
        echo "Navigation prev-change state failed: $prev_change"
        exit 1
    fi
    if [[ "$doc_top" != *"focus=right"* || "$doc_top" != *"left_top=1"* || "$doc_top" != *"right_top=1"* || "$doc_top" != *"left_cursor=1"* || "$doc_top" != *"right_cursor=1"* || "$doc_top" != *"chunk=0"* ]]; then
        echo "Navigation document-top state failed: $doc_top"
        exit 1
    fi
    if [[ "$doc_top_next" != *"focus=right"* || "$doc_top_next" != *"left_top=3"* || "$doc_top_next" != *"right_top=3"* || "$doc_top_next" != *"chunk=1"* ]]; then
        echo "Navigation document-top next-change state failed: $doc_top_next"
        exit 1
    fi
    if [[ "$doc_bottom" != *"focus=right"* || "$doc_bottom" != *"left_top=11"* || "$doc_bottom" != *"right_top=11"* || "$doc_bottom" != *"left_cursor=13"* || "$doc_bottom" != *"right_cursor=13"* || "$doc_bottom" != *"chunk=5"* ]]; then
        echo "Navigation document-bottom state failed: $doc_bottom"
        exit 1
    fi
    if [[ "$doc_bottom_prev" != *"focus=right"* || "$doc_bottom_prev" != *"left_top=12"* || "$doc_bottom_prev" != *"right_top=12"* || "$doc_bottom_prev" != *"chunk=4"* ]]; then
        echo "Navigation document-bottom prev-change state failed: $doc_bottom_prev"
        exit 1
    fi

    echo "  PASSED: $test_name"
    echo "  States: $case_dir"
}

write_git_fixture() {
    local repo="$1"

    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"

    cat > "$repo/alpha_modified.txt" <<'EOF'
alpha old one
alpha stable two
EOF
    cat > "$repo/delete_me.txt" <<'EOF'
deleted line one
deleted line two
EOF
    git -C "$repo" add .
    git -C "$repo" commit -m baseline >/dev/null

    cat > "$repo/alpha_modified.txt" <<'EOF'
alpha new one
alpha stable two
EOF
    rm "$repo/delete_me.txt"
    cat > "$repo/beta_added_staged.txt" <<'EOF'
staged added line one
staged added line two
EOF
    git -C "$repo" add beta_added_staged.txt
    cat > "$repo/z_new_file.txt" <<'EOF'
brand new content one
brand new content two
EOF
}

start_git_session() {
    local repo="$1"
    local height="${2:-16}"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    tmux new-session -d -s "$TMUX_SESSION" -x 120 -y "$height"
    start_test_nvim "cd '$repo' && nvim -n -u '$SCRIPT_DIR/init.lua'"
    sleep 1
}

capture_git_command() {
    local repo="$1"
    local test_name="$2"
    local command="$3"
    local case_dir="$CAPTURE_ROOT/git"
    local plain_capture="$case_dir/${test_name}.txt"
    local ansi_capture="$case_dir/${test_name}.ansi"

    echo "  phase: $test_name"
    start_git_session "$repo" 16
    tmux send-keys -t "$TMUX_SESSION" "$command" C-m
    sleep 2
    tmux capture-pane -t "$TMUX_SESSION" -p > "$plain_capture"
    tmux capture-pane -t "$TMUX_SESSION" -e -p > "$ansi_capture"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    lua "$SCRIPT_DIR/verify.lua" "$plain_capture" "git:${test_name#git-}" "$ansi_capture"
}

run_git_binary_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/binary-repo"

    echo "  phase: git-binary"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    printf '\000\001\002\003ABCD' > "$repo/binary.bin"
    git -C "$repo" add binary.bin
    git -C "$repo" commit -m baseline >/dev/null
    printf '\000\001\002\004ABCE' > "$repo/binary.bin"

    capture_git_command "$repo" "git-binary" ":DiffBanditGit -- binary.bin"
}

run_git_binary_truncation_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/binary-truncated-repo"
    local plain_capture="$case_dir/git-binary-truncated.txt"
    local ansi_capture="$case_dir/git-binary-truncated.ansi"

    echo "  phase: git-binary-truncated"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    printf '\000\001\002\003ABCD1234' > "$repo/large.bin"
    git -C "$repo" add large.bin
    git -C "$repo" commit -m baseline >/dev/null
    printf '\000\001\002\004ABCE5678' > "$repo/large.bin"

    start_git_session "$repo" 16
    tmux send-keys -t "$TMUX_SESSION" ":lua require('diffbandit').setup({ ui = { hex = { max_bytes = 8, bytes_per_row = 4 } } })" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditGit -- large.bin" C-m
    sleep 2
    tmux capture-pane -t "$TMUX_SESSION" -p > "$plain_capture"
    tmux capture-pane -t "$TMUX_SESSION" -e -p > "$ansi_capture"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    lua "$SCRIPT_DIR/verify.lua" "$plain_capture" "git:binary-truncated" "$ansi_capture"
}

run_git_symlink_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/symlink-repo"

    echo "  phase: git-symlink"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    ln -s old-target.txt "$repo/link.txt"
    git -C "$repo" add link.txt
    git -C "$repo" commit -m baseline >/dev/null
    rm "$repo/link.txt"
    ln -s new-target.txt "$repo/link.txt"

    capture_git_command "$repo" "git-symlink" ":DiffBanditGit -- link.txt"
}

run_git_mode_only_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/mode-only-repo"

    echo "  phase: git-mode-only"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    cat > "$repo/mode_only.sh" <<'EOF'
#!/bin/sh
echo mode
EOF
    git -C "$repo" add mode_only.sh
    git -C "$repo" commit -m baseline >/dev/null
    git -C "$repo" update-index --chmod=+x mode_only.sh

    capture_git_command "$repo" "git-mode-only" ":DiffBanditGit --staged -- mode_only.sh"
}

run_git_unmerged_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/unmerged-repo"

    echo "  phase: git-unmerged"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    cat > "$repo/conflict.txt" <<'EOF'
base
EOF
    git -C "$repo" add conflict.txt
    git -C "$repo" commit -m baseline >/dev/null
    git -C "$repo" checkout -b side >/dev/null
    cat > "$repo/conflict.txt" <<'EOF'
side
EOF
    git -C "$repo" commit -am side >/dev/null
    git -C "$repo" checkout main >/dev/null 2>&1 || git -C "$repo" checkout master >/dev/null
    cat > "$repo/conflict.txt" <<'EOF'
main
EOF
    git -C "$repo" commit -am main >/dev/null
    git -C "$repo" merge side >/dev/null 2>&1 || true

    capture_git_command "$repo" "git-unmerged" ":DiffBanditGit -- conflict.txt"
}

run_git_submodule_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/submodule-repo"
    local old_oid="1111111111111111111111111111111111111111"
    local new_oid="2222222222222222222222222222222222222222"

    echo "  phase: git-submodule"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    git -C "$repo" update-index --add --cacheinfo "160000,$old_oid,vendor/lib"
    git -C "$repo" commit -m baseline >/dev/null
    git -C "$repo" update-index --add --cacheinfo "160000,$new_oid,vendor/lib"

    capture_git_command "$repo" "git-submodule" ":DiffBanditGit --staged -- vendor/lib"
}

assert_git_state_contains() {
    local file="$1"
    local expected="$2"
    local label="$3"
    local state
    state="$(cat "$file")"
    if [[ "$state" != *"$expected"* ]]; then
        echo "Git navigation state failed ($label): expected '$expected'"
        echo "$state"
        exit 1
    fi
}

run_git_queue_navigation_test() {
    local repo="$1"
    local case_dir="$CAPTURE_ROOT/git"
    local initial_state="$case_dir/queue-initial.state"
    local first_hunk_state="$case_dir/queue-after-first-hunk.state"
    local first_boundary_state="$case_dir/queue-after-first-boundary.state"
    local second_boundary_state="$case_dir/queue-after-second-boundary.state"
    local next_file_state="$case_dir/queue-after-next-file.state"
    local prev_file_state="$case_dir/queue-after-prev-file.state"
    local focus_panel_state="$case_dir/queue-after-focus-panel.state"

    echo "  phase: git-queue-navigation"
    start_git_session "$repo" 12
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditGit" C-m
    sleep 2

    tmux send-keys -t "$TMUX_SESSION" ":DBWriteGitState $initial_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteGitState $first_hunk_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteGitState $first_boundary_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 0.8
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteGitState $second_boundary_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "]" "f"
    sleep 0.8
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteGitState $next_file_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "[" "f"
    sleep 0.8
    tmux send-keys -t "$TMUX_SESSION" ":DBWriteGitState $prev_file_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" C
    sleep 0.8
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $focus_panel_state" C-m
    sleep 0.2
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    assert_git_state_contains "$initial_state" "queue_index=1" "initial index"
    assert_git_state_contains "$initial_state" "queue_count=4" "initial count"
    assert_git_state_contains "$initial_state" "chunk=0" "initial git file should open at top"
    assert_git_state_contains "$initial_state" "alpha_modified.txt (HEAD)" "initial left label"
    assert_git_state_contains "$initial_state" "alpha_modified.txt (working tree)" "initial right label"
    assert_git_state_contains "$initial_state" "status_left=HEAD  alpha_modified.txt" "initial left status"
    assert_git_state_contains "$initial_state" "status_center=all 1/4" "initial center status"
    assert_git_state_contains "$initial_state" "status_right=working tree  alpha_modified.txt" "initial right status"

    assert_git_state_contains "$first_hunk_state" "queue_index=1" "first ]c should stay in the initial file"
    assert_git_state_contains "$first_hunk_state" "chunk=1" "first ]c should move to the first hunk"
    assert_git_state_contains "$first_boundary_state" "queue_index=1" "second ]c should only arm boundary"
    assert_git_state_contains "$second_boundary_state" "queue_index=2" "third ]c should open next file"
    assert_git_state_contains "$second_boundary_state" "chunk=0" "third ]c should open next file at top"
    assert_git_state_contains "$second_boundary_state" "beta_added_staged.txt" "third ]c next file label"
    assert_git_state_contains "$second_boundary_state" "status_center=all 2/4" "second file center status"

    assert_git_state_contains "$next_file_state" "queue_index=3" "]f should open third file"
    assert_git_state_contains "$next_file_state" "chunk=0" "]f should open third file at top"
    assert_git_state_contains "$next_file_state" "delete_me.txt" "]f third file label"
    assert_git_state_contains "$next_file_state" "status_center=all 3/4" "]f center status"
    assert_git_state_contains "$prev_file_state" "queue_index=2" "[f should return to second file"
    assert_git_state_contains "$prev_file_state" "chunk=0" "[f should open previous file at top"
    assert_git_state_contains "$prev_file_state" "beta_added_staged.txt" "[f second file label"
    assert_git_state_contains "$focus_panel_state" "panel_visible=true" "C should open the commit panel from DiffBanditGit"
    assert_git_state_contains "$focus_panel_state" "focus=panel" "C should focus the commit panel"
    assert_git_state_contains "$focus_panel_state" "queue_index=2" "C should preserve the current file index"
    assert_git_state_contains "$focus_panel_state" "selected_path=beta_added_staged.txt" "C should select the current file in the panel"
}

run_git_live_buffer_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/live-buffer-repo"
    local plain_capture="$case_dir/git-live-buffer.txt"
    local ansi_capture="$case_dir/git-live-buffer.ansi"

    echo "  phase: git-live-buffer"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    cat > "$repo/live_buffer.txt" <<'EOF'
saved buffer line
stable buffer line
EOF
    git -C "$repo" add live_buffer.txt
    git -C "$repo" commit -m baseline >/dev/null

    start_git_session "$repo" 16
    tmux send-keys -t "$TMUX_SESSION" ":edit live_buffer.txt" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":call setline(1, 'unsaved buffer line')" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditGitCurrent" C-m
    sleep 2
    tmux capture-pane -t "$TMUX_SESSION" -p > "$plain_capture"
    tmux capture-pane -t "$TMUX_SESSION" -e -p > "$ansi_capture"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    lua "$SCRIPT_DIR/verify.lua" "$plain_capture" "git:live-buffer" "$ansi_capture"
}

write_large_scroll_repo() {
    local repo="$1"
    local line_count="${2:-5000}"

    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"

    : > "$repo/big.lua"
    for i in $(seq 1 "$line_count"); do
        printf "local value_%04d = %04d\n" "$i" "$i" >> "$repo/big.lua"
    done
    git -C "$repo" add big.lua
    git -C "$repo" commit -m baseline >/dev/null

    local tmp_file="$repo/big.lua.tmp"
    : > "$tmp_file"
    for i in $(seq 1 "$line_count"); do
        case "$i" in
            250|750|1250|1750|2250|2750|3250|3750|4250|4750)
                printf "local value_%04d = %04d -- changed\n" "$i" "$((i + 10000))" >> "$tmp_file"
                ;;
            *)
                printf "local value_%04d = %04d\n" "$i" "$i" >> "$tmp_file"
                ;;
        esac
    done
    mv "$tmp_file" "$repo/big.lua"
}

perf_state_value() {
    local file="$1"
    local key="$2"
    grep "^$key=" "$file" | head -n 1 | cut -d= -f2
}

wait_for_file() {
    local file="$1"
    local attempts="${2:-20}"
    for _ in $(seq 1 "$attempts"); do
        if [[ -f "$file" ]]; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

run_git_scroll_perf_test() {
    local test_name="git-scroll-perf"
    local case_dir="$CAPTURE_ROOT/$test_name"
    local repo="$case_dir/repo"
    local initial_state="$case_dir/initial.state"

    echo "Running integration test: $test_name"
    mkdir -p "$case_dir"
    write_large_scroll_repo "$repo" 5000

    start_git_session "$repo" 24
    tmux send-keys -t "$TMUX_SESSION" ":lua require('diffbandit').setup({ ui = { scroll_debounce_ms = 25 } })" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":edit big.lua" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditGitCurrent" C-m
    sleep 2
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePerfState $initial_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":DBResetPerf" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":DBFocus right" C-m
    sleep 0.2

    run_scroll_burst() {
        local label="$1"
        local scroll_events="$2"
        local min_top="$3"
        local scroll_state="$case_dir/${label}.state"
        local render_count
        local request_count
        local right_top
        local right_lines

        rm -f "$scroll_state"
        tmux send-keys -t "$TMUX_SESSION" ":DBResetPerf" C-m
        sleep 0.1
        tmux send-keys -t "$TMUX_SESSION" ":DBRapidScroll $scroll_events" C-m
        sleep 1
        tmux send-keys -t "$TMUX_SESSION" ":DBWritePerfState $scroll_state" C-m
        wait_for_file "$scroll_state" 30 || true

        render_count="$(perf_state_value "$scroll_state" "render_count")"
        request_count="$(perf_state_value "$scroll_state" "viewport_request_count")"
        right_top="$(perf_state_value "$scroll_state" "right_top")"
        right_lines="$(perf_state_value "$scroll_state" "right_lines")"

        if [[ -z "$render_count" || -z "$request_count" || -z "$right_top" ]]; then
            echo "Git scroll perf state missing expected values ($label)"
            cat "$scroll_state"
            exit 1
        fi
        if (( right_lines < 5000 )); then
            echo "Git scroll perf fixture did not load the large current file ($label)"
            cat "$scroll_state"
            exit 1
        fi
        if (( right_top < min_top )); then
            echo "Git scroll perf failed: rapid scroll did not reach expected depth ($label)"
            echo "events=$scroll_events min_top=$min_top"
            cat "$scroll_state"
            exit 1
        fi
        if (( request_count <= 0 )); then
            echo "Git scroll perf failed: rapid scroll did not hit viewport rerender scheduling ($label)"
            cat "$scroll_state"
            exit 1
        fi
        if (( render_count >= scroll_events / 2 )); then
            echo "Git scroll perf failed: render count too high for debounced scroll ($label)"
            echo "events=$scroll_events renders=$render_count requests=$request_count"
            cat "$scroll_state"
            exit 1
        fi

        echo "  burst $label: events=$scroll_events renders=$render_count requests=$request_count right_top=$right_top"
    }

    run_scroll_burst "burst-1" 80 70
    run_scroll_burst "burst-2" 420 480
    run_scroll_burst "burst-3" 900 1350
    run_scroll_burst "burst-4" 1800 3100
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    echo "  PASSED: $test_name"
    echo "  States: $case_dir"
}

assert_git_diff_contains() {
    local repo="$1"
    local mode="$2"
    local file="$3"
    local expected="$4"
    local label="$5"
    local output

    if [[ "$mode" == "cached" ]]; then
        output="$(git -C "$repo" diff --cached -- "$file")"
    else
        output="$(git -C "$repo" diff -- "$file")"
    fi
    if [[ "$output" != *"$expected"* ]]; then
        echo "Git action state failed ($label): expected '$expected'"
        echo "$output"
        exit 1
    fi
}

assert_git_diff_clean() {
    local repo="$1"
    local mode="$2"
    local file="$3"
    local label="$4"

    if [[ "$mode" == "cached" ]]; then
        if ! git -C "$repo" diff --cached --quiet -- "$file"; then
            echo "Git action state failed ($label): cached diff not clean"
            git -C "$repo" diff --cached -- "$file"
            exit 1
        fi
    else
        if ! git -C "$repo" diff --quiet -- "$file"; then
            echo "Git action state failed ($label): worktree diff not clean"
            git -C "$repo" diff -- "$file"
            exit 1
        fi
    fi
}

run_git_actions_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/actions-repo"
    local initial_capture="$case_dir/git-action-unstaged-marker.txt"
    local initial_ansi="$case_dir/git-action-unstaged-marker.ansi"
    local staged_capture="$case_dir/git-action-staged-marker.txt"
    local staged_ansi="$case_dir/git-action-staged-marker.ansi"

    echo "  phase: git-actions"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    cat > "$repo/action.txt" <<'EOF'
action base line
stable action line
EOF
    git -C "$repo" add action.txt
    git -C "$repo" commit -m baseline >/dev/null
    cat > "$repo/action.txt" <<'EOF'
action changed line
stable action line
EOF

    start_git_session "$repo" 14
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditGit -- action.txt" C-m
    sleep 2
    tmux capture-pane -t "$TMUX_SESSION" -p > "$initial_capture"
    tmux capture-pane -t "$TMUX_SESSION" -e -p > "$initial_ansi"
    lua "$SCRIPT_DIR/verify.lua" "$initial_capture" "git:action-unstaged-marker" "$initial_ansi"

    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" Space
    sleep 1
    assert_git_diff_contains "$repo" "cached" "action.txt" "action changed line" "space should stage hunk"
    assert_git_diff_clean "$repo" "worktree" "action.txt" "space should leave no unstaged diff"

    tmux send-keys -t "$TMUX_SESSION" ":DBFocus right" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" u
    sleep 1
    assert_git_diff_clean "$repo" "cached" "action.txt" "u should undo staged hunk"
    assert_git_diff_contains "$repo" "worktree" "action.txt" "action changed line" "u should restore unstaged hunk"

    tmux send-keys -t "$TMUX_SESSION" Space
    sleep 1
    assert_git_diff_contains "$repo" "cached" "action.txt" "action changed line" "second space should stage hunk"
    assert_git_diff_clean "$repo" "worktree" "action.txt" "second space should leave no unstaged diff"

    tmux send-keys -t "$TMUX_SESSION" ">" ">"
    sleep 1
    assert_git_diff_contains "$repo" "worktree" "action.txt" "action base line" ">> should discard worktree side while staged change remains"

    tmux send-keys -t "$TMUX_SESSION" u
    sleep 1
    assert_git_diff_contains "$repo" "cached" "action.txt" "action changed line" "u after >> should leave staged hunk intact"
    assert_git_diff_clean "$repo" "worktree" "action.txt" "u after >> should restore worktree to staged content"

    tmux send-keys -t "$TMUX_SESSION" u
    sleep 1
    assert_git_diff_clean "$repo" "cached" "action.txt" "second u should undo the staged hunk"
    assert_git_diff_contains "$repo" "worktree" "action.txt" "action changed line" "second u should restore unstaged hunk"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    git -C "$repo" add action.txt
    start_git_session "$repo" 14
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditGit --staged -- action.txt" C-m
    sleep 2
    tmux capture-pane -t "$TMUX_SESSION" -p > "$staged_capture"
    tmux capture-pane -t "$TMUX_SESSION" -e -p > "$staged_ansi"
    lua "$SCRIPT_DIR/verify.lua" "$staged_capture" "git:action-staged-marker" "$staged_ansi"

    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" Space
    sleep 1
    assert_git_diff_clean "$repo" "cached" "action.txt" "space should unstage staged hunk"
    assert_git_diff_contains "$repo" "worktree" "action.txt" "action changed line" "unstage should leave worktree change"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}

run_git_staged_added_toggle_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/staged-added-toggle-repo"

    echo "  phase: git-staged-added-toggle"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    cat > "$repo/tracked.txt" <<'EOF'
baseline line
EOF
    git -C "$repo" add tracked.txt
    git -C "$repo" commit -m baseline >/dev/null
    cat > "$repo/already_staged_added.txt" <<'EOF'
already staged added one
already staged added two
EOF
    git -C "$repo" add already_staged_added.txt

    start_git_session "$repo" 14
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditGit -- already_staged_added.txt" C-m
    sleep 2
    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" Space
    sleep 1
    assert_git_diff_clean "$repo" "cached" "already_staged_added.txt" "space should unstage an already staged added file"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}

run_git_staged_added_hunk_toggle_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/staged-added-hunk-toggle-repo"

    echo "  phase: git-staged-added-hunk-toggle"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    cat > "$repo/already_staged_added_hunk.txt" <<'EOF'
one
three
EOF
    git -C "$repo" add already_staged_added_hunk.txt
    git -C "$repo" commit -m baseline >/dev/null
    cat > "$repo/already_staged_added_hunk.txt" <<'EOF'
one
two
three
EOF
    git -C "$repo" add already_staged_added_hunk.txt

    start_git_session "$repo" 14
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditGit -- already_staged_added_hunk.txt" C-m
    sleep 2
    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" Space
    sleep 1
    assert_git_diff_clean "$repo" "cached" "already_staged_added_hunk.txt" "space should unstage an already staged added hunk"
    assert_git_diff_contains "$repo" "worktree" "already_staged_added_hunk.txt" "two" "unstage should leave staged added hunk in the worktree"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}

run_git_mixed_staged_added_hunk_toggle_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/mixed-staged-added-hunk-toggle-repo"

    echo "  phase: git-mixed-staged-added-hunk-toggle"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    cat > "$repo/mixed_staged_added_hunk.txt" <<'EOF'
one
three
four
EOF
    git -C "$repo" add mixed_staged_added_hunk.txt
    git -C "$repo" commit -m baseline >/dev/null
    cat > "$repo/mixed_staged_added_hunk.txt" <<'EOF'
one
two
three
four
EOF
    git -C "$repo" add mixed_staged_added_hunk.txt
    cat > "$repo/mixed_staged_added_hunk.txt" <<'EOF'
one
two
THREE
four
EOF

    start_git_session "$repo" 14
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditGit -- mixed_staged_added_hunk.txt" C-m
    sleep 2
    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" Space
    sleep 1
    assert_git_diff_clean "$repo" "cached" "mixed_staged_added_hunk.txt" "space should unstage only the staged added hunk"
    assert_git_diff_contains "$repo" "worktree" "mixed_staged_added_hunk.txt" "two" "unstage should leave the added worktree line"
    assert_git_diff_contains "$repo" "worktree" "mixed_staged_added_hunk.txt" "THREE" "unstage should leave nearby worktree edits"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
}

run_git_commit_panel_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/commit-panel-repo"
    local initial_state="$case_dir/panel-initial.state"
    local amend_on_state="$case_dir/panel-amend-on.state"
    local amend_off_state="$case_dir/panel-amend-off.state"
    local first_move_state="$case_dir/panel-after-first-j.state"
    local second_move_state="$case_dir/panel-after-second-j.state"
    local next_change_state="$case_dir/panel-after-next-change.state"
    local staged_state="$case_dir/panel-after-stage.state"
    local hidden_state="$case_dir/panel-after-hide.state"
    local shown_state="$case_dir/panel-after-show.state"
    local committed_state="$case_dir/panel-after-commit.state"

    echo "  phase: git-commit-panel"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    cat > "$repo/alpha.txt" <<'EOF'
alpha base
EOF
    cat > "$repo/beta.txt" <<'EOF'
beta base
EOF
    git -C "$repo" add alpha.txt beta.txt
    git -C "$repo" commit -m baseline >/dev/null
    cat > "$repo/alpha.txt" <<'EOF'
alpha changed
EOF
    cat > "$repo/beta.txt" <<'EOF'
beta changed
EOF

    start_git_session "$repo" 18
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditCommitPanel" C-m
    sleep 2
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $initial_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" c c
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" Space
    sleep 0.8
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $amend_on_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" Space
    sleep 0.8
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $amend_off_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" C-w k
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" j
    sleep 0.8
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $first_move_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" j
    sleep 0.8
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $second_move_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "]" "c"
    sleep 0.8
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $next_change_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" Space
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $staged_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditCommitPanel" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $hidden_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditCommitPanel" C-m
    sleep 0.8
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $shown_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" c c
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" i "panel commit" Escape
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":w" C-m
    sleep 1.5
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $committed_state" C-m
    sleep 0.2
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    assert_git_state_contains "$initial_state" "surface=panel" "panel command should open only the standalone panel"
    assert_git_state_contains "$initial_state" "panel_visible=true" "panel initial visible"
    assert_git_state_contains "$initial_state" "focus=panel" "panel initial focus"
    assert_git_state_contains "$initial_state" "queue_index=0" "panel should not load a file before selection"
    assert_git_state_contains "$initial_state" "row=▾ Changes" "panel should initially rest on the group header"
    assert_git_state_contains "$amend_on_state" "focus=commit" "panel amend toggle should run from the commit pane"
    assert_git_state_contains "$amend_on_state" "amend=true" "commit pane space should enable amend mode"
    assert_git_state_contains "$amend_on_state" "stage_states=1:partial,2:partial" "panel amend mode should evaluate stage states against the amend base"
    assert_git_state_contains "$amend_off_state" "amend=false" "commit pane space should disable amend mode"
    assert_git_state_contains "$amend_off_state" "stage_states=1:unstaged,2:unstaged" "panel normal mode should restore ordinary stage states"
    assert_git_state_contains "$first_move_state" "focus=panel" "panel first j keeps focus"
    assert_git_state_contains "$first_move_state" "queue_index=1" "panel first j selects first file"
    assert_git_state_contains "$first_move_state" "selected_path=alpha.txt" "panel first j selects alpha"
    assert_git_state_contains "$second_move_state" "focus=panel" "panel second j keeps focus"
    assert_git_state_contains "$second_move_state" "queue_index=2" "panel second j previews second file"
    assert_git_state_contains "$second_move_state" "selected_path=beta.txt" "panel second j selects beta"
    assert_git_state_contains "$next_change_state" "focus=panel" "panel ]c keeps focus"
    assert_git_state_contains "$next_change_state" "surface=session" "panel ]c operates after diff session load"
    assert_git_state_contains "$next_change_state" "queue_index=2" "panel ]c stays on selected file"
    assert_git_state_contains "$next_change_state" "chunk=1" "panel ]c moves to the first hunk"
    assert_git_state_contains "$staged_state" "2:staged" "panel space stages selected file"
    assert_git_state_contains "$hidden_state" "panel_visible=false" "panel command hides panel"
    assert_git_state_contains "$shown_state" "panel_visible=true" "panel command shows panel"
    assert_git_state_contains "$committed_state" "queue_count=1" "panel commit refreshes remaining queue"
    if [[ "$(git -C "$repo" log -1 --pretty=%B | tr -d '\n')" != "panel commit" ]]; then
        echo "Git commit panel failed: latest commit message mismatch"
        git -C "$repo" log -1 --pretty=%B
        exit 1
    fi
    if ! git -C "$repo" diff --cached --quiet; then
        echo "Git commit panel failed: cached diff should be clean after commit"
        git -C "$repo" diff --cached
        exit 1
    fi
    if find "$repo" -maxdepth 1 -name 'diffbandit-commit-*' | grep -q .; then
        echo "Git commit panel failed: :w should be intercepted, not written to disk"
        exit 1
    fi
    assert_git_diff_contains "$repo" "worktree" "alpha.txt" "alpha changed" "panel commit should leave unstaged alpha change"
}

run_git_panel_file_actions_test() {
    local case_dir="$CAPTURE_ROOT/git"
    local repo="$case_dir/panel-file-actions-repo"
    local initial_state="$case_dir/panel-file-actions-initial.state"
    local ignore_state="$case_dir/panel-file-actions-ignore.state"
    local discard_state="$case_dir/panel-file-actions-discard.state"
    local delete_state="$case_dir/panel-file-actions-delete.state"

    echo "  phase: git-panel-file-actions"
    rm -rf "$repo"
    mkdir -p "$repo/logs"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    cat > "$repo/tracked.txt" <<'EOF'
base
EOF
    cat > "$repo/deleted.txt" <<'EOF'
deleted base
EOF
    git -C "$repo" add tracked.txt deleted.txt
    git -C "$repo" commit -m baseline >/dev/null
    cat > "$repo/tracked.txt" <<'EOF'
staged
EOF
    git -C "$repo" add tracked.txt
    cat > "$repo/tracked.txt" <<'EOF'
worktree
EOF
    rm "$repo/deleted.txt"
    cat > "$repo/logs/app.log" <<'EOF'
temporary log
EOF
    cat > "$repo/remove.tmp" <<'EOF'
temporary remove
EOF

    start_git_session "$repo" 24
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditCommitPanel" C-m
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $initial_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":DBSelectPanelPath logs/app.log" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":DBPanelAction ignore:/logs/app.log" C-m
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $ignore_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":DBSelectPanelPath tracked.txt" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":DBPanelAction discard_worktree" C-m
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $discard_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":DBSelectPanelPath remove.tmp" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":DBPanelAction delete_untracked" C-m
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $delete_state" C-m
    sleep 0.2
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    assert_git_state_contains "$initial_state" "panel_visible=true" "panel file actions initial panel visible"
    assert_git_state_contains "$ignore_state" "focus=panel" "ignore action should keep panel focus"
    if grep -q "selected_path=logs/app.log" "$ignore_state" || grep -qx "selected_path=" "$ignore_state"; then
        echo "Git panel file actions failed: ignore action should select a remaining file row"
        cat "$ignore_state"
        exit 1
    fi
    if ! grep -qx "/logs/app.log" "$repo/.gitignore"; then
        echo "Git panel file actions failed: .gitignore missing exact path"
        cat "$repo/.gitignore" 2>/dev/null || true
        exit 1
    fi
    if git -C "$repo" status --porcelain -- logs/app.log | grep -q .; then
        echo "Git panel file actions failed: ignored file should disappear from status"
        git -C "$repo" status --porcelain -- logs/app.log
        exit 1
    fi
    if [[ "$(cat "$repo/tracked.txt")" != "staged" ]]; then
        echo "Git panel file actions failed: discard should restore worktree to staged content"
        cat "$repo/tracked.txt"
        exit 1
    fi
    assert_git_diff_contains "$repo" "cached" "tracked.txt" "staged" "discard action should preserve staged content"
    assert_git_state_contains "$discard_state" "focus=panel" "discard action should keep panel focus"
    if [[ -e "$repo/remove.tmp" ]]; then
        echo "Git panel file actions failed: delete action should remove untracked file"
        exit 1
    fi
    assert_git_state_contains "$delete_state" "focus=panel" "delete action should keep panel focus"
}

run_git_test() {
    local test_name="git"
    local case_dir="$CAPTURE_ROOT/$test_name"
    local repo="$case_dir/repo"

    echo "Running integration test: $test_name"
    mkdir -p "$case_dir"
    write_git_fixture "$repo"

    capture_git_command "$repo" "git-untracked" ":DiffBanditGit -- z_new_file.txt"
    capture_git_command "$repo" "git-deleted" ":DiffBanditGit -- delete_me.txt"
    capture_git_command "$repo" "git-staged-added" ":DiffBanditGit --staged -- beta_added_staged.txt"
    run_git_binary_test
    run_git_binary_truncation_test
    run_git_symlink_test
    run_git_mode_only_test
    run_git_unmerged_test
    run_git_submodule_test
    run_git_queue_navigation_test "$repo"
    run_git_actions_test
    run_git_staged_added_toggle_test
    run_git_staged_added_hunk_toggle_test
    run_git_mixed_staged_added_hunk_toggle_test
    run_git_commit_panel_test
    run_git_panel_file_actions_test
    run_git_live_buffer_test

    echo "  PASSED: $test_name"
    echo "  Captures: $case_dir"
}

run_git_merge_test() {
    local test_name="git-merge"
    local case_dir="$CAPTURE_ROOT/$test_name"
    local repo="$case_dir/repo"
    local plain_capture="$case_dir/capture.txt"

    echo "Running integration test: $test_name"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init >/dev/null
    git -C "$repo" config user.email "diffbandit@example.test"
    git -C "$repo" config user.name "DiffBandit Test"
    printf "one\nbase\nthree\n" > "$repo/conflict.txt"
    printf "alpha\nbase two\nomega\n" > "$repo/second_conflict.txt"
    git -C "$repo" add conflict.txt
    git -C "$repo" add second_conflict.txt
    git -C "$repo" commit -m baseline >/dev/null
    local main_branch
    main_branch="$(git -C "$repo" branch --show-current)"
    git -C "$repo" checkout -b feature >/dev/null
    printf "one\nremote\nthree\n" > "$repo/conflict.txt"
    printf "alpha\nremote two\nomega\n" > "$repo/second_conflict.txt"
    git -C "$repo" commit -am "remote change" >/dev/null
    git -C "$repo" checkout "$main_branch" >/dev/null
    printf "one\nlocal\nthree\n" > "$repo/conflict.txt"
    printf "alpha\nlocal two\nomega\n" > "$repo/second_conflict.txt"
    git -C "$repo" commit -am "local change" >/dev/null
    if git -C "$repo" merge feature >/dev/null 2>&1; then
        echo "Git merge resolver test failed: fixture merge did not conflict"
        exit 1
    fi

    local panel_state="$case_dir/panel_after_conflict_open.state"
    local second_panel_state="$case_dir/panel_after_second_conflict_open.state"
    local panel_capture="$case_dir/panel_conflict_preview.txt"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    tmux new-session -d -s "$TMUX_SESSION" -x 120 -y 32 -c "$repo"
    start_test_nvim "nvim -u '$SCRIPT_DIR/init.lua'"
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditCommitPanel" C-m
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" "j"
    sleep 1
    tmux capture-pane -t "$TMUX_SESSION" -p > "$panel_capture"
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $panel_state" C-m
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" "j"
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $second_panel_state" C-m
    sleep 0.2
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    assert_git_state_contains "$panel_state" "surface=session" "panel conflict preview should open a merge session"
    assert_git_state_contains "$panel_state" "panel_visible=true" "panel should remain visible after opening a conflict"
    assert_git_state_contains "$panel_state" "focus=panel" "panel should keep focus after opening a conflict"
    assert_git_state_contains "$panel_state" "row=  ! U conflict.txt" "panel should keep the selected conflict row visible"
    if ! grep -q "Merge Conflicts" "$panel_capture" \
        || ! grep -q "local/c" "$panel_capture" \
        || ! grep -q "merge result" "$panel_capture" \
        || ! grep -q "remote/incom" "$panel_capture"; then
        echo "Git merge resolver test failed: panel conflict preview did not render merge status headers"
        cat "$panel_capture"
        exit 1
    fi
    assert_git_state_contains "$second_panel_state" "surface=session" "panel second conflict preview should stay in a merge session"
    assert_git_state_contains "$second_panel_state" "panel_visible=true" "panel should remain visible after opening a second conflict"
    assert_git_state_contains "$second_panel_state" "focus=panel" "panel should keep focus after opening a second conflict"
    assert_git_state_contains "$second_panel_state" "row=  ! U second_conflict.txt" "panel should move to the second conflict row"

    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    tmux new-session -d -s "$TMUX_SESSION" -x 120 -y 32 -c "$repo"
    start_test_nvim "nvim -u '$SCRIPT_DIR/init.lua'"
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditMerge conflict.txt" C-m
    sleep 1
    tmux capture-pane -t "$TMUX_SESSION" -p > "$plain_capture"
    if ! grep -q "local/current" "$plain_capture" \
        || ! grep -q "merge result" "$plain_capture" \
        || ! grep -q "conflict 1/1" "$plain_capture" \
        || ! grep -q "remote/incoming" "$plain_capture"; then
        echo "Git merge resolver test failed: merge status headers did not render"
        cat "$plain_capture"
        exit 1
    fi
    tmux send-keys -t "$TMUX_SESSION" ">>"
    sleep 0.2
    tmux send-keys -t "$TMUX_SESSION" ":w" C-m
    sleep 1
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    if git -C "$repo" ls-files -u -- conflict.txt | grep -q .; then
        echo "Git merge resolver test failed: conflict remains unmerged"
        git -C "$repo" ls-files -u -- conflict.txt
        exit 1
    fi
    if [[ "$(cat "$repo/conflict.txt")" != $'one\nlocal\nthree' ]]; then
        echo "Git merge resolver test failed: accept-local result was not written"
        cat "$repo/conflict.txt"
        exit 1
    fi

    local full_repo="$case_dir/full-repo"
    local full_panel_state="$case_dir/full_after_commit.state"
    rm -rf "$full_repo"
    mkdir -p "$full_repo"
    git -C "$full_repo" init >/dev/null
    git -C "$full_repo" config user.email "diffbandit@example.test"
    git -C "$full_repo" config user.name "DiffBandit Test"
    printf "base delete/modify\n" > "$full_repo/delete_vs_modify.txt"
    printf "base modify/delete\n" > "$full_repo/modify_vs_delete.txt"
    printf "base same\n" > "$full_repo/same_line.txt"
    git -C "$full_repo" add delete_vs_modify.txt modify_vs_delete.txt same_line.txt
    git -C "$full_repo" commit -m baseline >/dev/null
    main_branch="$(git -C "$full_repo" branch --show-current)"
    git -C "$full_repo" checkout -b incoming >/dev/null
    printf "incoming add/add\n" > "$full_repo/add_add.txt"
    printf "incoming modifies\n" > "$full_repo/delete_vs_modify.txt"
    git -C "$full_repo" rm modify_vs_delete.txt >/dev/null
    printf "incoming same\n" > "$full_repo/same_line.txt"
    git -C "$full_repo" add -A
    git -C "$full_repo" commit -m "incoming conflict sides" >/dev/null
    git -C "$full_repo" checkout "$main_branch" >/dev/null
    printf "local add/add\n" > "$full_repo/add_add.txt"
    git -C "$full_repo" rm delete_vs_modify.txt >/dev/null
    printf "local modifies\n" > "$full_repo/modify_vs_delete.txt"
    printf "local same\n" > "$full_repo/same_line.txt"
    git -C "$full_repo" add -A
    git -C "$full_repo" commit -m "local conflict sides" >/dev/null
    if git -C "$full_repo" merge incoming >/dev/null 2>&1; then
        echo "Git merge resolver test failed: full fixture merge did not conflict"
        exit 1
    fi
    local full_unmerged
    full_unmerged="$(git -C "$full_repo" status --porcelain | grep -E '^(AA|DU|UD|UU) ' | wc -l | tr -d ' ')"
    if [[ "$full_unmerged" != "4" ]]; then
        echo "Git merge resolver test failed: full fixture should have four unmerged paths"
        git -C "$full_repo" status --porcelain
        exit 1
    fi

    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    tmux new-session -d -s "$TMUX_SESSION" -x 120 -y 32 -c "$full_repo"
    start_test_nvim "nvim -u '$SCRIPT_DIR/init.lua'"
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DiffBanditCommitPanel" C-m
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DBOpenQueuePath add_add.txt" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBAcceptResolve local" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBOpenQueuePath delete_vs_modify.txt" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBAcceptResolve local" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBOpenQueuePath modify_vs_delete.txt" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBAcceptResolve local" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBOpenQueuePath same_line.txt" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBAcceptResolve local" C-m
    sleep 0.5
    tmux send-keys -t "$TMUX_SESSION" ":DBPanelCommit full fixture merge" C-m
    sleep 1
    tmux send-keys -t "$TMUX_SESSION" ":DBWritePanelState $full_panel_state" C-m
    sleep 0.2
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    if git -C "$full_repo" ls-files -u | grep -q .; then
        echo "Git merge resolver test failed: full fixture left unmerged entries"
        git -C "$full_repo" ls-files -u
        exit 1
    fi
    if [[ "$(git -C "$full_repo" status --porcelain)" != "" ]]; then
        echo "Git merge resolver test failed: full fixture should be clean after commit"
        git -C "$full_repo" status --porcelain
        exit 1
    fi
    if git -C "$full_repo" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        echo "Git merge resolver test failed: full fixture should complete the merge commit"
        exit 1
    fi
    if [[ "$(git -C "$full_repo" log -1 --pretty=%B | tr -d '\n')" != "full fixture merge" ]]; then
        echo "Git merge resolver test failed: full fixture commit message mismatch"
        git -C "$full_repo" log -1 --pretty=%B
        exit 1
    fi
    assert_git_state_contains "$full_panel_state" "queue_count=0" "full fixture commit should leave an empty queue"

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
    dense-mixed)
        run_test "dense-mixed" \
            "$PROJECT_ROOT/tests/files/left_dense_mixed.txt" \
            "$PROJECT_ROOT/tests/files/right_dense_mixed.txt"
        ;;
    theme-default)
        run_test "theme-default" \
            "$PROJECT_ROOT/tests/files/left_mixed.txt" \
            "$PROJECT_ROOT/tests/files/right_mixed.txt"
        ;;
    comprehensive)
        run_test "comprehensive" \
            "$PROJECT_ROOT/tests/files/left_comprehensive.txt" \
            "$PROJECT_ROOT/tests/files/right_comprehensive.txt"
        ;;
    listchars)
        run_listchars_test
        ;;
    navigation)
        run_navigation_test
        ;;
    git)
        run_git_test
        ;;
    git-merge)
        run_git_merge_test
        ;;
    git-scroll-perf)
        run_git_scroll_perf_test
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
    scroll-dense-mixed)
        run_scroll_test "scroll-dense-mixed" \
            "$PROJECT_ROOT/tests/files/left_dense_mixed.txt" \
            "$PROJECT_ROOT/tests/files/right_dense_mixed.txt"
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

        run_test "dense-mixed" \
            "$PROJECT_ROOT/tests/files/left_dense_mixed.txt" \
            "$PROJECT_ROOT/tests/files/right_dense_mixed.txt"

        run_test "theme-default" \
            "$PROJECT_ROOT/tests/files/left_mixed.txt" \
            "$PROJECT_ROOT/tests/files/right_mixed.txt"

        run_test "comprehensive" \
            "$PROJECT_ROOT/tests/files/left_comprehensive.txt" \
            "$PROJECT_ROOT/tests/files/right_comprehensive.txt"

        run_listchars_test

        run_navigation_test

        run_git_test

        run_git_merge_test

        run_git_scroll_perf_test

        ;;
    *)
        echo "Unknown test: $TEST_TO_RUN"
        echo "Usage: $0 [extreme|pure|deletions|mixed|dense-mixed|theme-default|comprehensive|listchars|navigation|git|git-merge|git-scroll-perf|scroll-additions|scroll-deletions|scroll-mixed|scroll-dense-mixed|scroll-changes|all]"
        exit 1
        ;;
esac

echo ""
echo "All integration tests passed!"
