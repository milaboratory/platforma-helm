#!/bin/sh
set -e
set -u

# Prepend PL_JOB_PATH to PATH if set
if [ -n "${PL_JOB_PATH:-}" ]; then
  export PATH="${PL_JOB_PATH}:${PATH}"
fi

# --- Prune unexpected items from workdir ---
# Removes leftover output from OOM-killed retries so they don't consume memory.
# PL_JOB_EXPECTED_ITEMS is a newline-separated list of relative paths.
# Files are plain paths (e.g. "input.txt"), directories end with "/" (e.g. "output_dir/").
# Expected files are kept. Expected directories are kept but their unexpected contents are cleaned.
# Unexpected files and directories are removed entirely.
# When unset, no pruning occurs (backward compat).
if [ -n "${PL_JOB_EXPECTED_ITEMS:-}" ] && [ -n "${PL_JOB_WORKDIR:-}" ] && [ -d "${PL_JOB_WORKDIR}" ]; then
  _expected_files=$(mktemp)
  _expected_dirs=$(mktemp)
  trap 'rm -f "$_expected_files" "$_expected_dirs"' EXIT INT TERM

  # Split items into files and directories (dirs end with /)
  printf '%s\n' "$PL_JOB_EXPECTED_ITEMS" | while IFS= read -r _item; do
    case "$_item" in
      */) printf '%s\n' "$_item" >> "$_expected_dirs" ;;
      *)  printf '%s\n' "$_item" >> "$_expected_files" ;;
    esac
  done

  # Prune unexpected files
  find "$PL_JOB_WORKDIR" -type f | while IFS= read -r _abs_path; do
    _rel_path="${_abs_path#"${PL_JOB_WORKDIR}/"}"
    if ! grep -qxF "$_rel_path" "$_expected_files"; then
      echo "[job-script] Pruning unexpected file: ${_rel_path}" >&2
      rm -f "$_abs_path"
    fi
  done

  # Prune unexpected directories (depth-first to handle nested dirs correctly)
  find "$PL_JOB_WORKDIR" -depth -type d ! -path "$PL_JOB_WORKDIR" | while IFS= read -r _abs_dir; do
    _rel_dir="${_abs_dir#"${PL_JOB_WORKDIR}/"}"
    _rel_dir_slash="${_rel_dir}/"

    # Check if this directory is expected
    if grep -qxF "$_rel_dir_slash" "$_expected_dirs"; then
      continue
    fi

    # Check if this directory is an ancestor of an expected item
    _is_ancestor=false
    while IFS= read -r _exp_item; do
      case "$_exp_item" in
        "${_rel_dir}/"*) _is_ancestor=true; break ;;
      esac
    done < "$_expected_files"

    if [ "$_is_ancestor" = false ] && [ -s "$_expected_dirs" ]; then
      while IFS= read -r _exp_dir; do
        case "$_exp_dir" in
          "${_rel_dir}/"*) _is_ancestor=true; break ;;
        esac
      done < "$_expected_dirs"
    fi

    if [ "$_is_ancestor" = true ]; then
      continue
    fi

    # Not expected and not an ancestor — remove if empty, or force remove
    if rmdir "$_abs_dir" 2>/dev/null; then
      echo "[job-script] Pruning empty directory: ${_rel_dir}" >&2
    else
      echo "[job-script] Pruning unexpected directory: ${_rel_dir}" >&2
      rm -rf "$_abs_dir"
    fi
  done

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

# Write completion marker (signals script was NOT OOM-killed)
if [ -n "${PL_JOB_COMPLETION_MARKER_PATH:-}" ]; then
  echo "$EXIT_CODE" > "$PL_JOB_COMPLETION_MARKER_PATH"
fi

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
