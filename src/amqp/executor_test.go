package amqp

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"openhvx-agent/journal"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
)

func testTask() Task {
	return Task{TaskID: "operation-1", OperationID: "operation-1", AgentID: "host-1", TenantID: "tenant-1", Action: "vm.create", CommandFingerprint: hex.EncodeToString(make([]byte, 32)), Data: map[string]interface{}{}}
}
func openTestStore(t *testing.T, path string) *journal.Store {
	t.Helper()
	s, err := journal.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	return s
}
func TestConcurrentDeliveryExecutesOnce(t *testing.T) {
	store := openTestStore(t, filepath.Join(t.TempDir(), "operations.db"))
	defer store.Close()
	var executions atomic.Int32
	executor := NewExecutor(store, "host-1", func(Task) (any, error) {
		executions.Add(1)
		return map[string]any{"vm": map[string]any{"guid": "vm-1"}}, nil
	}, nil)
	var wg sync.WaitGroup
	for i := 0; i < 30; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := executor.Execute(testTask()); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if executions.Load() != 1 {
		t.Fatalf("executed %d times", executions.Load())
	}
	changed := testTask()
	changed.CommandFingerprint = "other"
	if _, err := executor.Execute(changed); !errors.Is(err, journal.ErrConflict) {
		t.Fatalf("expected identity conflict: %v", err)
	}
}

// The child exits without Close(), so these tests exercise durable process loss,
// not just repeated calls against one in-memory object.
func TestCrashHelper(t *testing.T) {
	mode := os.Getenv("OPENHVX_CRASH_MODE")
	if mode == "" {
		return
	}
	path := os.Getenv("OPENHVX_JOURNAL_TEST")
	store, err := journal.Open(path)
	if err != nil {
		os.Exit(10)
	}
	executor := NewExecutor(store, "host-1", func(Task) (any, error) {
		file, err := os.OpenFile(path+".effect", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
		if err != nil {
			os.Exit(11)
		}
		file.WriteString("effect\n")
		file.Sync()
		file.Close()
		if mode == "after-effect" {
			os.Exit(41)
		}
		return map[string]any{"vm": map[string]any{"guid": "vm-1"}}, nil
	}, nil)
	if _, err = executor.Execute(testTask()); err != nil {
		os.Exit(12)
	}
	os.Exit(42)
}
func TestCrashBoundariesDoNotRepeatHostEffect(t *testing.T) {
	for _, mode := range []string{"after-effect", "after-result"} {
		t.Run(mode, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "operations.db")
			child := exec.Command(os.Args[0], "-test.run=^TestCrashHelper$")
			child.Env = append(os.Environ(), "OPENHVX_CRASH_MODE="+mode, "OPENHVX_JOURNAL_TEST="+path)
			if err := child.Run(); err == nil {
				t.Fatal("child did not crash")
			}
			store := openTestStore(t, path)
			defer store.Close()
			executor := NewExecutor(store, "host-1", func(Task) (any, error) { t.Error("repeated host effect"); return nil, nil }, nil)
			result, err := executor.Execute(testTask())
			if err != nil {
				t.Fatal(err)
			}
			var event map[string]any
			json.Unmarshal(result, &event)
			expected := "applied"
			if mode == "after-effect" {
				expected = "unknown"
			}
			if event["outcome"] != expected {
				t.Fatalf("unexpected recovery: %s", result)
			}
			effect, err := os.ReadFile(path + ".effect")
			if err != nil || string(effect) != "effect\n" {
				t.Fatalf("effect not unique: %q %v", effect, err)
			}
			again, err := executor.Execute(testTask())
			if err != nil || string(result) != string(again) {
				t.Fatal("result identity changed on replay")
			}
		})
	}
}
func TestReconciledResultSurvivesPublisherCrash(t *testing.T) {
	path := filepath.Join(t.TempDir(), "operations.db")
	store := openTestStore(t, path)
	recovered := false
	executor := NewExecutor(store, "host-1", func(Task) (any, error) { return nil, errors.New("host outcome uncertain") }, func(Task) (any, bool, error) {
		return map[string]any{"vm": map[string]any{"guid": "vm-1"}}, recovered, nil
	})
	uncertain, err := executor.Execute(testTask())
	if err != nil {
		t.Fatal(err)
	}
	if err = executor.MarkPublished(uncertain); err != nil {
		t.Fatal(err)
	}
	recovered = true
	results, err := executor.Reconcile()
	if err != nil || len(results) != 1 {
		t.Fatalf("reconcile: %v %d", err, len(results))
	}
	store.Close() // crash before publishing the recovered result
	store = openTestStore(t, path)
	defer store.Close()
	executor = NewExecutor(store, "host-1", nil, nil)
	pending, err := executor.Reconcile()
	if err != nil || len(pending) != 1 || string(pending[0]) != string(results[0]) {
		t.Fatalf("lost recovered result: %v", err)
	}
	// A delayed confirm for the old unknown result cannot hide the new result.
	if err = executor.MarkPublished(uncertain); err != nil {
		t.Fatal(err)
	}
	pending, err = executor.Reconcile()
	if err != nil || len(pending) != 1 {
		t.Fatal("old publisher hid newer result")
	}
	if err = executor.MarkPublished(pending[0]); err != nil {
		t.Fatal(err)
	}
	pending, err = executor.Reconcile()
	if err != nil || len(pending) != 0 {
		t.Fatal("confirmed terminal result remained pending")
	}
}
func TestDecodeCommandRejectsTampering(t *testing.T) {
	body := `{"operationId":"op-1","agentId":"host-1","tenantId":"tenant-1","action":"echo","data":{"message":"hello"}}`
	hash := sha256.Sum256([]byte(body))
	envelope := Task{TaskID: "op-1", OperationID: "op-1", EventID: "event-1", ContractVersion: 2, CommandBody: body, CommandFingerprint: hex.EncodeToString(hash[:])}
	raw, _ := json.Marshal(envelope)
	if _, err := DecodeCommand(raw, "host-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeCommand(raw, "host-2"); err == nil {
		t.Fatal("wrong host accepted")
	}
	envelope.CommandBody = body + " "
	raw, _ = json.Marshal(envelope)
	if _, err := DecodeCommand(raw, "host-1"); err == nil {
		t.Fatal("tampered command accepted")
	}
}

func TestSharedBackendCommandVector(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "task-v2.json"))
	if err != nil {
		t.Fatal(err)
	}
	command, err := DecodeCommand(raw, "contract-host")
	if err != nil {
		t.Fatal(err)
	}
	if command.OperationID != "contract-vector-1" || command.Data["message"] != "héllo\nworld" {
		t.Fatal("cross-language command mismatch")
	}
}

func TestHostPathIdentifiers(t *testing.T) {
	for _, name := range []string{"../other", `..\other`, "D:other", "CON", "NUL.txt", "vm.", "vm ", "", "a\x00b"} {
		if validPathSegment(name) {
			t.Errorf("unsafe path accepted: %q", name)
		}
	}
	if !validPathSegment("VM Ubuntu 24.04") {
		t.Fatal("valid VM name rejected")
	}
}

func TestUnavailableRecoveryStillReportsUnknown(t *testing.T) {
	path := filepath.Join(t.TempDir(), "operations.db")
	store := openTestStore(t, path)
	defer store.Close()
	command := testTask()
	minimal, _ := json.Marshal(command)
	if _, _, err := store.Begin(command.OperationID, command.CommandFingerprint, minimal); err != nil {
		t.Fatal(err)
	}
	executor := NewExecutor(store, "host-1", func(Task) (any, error) {
		t.Fatal("repeated a host effect during unavailable recovery")
		return nil, nil
	}, func(Task) (any, bool, error) { return nil, false, errors.New("hypervisor offline") })
	result, err := executor.Execute(command)
	if err != nil {
		t.Fatal(err)
	}
	var event map[string]any
	if err = json.Unmarshal(result, &event); err != nil {
		t.Fatal(err)
	}
	if event["outcome"] != "unknown" {
		t.Fatal("unavailable observation did not preserve uncertainty")
	}
	pending, err := executor.Reconcile()
	if err != nil || len(pending) != 1 {
		t.Fatal("unavailable host prevented durable result delivery")
	}
}
