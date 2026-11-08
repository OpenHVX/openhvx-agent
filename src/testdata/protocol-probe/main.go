// Test-only process bridge for the backend integration suite. It simulates a
// durable host effect; it never invokes PowerShell or manages a real VM.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"openhvx-agent/amqp"
	"openhvx-agent/journal"
	"os"
)

func main() {
	path := flag.String("journal", "", "test journal path")
	mode := flag.String("mode", "normal", "normal|after-effect|recover")
	flag.Parse()
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		panic(err)
	}
	command, err := amqp.DecodeCommand(raw, "probe-storage")
	if err != nil {
		panic(err)
	}
	store, err := journal.Open(*path)
	if err != nil {
		panic(err)
	}
	defer store.Close()
	if err = store.BindAgent("probe-storage"); err != nil {
		panic(err)
	}
	response := map[string]any{"disk": map[string]any{"id": command.OperationID, "name": "probe-disk"}}
	executor := amqp.NewExecutor(store, "probe-storage", func(amqp.Task) (any, error) {
		effect, err := os.OpenFile(*path+".effects", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
		if err != nil {
			return nil, err
		}
		if _, err = effect.WriteString(command.OperationID + "\n"); err != nil {
			effect.Close()
			return nil, err
		}
		if err = effect.Sync(); err != nil {
			effect.Close()
			return nil, err
		}
		effect.Close()
		if *mode == "after-effect" {
			os.Exit(44)
		}
		return response, nil
	}, func(amqp.Task) (any, bool, error) {
		if *mode != "recover" {
			return nil, false, nil
		}
		_, err := os.Stat(*path + ".effects")
		return response, err == nil, err
	})
	var result json.RawMessage
	if *mode == "recover" {
		pending, err := executor.Reconcile()
		if err != nil {
			panic(err)
		}
		if len(pending) != 1 {
			panic("one pending result required")
		}
		result = pending[0]
	} else {
		result, err = executor.Execute(command)
		if err != nil {
			panic(err)
		}
	}
	fmt.Println(string(result))
}
