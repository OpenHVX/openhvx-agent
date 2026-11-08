# Configuration

The agent reads a JSON file selected with `-config`; the default is `config.json`
in the current working directory. Real `config.json` files are ignored by Git.
The executable does not load backend `.env` profiles.

```json
{
  "agentId": "HOST-OPENHVX-HYPERV-001",
  "rabbitmqUrl": "amqps://agent-user:REPLACE_ME@rabbitmq.example.test:5671/",
  "heartbeatIntervalSec": 30,
  "inventoryIntervalSec": 60,
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

## Settings

| Setting | Meaning |
| --- | --- |
| `agentId` | Stable host identity; must match backend routing and inventory identity |
| `rabbitmqUrl` | Reachable AMQP URI with dedicated broker credentials |
| `heartbeatIntervalSec` | Heartbeat interval; defaults to 30 for omitted/nonpositive values |
| `inventoryIntervalSec` | Full inventory interval; defaults to 60 for omitted/nonpositive values |
| `basePath` | Managed host data root; use a stable absolute Windows path |
| `journalPath` | Absolute persistent journal path; defaults to `basePath/agent-state/operations.db` |
| `capabilities` | Advertised capabilities; defaults to `inventory` and `vm.power` when empty |

The agent adds `task.protocol.v2` after opening its journal. Do not manually add it
as a substitute for a working journal. Configure capabilities to match the host's
actual supported actions and prerequisites.

## Environment variables

| Variable | Meaning |
| --- | --- |
| `AMQP_QUEUE_TYPE` | `classic` (default) or `quorum`; must match backend and existing queues |
| `AMQP_INTEGRATION_URL` | Test-only broker URI; enables RabbitMQ integration tests |
| `PWSH_BINARY` | Test-only override for the PowerShell executable used by adapter tests |

The backend test runner accepts `AGENT_SOURCE_DIR` pointing at this repository's
`src`; it is not an agent runtime setting.

## Persistent state and credentials

Keep the journal on durable local storage, with Windows ACLs restricting access to
the agent account and authorized administrators. Protect its backups alongside the
host identity. The journal has no automatic retention expiry.

Do not delete the journal, substitute an empty journal, or reuse the same `agentId`
on another host to retry an operation with an unknown outcome. One process opens a
journal at a time. See [recovery semantics](task-protocol.md#outcomes-and-recovery).

Use authenticated broker access and TLS appropriate to the environment. Credentials,
certificates, host provisioning, and service installation belong to deployment
automation. Changing queue type requires coordinated broker migration; changing an
environment variable does not convert an existing queue.
