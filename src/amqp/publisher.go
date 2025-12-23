// publisher.go
package amqp

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"sync"
	"time"

	amqp091 "github.com/rabbitmq/amqp091-go"
)

const (
	JobsEx      = "jobs"            // direct
	TelemetryEx = "agent.telemetry" // topic
	ResultsEx   = "results"         // topic
)

var (
	conn    *amqp091.Connection
	ch      *amqp091.Channel
	amqpURL string
	connMu  sync.Mutex
)

func InitPublisher(url string) error {
	amqpURL = url

	if _, err := ensureChannelWithRetry(3, 2*time.Second); err != nil {
		return err
	}

	return nil
}

func ClosePublisher() {
	if ch != nil {
		_ = ch.Close()
	}
	if conn != nil {
		_ = conn.Close()
	}
	connMu.Lock()
	defer connMu.Unlock()
	ch = nil
	conn = nil
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

	return publishWithRetry(func(c *amqp091.Channel) error {
		return c.Publish(
			TelemetryEx, rk,
			true,  // mandatory
			false, // immediate
			amqp091.Publishing{
				ContentType:  "application/json",
				DeliveryMode: amqp091.Persistent,
				Body:         body,
			},
		)
	})
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

	return publishWithRetry(func(c *amqp091.Channel) error {
		return c.Publish(
			TelemetryEx, rk,
			true,  // mandatory -> log via NotifyReturn si non routé
			false, // immediate
			amqp091.Publishing{
				ContentType:  "application/json",
				DeliveryMode: amqp091.Persistent,
				Body:         body,
			},
		)
	})
}

type InventoryPublishOpts struct {
	AgentID   string
	Body      []byte
	Source    string            // ex: "inventory.refresh.light"
	MergeMode string            // "patch-nondestructive" | "replace" | "raw"
	Headers   map[string]string // optionnel
}

type inventoryEnvelopeMeta struct {
	AgentID   string          `json:"agentId"`
	Timestamp string          `json:"ts"`
	Source    string          `json:"source,omitempty"`    // ex: inventory.refresh.light
	MergeMode string          `json:"mergeMode,omitempty"` // ex: patch-nondestructive
	Inventory json.RawMessage `json:"inventory"`           // { inventory, datastores }
}

func PublishInventoryJSONWithMeta(opts InventoryPublishOpts) error {
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

	return publishWithRetry(func(c *amqp091.Channel) error {
		return c.Publish(
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
	})
}

// --------- Internals (reconnexion + canal) ----------

func ensureChannelWithRetry(attempts int, delay time.Duration) (*amqp091.Channel, error) {
	var lastErr error
	for i := 0; attempts == 0 || i < attempts; i++ {
		c, err := ensureChannel()
		if err == nil {
			return c, nil
		}
		lastErr = err
		log.Printf("[AMQP] channel ensure failed (try %d): %v", i+1, err)
		time.Sleep(delay)
	}
	return nil, fmt.Errorf("amqp channel init failed after %d attempts: %w", attempts, lastErr)
}

func ensureChannel() (*amqp091.Channel, error) {
	connMu.Lock()
	defer connMu.Unlock()

	if ch != nil && !ch.IsClosed() && conn != nil && !conn.IsClosed() {
		return ch, nil
	}

	// Nettoie l'état précédent
	if ch != nil {
		_ = ch.Close()
		ch = nil
	}
	if conn != nil {
		_ = conn.Close()
		conn = nil
	}

	if amqpURL == "" {
		return nil, errors.New("amqp url is empty")
	}

	c, err := amqp091.Dial(amqpURL)
	if err != nil {
		return nil, fmt.Errorf("amqp dial: %w", err)
	}

	newCh, err := c.Channel()
	if err != nil {
		_ = c.Close()
		return nil, fmt.Errorf("amqp channel: %w", err)
	}

	if err := declareExchanges(newCh); err != nil {
		_ = newCh.Close()
		_ = c.Close()
		return nil, err
	}
	startReturnLogger(newCh)

	conn = c
	ch = newCh
	return ch, nil
}

func declareExchanges(c *amqp091.Channel) error {
	if err := c.ExchangeDeclare(JobsEx, "direct", true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare exchange %s: %w", JobsEx, err)
	}
	if err := c.ExchangeDeclare(TelemetryEx, "topic", true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare exchange %s: %w", TelemetryEx, err)
	}
	if err := c.ExchangeDeclare(ResultsEx, "topic", true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare exchange %s: %w", ResultsEx, err)
	}
	return nil
}

func publishWithRetry(fn func(*amqp091.Channel) error) error {
	var lastErr error
	for i := 0; i < 3; i++ {
		c, err := ensureChannel()
		if err != nil {
			lastErr = err
			time.Sleep(2 * time.Second)
			continue
		}

		if err := fn(c); err != nil {
			lastErr = err
			if isConnErr(err) {
				resetConnection()
				time.Sleep(2 * time.Second)
				continue
			}
			return err
		}
		return nil
	}
	return lastErr
}

func isConnErr(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, amqp091.ErrClosed) {
		return true
	}
	var amqErr *amqp091.Error
	if errors.As(err, &amqErr) {
		return true
	}
	return false
}

func resetConnection() {
	connMu.Lock()
	defer connMu.Unlock()
	if ch != nil {
		_ = ch.Close()
	}
	if conn != nil {
		_ = conn.Close()
	}
	ch = nil
	conn = nil
}

func startReturnLogger(c *amqp091.Channel) {
	retCh := c.NotifyReturn(make(chan amqp091.Return, 1))
	go func() {
		for r := range retCh {
			log.Printf("[AMQP] UNROUTABLE publish corrId=%s rk=%s", r.CorrelationId, r.RoutingKey)
		}
	}()
}
