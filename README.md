# OpenHVX Agent

Agent that executes Hyper-V actions with PowerShell and communicates with the Controller over AMQP (RabbitMQ).

See [durable task execution v2](docs/task-protocol-v2.md) for the journal, compatibility, recovery and tests.

## Setup

### Build `openhvx-cidata-iso.exe`
Place the helper binary under `src/powershell/bin`:

```powershell
cd tools/cloudinit-iso/src
New-Item -ItemType Directory -Force ../../../src/powershell/bin | Out-Null
go build -o ../../../src/powershell/bin/openhvx-cidata-iso.exe .
```

### Build the serial console helper

```powershell
cd tools/serial-bridge/src
New-Item -ItemType Directory -Force ../../../src/powershell/bin | Out-Null
go build -o ../../../src/powershell/bin/openhvx-serial-bridge.exe .
```

### Configure the agent
Create `src/config.json` before starting the service. Example:

```json
{
  "agentId": "HOST-OPENHVX-HYPERV-001",
  "rabbitmqUrl": "amqp://guest:guest@192.168.1.35:5672/",
  "heartbeatIntervalSec": 60,
  "inventoryIntervalSec": 120,
  "basePath": "D:\\DATA",
  "journalPath": "D:\\DATA\\agent-state\\operations.db",
  "capabilities": [
    "inventory",
    "vm.power",
    "vm.create",
    "vm.delete",
    "echo",
    "console",
    "vm.edit"
  ]
}
```

Adjust the AMQP URL, base path, and capabilities to fit your environment.

### Telemetry
The agent publishes operational telemetry to the RabbitMQ topic exchange `agent.telemetry`:
- Heartbeats every `heartbeatIntervalSec` to routing key `heartbeat.<agentId>` with version, host, and capabilities.
- Inventory snapshots every `inventoryIntervalSec` to routing key `inventory.<agentId>`; the body contains the raw inventory payload produced by the agent.
Make sure the exchange exists on your broker if you manage RabbitMQ manually.
