# Architecture

The backend submits host commands through RabbitMQ. The agent consumes its dedicated
`agent.<agentId>.tasks` queue, validates the protocol envelope, and executes approved
operations through PowerShell. It publishes results for the backend to apply to its
transactional task, quota, and ownership state.

## Components

| Component | Responsibility |
| --- | --- |
| `src/main.go` | Configuration, host context, telemetry, recovery loop, and shutdown |
| `src/amqp` | Command validation, consumer lifecycle, execution coordination, confirmed results |
| `src/journal` | Durable operation identity, execution state, and result publication state |
| `src/tasks` | Action dispatch and read-only recovery adapters |
| `src/powershell` | Script execution and Hyper-V adapters |
| `tools/serial-bridge` | Serial console connection helper |
| `tools/cloudinit-iso` | Cloud-init ISO generation helper |

## Message flow

The agent declares durable `jobs` (direct), `results` (topic), and `agent.telemetry`
(topic) exchanges. Heartbeats use `heartbeat.<agentId>` and full inventories use
`inventory.<agentId>` telemetry routing keys. Broker permissions must permit the
required declarations, bindings, publications, and consumption.

Before a host action runs, the agent records its identity and execution intent in
its journal. It persists the outcome before publishing a confirmed result and
acknowledging the command. Redelivery reuses the recorded operation. See the
[task protocol](task-protocol.md) for the crash boundaries and recovery rules.

Serial console actions launch the bridge helper to connect to the backend
WebSocket broker. Console ownership and routing across backend replicas are managed
by the backend, outside this agent's local journal.

## Known limitations

The journal provides local ACID persistence. RabbitMQ and Hyper-V are separate
systems; they do not participate in the same database transaction.

Partial VM creation, uncertain restarts, and operations without a conclusive
observation adapter can require operator investigation. Reconciliation never
reruns an uncertain mutation merely to obtain a result.

CI runs on Linux with simulated Hyper-V cmdlets and host effects. Windows binaries
are cross-compiled; real host execution, abrupt host loss, journal backup/restore,
and cluster/network failures still require environment-level tests.
