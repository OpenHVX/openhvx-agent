package tasks

import (
	"encoding/json"
	"fmt"
	"log"

	"hvwm-agent/amqp"       // adapte
	"hvwm-agent/powershell" // adapte
)

func HandleTask(t amqp.Task) (any, error) {
	log.Printf("[TASK] action=%s taskId=%s", t.Action, t.TaskID)

	raw, err := powershell.RunActionScript(t.Action, t.Data)

	// Essaye toujours d’unmarshal le stdout
	var obj any
	if uErr := json.Unmarshal(raw, &obj); uErr == nil {
		// on a un JSON valide
		if err != nil {
			// script a échoué -> on garde le JSON ET l’erreur
			return obj, fmt.Errorf("action script failed")
		}
		return obj, nil
	}

	// si stdout pas JSON, renvoyer brut
	if err != nil {
		return map[string]any{"ok": false, "raw": string(raw)}, fmt.Errorf("action script failed")
	}
	return map[string]any{"ok": true, "raw": string(raw)}, nil
}
