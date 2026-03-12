package tests

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func scriptPath(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	require.True(t, ok, "failed to determine test file path")
	return filepath.Join(filepath.Dir(thisFile), "..", "files", "job-script.sh")
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

func TestJobPathPrepend(t *testing.T) {
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
