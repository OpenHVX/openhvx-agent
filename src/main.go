package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"hvwm-agent/amqp"
	"hvwm-agent/config"
	"hvwm-agent/powershell"
	"hvwm-agent/tasks"
)

type actionResp struct {
	Ok     bool        `json:"ok"`
	Result interface{} `json:"result"`
	Error  string      `json:"error"`
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
			raw, err := powershell.RunActionScript("inventory.refresh", map[string]any{})
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
			_ = cfg // évite l'optimisation du compilateur si non utilisé dans ce bloc
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

	if err := amqp.InitPublisher(cfg.RabbitMQURL); err != nil {
		log.Fatalf("amqp init failed: %v", err)
	}
	defer amqp.ClosePublisher()

	hbEvery := time.Duration(cfg.HeartbeatIntervalSec) * time.Second
	invEvery := time.Duration(cfg.InventoryIntervalSec) * time.Second
	// Heartbeat périodique (sans tenantId)
	go func() {
		t := time.NewTicker(hbEvery)
		defer t.Stop()
		for range t.C {
			if err := amqp.PublishHeartbeat(cfg.AgentID, cfg.Capabilities); err != nil {
				log.Println("heartbeat error:", err)
			}
		}
	}()
	// Inventory périodique via action PS (inventory.refresh) — publication sans tenantId
	go func() {
		t := time.NewTicker(invEvery)
		defer t.Stop()
		for range t.C {
			raw, err := powershell.RunActionScript("inventory.refresh", map[string]any{})
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

	// Consumer des tâches -> tasks.HandleTask
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
