# OpenHVX Agent

OpenHVX Agent executes Hyper-V operations through PowerShell and exchanges commands,
results, and host telemetry with the backend over RabbitMQ.

**Status:** active development. Durable execution and recovery are tested with
simulated host effects; real Windows/Hyper-V failure testing remains necessary.

## Documentation

| Guide | Contents |
| --- | --- |
| [Architecture](docs/architecture.md) | Component boundaries, message flow, and limitations |
| [Configuration](docs/configuration.md) | Host identity, RabbitMQ, storage, and journal settings |
| [Development](docs/development.md) | Build, local execution, tests, and CI |
| [Task protocol](docs/task-protocol.md) | Durable execution, acknowledgment, and recovery |

## Getting started

Use Windows with Hyper-V, PowerShell, and the Go version declared in `src/go.mod`.
Follow the [build instructions](docs/development.md#build-on-windows), then create a
private `config.json` using the [configuration guide](docs/configuration.md).
Keep configuration credentials and the durable journal out of Git.

Host installation and environment-specific infrastructure belong to deployment
automation maintained separately from this repository.

## License

[Apache-2.0](LICENCE.md).
