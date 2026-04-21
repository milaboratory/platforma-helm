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

	k8sutil "github.com/milaboratory/pl/util/k8s"
)

func testValuesPath(t *testing.T) string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	require.True(t, ok, "failed to determine test file path")
	return filepath.Join(filepath.Dir(thisFile), "test-values.yaml")
}

func helmTemplateWatchConfigYAML(t *testing.T) string {
	t.Helper()

	chartDir := "../../../charts/platforma/"

	_, err := os.Stat(chartDir + "Chart.yaml")
	require.NoError(t, err, "Chart.yaml not found — run test from helm/tests/charts/platforma/")

	cmd := exec.Command("helm", "template", "test-release", chartDir,
		"--values", testValuesPath(t),
	)
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "helm template failed: %s", string(out))

	docs := strings.Split(string(out), "---")
	for _, doc := range docs {
		if !strings.Contains(doc, "kind: ConfigMap") || !strings.Contains(doc, "watch-config.yaml") {
			continue
		}
		data := extractConfigMapValue(t, doc, "watch-config.yaml")
		require.NotEmpty(t, data, "watch-config.yaml not found in any rendered ConfigMap")
		return data
	}

	t.Fatal("watch-config ConfigMap not found in helm template output")
	return ""
}

// extractConfigMapValue extracts a block scalar value from a ConfigMap YAML document.
func extractConfigMapValue(t *testing.T, doc string, key string) string {
	t.Helper()

	lines := strings.Split(doc, "\n")
	inData := false
	inValue := false
	var valueLines []string
	valueIndent := 0

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)

		if trimmed == "data:" {
			inData = true
			continue
		}

		if !inData {
			continue
		}

		if !inValue && strings.HasPrefix(trimmed, key+":") {
			after := strings.TrimPrefix(trimmed, key+":")
			after = strings.TrimSpace(after)
			if after == "|" {
				inValue = true
				valueIndent = 0
				continue
			}
			return after
		}

		if inValue {
			if valueIndent == 0 && len(strings.TrimSpace(line)) > 0 {
				valueIndent = len(line) - len(strings.TrimLeft(line, " "))
			}

			currentIndent := len(line) - len(strings.TrimLeft(line, " "))
			if len(strings.TrimSpace(line)) > 0 && currentIndent < valueIndent {
				break
			}

			if valueIndent > 0 && len(line) >= valueIndent {
				valueLines = append(valueLines, line[valueIndent:])
			} else {
				valueLines = append(valueLines, "")
			}
		}
	}

	return strings.Join(valueLines, "\n")
}

func TestHelmWatchConfig_Compiles(t *testing.T) {
	if os.Getenv("HELM_TEST") != "true" {
		t.Skip("skipping helm tests because HELM_TEST=true")
	}
	raw := helmTemplateWatchConfigYAML(t)

	// Replace Go template delimiters with concrete values so YAML is valid
	cleaned := strings.ReplaceAll(raw, "<< .JobID >>", "test-job-id")

	compiled, err := k8sutil.ParseWatchConfig([]byte(cleaned))
	require.NoError(t, err, "watch config must compile without errors")

	assert.Equal(t, "workload.codeflare.dev", compiled.GVR.Group)
	assert.Equal(t, "v1beta2", compiled.GVR.Version)
	assert.Equal(t, "appwrappers", compiled.GVR.Resource)
	assert.Equal(t, "test-job-id", compiled.LabelSelector["platforma.bio/job-id"])
}
