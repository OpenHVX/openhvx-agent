// publisher.go
package amqp

import (
	"encoding/json"
	"fmt"
	"log"
	"time"

	amqp091 "github.com/rabbitmq/amqp091-go"
)

const (
	JobsEx      = "jobs"            // direct
	TelemetryEx = "agent.telemetry" // topic
	ResultsEx   = "results"         // topic
)

var conn *amqp091.Connection
var ch *amqp091.Channel

func InitPublisher(amqpURL string) error {
	var err error

	conn, err = amqp091.Dial(amqpURL)
	if err != nil {
		return fmt.Errorf("amqp dial: %w", err)
	}

	ch, err = conn.Channel()
	if err != nil {
		return fmt.Errorf("amqp channel: %w", err)
	}

	// Exchanges (idempotent; mêmes paramètres partout)
	if err := ch.ExchangeDeclare(JobsEx, "direct", true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare exchange %s: %w", JobsEx, err)
	}
	if err := ch.ExchangeDeclare(TelemetryEx, "topic", true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare exchange %s: %w", TelemetryEx, err)
	}
	if err := ch.ExchangeDeclare(ResultsEx, "topic", true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare exchange %s: %w", ResultsEx, err)
	}

	// (optionnel) log des publish "mandatory" non routés
	retCh := ch.NotifyReturn(make(chan amqp091.Return, 1))
	go func() {
		for r := range retCh {
			log.Printf("[AMQP] UNROUTABLE publish corrId=%s rk=%s", r.CorrelationId, r.RoutingKey)
		}
	}()

	return nil
}

func ClosePublisher() {
	if ch != nil {
		_ = ch.Close()
	}
	if conn != nil {
		_ = conn.Close()
	}
}

type heartbeat struct {
	Version      string   `json:"version"`
	AgentID      string   `json:"agentId"`
	Timestamp    string   `json:"ts"`
	Host         string   `json:"host"`
	Capabilities []string `json:"capabilities"`
}

// PublishHeartbeat envoie un heartbeat sans notion de tenant.
func PublishHeartbeat(agentID string, host string, caps []string) error {
	hb := heartbeat{
		Version:      "0.1.0",
		AgentID:      agentID,
		Host:         host,
		Timestamp:    time.Now().UTC().Format(time.RFC3339),
		Capabilities: caps,
	}
	body, _ := json.Marshal(hb)
	rk := "heartbeat." + agentID

	return ch.Publish(
		TelemetryEx, rk,
		true,  // mandatory
		false, // immediate
		amqp091.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp091.Persistent,
			Body:         body,
		},
	)
}

type inventoryEnvelope struct {
	AgentID   string          `json:"agentId"`
	Timestamp string          `json:"ts"`
	Inventory json.RawMessage `json:"inventory"`
}

// PublishInventoryJSON publie l'inventaire brut sans tenant.
func PublishInventoryJSON(agentID string, invJSON []byte) error {
	env := inventoryEnvelope{
		AgentID:   agentID,
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Inventory: invJSON,
	}
	body, _ := json.Marshal(env)
	rk := "inventory." + agentID

	log.Println("[AMQP] Publishing inventory (FULL) to", TelemetryEx, "rk=", rk)

	return ch.Publish(
		TelemetryEx, rk,
		true,  // mandatory -> log via NotifyReturn si non routé
		false, // immediate
		amqp091.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp091.Persistent,
			Body:         body,
		},
	)
}

// ======= ⬇️ Manquait : définition du type d'options pour WithMeta ⬇️
type InventoryPublishOpts struct {
	AgentID   string
	Body      []byte
	Source    string            // ex: "inventory.refresh.light"
	MergeMode string            // "patch-nondestructive" | "replace" | "raw"
	Headers   map[string]string // optionnel
}

// ======= ⬆️ Fin du bloc manquant ⬆️

type inventoryEnvelopeMeta struct {
	AgentID   string          `json:"agentId"`
	Timestamp string          `json:"ts"`
	Source    string          `json:"source,omitempty"`    // ex: inventory.refresh.light
	MergeMode string          `json:"mergeMode,omitempty"` // ex: patch-nondestructive
	Inventory json.RawMessage `json:"inventory"`           // { inventory, datastores }
}

func PublishInventoryJSONWithMeta(opts InventoryPublishOpts) error {
	if ch == nil {
		return fmt.Errorf("AMQP channel not initialized")
	}
	// Harmonisation: même topic pattern que PublishInventoryJSON
	rk := "inventory." + opts.AgentID

	// Enveloppe uniforme (agentId + horodatage)
	env := inventoryEnvelopeMeta{
		AgentID:   opts.AgentID,
		Timestamp: time.Now().UTC().Format(time.RFC3339),
		Source:    opts.Source,
		MergeMode: opts.MergeMode,
		Inventory: json.RawMessage(opts.Body), // Body = { inventory, datastores }
	}
	body, _ := json.Marshal(env)

	// Headers optionnels
	h := amqp091.Table{
		"x-source":     opts.Source,
		"x-merge-mode": opts.MergeMode,
	}
	for k, v := range opts.Headers {
		h[k] = v
	}

	log.Println("[AMQP] Publishing inventory (LIGHT) to", TelemetryEx, "rk=", rk)

	return ch.Publish(
		TelemetryEx, rk,
		true,  // mandatory
		false, // immediate
		amqp091.Publishing{
			ContentType:  "application/json",
			DeliveryMode: amqp091.Persistent,
			Headers:      h,
			Body:         body,
		},
	)
}
