package amqp

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"openhvx-agent/journal"
	"sync"
	"time"
)

const ProtocolCapability = "task.protocol.v2"

type NotAppliedError struct{ Reason string }

func (e *NotAppliedError) Error() string { return e.Reason }

type RecoverFunc func(Task) (result any, complete bool, err error)
type Executor struct {
	mu      sync.Mutex
	store   *journal.Store
	handle  HandlerFunc
	recover RecoverFunc
	agentID string
}

func NewExecutor(store *journal.Store, agentID string, handle HandlerFunc, recover RecoverFunc) *Executor {
	return &Executor{store: store, agentID: agentID, handle: handle, recover: recover}
}

// DecodeCommand verifies the exact bytes hashed by the controller. Only the
// immutable inner command is executable; outer duplicate fields have no authority.
func DecodeCommand(body []byte, agentID string) (Task, error) {
	var envelope Task
	if err := json.Unmarshal(body, &envelope); err != nil {
		return Task{}, err
	}
	if envelope.ContractVersion != 2 || envelope.CommandBody == "" || envelope.EventID == "" {
		return Task{}, errors.New("task protocol v2 required")
	}
	hash := sha256.Sum256([]byte(envelope.CommandBody))
	if hex.EncodeToString(hash[:]) != envelope.CommandFingerprint {
		return Task{}, errors.New("command fingerprint mismatch")
	}
	var t Task
	if err := json.Unmarshal([]byte(envelope.CommandBody), &t); err != nil {
		return Task{}, err
	}
	if t.OperationID == "" || t.OperationID != envelope.TaskID || t.OperationID != envelope.OperationID || t.AgentID != agentID || t.TenantID == "" || t.Action == "" {
		return Task{}, errors.New("invalid command identity")
	}
	if !validPathSegment(t.TenantID) {
		return Task{}, errors.New("invalid tenant path component")
	}
	if t.Action == "vm.create" {
		name, ok := t.Data["name"].(string)
		if !ok || !validPathSegment(name) {
			return Task{}, errors.New("invalid VM name")
		}
	}
	if t.Action == "vm.delete" || t.Action == "vm.power" {
		target, ok := t.Data["target"].(map[string]interface{})
		if !ok {
			return Task{}, errors.New("canonical target required")
		}
		ref, ok := target["refId"].(string)
		if !ok || !vmGUID.MatchString(ref) {
			return Task{}, errors.New("canonical target reference required")
		}
		for _, key := range []string{"id", "guid", "refId"} {
			if value, present := t.Data[key]; present && value != ref {
				return Task{}, errors.New("resource alias contradicts the canonical target")
			}
		}
	}
	t.TaskID = t.OperationID
	t.CommandFingerprint = envelope.CommandFingerprint
	t.ContractVersion = 2
	t.EventID = envelope.EventID
	if t.Data == nil {
		t.Data = map[string]interface{}{}
	}
	return t, nil
}
func (e *Executor) Execute(t Task) (json.RawMessage, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	// Journal recovery context contains no tickets, cloud-init or storage secrets.
	minimal := t
	minimal.CommandBody = ""
	minimal.Data = map[string]interface{}{"target": t.Data["target"], "state": t.Data["state"]}
	recovery, err := json.Marshal(minimal)
	if err != nil {
		return nil, err
	}
	record, fresh, err := e.store.Begin(t.OperationID, t.CommandFingerprint, recovery)
	if err != nil {
		return nil, err
	}
	if !fresh {
		if record.State == "completed" {
			return record.Result, nil
		}
		if e.recover != nil {
			result, complete, recoveryErr := e.recover(t)
			if recoveryErr == nil && complete {
				return e.finish(t, record, "applied", result, "")
			}
		}
		if len(record.Result) > 0 {
			return record.Result, nil
		}
		return e.finish(t, record, "unknown", nil, "Agent restarted after durable intent; host effect requires reconciliation")
	}
	result, handlerErr := e.handle(t)
	outcome := "applied"
	message := ""
	if handlerErr != nil {
		message = "Host execution failed; reconciliation required"
		outcome = "unknown"
		var noEffect *NotAppliedError
		if errors.As(handlerErr, &noEffect) {
			outcome = "not_applied"
			message = noEffect.Reason
		}
	}
	return e.finish(t, record, outcome, result, message)
}
func (e *Executor) finish(t Task, r journal.Record, outcome string, result any, message string) (json.RawMessage, error) {
	sequence := r.Sequence + 1
	event := sha256.Sum256([]byte(fmt.Sprintf("%s:%s:%d", t.OperationID, t.CommandFingerprint, sequence)))
	response := map[string]any{"contractVersion": 2, "taskId": t.TaskID, "operationId": t.OperationID, "eventId": hex.EncodeToString(event[:]), "commandFingerprint": t.CommandFingerprint, "sequence": sequence, "tenantId": t.TenantID, "agentId": e.agentID, "action": t.Action, "outcome": outcome, "ok": outcome == "applied", "result": result, "error": message, "finishedAt": time.Now().UTC().Format(time.RFC3339Nano)}
	body, err := json.Marshal(response)
	if err != nil {
		return nil, err
	}
	r.Published = false
	r.Sequence = sequence
	r.Result = body
	r.State = "completed"
	if outcome == "unknown" {
		r.State = "uncertain"
	}
	if err = e.store.Finish(r); err != nil {
		return nil, err
	}
	return body, nil
}

// Reconcile uses observation only. It never calls the effectful handler again.
func (e *Executor) Reconcile() ([]json.RawMessage, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	records, err := e.store.Uncertain()
	if err != nil {
		return nil, err
	}
	var results []json.RawMessage
	for _, r := range records {
		var t Task
		if err = json.Unmarshal(r.Recovery, &t); err != nil {
			return nil, err
		}
		if r.State == "completed" {
			if !r.Published {
				results = append(results, r.Result)
			}
			continue
		}
		if e.recover == nil {
			if !r.Published && len(r.Result) > 0 {
				results = append(results, r.Result)
			}
			continue
		}
		result, complete, err := e.recover(t)
		if err != nil {
			if len(r.Result) == 0 {
				body, persistErr := e.finish(t, r, "unknown", nil, "Host observation unavailable; effect requires reconciliation")
				if persistErr != nil {
					return nil, persistErr
				}
				results = append(results, body)
			} else if !r.Published {
				results = append(results, r.Result)
			}
			continue
		}
		if complete {
			body, err := e.finish(t, r, "applied", result, "")
			if err != nil {
				return nil, err
			}
			results = append(results, body)
		} else if !r.Published && len(r.Result) > 0 {
			results = append(results, r.Result)
		}
	}
	return results, nil
}

func (e *Executor) MarkPublished(body json.RawMessage) error {
	var event struct {
		OperationID string `json:"operationId"`
		Sequence    int    `json:"sequence"`
	}
	if err := json.Unmarshal(body, &event); err != nil {
		return err
	}
	return e.store.MarkPublished(event.OperationID, event.Sequence)
}
