package tests

import (
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type watchConfig struct {
	GVR struct {
		Group    string `json:"group"`
		Version  string `json:"version"`
		Resource string `json:"resource"`
	} `json:"gvr"`
	LabelSelector     map[string]string `json:"labelSelector"`
	StatusExpressions struct {
		IsRunning     string `json:"isRunning"`
		IsFailed      string `json:"isFailed"`
		IsCompleted   string `json:"isCompleted"`
		FailureDetail string `json:"failureDetail"`
	} `json:"statusExpressions"`
}

func helmTemplateWatchConfig(t *testing.T) watchConfig {
	t.Helper()

	chartDir := "../"

	_, err := os.Stat(chartDir + "Chart.yaml")
	require.NoError(t, err, "Chart.yaml not found — run test from helm/charts/platforma/tests/")

	cmd := exec.Command("helm", "template", "test-release", chartDir,
		"--set", "storage.workspace.pvc.enabled=true",
		"--set", "app.extraArgs[0]=--no-auth",
		"--set", "storage.main.type=s3",
		"--set", "storage.main.s3.bucket=test",
		"--set", "storage.main.s3.region=us-east-1",
	)
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "helm template failed: %s", string(out))

	docs := strings.Split(string(out), "---")
	var watchConfigData string
	for _, doc := range docs {
		if !strings.Contains(doc, "kind: ConfigMap") || !strings.Contains(doc, "watch-config.yaml") {
			continue
		}
		watchConfigData = extractConfigMapValue(t, doc, "watch-config.yaml")
		break
	}

	require.NotEmpty(t, watchConfigData, "watch-config.yaml not found in any rendered ConfigMap")

	cleaned := strings.ReplaceAll(watchConfigData, "<< .JobID >>", "test-job-id")

	return parseWatchConfigYAML(t, cleaned)
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

func parseWatchConfigYAML(t *testing.T, yamlStr string) watchConfig {
	t.Helper()

	result := make(map[string]any)
	parseYAMLToMap(yamlStr, result)

	jsonBytes, err := json.Marshal(result)
	require.NoError(t, err, "failed to marshal to JSON")

	var cfg watchConfig
	require.NoError(t, json.Unmarshal(jsonBytes, &cfg), "failed to unmarshal watch config")
	return cfg
}

// unquoteYAML strips matching outer quotes from a YAML scalar value.
func unquoteYAML(s string) string {
	if len(s) >= 2 {
		if (s[0] == '"' && s[len(s)-1] == '"') || (s[0] == '\'' && s[len(s)-1] == '\'') {
			return s[1 : len(s)-1]
		}
	}
	return s
}

// parseYAMLToMap handles simple nested YAML (no arrays, no multi-line values).
// Sufficient for the watch-config structure.
func parseYAMLToMap(yamlStr string, result map[string]any) {
	type stackEntry struct {
		indent int
		m      map[string]any
	}

	stack := []stackEntry{{indent: -1, m: result}}

	for _, line := range strings.Split(yamlStr, "\n") {
		if strings.TrimSpace(line) == "" || strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}

		indent := len(line) - len(strings.TrimLeft(line, " "))
		trimmed := strings.TrimSpace(line)

		for len(stack) > 1 && stack[len(stack)-1].indent >= indent {
			stack = stack[:len(stack)-1]
		}
		parent := stack[len(stack)-1].m

		parts := strings.SplitN(trimmed, ":", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])
		value = unquoteYAML(value)

		if value == "" {
			child := make(map[string]any)
			parent[key] = child
			stack = append(stack, stackEntry{indent: indent, m: child})
		} else {
			parent[key] = value
		}
	}
}

func TestHelmWatchConfig_Structure(t *testing.T) {
	cfg := helmTemplateWatchConfig(t)

	assert.Equal(t, "workload.codeflare.dev", cfg.GVR.Group)
	assert.Equal(t, "v1beta2", cfg.GVR.Version)
	assert.Equal(t, "appwrappers", cfg.GVR.Resource)
}

func TestHelmWatchConfig_LabelSelector(t *testing.T) {
	cfg := helmTemplateWatchConfig(t)

	assert.Equal(t, "test-job-id", cfg.LabelSelector["platforma.bio/job-id"])
}

func TestHelmWatchConfig_StatusExpressions(t *testing.T) {
	cfg := helmTemplateWatchConfig(t)

	assert.Equal(t, "resource?.status?.phase == 'Running'", cfg.StatusExpressions.IsRunning)
	assert.Equal(t, "resource?.status?.phase == 'Failed'", cfg.StatusExpressions.IsFailed)
	assert.Equal(t, "resource?.status?.phase == 'Succeeded'", cfg.StatusExpressions.IsCompleted)
}

func TestHelmWatchConfig_FailureDetail(t *testing.T) {
	cfg := helmTemplateWatchConfig(t)

	assert.NotEmpty(t, cfg.StatusExpressions.FailureDetail, "failureDetail expression must be defined")
	assert.Equal(t, "resource?.status?.conditions", cfg.StatusExpressions.FailureDetail)
}

func TestHelmWatchConfig_AllExpressionsNonEmpty(t *testing.T) {
	cfg := helmTemplateWatchConfig(t)

	assert.NotEmpty(t, cfg.StatusExpressions.IsRunning)
	assert.NotEmpty(t, cfg.StatusExpressions.IsFailed)
	assert.NotEmpty(t, cfg.StatusExpressions.IsCompleted)
	assert.NotEmpty(t, cfg.StatusExpressions.FailureDetail)
}

func TestHelmWatchConfig_ExpressionsUseOptionalChaining(t *testing.T) {
	cfg := helmTemplateWatchConfig(t)

	assert.Contains(t, cfg.StatusExpressions.IsRunning, "?.")
	assert.Contains(t, cfg.StatusExpressions.IsFailed, "?.")
	assert.Contains(t, cfg.StatusExpressions.IsCompleted, "?.")
	assert.Contains(t, cfg.StatusExpressions.FailureDetail, "?.")
}
