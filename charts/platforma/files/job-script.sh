#!/bin/sh
set -e
set -u

# Prepend GPU driver paths (set by the chart when the job runs on a GPU node).
# Done at runtime, not via k8s env, because k8s env can't reference $(PATH) /
# $(LD_LIBRARY_PATH) from the container image — setting them statically would
# wipe image-provided entries (e.g. conda's /opt/conda/bin).
if [ -n "${PL_GPU_BIN_PATH:-}" ]; then
  export PATH="${PL_GPU_BIN_PATH}:${PATH}"
fi
if [ -n "${PL_GPU_LIB_PATH:-}" ]; then
  export LD_LIBRARY_PATH="${PL_GPU_LIB_PATH}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

# Prepend PL_JOB_PATH to PATH if set. Applied after PL_GPU_BIN_PATH so
# runenv-provided entries (e.g. a conda env's bin) win over GPU paths.
if [ -n "${PL_JOB_PATH:-}" ]; then
  export PATH="${PL_JOB_PATH}:${PATH}"
fi

# --- The command's temporary directory ---
# One path on every infrastructure: backed by a scratch volume the job template mounts here where
# the cluster has scratch storage, by the working directory's own filesystem where it has not.
# TMPDIR and TMP point at it for every command that asked for one.
#
# The prune below must not walk into it. This script's own mktemp files land there when TMPDIR does,
# so pruning it would delete the expected-items lists mid-run and make every real item look
# unexpected. It is emptied instead, once the prune is done and before the command starts.
PL_JOB_TMPDIR="${PL_JOB_WORKDIR:-}/.pl/tmp"

# --- Prune unexpected items from workdir ---
# Removes leftover output from OOM-killed retries so they don't consume memory.
# The expected items are a newline-separated list of relative paths.
# Files are plain paths (e.g. "input.txt"), directories end with "/" (e.g. "output_dir/").
# Expected files are kept. Expected directories are kept but their unexpected contents are cleaned.
# Unexpected files and directories are removed entirely.
#
# The list arrives as PL_JOB_EXPECTED_ITEMS_FILE, a path inside the workdir. It is never passed
# by value: a single env var is capped at MAX_ARG_STRLEN (131072 bytes), which a workdir of more
# than ~7300 files exceeds, and execve then fails with E2BIG before this script runs.
# When unset, no pruning occurs. An items file that is missing or empty also means no pruning —
# pruning against an empty list would wipe the whole workdir.
#
# Matching runs through awk, which holds the expected list in a hash. Spawning a grep per workdir
# entry instead is quadratic: on the 9000-file workdir that motivated the file-based list it costs
# ~27s of pure CPU before every job start, and again on every OOM retry. awk ships with busybox,
# but this image comes from the user's software package, so a missing awk downgrades to no pruning
# rather than killing the job.
if [ -n "${PL_JOB_EXPECTED_ITEMS_FILE:-}" ] && [ -s "${PL_JOB_EXPECTED_ITEMS_FILE}" ] \
  && [ -n "${PL_JOB_WORKDIR:-}" ] && [ -d "${PL_JOB_WORKDIR}" ] \
  && command -v awk >/dev/null 2>&1; then
  _expected_files=$(mktemp)
  _expected_dirs=$(mktemp)
  trap 'rm -f "$_expected_files" "$_expected_dirs"' EXIT INT TERM

  # Split items into files and directories (dirs end with /)
  awk -v files="$_expected_files" -v dirs="$_expected_dirs" '
    $0 == "" { next }
    /\/$/ { print > dirs; next }
    { print > files }
  ' "$PL_JOB_EXPECTED_ITEMS_FILE"

  # Prune unexpected files. awk emits only the paths to remove, so the shell loop below runs
  # once per pruned file rather than once per workdir file.
  find "$PL_JOB_WORKDIR" -path "${PL_JOB_TMPDIR}" -prune -o -type f -print \
    | awk -v prefix="${PL_JOB_WORKDIR}/" -v expected="$_expected_files" '
        BEGIN { while ((getline _line < expected) > 0) keep[_line] = 1 }
        {
          _rel = (index($0, prefix) == 1) ? substr($0, length(prefix) + 1) : $0
          if (!(_rel in keep)) print
        }
      ' \
    | while IFS= read -r _abs_path; do
        _rel_path="${_abs_path#"${PL_JOB_WORKDIR}/"}"
        echo "[job-script] Pruning unexpected file: ${_rel_path}" >&2
        rm -f "$_abs_path"
      done

  # Prune unexpected directories, depth-first so nested ones go before their parents.
  #
  # One awk holds both expected lists in memory and decides every directory, the way the file pass
  # above does. The previous shape spawned a grep AND an awk per directory, which is a process pair
  # per workdir entry: on a workdir of any size that dominates the whole prune. awk emits only the
  # directories to remove, so the shell loop runs once per removal rather than once per directory.
  find "$PL_JOB_WORKDIR" -path "${PL_JOB_TMPDIR}" -prune -o -depth -type d ! -path "$PL_JOB_WORKDIR" -print \
    | awk -v prefix="${PL_JOB_WORKDIR}/" -v files="$_expected_files" -v dirs="$_expected_dirs" '
        BEGIN {
          while ((getline _line < files) > 0) { expected_files[_line] = 1; all[_n++] = _line }
          while ((getline _line < dirs) > 0)  { expected_dirs[_line] = 1;  all[_n++] = _line }
        }
        {
          _rel = (index($0, prefix) == 1) ? substr($0, length(prefix) + 1) : $0
          if ((_rel "/") in expected_dirs) next

          # Keep a directory that an expected item lives under. index() is a literal prefix test,
          # so a path holding regex metacharacters compares the way the shell case used to.
          _pre = _rel "/"
          for (_i = 0; _i < _n; _i++) {
            if (index(all[_i], _pre) == 1) next
          }

          print
        }
      ' \
    | while IFS= read -r _abs_dir; do
        _rel_dir="${_abs_dir#"${PL_JOB_WORKDIR}/"}"
        if rmdir "$_abs_dir" 2>/dev/null; then
          echo "[job-script] Pruning empty directory: ${_rel_dir}" >&2
        else
          echo "[job-script] Pruning unexpected directory: ${_rel_dir}" >&2
          rm -rf "$_abs_dir"
        fi
      done

elif [ -n "${PL_JOB_EXPECTED_ITEMS_FILE:-}" ] && ! command -v awk >/dev/null 2>&1; then
  echo "[job-script] awk not found in image: skipping workdir prune" >&2
fi

# Empty the temporary directory, whether or not the prune ran: the command must start on a clean
# one. Doing it here rather than after the command is what makes it self-healing - an attempt the
# OOM reaper kills never reaches its own cleanup, and the next attempt clears what it left.
#
# find streams and -delete removes as it goes, so a directory of a million temporary files costs no
# shell memory and no glob expansion. The expected-items lists go with it; they have done their job.
if [ -n "${PL_JOB_WORKDIR:-}" ] && [ -d "${PL_JOB_TMPDIR}" ]; then
  find "${PL_JOB_TMPDIR}" -mindepth 1 -delete 2>/dev/null || true
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
# The marker lives in the workdir's reserved service directory, which the runner only creates
# when it has an item list to write, so create it here too. Its absence is read as an OOM kill.
if [ -n "${PL_JOB_COMPLETION_MARKER_PATH:-}" ]; then
  mkdir -p "$(dirname "$PL_JOB_COMPLETION_MARKER_PATH")"
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
