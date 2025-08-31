package tasks

import "openhvx-agent/datadirs"

type runtimeCtx struct {
	AgentID    string
	BasePath   string
	Paths      map[string]string
	Datastores []map[string]string
}

var rt runtimeCtx

func SetRuntimeContext(agentID, basePath string, d datadirs.DataDirs) {
	rt = runtimeCtx{
		AgentID:  agentID,
		BasePath: basePath,
		Paths: map[string]string{
			"root":        d.Root,
			"vms":         d.VMS,
			"vhd":         d.VHD,
			"isos":        d.ISOs,
			"checkpoints": d.Checkpoints,
			"logs":        d.Logs,
			"trash":       d.Trash,
		},
		Datastores: []map[string]string{
			{"name": "OpenHVX Root", "kind": "root", "path": d.Root},
			{"name": "OpenHVX VMS", "kind": "vm", "path": d.VMS},
			{"name": "OpenHVX VHD", "kind": "vhd", "path": d.VHD},
			{"name": "OpenHVX ISOs", "kind": "iso", "path": d.ISOs},
			{"name": "Checkpoints", "kind": "checkpoint", "path": d.Checkpoints},
			{"name": "Logs", "kind": "logs", "path": d.Logs},
		},
	}
}

func ctxMap(tenantID string) map[string]any {
	return map[string]any{
		"agentId":    rt.AgentID,
		"tenantId":   tenantID,
		"basePath":   rt.BasePath,
		"paths":      rt.Paths,
		"datastores": rt.Datastores,
	}
}
