package amqp

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	amqp091 "github.com/rabbitmq/amqp091-go"
	"openhvx-agent/journal"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestRabbitMQConfirmedResultsAndDuplicateCommands(t *testing.T) {
	url := os.Getenv("AMQP_INTEGRATION_URL")
	if url == "" {
		t.Skip("AMQP_INTEGRATION_URL not set")
	}
	if err := InitPublisher(url); err != nil {
		t.Fatal(err)
	}
	client, err := amqp091.Dial(url)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	channel, err := client.Channel()
	if err != nil {
		t.Fatal(err)
	}
	defer channel.Close()
	id := fmt.Sprintf("integration-%d", time.Now().UnixNano())
	operation := "op-" + id
	queue := "agent." + id + ".tasks"
	if _, err = channel.QueueDeclare(queue, true, false, false, false, queueOptions()); err != nil {
		t.Fatal(err)
	}
	if err = channel.QueueBind(queue, id, JobsEx, false, nil); err != nil {
		t.Fatal(err)
	}
	resultQueue, err := channel.QueueDeclare("", false, true, true, false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err = channel.QueueBind(resultQueue.Name, "task."+operation, ResultsEx, false, nil); err != nil {
		t.Fatal(err)
	}
	results, err := channel.Consume(resultQueue.Name, "", true, true, false, false, nil)
	if err != nil {
		t.Fatal(err)
	}
	store, err := journal.Open(filepath.Join(t.TempDir(), "operations.db"))
	if err != nil {
		t.Fatal(err)
	}
	var count atomic.Int32
	executor := NewExecutor(store, id, func(Task) (any, error) { count.Add(1); return map[string]any{"completed": true}, nil }, nil)
	ctx, cancel := context.WithCancel(context.Background())
	done, err := StartTaskConsumer(ctx, id, executor)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		cancel()
		<-done
		ClosePublisher()
		store.Close()
		channel.QueueDelete(queue, false, false, false)
		channel.QueueDelete(queue+".invalid", false, false, false)
	}()
	inner, _ := json.Marshal(map[string]any{"operationId": operation, "agentId": id, "tenantId": "integration-tenant", "action": "echo", "data": map[string]any{}})
	hash := sha256.Sum256(inner)
	body, _ := json.Marshal(Task{TaskID: operation, OperationID: operation, EventID: "command-" + operation, ContractVersion: 2, CommandBody: string(inner), CommandFingerprint: hex.EncodeToString(hash[:])})
	var first string
	for i := 0; i < 2; i++ {
		if err = publishConfirmed(ctx, JobsEx, id, body, "command-"+operation); err != nil {
			t.Fatal(err)
		}
		select {
		case delivery := <-results:
			if i == 0 {
				first = string(delivery.Body)
			} else if first != string(delivery.Body) {
				t.Fatal("duplicate command changed its durable result")
			}
		case <-time.After(10 * time.Second):
			t.Fatal("result delivery timed out")
		}
	}
	if count.Load() != 1 {
		t.Fatal("command executed more than once")
	}
	if err = publishConfirmed(ctx, JobsEx, id, []byte(`{"invalid":true}`), "invalid-command"); err != nil {
		t.Fatal(err)
	}
	found := false
	for i := 0; i < 100; i++ {
		_, ok, err := channel.Get(queue+".invalid", true)
		if err != nil {
			t.Fatal(err)
		}
		if ok {
			found = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !found {
		t.Fatal("invalid command was not quarantined")
	}
}
