// consumer.go
package amqp

import (
	"encoding/json"
	"fmt"
	"log"
	"time"

	amqp091 "github.com/rabbitmq/amqp091-go"
)

// AfterResult est un hook optionnel appelé juste après la publication du résultat.
// Laisse-le à nil si tu ne veux rien faire après les tasks.
// C'est le binaire agent (main) qui peut affecter: amqp.AfterResult = func(t Task){ ... }
var AfterResult func(Task)

type Task struct {
	TaskID        string                 `json:"taskId,omitempty"`
	AgentID       string                 `json:"agentId,omitempty"`
	Action        string                 `json:"action"`
	TenantID      string                 `json:"tenantId,omitempty"` // présent pour d'autres usages, l'inventaire reste tenant-agnostic
	Data          map[string]interface{} `json:"data,omitempty"`
	ReplyTo       string                 `json:"replyTo,omitempty"`
	CorrelationID string                 `json:"correlationId,omitempty"`
	Attempt       int                    `json:"attempt,omitempty"`
	MaxAttempts   int                    `json:"maxAttempts,omitempty"`
}

type HandlerFunc func(Task) (any, error)

func StartTaskConsumer(agentID string, handle HandlerFunc) error {
	if agentID == "" {
		return fmt.Errorf("agentID is required")
	}
	if handle == nil {
		return fmt.Errorf("task handler is required")
	}

	if _, err := ensureChannelWithRetry(3, 2*time.Second); err != nil {
		return fmt.Errorf("AMQP not initialized: %w", err)
	}

	go consumeLoop(agentID, handle)
	return nil
}

func consumeLoop(agentID string, handle HandlerFunc) {
	queueName := fmt.Sprintf("agent.%s.tasks", agentID)

	for {
		c, err := ensureChannelWithRetry(0, 3*time.Second)
		if err != nil {
			log.Printf("[AMQP] consumer channel error: %v (retrying in 5s)", err)
			time.Sleep(5 * time.Second)
			continue
		}

		// Queue et binding vers l'exchange jobs (rk = agentID)
		if _, err := c.QueueDeclare(queueName, true, false, false, false, nil); err != nil {
			log.Printf("[AMQP] declare %s: %v", queueName, err)
			resetConnection()
			time.Sleep(3 * time.Second)
			continue
		}
		if err := c.QueueBind(queueName, agentID, JobsEx, false, nil); err != nil {
			log.Printf("[AMQP] bind %s to %s: %v", queueName, JobsEx, err)
			resetConnection()
			time.Sleep(3 * time.Second)
			continue
		}

		// Limiter les messages non-ack en vol
		if err := c.Qos(5, 0, false); err != nil {
			log.Printf("[AMQP] qos error: %v", err)
			resetConnection()
			time.Sleep(3 * time.Second)
			continue
		}

		msgs, err := c.Consume(
			queueName,
			"agent-"+agentID, // consumer tag
			false,            // autoAck=false
			false,            // exclusive
			false,            // noLocal
			false,            // noWait
			nil,
		)
		if err != nil {
			log.Printf("[AMQP] consume setup error: %v (retrying)", err)
			resetConnection()
			time.Sleep(3 * time.Second)
			continue
		}

		log.Printf("[AMQP] consuming %s ...", queueName)
		for d := range msgs {
			var t Task
			if err := json.Unmarshal(d.Body, &t); err != nil {
				log.Printf("[TASK] invalid JSON: %v", err)
				_ = d.Nack(false, false) // drop poison
				continue
			}

			// Ignore si le message cible un autre agent
			if t.AgentID != "" && t.AgentID != agentID {
				_ = d.Ack(false)
				continue
			}

			result, hErr := handle(t)
			ok := (hErr == nil)

			if ok {
				_ = d.Ack(false)
			} else {
				log.Printf("[TASK] handler error | taskId=%s action=%s agentId=%s error=%v result=%#v",
					t.TaskID, t.Action, t.AgentID, hErr, result,
				)
				_ = d.Nack(false, false)
			}

			// ---- Publier le résultat sur l'exchange results ----
			corr := t.CorrelationID
			if corr == "" {
				corr = t.TaskID
			}

			// Détermine l'erreur principale à publier
			errMsg := ""
			if m, okCast := result.(map[string]any); okCast {
				if s, ok := m["error"].(string); ok && s != "" {
					errMsg = s
				}
			}
			if errMsg == "" && hErr != nil {
				errMsg = hErr.Error()
			}

			res := map[string]any{
				"taskId":     t.TaskID,
				"agentId":    agentID,
				"ok":         ok,
				"result":     result,
				"error":      errMsg,
				"finishedAt": time.Now().UTC().Format(time.RFC3339),
			}

			b, _ := json.Marshal(res)

			rk := "task." + t.TaskID
			if err := c.Publish(
				ResultsEx, rk,
				true,  // mandatory
				false, // immediate
				amqp091.Publishing{
					ContentType:   "application/json",
					DeliveryMode:  amqp091.Persistent,
					CorrelationId: corr,
					Body:          b,
				},
			); err != nil {
				log.Printf("[AMQP] publish result (exchange) error: %v", err)
			}

			// ---- Optionnel: compat queue replyTo ----
			if t.ReplyTo != "" {
				_, _ = c.QueueDeclare(t.ReplyTo, true, false, false, false, nil)
				if err := c.Publish(
					"", t.ReplyTo,
					true,
					false,
					amqp091.Publishing{
						ContentType:   "application/json",
						DeliveryMode:  amqp091.Persistent,
						CorrelationId: corr,
						Body:          b,
					},
				); err != nil {
					log.Printf("[AMQP] publish result (replyTo) error: %v", err)
				}
			}

			// ---- Hook post-publication (ex: déclencher inventory.refresh.light) ----
			if AfterResult != nil {
				go AfterResult(t) // non bloquant
			}
		}
		log.Printf("[AMQP] consumer stopped for %s (channel closed?), retrying...", queueName)
		time.Sleep(2 * time.Second)
	}
}
