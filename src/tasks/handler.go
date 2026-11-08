package tasks

import (
	"encoding/json"
	"fmt"
	"log"
	"openhvx-agent/amqp"
	"openhvx-agent/powershell"
)

func HandleTask(t amqp.Task) (any, error) {
	log.Printf("[TASK] action=%s operationId=%s", t.Action, t.OperationID)
	allowed := map[string]bool{"vm.create": true, "vm.delete": true, "vm.power": true, "vm.edit": true, "echo": true, "inventory.refresh": true, "console.serial.open": true}
	if !allowed[t.Action] {
		return nil, &amqp.NotAppliedError{Reason: "Unsupported action; no script executed"}
	}
	merged := make(map[string]any, len(t.Data)+2)
	for k, v := range t.Data {
		merged[k] = v
	}
	merged["__ctx"] = ctxMap(t.TenantID)
	merged["__operation"] = map[string]any{"operationId": t.OperationID, "commandFingerprint": t.CommandFingerprint}
	raw, err := powershell.RunActionScript(t.Action, merged)
	var obj map[string]any
	if json.Unmarshal(raw, &obj) != nil {
		return nil, fmt.Errorf("invalid action result; host effect unknown")
	}
	if err != nil {
		return obj, fmt.Errorf("action script failed; host effect unknown")
	}
	if ok, present := obj["ok"].(bool); present && !ok {
		return obj, fmt.Errorf("action reported failure; host effect unknown")
	}
	if result, present := obj["result"]; present {
		return result, nil
	}
	return obj, nil
}

// Recovery is observation only: a restarted executor never reruns a host action.
func RecoverTask(t amqp.Task) (any, bool, error) {
	if t.Action != "vm.create" && t.Action != "vm.delete" && t.Action != "vm.power" {
		return nil, false, nil
	}
	target, _ := t.Data["target"].(map[string]interface{})
	var ref any
	if target != nil {
		ref = target["refId"]
	}
	raw, err := powershell.RunActionScript("operation.observe", map[string]any{"operationId": t.OperationID, "commandFingerprint": t.CommandFingerprint, "action": t.Action, "targetRef": ref, "requestedState": t.Data["state"]})
	if err != nil {
		return nil, false, err
	}
	var observation struct {
		Complete bool           `json:"complete"`
		Result   map[string]any `json:"result"`
	}
	if err = json.Unmarshal(raw, &observation); err != nil {
		return nil, false, err
	}
	return observation.Result, observation.Complete, nil
}
