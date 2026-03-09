#!/bin/sh
set -e
set -u

# Prepend PL_JOB_PATH to PATH if set
if [ -n "${PL_JOB_PATH:-}" ]; then
  export PATH="${PL_JOB_PATH}:${PATH}"
fi

# Save 'real stdout' and 'real stderr' of current script in descriptors 3 and 4
exec 3>&1 4>&2

# --- Stderr redirection: tee stderr to file ---
if [ -n "${PL_JOB_STDERR_PATH:-}" ]; then
  # Create named pipe for stderr redirection
  STDERR_FIFO=$(mktemp -u /tmp/stderr_fifo.XXXXXX)
  mkfifo "$STDERR_FIFO"

  # Duplicate all data received from named pipe to descripor 4 (real stderr) and file
  tee -a "${PL_JOB_STDERR_PATH}" >&4 < "$STDERR_FIFO" &

  # Redirect entire stderr of current script to named pipe.
  exec 2>"$STDERR_FIFO"

  # We now have:
  # - tee reading from named pipe and writing to real stderr (descriptor 4) and desired redirect file
  # - script writing its stderr to that named pipe.
  # All commands executed by this script now have their stderr writing to 'tee' command via named pipe.
fi

# --- Stdout redirection: tee stdout to file ---
if [ -n "${PL_JOB_STDOUT_PATH:-}" ]; then
  if [ "${PL_JOB_STDOUT_PATH:-}" = "${PL_JOB_STDERR_PATH:-}" ]; then
    # When stderr == stdout, we can just make 'stdout' to write to the same named pipe, as stderr.
    exec 1>&2
  else
    # Do the same magic for stdout (see comments above)
    STDOUT_FIFO=$(mktemp -u /tmp/stdout_fifo.XXXXXX)
    mkfifo "$STDOUT_FIFO"
    tee -a "${PL_JOB_STDOUT_PATH}" >&3 < "$STDOUT_FIFO" &
    exec 1>"$STDOUT_FIFO"

    # We now have:
    # - tee reading from named pipe and writing to real stdout (descriptor 3) and desired redirect file
    # - script writing its stdout to that named pipe
  fi
fi

# --- Run the command, capture its exit code ---

set +e # we should not interrupt script until 'tee' commands finish and flush their buffers to files

# Thanks to earlier preparations, command run here sends its stdout/err to 'tee' commands.
# Both streams then appear both in job's logs and in files.
sh -c "$PL_JOB_CMD_AND_ARGS"

# As we disabled 'errexit' shell option, we need to save exit code for later explicit 'exit' call
# otherwise, shell script will always exit with 0
EXIT_CODE=$?

# --- Report non-zero exit code ---
if [ "$EXIT_CODE" -ne 0 ]; then
  echo "[job-script] Process exited with code ${EXIT_CODE}" >&2
  if [ "$EXIT_CODE" -eq 137 ]; then
    echo "[job-script] The process was killed (likely out of memory). Consider running this job with more memory." >&2
  fi
fi

# --- Cleanup ---

# Close additional descriptors we had. If we had 'tee' attached to them, they will get
# EOF reading from named pipes, flush their buffers and exit.
# If we had no out/err redirection, this is noop.
exec 1>&3 3>&- 2>&4 4>&-

# Wait for 'tee' commands to finish (if any)
wait

# Drop named pipes (if any)
[ -n "${STDOUT_FIFO:-}" ] && rm -f "$STDOUT_FIFO"
[ -n "${STDERR_FIFO:-}" ] && rm -f "$STDERR_FIFO"

exit "$EXIT_CODE"
