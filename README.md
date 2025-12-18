# OpenHVX Agent

Agent that executes Hyper-V actions with PowerShell and communicates with the Controller over AMQP (RabbitMQ).

## Setup

### Build & move `openhvx-cloudinit-iso.exe`
Place the helper binary under `src/powershell/bin`:

```powershell
cd tools/cloudinit-iso/src && go build && mv ./openhvx-cloudinit-iso.exe ../../../src/powershell/bin
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
