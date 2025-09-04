package tasks

import "openhvx-agent/datadirs"

type runtimeCtx struct {
	AgentID    string
	BasePath   string
	Paths      map[string]string
	Datastores []map[string]any
}

var rt runtimeCtx

// SetRuntimeContext initialise le contexte runtime de l'agent
// d : arborescence OpenHVX (incluant Images global)
func SetRuntimeContext(agentID, basePath string, d datadirs.DataDirs) {
	rt = runtimeCtx{
		AgentID:  agentID,
		BasePath: basePath,
		Paths: map[string]string{
			"root":        d.Root,
			"vms":         d.VMS,
			"vhd":         d.VHD,
			"images":      d.Images, // <-- GLOBAL (lecture seule)
			"isos":        d.ISOs,   // legacy / compat
			"checkpoints": d.Checkpoints,
			"logs":        d.Logs,
			"trash":       d.Trash,
		},
		Datastores: []map[string]any{
			{"name": "OpenHVX Root", "kind": "root", "path": d.Root, "readOnly": false},
			{"name": "OpenHVX VMS", "kind": "vm", "path": d.VMS, "readOnly": false},
			{"name": "OpenHVX VHD", "kind": "vhd", "path": d.VHD, "readOnly": false},
			{"name": "OpenHVX Images", "kind": "image", "path": d.Images, "readOnly": true}, // <-- important
			{"name": "OpenHVX ISOs", "kind": "iso", "path": d.ISOs, "readOnly": true},       // legacy
			{"name": "OpenHVX Checkpoints", "kind": "checkpoint", "path": d.Checkpoints, "readOnly": false},
			{"name": "OpenHVX Logs", "kind": "logs", "path": d.Logs, "readOnly": false},
		},
	}
}

// ctxMap expose un contexte simple pour inclure dans les payloads retournés par l'agent
func ctxMap(tenantID string) map[string]any {
	return map[string]any{
		"agentId":    rt.AgentID,
		"tenantId":   tenantID,
		"basePath":   rt.BasePath,
		"paths":      rt.Paths,
		"datastores": rt.Datastores,
	}
}

// GetRuntimeContext retourne une copie du contexte courant (utile en debug/tests)
func GetRuntimeContext() map[string]any {
	return map[string]any{
		"agentId":    rt.AgentID,
		"basePath":   rt.BasePath,
		"paths":      rt.Paths,
		"datastores": rt.Datastores,
	}
}
