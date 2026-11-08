package amqp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"openhvx-agent/journal"
	"time"
)

var AfterResult func(Task)

type Task struct {
	TaskID             string                 `json:"taskId,omitempty"`
	OperationID        string                 `json:"operationId,omitempty"`
	EventID            string                 `json:"eventId,omitempty"`
	ContractVersion    int                    `json:"contractVersion,omitempty"`
	CommandBody        string                 `json:"commandBody,omitempty"`
	CommandFingerprint string                 `json:"commandFingerprint,omitempty"`
	AgentID            string                 `json:"agentId,omitempty"`
	Action             string                 `json:"action"`
	TenantID           string                 `json:"tenantId,omitempty"`
	Data               map[string]interface{} `json:"data,omitempty"`
	CorrelationID      string                 `json:"correlationId,omitempty"`
}
type HandlerFunc func(Task) (any, error)

func StartTaskConsumer(ctx context.Context, agentID string, executor *Executor) (<-chan struct{}, error) {
	if agentID == "" || executor == nil {
		return nil, fmt.Errorf("agent ID and durable executor required")
	}
	if _, err := ensureChannelWithRetry(3, 2*time.Second); err != nil {
		return nil, err
	}
	done := make(chan struct{})
	go func() { defer close(done); consumeLoop(ctx, agentID, executor) }()
	return done, nil
}

func consumeLoop(ctx context.Context, agentID string, executor *Executor) {
	queue := "agent." + agentID + ".tasks"
	for ctx.Err() == nil {
		shared, err := ensureChannelWithRetry(3, time.Second)
		if err != nil {
			time.Sleep(time.Second)
			continue
		}
		// A dedicated consumer channel prevents telemetry confirms/returns from
		// sharing acknowledgment state with command delivery.
		c, err := sharedConnectionChannel(shared)
		if err != nil {
			continue
		}
		invalid := queue + ".invalid"
		_, err = c.QueueDeclare(invalid, true, false, false, false, queueOptions())
		if err != nil {
			c.Close()
			time.Sleep(time.Second)
			continue
		}
		_, err = c.QueueDeclare(queue, true, false, false, false, queueOptions())
		if err == nil {
			err = c.QueueBind(queue, agentID, JobsEx, false, nil)
		}
		if err != nil {
			c.Close()
			time.Sleep(time.Second)
			continue
		}
		if err = c.Qos(1, 0, false); err != nil {
			c.Close()
			continue
		}
		messages, err := c.Consume(queue, "agent-"+agentID, false, true, false, false, nil)
		if err != nil {
			c.Close()
			time.Sleep(time.Second)
			continue
		}
		running := true
		for running {
			select {
			case <-ctx.Done():
				c.Close()
				return
			case delivery, open := <-messages:
				if !open {
					running = false
					break
				}
				task, decodeErr := DecodeCommand(delivery.Body, agentID)
				if decodeErr != nil {
					// Quarantine must be confirmed before removing the poison command.
					if err = publishConfirmed(ctx, "", invalid, delivery.Body, delivery.MessageId); err != nil {
						delivery.Nack(false, true)
						c.Close()
						running = false
						break
					}
					delivery.Ack(false)
					log.Printf("[TASK] invalid command quarantined")
					continue
				}
				result, execErr := executor.Execute(task)
				if execErr != nil {
					// Journal failures never permit an untracked host effect. Identity
					// conflicts remain poison, all other failures are retried safely.
					if isJournalConflict(execErr) {
						err = publishConfirmed(ctx, "", invalid, delivery.Body, delivery.MessageId)
						if err == nil {
							delivery.Ack(false)
							continue
						}
					}
					delivery.Nack(false, true)
					c.Close()
					running = false
					time.Sleep(time.Second)
					break
				}
				if err = PublishTaskResult(ctx, result); err != nil {
					delivery.Nack(false, true)
					c.Close()
					running = false
					time.Sleep(time.Second)
					break
				}
				if err = executor.MarkPublished(result); err != nil {
					delivery.Nack(false, true)
					c.Close()
					running = false
					break
				}
				if err = delivery.Ack(false); err != nil {
					c.Close()
					running = false
					break
				}
				if AfterResult != nil {
					AfterResult(task)
				}
			}
		}
		c.Close()
	}
}
func PublishTaskResult(ctx context.Context, body json.RawMessage) error {
	var identity struct {
		TaskID  string `json:"taskId"`
		EventID string `json:"eventId"`
	}
	if err := json.Unmarshal(body, &identity); err != nil {
		return err
	}
	return publishConfirmed(ctx, ResultsEx, "task."+identity.TaskID, body, identity.EventID)
}

func isJournalConflict(err error) bool { return errors.Is(err, journal.ErrConflict) }
