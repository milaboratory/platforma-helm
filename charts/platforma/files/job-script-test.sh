#!/bin/sh
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
JOB_SCRIPT="${SCRIPT_DIR}/job-script.sh"

TESTS_RUN=0
TESTS_FAILED=0

# --- Per-test state ---
TEST_DIR=""
TEST_OK=true

fail() {
  echo "  FAIL: $1"
  TEST_OK=false
}

begin_test() {
  TEST_OK=true
  TEST_DIR=$(mktemp -d)
  TESTS_RUN=$((TESTS_RUN + 1))

  # Clean environment for each test
  unset PL_JOB_STDOUT_PATH 2>/dev/null || true
  unset PL_JOB_STDERR_PATH 2>/dev/null || true
  unset PL_JOB_PATH 2>/dev/null || true
}

end_test() {
  _name="$1"
  if $TEST_OK; then
    echo "PASS: $_name"
  else
    echo "FAIL: $_name"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
  rm -rf "$TEST_DIR"
}

# Run job-script.sh with current env, capture outputs.
# Sets: GOT_EXIT, CAPTURED_STDOUT (file), CAPTURED_STDERR (file)
run_job() {
  export PL_JOB_CMD_AND_ARGS="$1"

  CAPTURED_STDOUT="${TEST_DIR}/captured_stdout"
  CAPTURED_STDERR="${TEST_DIR}/captured_stderr"

  GOT_EXIT=0
  sh "$JOB_SCRIPT" >"$CAPTURED_STDOUT" 2>"$CAPTURED_STDERR" || GOT_EXIT=$?
}

# --- Assertions ---

check_exit() {
  _expected="$1"
  if [ "$GOT_EXIT" -ne "$_expected" ]; then
    fail "exit code: expected $_expected, got $GOT_EXIT"
  fi
}

check_file_contains() {
  _file="$1"; _str="$2"; _desc="$3"
  if [ ! -f "$_file" ]; then
    fail "$_desc: file does not exist"
  elif ! grep -qF "$_str" "$_file"; then
    fail "$_desc: should contain '$_str', got '$(cat "$_file")'"
  fi
}

check_file_not_contains() {
  _file="$1"; _str="$2"; _desc="$3"
  if [ -f "$_file" ] && grep -qF "$_str" "$_file"; then
    fail "$_desc: should NOT contain '$_str'"
  fi
}

check_file_empty() {
  _file="$1"; _desc="$2"
  if [ -s "$_file" ]; then
    fail "$_desc: should be empty, got '$(cat "$_file")'"
  fi
}

check_file_not_exists() {
  _file="$1"; _desc="$2"
  if [ -f "$_file" ]; then
    fail "$_desc: file should not exist"
  fi
}

# --- Test commands ---

GOOD_CMD='printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2'
BAD_CMD='printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2; exit 42'
OOM_CMD='printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2; exit 137'

# Runs a full suite of checks for one redirect configuration.
# Usage: run_scenario <label_prefix> <cmd> <expected_exit>
#   Env vars PL_JOB_STDOUT_PATH / PL_JOB_STDERR_PATH must already be set (or unset).
#   $EXPECT_STDOUT_EMPTY, $EXPECT_STDOUT_FILE, $EXPECT_STDERR_FILE must be set by caller.
#   When both redirect to the same file, set EXPECT_SAME_FILE=true.

# =============================================================================
# Good command (exit 0)
# =============================================================================

# 1) No redirects
begin_test

run_job "$GOOD_CMD"
check_exit 0

check_file_contains "$CAPTURED_STDOUT" "STDOUT_MARKER" "captured stdout"
check_file_not_contains "$CAPTURED_STDOUT" "STDERR_MARKER" "captured stdout"

check_file_contains "$CAPTURED_STDERR" "STDERR_MARKER" "captured stderr"
check_file_not_contains "$CAPTURED_STDERR" "STDOUT_MARKER" "captured stderr"

end_test "good cmd, no redirects"

# 2) Stdout only
begin_test

export PL_JOB_STDOUT_PATH="${TEST_DIR}/stdout_file"
run_job "$GOOD_CMD"
check_exit 0

check_file_contains "$CAPTURED_STDOUT" "STDOUT_MARKER" "captured stdout"
check_file_not_contains "$CAPTURED_STDOUT" "STDERR_MARKER" "captured stdout"

check_file_contains "$CAPTURED_STDERR" "STDERR_MARKER" "captured stderr"
check_file_not_contains "$CAPTURED_STDERR" "STDOUT_MARKER" "captured stderr"

check_file_contains "$PL_JOB_STDOUT_PATH" "STDOUT_MARKER" "stdout file"
check_file_not_contains "$PL_JOB_STDOUT_PATH" "STDERR_MARKER" "stdout file"

end_test "good cmd, stdout redirect only"

# 3) Stderr only
begin_test

export PL_JOB_STDERR_PATH="${TEST_DIR}/stderr_file"
run_job "$GOOD_CMD"
check_exit 0

check_file_contains "$CAPTURED_STDOUT" "STDOUT_MARKER" "captured stdout"
check_file_not_contains "$CAPTURED_STDOUT" "STDERR_MARKER" "captured stdout"

check_file_contains "$CAPTURED_STDERR" "STDERR_MARKER" "captured stderr"
check_file_not_contains "$CAPTURED_STDERR" "STDOUT_MARKER" "captured stderr"

check_file_contains "$PL_JOB_STDERR_PATH" "STDERR_MARKER" "stderr file"
check_file_not_contains "$PL_JOB_STDERR_PATH" "STDOUT_MARKER" "stderr file"

end_test "good cmd, stderr redirect only"

# 4) Both to same file
begin_test

export PL_JOB_STDOUT_PATH="${TEST_DIR}/combined_file"
export PL_JOB_STDERR_PATH="${TEST_DIR}/combined_file"
run_job "$GOOD_CMD"
check_exit 0

# stdout goes through stderr's tee, so captured stdout is empty
check_file_empty "$CAPTURED_STDOUT" "captured stdout"

check_file_contains "$CAPTURED_STDERR" "STDOUT_MARKER" "captured stderr"
check_file_contains "$CAPTURED_STDERR" "STDERR_MARKER" "captured stderr"

check_file_contains "$PL_JOB_STDERR_PATH" "STDOUT_MARKER" "combined file"
check_file_contains "$PL_JOB_STDERR_PATH" "STDERR_MARKER" "combined file"

end_test "good cmd, both to same file"

# 5) Both to different files
begin_test

export PL_JOB_STDOUT_PATH="${TEST_DIR}/stdout_file"
export PL_JOB_STDERR_PATH="${TEST_DIR}/stderr_file"
run_job "$GOOD_CMD"
check_exit 0

check_file_contains "$CAPTURED_STDOUT" "STDOUT_MARKER" "captured stdout"
check_file_not_contains "$CAPTURED_STDOUT" "STDERR_MARKER" "captured stdout"

check_file_contains "$CAPTURED_STDERR" "STDERR_MARKER" "captured stderr"
check_file_not_contains "$CAPTURED_STDERR" "STDOUT_MARKER" "captured stderr"

check_file_contains "$PL_JOB_STDOUT_PATH" "STDOUT_MARKER" "stdout file"
check_file_not_contains "$PL_JOB_STDOUT_PATH" "STDERR_MARKER" "stdout file"

check_file_contains "$PL_JOB_STDERR_PATH" "STDERR_MARKER" "stderr file"
check_file_not_contains "$PL_JOB_STDERR_PATH" "STDOUT_MARKER" "stderr file"

end_test "good cmd, both to different files"

# =============================================================================
# Bad command (exit 42)
# =============================================================================

# 6) No redirects
begin_test

run_job "$BAD_CMD"
check_exit 42

check_file_contains "$CAPTURED_STDOUT" "STDOUT_MARKER" "captured stdout"
check_file_not_contains "$CAPTURED_STDOUT" "STDERR_MARKER" "captured stdout"

check_file_contains "$CAPTURED_STDERR" "STDERR_MARKER" "captured stderr"
check_file_not_contains "$CAPTURED_STDERR" "STDOUT_MARKER" "captured stderr"
check_file_contains "$CAPTURED_STDERR" "[job-script] Process exited with code 42" "captured stderr exit hint"
check_file_not_contains "$CAPTURED_STDERR" "out of memory" "captured stderr no OOM hint"

end_test "bad cmd, no redirects"

# 7) Stdout only
begin_test

export PL_JOB_STDOUT_PATH="${TEST_DIR}/stdout_file"
run_job "$BAD_CMD"
check_exit 42

check_file_contains "$CAPTURED_STDOUT" "STDOUT_MARKER" "captured stdout"
check_file_not_contains "$CAPTURED_STDOUT" "STDERR_MARKER" "captured stdout"

check_file_contains "$CAPTURED_STDERR" "STDERR_MARKER" "captured stderr"
check_file_not_contains "$CAPTURED_STDERR" "STDOUT_MARKER" "captured stderr"

check_file_contains "$PL_JOB_STDOUT_PATH" "STDOUT_MARKER" "stdout file"
check_file_not_contains "$PL_JOB_STDOUT_PATH" "STDERR_MARKER" "stdout file"

end_test "bad cmd, stdout redirect only"

# 8) Stderr only
begin_test

export PL_JOB_STDERR_PATH="${TEST_DIR}/stderr_file"
run_job "$BAD_CMD"
check_exit 42

check_file_contains "$CAPTURED_STDOUT" "STDOUT_MARKER" "captured stdout"
check_file_not_contains "$CAPTURED_STDOUT" "STDERR_MARKER" "captured stdout"

check_file_contains "$CAPTURED_STDERR" "STDERR_MARKER" "captured stderr"
check_file_not_contains "$CAPTURED_STDERR" "STDOUT_MARKER" "captured stderr"
check_file_contains "$CAPTURED_STDERR" "[job-script] Process exited with code 42" "captured stderr exit hint"

check_file_contains "$PL_JOB_STDERR_PATH" "STDERR_MARKER" "stderr file"
check_file_not_contains "$PL_JOB_STDERR_PATH" "STDOUT_MARKER" "stderr file"
check_file_contains "$PL_JOB_STDERR_PATH" "[job-script] Process exited with code 42" "stderr file exit hint"

end_test "bad cmd, stderr redirect only"

# 9) Both to same file
begin_test

export PL_JOB_STDOUT_PATH="${TEST_DIR}/combined_file"
export PL_JOB_STDERR_PATH="${TEST_DIR}/combined_file"
run_job "$BAD_CMD"
check_exit 42

check_file_empty "$CAPTURED_STDOUT" "captured stdout"

check_file_contains "$CAPTURED_STDERR" "STDOUT_MARKER" "captured stderr"
check_file_contains "$CAPTURED_STDERR" "STDERR_MARKER" "captured stderr"

check_file_contains "$PL_JOB_STDERR_PATH" "STDOUT_MARKER" "combined file"
check_file_contains "$PL_JOB_STDERR_PATH" "STDERR_MARKER" "combined file"

end_test "bad cmd, both to same file"

# 10) Both to different files
begin_test

export PL_JOB_STDOUT_PATH="${TEST_DIR}/stdout_file"
export PL_JOB_STDERR_PATH="${TEST_DIR}/stderr_file"
run_job "$BAD_CMD"
check_exit 42

check_file_contains "$CAPTURED_STDOUT" "STDOUT_MARKER" "captured stdout"
check_file_not_contains "$CAPTURED_STDOUT" "STDERR_MARKER" "captured stdout"

check_file_contains "$CAPTURED_STDERR" "STDERR_MARKER" "captured stderr"
check_file_not_contains "$CAPTURED_STDERR" "STDOUT_MARKER" "captured stderr"

check_file_contains "$PL_JOB_STDOUT_PATH" "STDOUT_MARKER" "stdout file"
check_file_not_contains "$PL_JOB_STDOUT_PATH" "STDERR_MARKER" "stdout file"

check_file_contains "$PL_JOB_STDERR_PATH" "STDERR_MARKER" "stderr file"
check_file_not_contains "$PL_JOB_STDERR_PATH" "STDOUT_MARKER" "stderr file"

end_test "bad cmd, both to different files"

# =============================================================================
# OOM command (exit 137) — check for memory hint
# =============================================================================

# 11) OOM, no redirects
begin_test

run_job "$OOM_CMD"
check_exit 137

check_file_contains "$CAPTURED_STDERR" "[job-script] Process exited with code 137" "captured stderr exit hint"
check_file_contains "$CAPTURED_STDERR" "out of memory" "captured stderr OOM hint"
check_file_contains "$CAPTURED_STDERR" "more memory" "captured stderr memory suggestion"

end_test "OOM cmd, no redirects"

# 12) OOM, stderr redirect
begin_test

export PL_JOB_STDERR_PATH="${TEST_DIR}/stderr_file"
run_job "$OOM_CMD"
check_exit 137

check_file_contains "$CAPTURED_STDERR" "[job-script] Process exited with code 137" "captured stderr exit hint"
check_file_contains "$CAPTURED_STDERR" "out of memory" "captured stderr OOM hint"

check_file_contains "$PL_JOB_STDERR_PATH" "[job-script] Process exited with code 137" "stderr file exit hint"
check_file_contains "$PL_JOB_STDERR_PATH" "out of memory" "stderr file OOM hint"
check_file_contains "$PL_JOB_STDERR_PATH" "more memory" "stderr file memory suggestion"

end_test "OOM cmd, stderr redirect"

# 13) OOM, both to same file
begin_test

export PL_JOB_STDOUT_PATH="${TEST_DIR}/combined_file"
export PL_JOB_STDERR_PATH="${TEST_DIR}/combined_file"
run_job "$OOM_CMD"
check_exit 137

check_file_contains "$CAPTURED_STDERR" "out of memory" "captured stderr OOM hint"

check_file_contains "$PL_JOB_STDERR_PATH" "[job-script] Process exited with code 137" "combined file exit hint"
check_file_contains "$PL_JOB_STDERR_PATH" "out of memory" "combined file OOM hint"

end_test "OOM cmd, both to same file"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "--- Results: $((TESTS_RUN - TESTS_FAILED))/$TESTS_RUN passed ---"

if [ "$TESTS_FAILED" -ne 0 ]; then
  exit 1
fi
