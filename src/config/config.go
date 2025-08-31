package config

import (
	"encoding/json"
	"os"
)

type Config struct {
	AgentID              string   `json:"agentId"`
	RabbitMQURL          string   `json:"rabbitmqUrl"`          // ⚠️ clé JSON en camelCase
	HeartbeatIntervalSec int      `json:"heartbeatIntervalSec"` // ex: 30
	InventoryIntervalSec int      `json:"inventoryIntervalSec"` // ex: 60
	Capabilities         []string `json:"capabilities"`         // ex: ["inventory","vm.power"]
	BasePath             string   `json:"basePath"`             // ex: "C:\\Hyper-V"
}

func Load(path string) (*Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := json.Unmarshal(b, &cfg); err != nil {
		return nil, err
	}
	// Defaults
	if cfg.HeartbeatIntervalSec <= 0 {
		cfg.HeartbeatIntervalSec = 30
	}
	if cfg.InventoryIntervalSec <= 0 {
		cfg.InventoryIntervalSec = 60
	}
	if len(cfg.Capabilities) == 0 {
		cfg.Capabilities = []string{"inventory", "vm.power"}
	}
	return &cfg, nil
}
