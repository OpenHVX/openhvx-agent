package powershell

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func testPowerShell(t *testing.T) string {
	t.Helper()
	if binary := os.Getenv("PWSH_BINARY"); binary != "" {
		return binary
	}
	binary, err := exec.LookPath("pwsh")
	if err != nil {
		t.Skip("PowerShell unavailable; set PWSH_BINARY to run adapter tests")
	}
	return binary
}
func TestActiveScriptsParse(t *testing.T) {
	binary := testPowerShell(t)
	output, err := exec.Command(binary, "-NoLogo", "-NoProfile", "-File", filepath.Join("tests", "parse.ps1")).CombinedOutput()
	if err != nil {
		t.Fatalf("PowerShell parse error: %v\n%s", err, output)
	}
}
func TestDeleteUsesVMIdentityAndRequiresSuccessfulObservation(t *testing.T) {
	binary := testPowerShell(t)
	for _, mode := range []string{"available", "unavailable", "absent"} {
		t.Run(mode, func(t *testing.T) {
			effect := filepath.Join(t.TempDir(), "removed-vm")
			payload := `{"id":"11111111-1111-4111-8111-111111111111"}`
			command := exec.Command(binary, "-NoLogo", "-NoProfile", "-File", filepath.Join("tests", "vm-delete.mock.ps1"), "-InputJson", payload)
			command.Env = append(os.Environ(), "OPENHVX_TEST_MODE="+mode, "OPENHVX_TEST_EFFECT="+effect)
			output, err := command.Output()
			if mode == "unavailable" {
				if err == nil {
					t.Fatalf("host failure was reported as success: %s", output)
				}
				if _, err = os.Stat(effect); !os.IsNotExist(err) {
					t.Fatal("deleted a VM without observing the host")
				}
				return
			}
			if err != nil {
				t.Fatalf("adapter failed: %v\n%s", err, output)
			}
			var result struct {
				VM struct {
					GUID     string `json:"guid"`
					NotFound bool   `json:"notFound"`
				} `json:"vm"`
			}
			if err = json.Unmarshal(output, &result); err != nil {
				t.Fatalf("invalid result: %s", output)
			}
			if mode == "absent" {
				if !result.VM.NotFound {
					t.Fatal("expected a conclusive absence")
				}
				return
			}
			removed, err := os.ReadFile(effect)
			if err != nil || string(removed) != "11111111-1111-4111-8111-111111111111" {
				t.Fatalf("wrong host effect: %q %v", removed, err)
			}
			if result.VM.GUID != string(removed) {
				t.Fatal("result did not match the affected VM")
			}
		})
	}
}

func TestRecoveryRequiresConclusiveReadOnlyState(t *testing.T) {
	binary := testPowerShell(t)
	cases := []struct {
		mode, action, state string
		complete, fail      bool
	}{
		{"create-complete", "vm.create", "", true, false},
		{"create-partial", "vm.create", "", false, false},
		{"deleted", "vm.delete", "", true, false},
		{"running", "vm.delete", "", false, false},
		{"running", "vm.power", "start", true, false},
		{"off", "vm.power", "stop", true, false},
		{"running", "vm.power", "restart", false, false},
		{"unavailable", "vm.delete", "", false, true},
	}
	for _, tc := range cases {
		t.Run(tc.mode+"-"+tc.action+"-"+tc.state, func(t *testing.T) {
			body, _ := json.Marshal(map[string]any{"operationId": "operation-1", "commandFingerprint": "0000000000000000000000000000000000000000000000000000000000000000", "targetRef": "11111111-1111-4111-8111-111111111111", "action": tc.action, "requestedState": tc.state})
			command := exec.Command(binary, "-NoLogo", "-NoProfile", "-File", filepath.Join("tests", "observe.mock.ps1"), "-InputJson", string(body))
			command.Env = append(os.Environ(), "OPENHVX_TEST_MODE="+tc.mode)
			output, err := command.Output()
			if tc.fail {
				if err == nil {
					t.Fatal("failed host observation was accepted")
				}
				return
			}
			if err != nil {
				t.Fatalf("observation failed: %v %s", err, output)
			}
			var observation struct {
				Complete bool `json:"complete"`
			}
			if err = json.Unmarshal(output, &observation); err != nil {
				t.Fatalf("bad observation: %s", output)
			}
			if observation.Complete != tc.complete {
				t.Fatalf("unexpected proof: %s", output)
			}
		})
	}
}
