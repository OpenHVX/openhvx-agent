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

// ⚠️ Appelle d'abord InitPublisher(...) (dans publisher.go) pour initialiser conn/ch
func StartTaskConsumer(agentID string, handle HandlerFunc) error {
	if ch == nil || conn == nil {
		return fmt.Errorf("AMQP not initialized: call InitPublisher(...) first")
	}

	queueName := fmt.Sprintf("agent.%s.tasks", agentID)

	// Queue et binding vers l'exchange jobs (rk = agentID)
	if _, err := ch.QueueDeclare(queueName, true, false, false, false, nil); err != nil {
		return fmt.Errorf("declare %s: %w", queueName, err)
	}
	if err := ch.QueueBind(queueName, agentID, JobsEx, false, nil); err != nil {
		return fmt.Errorf("bind %s to %s: %w", queueName, JobsEx, err)
	}

	// Limiter les messages non-ack en vol
	if err := ch.Qos(5, 0, false); err != nil {
		return fmt.Errorf("qos: %w", err)
	}

	msgs, err := ch.Consume(
		queueName,
		"agent-"+agentID, // consumer tag
		false,            // autoAck=false
		false,            // exclusive
		false,            // noLocal
		false,            // noWait
		nil,
	)
	if err != nil {
		return fmt.Errorf("consume: %w", err)
	}

	go func() {
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
			if err := ch.Publish(
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
				_, _ = ch.QueueDeclare(t.ReplyTo, true, false, false, false, nil)
				if err := ch.Publish(
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
		log.Printf("[AMQP] consumer stopped for %s", queueName)
	}()

	return nil
}
