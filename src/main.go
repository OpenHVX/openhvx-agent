// main.go
package main

import (
	"context" // ⬅️ NEW
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"openhvx-agent/amqp"
	"openhvx-agent/config"
	"openhvx-agent/datadirs"
	"openhvx-agent/powershell"
	"openhvx-agent/tasks"
)

type actionResp struct {
	Ok     bool        `json:"ok"`
	Result interface{} `json:"result"`
	Error  string      `json:"error"`
}

// Construit le paramètre "datastores" à transmettre au script PowerShell
func buildDatastoresParam(d datadirs.DataDirs) []map[string]string {
	if d.Root == "" {
		return nil
	}
	return []map[string]string{
		{"name": "OpenHVX Root", "kind": "root", "path": d.Root},
		{"name": "OpenHVX VMS", "kind": "vm", "path": d.VMS},
		{"name": "OpenHVX VHD", "kind": "vhd", "path": d.VHD},
		{"name": "OpenHVX ISOs", "kind": "iso", "path": d.ISOs},
		{"name": "Checkpoints", "kind": "checkpoint", "path": d.Checkpoints},
		{"name": "Logs", "kind": "logs", "path": d.Logs},
	}
}

func main() {
	// Flags
	cfgPath := flag.String("config", "config.json", "Chemin du fichier de configuration")
	dryRun := flag.Bool("dry-run", false, "Mode sec: pas d'AMQP, affiche seulement un JSON et quitte")
	module := flag.String("modules", "inventory", "Dry-run module: inventory | heartbeat")
	flag.Parse()

	// Logs sur stderr
	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("[agent] ")

	// === DRY-RUN ===
	if *dryRun {
		switch strings.ToLower(*module) {
		case "inventory":
			cfg, err := config.Load(*cfgPath)
			if err != nil {
				fmt.Fprintln(os.Stderr, "config error:", err)
				os.Exit(1)
			}

			// Prépare l’arbo openhvx si basePath est fourni
			var dirs datadirs.DataDirs
			if cfg.BasePath != "" {
				if d, e := datadirs.EnsureDataDirs(cfg.BasePath); e == nil {
					dirs = d
				} else {
					log.Printf("warn: ensure data dirs failed: %v", e)
				}
			}
			// Exposer le contexte runtime aux scripts côté tasks (si utilisé)
			tasks.SetRuntimeContext(cfg.AgentID, cfg.BasePath, dirs)

			dsParam := buildDatastoresParam(dirs)

			// Passe basePath + datastores au script inventory.refresh
			raw, err := powershell.RunActionScript("inventory.refresh", map[string]any{
				"basePath":   cfg.BasePath,
				"datastores": dsParam,
			})
			if err != nil {
				fmt.Fprintln(os.Stderr, "inventory collect error:", err)
				os.Exit(1)
			}

			// Si le script renvoie {ok,result,error}, on sort seulement result
			var r actionResp
			if err := json.Unmarshal(raw, &r); err == nil && r.Ok {
				out, _ := json.Marshal(r.Result)
				_, _ = os.Stdout.Write(out)
				os.Exit(0)
			}

			// Sinon, on renvoie tel quel
			_, _ = os.Stdout.Write(raw)
			os.Exit(0)

		case "heartbeat":
			cfg, err := config.Load(*cfgPath)
			if err != nil {
				fmt.Fprintln(os.Stderr, "config error:", err)
				os.Exit(1)
			}
			hb := map[string]any{
				"v":            1,
				"agentId":      cfg.AgentID,
				"ts":           time.Now().UTC().Format(time.RFC3339),
				"version":      "0.1.0",
				"capabilities": cfg.Capabilities, // depuis la config
			}
			out, _ := json.Marshal(hb)
			_, _ = os.Stdout.Write(out)
			os.Exit(0)

		default:
			fmt.Fprintln(os.Stderr, "unknown dry-run module (use: inventory | heartbeat)")
			os.Exit(2)
		}
	}

	// === MODE NORMAL ===
	cfg, err := config.Load(*cfgPath)
	if err != nil {
		log.Fatalf("config load failed (%s): %v", *cfgPath, err)
	}

	// 1) Préparer l’arbo gérée + exposer le contexte pour PowerShell (__ctx)
	var dirs datadirs.DataDirs
	if cfg.BasePath != "" {
		dirs, err = datadirs.EnsureDataDirs(cfg.BasePath)
		if err != nil {
			log.Fatalf("ensure data dirs: %v", err)
		}
		log.Printf("datadirs ready | %s", dirs.DebugString())
	} else {
		log.Printf("no basePath configured; datastores will be empty in inventory")
	}
	tasks.SetRuntimeContext(cfg.AgentID, cfg.BasePath, dirs)
	dsParam := buildDatastoresParam(dirs)

	// 2) AMQP
	if err := amqp.InitPublisher(cfg.RabbitMQURL); err != nil {
		log.Fatalf("amqp init failed: %v", err)
	}
	defer amqp.ClosePublisher()

	amqp.AfterResult = func(t amqp.Task) {
		tasks.KickLightRefresh(context.Background(), tasks.LightCtx{
			AgentID:    cfg.AgentID,
			BasePath:   cfg.BasePath,
			DataStores: dsParam,
		})
	}

	// 3) Tickers
	hbEvery := time.Duration(cfg.HeartbeatIntervalSec) * time.Second
	invEvery := time.Duration(cfg.InventoryIntervalSec) * time.Second

	// Heartbeat périodique
	go func() {
		t := time.NewTicker(hbEvery)
		defer t.Stop()
		host, err := os.Hostname()
		if err != nil {
			log.Fatalf("Not able to retrieve hostname: %v", err)
		}
		for range t.C {
			if err := amqp.PublishHeartbeat(cfg.AgentID, host, cfg.Capabilities); err != nil {
				log.Println("heartbeat error:", err)
			}
		}
	}()

	// Inventory périodique (complet) via action PS (inventory.refresh)
	go func() {
		t := time.NewTicker(invEvery)
		defer t.Stop()
		for range t.C {
			// Passe basePath + datastores au script
			raw, err := powershell.RunActionScript("inventory.refresh", map[string]any{
				"basePath":   cfg.BasePath,
				"datastores": dsParam,
			})
			if err != nil {
				log.Println("inventory collect error:", err)
				continue
			}

			// Essaie d'interpréter {ok,result,error}; sinon publie tel quel
			var r actionResp
			if err := json.Unmarshal(raw, &r); err == nil && r.Ok {
				invBytes, _ := json.Marshal(r.Result)
				if err := amqp.PublishInventoryJSON(cfg.AgentID, invBytes); err != nil {
					log.Println("inventory publish error:", err)
				}
				continue
			}
			if err := amqp.PublishInventoryJSON(cfg.AgentID, raw); err != nil {
				log.Println("inventory publish error (raw):", err)
			}
		}
	}()

	// 4) Consumer des tâches -> tasks.HandleTask (injecte __ctx pour les scripts)
	if err := amqp.StartTaskConsumer(cfg.AgentID, tasks.HandleTask); err != nil {
		log.Fatalf("start consumer failed: %v", err)
	}

	log.Printf("started | agentId=%s rmq=%s", cfg.AgentID, cfg.RabbitMQURL)

	// Arrêt propre (CTRL+C / SIGTERM)
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	log.Println("shutting down...")
}
