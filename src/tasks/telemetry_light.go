package tasks

import (
	"context"
	"encoding/json"
	"log"

	"openhvx-agent/amqp"
	"openhvx-agent/powershell"
)

type LightCtx struct {
	AgentID    string
	BasePath   string
	DataStores any // []map[string]any ou ton type concret
}

func KickLightRefresh(ctx context.Context, lc LightCtx) {
	go func() {
		payload := map[string]any{
			"basePath":   lc.BasePath,
			"datastores": lc.DataStores,
			"__ctx": map[string]any{
				"agentId":    lc.AgentID,
				"basePath":   lc.BasePath,
				"datastores": lc.DataStores,
			},
		}

		raw, err := powershell.RunActionScript("inventory.refresh.light", payload)
		if err != nil {
			log.Println("inventory light error:", err)
			return
		}

		var r struct {
			Ok     bool            `json:"ok"`
			Result json.RawMessage `json:"result"`
			Error  string          `json:"error"`
		}
		if err := json.Unmarshal(raw, &r); err == nil && r.Ok && len(r.Result) > 0 {
			_ = amqp.PublishInventoryJSONWithMeta(amqp.InventoryPublishOpts{
				AgentID:   lc.AgentID,
				Body:      r.Result,                  // { inventory, datastores }
				Source:    "inventory.refresh.light", // provenance
				MergeMode: "patch-nondestructive",    // règle de merge
				Headers: map[string]string{
					"x-agent-id": lc.AgentID,
				},
			})
			return
		}

		_ = amqp.PublishInventoryJSONWithMeta(amqp.InventoryPublishOpts{
			AgentID:   lc.AgentID,
			Body:      raw,
			Source:    "inventory.refresh.light",
			MergeMode: "raw",
			Headers: map[string]string{
				"x-agent-id": lc.AgentID,
			},
		})
	}()
}
