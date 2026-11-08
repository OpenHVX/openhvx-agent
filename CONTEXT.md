# Repository context

This is the OpenHVX Hyper-V agent repository. The backend and deployment automation
live in separate repositories. Start with [README.md](README.md); maintain current
behavior in English guides under `docs/`, using lowercase, topic-based filenames.

Core constraints:

- `src/amqp` validates protocol v2 commands and coordinates execution and delivery.
- `src/journal` persists operation identity and results with bbolt before acknowledgment.
- `src/tasks` adapts commands to PowerShell actions under `src/powershell/actions`.
- Unknown host outcomes trigger read-only reconciliation, never blind re-execution.
- The durable journal belongs to one stable agent identity and must survive restarts.
- RabbitMQ delivery and Hyper-V effects do not form one distributed ACID transaction.
- `tools/` contains the serial bridge and cloud-init ISO helper, with separate Go modules.

See [development checks](docs/development.md#checks) for validation and
[known limitations](docs/architecture.md#known-limitations) for remaining work.
