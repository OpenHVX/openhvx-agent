package tasks

import (
	"encoding/json"
	"fmt"
	"log"

	"openhvx-agent/amqp"
	"openhvx-agent/powershell"
)

func HandleTask(t amqp.Task) (any, error) {
	log.Printf("[TASK] action=%s taskId=%s tenant=%s", t.Action, t.TaskID, t.TenantID)

	// 1) Merge des params: on ajoute __ctx sans écraser les clés métier
	merged := make(map[string]any, len(t.Data)+1)
	for k, v := range t.Data {
		merged[k] = v
	}
	merged["__ctx"] = ctxMap(t.TenantID) // ⬅️ CONTEXTE STANDARD

	// 2) Exécuter le script
	raw, err := powershell.RunActionScript(t.Action, merged)

	// 3) Toujours essayer d’unmarshal
	var obj any
	if uErr := json.Unmarshal(raw, &obj); uErr == nil {
		if err != nil {
			return obj, fmt.Errorf("action script failed")
		}
		return obj, nil
	}

	// 4) Sinon renvoyer stdout brut + statut ok/ko
	if err != nil {
		return map[string]any{"ok": false, "raw": string(raw)}, fmt.Errorf("action script failed")
	}
	return map[string]any{"ok": true, "raw": string(raw)}, nil
}
