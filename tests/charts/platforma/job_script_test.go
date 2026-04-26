package tests

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func scriptPath(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	require.True(t, ok, "failed to determine test file path")
	return filepath.Join(filepath.Dir(thisFile), "..", "..", "..", "charts", "platforma", "files", "job-script.sh")
}

// runJobScript executes job-script.sh with the given env vars and returns
// captured stdout, stderr and the process exit code.
func runJobScript(t *testing.T, env map[string]string) (stdout, stderr string, exitCode int) {
	t.Helper()

	script := scriptPath(t)
	require.FileExists(t, script, "job-script.sh must exist")

	cmd := exec.Command("sh", script)
	// Start with a clean environment, inheriting only PATH and HOME.
	cmd.Env = append(os.Environ()[:0],
		"PATH="+os.Getenv("PATH"),
		"HOME="+os.Getenv("HOME"),
	)
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}

	var stdoutBuf, stderrBuf strings.Builder
	cmd.Stdout = &stdoutBuf
	cmd.Stderr = &stderrBuf

	err := cmd.Run()

	exitCode = 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			t.Fatalf("failed to run job-script.sh: %v", err)
		}
	}

	return stdoutBuf.String(), stderrBuf.String(), exitCode
}

func readFileContent(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	require.NoError(t, err, "reading file %s", path)
	return string(data)
}

// --- Success cases ---

func TestSuccessNoRedirects(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST!=true")
	}
	stdout, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": `printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2`,
	})

	assert.Equal(t, 0, exitCode)
	assert.Contains(t, stdout, "STDOUT_MARKER")
	assert.NotContains(t, stdout, "STDERR_MARKER")
	assert.Contains(t, stderr, "STDERR_MARKER")
	assert.NotContains(t, stderr, "STDOUT_MARKER")
}

func TestSuccessStdoutRedirectOnly(t *testing.T) {
	tmpDir := t.TempDir()
	stdoutPath := filepath.Join(tmpDir, "stdout_file")

	stdout, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": `printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2`,
		"PL_JOB_STDOUT_PATH":  stdoutPath,
	})

	assert.Equal(t, 0, exitCode)

	assert.Contains(t, stdout, "STDOUT_MARKER")
	assert.NotContains(t, stdout, "STDERR_MARKER")
	assert.Contains(t, stderr, "STDERR_MARKER")
	assert.NotContains(t, stderr, "STDOUT_MARKER")

	fileContent := readFileContent(t, stdoutPath)
	assert.Contains(t, fileContent, "STDOUT_MARKER")
	assert.NotContains(t, fileContent, "STDERR_MARKER")
}

func TestSuccessStderrRedirectOnly(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST!=true")
	}

	tmpDir := t.TempDir()
	stderrPath := filepath.Join(tmpDir, "stderr_file")

	stdout, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": `printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2`,
		"PL_JOB_STDERR_PATH":  stderrPath,
	})

	assert.Equal(t, 0, exitCode)

	assert.Contains(t, stdout, "STDOUT_MARKER")
	assert.NotContains(t, stdout, "STDERR_MARKER")
	assert.Contains(t, stderr, "STDERR_MARKER")
	assert.NotContains(t, stderr, "STDOUT_MARKER")

	fileContent := readFileContent(t, stderrPath)
	assert.Contains(t, fileContent, "STDERR_MARKER")
	assert.NotContains(t, fileContent, "STDOUT_MARKER")
}

func TestSuccessBothRedirectsSameFile(t *testing.T) {
	tmpDir := t.TempDir()
	combinedPath := filepath.Join(tmpDir, "combined_file")

	stdout, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": `printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2`,
		"PL_JOB_STDOUT_PATH":  combinedPath,
		"PL_JOB_STDERR_PATH":  combinedPath,
	})

	assert.Equal(t, 0, exitCode)

	// When both redirect to same file, stdout goes through stderr's tee,
	// so captured stdout should be empty.
	assert.Empty(t, stdout)
	assert.Contains(t, stderr, "STDOUT_MARKER")
	assert.Contains(t, stderr, "STDERR_MARKER")

	fileContent := readFileContent(t, combinedPath)
	assert.Contains(t, fileContent, "STDOUT_MARKER")
	assert.Contains(t, fileContent, "STDERR_MARKER")
}

func TestSuccessBothRedirectsDifferentFiles(t *testing.T) {
	tmpDir := t.TempDir()
	stdoutPath := filepath.Join(tmpDir, "stdout_file")
	stderrPath := filepath.Join(tmpDir, "stderr_file")

	stdout, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": `printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2`,
		"PL_JOB_STDOUT_PATH":  stdoutPath,
		"PL_JOB_STDERR_PATH":  stderrPath,
	})

	assert.Equal(t, 0, exitCode)

	assert.Contains(t, stdout, "STDOUT_MARKER")
	assert.NotContains(t, stdout, "STDERR_MARKER")
	assert.Contains(t, stderr, "STDERR_MARKER")
	assert.NotContains(t, stderr, "STDOUT_MARKER")

	stdoutContent := readFileContent(t, stdoutPath)
	assert.Contains(t, stdoutContent, "STDOUT_MARKER")
	assert.NotContains(t, stdoutContent, "STDERR_MARKER")

	stderrContent := readFileContent(t, stderrPath)
	assert.Contains(t, stderrContent, "STDERR_MARKER")
	assert.NotContains(t, stderrContent, "STDOUT_MARKER")
}

// --- Failure cases ---

func TestFailureNoRedirects(t *testing.T) {
	stdout, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": `printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2; exit 42`,
	})

	assert.Equal(t, 42, exitCode)
	assert.Contains(t, stdout, "STDOUT_MARKER")
	assert.Contains(t, stderr, "STDERR_MARKER")
}

func TestFailureStdoutRedirectOnly(t *testing.T) {
	tmpDir := t.TempDir()
	stdoutPath := filepath.Join(tmpDir, "stdout_file")

	stdout, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": `printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2; exit 42`,
		"PL_JOB_STDOUT_PATH":  stdoutPath,
	})

	assert.Equal(t, 42, exitCode)

	assert.Contains(t, stdout, "STDOUT_MARKER")
	assert.Contains(t, stderr, "STDERR_MARKER")

	fileContent := readFileContent(t, stdoutPath)
	assert.Contains(t, fileContent, "STDOUT_MARKER")
	assert.NotContains(t, fileContent, "STDERR_MARKER")
}

func TestFailureStderrRedirectOnly(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST!=true")
	}

	tmpDir := t.TempDir()
	stderrPath := filepath.Join(tmpDir, "stderr_file")

	stdout, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": `printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2; exit 42`,
		"PL_JOB_STDERR_PATH":  stderrPath,
	})

	assert.Equal(t, 42, exitCode)

	assert.Contains(t, stdout, "STDOUT_MARKER")
	assert.Contains(t, stderr, "STDERR_MARKER")

	fileContent := readFileContent(t, stderrPath)
	assert.Contains(t, fileContent, "STDERR_MARKER")
	assert.NotContains(t, fileContent, "STDOUT_MARKER")
}

func TestFailureBothRedirectsSameFile(t *testing.T) {
	tmpDir := t.TempDir()
	combinedPath := filepath.Join(tmpDir, "combined_file")

	stdout, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": `printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2; exit 42`,
		"PL_JOB_STDOUT_PATH":  combinedPath,
		"PL_JOB_STDERR_PATH":  combinedPath,
	})

	assert.Equal(t, 42, exitCode)
	assert.Empty(t, stdout)
	assert.Contains(t, stderr, "STDOUT_MARKER")
	assert.Contains(t, stderr, "STDERR_MARKER")

	fileContent := readFileContent(t, combinedPath)
	assert.Contains(t, fileContent, "STDOUT_MARKER")
	assert.Contains(t, fileContent, "STDERR_MARKER")
}

func TestFailureBothRedirectsDifferentFiles(t *testing.T) {
	tmpDir := t.TempDir()
	stdoutPath := filepath.Join(tmpDir, "stdout_file")
	stderrPath := filepath.Join(tmpDir, "stderr_file")

	stdout, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": `printf "STDOUT_MARKER\n"; printf "STDERR_MARKER\n" >&2; exit 42`,
		"PL_JOB_STDOUT_PATH":  stdoutPath,
		"PL_JOB_STDERR_PATH":  stderrPath,
	})

	assert.Equal(t, 42, exitCode)

	assert.Contains(t, stdout, "STDOUT_MARKER")
	assert.Contains(t, stderr, "STDERR_MARKER")

	stdoutContent := readFileContent(t, stdoutPath)
	assert.Contains(t, stdoutContent, "STDOUT_MARKER")
	assert.NotContains(t, stdoutContent, "STDERR_MARKER")

	stderrContent := readFileContent(t, stderrPath)
	assert.Contains(t, stderrContent, "STDERR_MARKER")
	assert.NotContains(t, stderrContent, "STDOUT_MARKER")
}

// --- PATH prepend ---

// --- Workdir prune tests ---

func TestPruneRemovesUnexpectedFiles(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST!=true")
	}

	tmpDir := t.TempDir()
	workdir := filepath.Join(tmpDir, "workdir")
	require.NoError(t, os.MkdirAll(workdir, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "expected.txt"), []byte("data"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "leftover.bin"), []byte("stale"), 0o644))

	_, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS":   "true",
		"PL_JOB_WORKDIR":        workdir,
		"PL_JOB_EXPECTED_ITEMS": "expected.txt",
	})

	assert.Equal(t, 0, exitCode)
	assert.FileExists(t, filepath.Join(workdir, "expected.txt"))
	assert.NoFileExists(t, filepath.Join(workdir, "leftover.bin"))
	assert.Contains(t, stderr, "Pruning unexpected file: leftover.bin")
}

func TestPruneNestedPaths(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST!=true")
	}

	tmpDir := t.TempDir()
	workdir := filepath.Join(tmpDir, "workdir")
	require.NoError(t, os.MkdirAll(filepath.Join(workdir, "subdir"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "subdir", "nested.txt"), []byte("keep"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "subdir", "stale.bin"), []byte("stale"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "top.txt"), []byte("top"), 0o644))

	_, _, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS":   "true",
		"PL_JOB_WORKDIR":        workdir,
		"PL_JOB_EXPECTED_ITEMS": "subdir/nested.txt\ntop.txt",
	})

	assert.Equal(t, 0, exitCode)
	assert.FileExists(t, filepath.Join(workdir, "subdir", "nested.txt"))
	assert.FileExists(t, filepath.Join(workdir, "top.txt"))
	assert.NoFileExists(t, filepath.Join(workdir, "subdir", "stale.bin"))
}

func TestPruneNoOpWhenEnvUnset(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST!=true")
	}

	tmpDir := t.TempDir()
	workdir := filepath.Join(tmpDir, "workdir")
	require.NoError(t, os.MkdirAll(workdir, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "file1.txt"), []byte("data"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "file2.txt"), []byte("data"), 0o644))

	_, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": "true",
		"PL_JOB_WORKDIR":      workdir,
		// PL_JOB_EXPECTED_ITEMS intentionally not set
	})

	assert.Equal(t, 0, exitCode)
	assert.FileExists(t, filepath.Join(workdir, "file1.txt"))
	assert.FileExists(t, filepath.Join(workdir, "file2.txt"))
	assert.NotContains(t, stderr, "Pruning")
}

func TestPruneEmptyWorkdir(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST!=true")
	}

	tmpDir := t.TempDir()
	workdir := filepath.Join(tmpDir, "workdir")
	require.NoError(t, os.MkdirAll(workdir, 0o755))

	_, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS":   "true",
		"PL_JOB_WORKDIR":        workdir,
		"PL_JOB_EXPECTED_ITEMS": "some.txt",
	})

	assert.Equal(t, 0, exitCode)
	assert.NotContains(t, stderr, "Pruning")
}

func TestPruneFilesWithSpaces(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST!=true")
	}

	tmpDir := t.TempDir()
	workdir := filepath.Join(tmpDir, "workdir")
	require.NoError(t, os.MkdirAll(workdir, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "file with spaces.txt"), []byte("keep"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "stale file.bin"), []byte("stale"), 0o644))

	_, _, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS":   "true",
		"PL_JOB_WORKDIR":        workdir,
		"PL_JOB_EXPECTED_ITEMS": "file with spaces.txt",
	})

	assert.Equal(t, 0, exitCode)
	assert.FileExists(t, filepath.Join(workdir, "file with spaces.txt"))
	assert.NoFileExists(t, filepath.Join(workdir, "stale file.bin"))
}

func TestPrunePreservesExpectedDirectories(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST!=true")
	}

	tmpDir := t.TempDir()
	workdir := filepath.Join(tmpDir, "workdir")
	require.NoError(t, os.MkdirAll(filepath.Join(workdir, "expected_empty"), 0o755))
	require.NoError(t, os.MkdirAll(filepath.Join(workdir, "unexpected_empty"), 0o755))
	require.NoError(t, os.MkdirAll(filepath.Join(workdir, "subdir"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "subdir", "keep.txt"), []byte("keep"), 0o644))

	_, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS":   "true",
		"PL_JOB_WORKDIR":        workdir,
		"PL_JOB_EXPECTED_ITEMS": "subdir/keep.txt\nexpected_empty/",
	})

	assert.Equal(t, 0, exitCode)
	assert.FileExists(t, filepath.Join(workdir, "subdir", "keep.txt"))
	assert.DirExists(t, filepath.Join(workdir, "expected_empty"), "expected empty dir should be preserved")
	assert.NoDirExists(t, filepath.Join(workdir, "unexpected_empty"), "unexpected empty dir should be removed")
	assert.Contains(t, stderr, "Pruning")
}

func TestPruneRemovesUnexpectedDirectories(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST!=true")
	}

	tmpDir := t.TempDir()
	workdir := filepath.Join(tmpDir, "workdir")
	// Simulate OOM retry: pframe_1 dir with partial output left from previous attempt
	require.NoError(t, os.MkdirAll(filepath.Join(workdir, "pframe_1", "subdir"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "pframe_1", "data.bin"), []byte("stale"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "pframe_1", "subdir", "nested.bin"), []byte("stale"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "input.txt"), []byte("input"), 0o644))

	_, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS":   "true",
		"PL_JOB_WORKDIR":        workdir,
		"PL_JOB_EXPECTED_ITEMS": "input.txt",
	})

	assert.Equal(t, 0, exitCode)
	assert.FileExists(t, filepath.Join(workdir, "input.txt"))
	assert.NoDirExists(t, filepath.Join(workdir, "pframe_1"), "stale output dir should be removed entirely")
	assert.Contains(t, stderr, "Pruning unexpected file")
	assert.Contains(t, stderr, "Pruning")
}

func TestPruneCleanExpectedDirContents(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST!=true")
	}

	tmpDir := t.TempDir()
	workdir := filepath.Join(tmpDir, "workdir")
	// Expected dir with stale contents from OOM-killed run
	require.NoError(t, os.MkdirAll(filepath.Join(workdir, "output"), 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "output", "stale.bin"), []byte("stale"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(workdir, "input.txt"), []byte("input"), 0o644))

	_, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS":   "true",
		"PL_JOB_WORKDIR":        workdir,
		"PL_JOB_EXPECTED_ITEMS": "input.txt\noutput/",
	})

	assert.Equal(t, 0, exitCode)
	assert.FileExists(t, filepath.Join(workdir, "input.txt"))
	assert.DirExists(t, filepath.Join(workdir, "output"), "expected dir should be preserved")
	assert.NoFileExists(t, filepath.Join(workdir, "output", "stale.bin"), "stale file inside expected dir should be removed")
	assert.Contains(t, stderr, "Pruning unexpected file: output/stale.bin")
}

func TestJobPathPrepend(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST!=true")
	}

	tmpDir := t.TempDir()

	// Create a custom script in a temp directory that the job should find via PL_JOB_PATH
	customBin := filepath.Join(tmpDir, "my-custom-cmd")
	err := os.WriteFile(customBin, []byte("#!/bin/sh\necho CUSTOM_PATH_WORKS\n"), 0o755)
	require.NoError(t, err)

	stdout, _, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": "my-custom-cmd",
		"PL_JOB_PATH":         tmpDir,
	})

	assert.Equal(t, 0, exitCode)
	assert.Contains(t, stdout, "CUSTOM_PATH_WORKS")
}

// --- Completion marker ---

func TestCompletionMarkerWrittenOnSuccess(t *testing.T) {
	tmpDir := t.TempDir()
	markerPath := filepath.Join(tmpDir, ".pl_completed")

	_, _, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS":           "exit 0",
		"PL_JOB_COMPLETION_MARKER_PATH": markerPath,
	})

	assert.Equal(t, 0, exitCode)
	content := readFileContent(t, markerPath)
	assert.Contains(t, content, "0")
}

func TestCompletionMarkerWrittenOnFailure(t *testing.T) {
	tmpDir := t.TempDir()
	markerPath := filepath.Join(tmpDir, ".pl_completed")

	_, _, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS":           "exit 42",
		"PL_JOB_COMPLETION_MARKER_PATH": markerPath,
	})

	assert.Equal(t, 42, exitCode)
	content := readFileContent(t, markerPath)
	assert.Contains(t, content, "42")
}

func TestCompletionMarkerNotWrittenWhenUnset(t *testing.T) {
	tmpDir := t.TempDir()
	markerPath := filepath.Join(tmpDir, ".pl_completed")

	_, _, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS": "exit 0",
	})

	assert.Equal(t, 0, exitCode)
	assert.NoFileExists(t, markerPath)
}

func TestCompletionMarkerWrittenOnOOMExitCode(t *testing.T) {
	tmpDir := t.TempDir()
	markerPath := filepath.Join(tmpDir, ".pl_completed")

	_, stderr, exitCode := runJobScript(t, map[string]string{
		"PL_JOB_CMD_AND_ARGS":           "exit 137",
		"PL_JOB_COMPLETION_MARKER_PATH": markerPath,
	})

	assert.Equal(t, 137, exitCode)
	assert.Contains(t, stderr, "out of memory")
	content := readFileContent(t, markerPath)
	assert.Contains(t, content, "137")
}

func TestCompletionMarkerNotWrittenWhenKilled(t *testing.T) {
	tmpDir := t.TempDir()
	markerPath := filepath.Join(tmpDir, ".pl_completed")

	script := scriptPath(t)
	cmd := exec.Command("sh", script)
	sentinelPath := filepath.Join(tmpDir, ".started")
	cmd.Env = append(os.Environ()[:0],
		"PATH="+os.Getenv("PATH"),
		"HOME="+os.Getenv("HOME"),
		"PL_JOB_CMD_AND_ARGS=touch "+sentinelPath+" && sleep 60",
		"PL_JOB_COMPLETION_MARKER_PATH="+markerPath,
	)
	// Use process group so SIGKILL reaches the whole tree
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	require.NoError(t, cmd.Start())

	// Wait until the command has started (sentinel proves script reached execution)
	require.Eventually(t, func() bool {
		_, err := os.Stat(sentinelPath)
		return err == nil
	}, 5*time.Second, 50*time.Millisecond)

	// Kill the entire process group (simulates OOM kill)
	require.NoError(t, syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL))
	_ = cmd.Wait()

	assert.NoFileExists(t, markerPath)
}
