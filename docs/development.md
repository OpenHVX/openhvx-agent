# Development

Use the Go version declared in `src/go.mod`. Host execution requires Windows with
Hyper-V management cmdlets and permissions to manage the selected resources.
PowerShell 7 (`pwsh`) is preferred; the runtime also supports Windows PowerShell.

## Build on Windows

From the repository root in PowerShell:

```powershell
New-Item -ItemType Directory -Force src/powershell/bin | Out-Null
Push-Location tools/cloudinit-iso/src
go build -o ../../../src/powershell/bin/openhvx-cidata-iso.exe .
Pop-Location
Push-Location tools/serial-bridge/src
go build -o ../../../src/powershell/bin/openhvx-serial-bridge.exe .
Pop-Location
Push-Location src
go build -o openhvx-agent.exe .
Pop-Location
```

Keep the `powershell` tree and helper binaries available alongside the agent's
runtime files. The helpers have their own Go modules and are built separately.

## Local execution

Create `src/config.json` using the [configuration guide](configuration.md), then
run from `src` in PowerShell:

```powershell
.\openhvx-agent.exe -config .\config.json
```

The executable runs as a foreground process; Windows service installation is a
separate deployment concern. Keep the configured journal path stable across
restarts and upgrades.

The diagnostic `-dry-run -modules heartbeat` and `-dry-run -modules inventory`
modes print JSON without connecting to AMQP. Inventory mode still invokes host
scripts and can create the managed data directories; it is not a side-effect-free
preview of a task.

## Checks

From `src`:

```bash
go vet ./...
go test -race ./...
go build ./...
GOOS=windows GOARCH=amd64 go build -o /tmp/openhvx-agent.exe .
```

The final command is for cross-compilation from Linux. Build both helper modules
separately as shown above, using the same target platform for a Windows package.

Set `AMQP_INTEGRATION_URL` to a dedicated disposable RabbitMQ broker to include
real messaging tests. Without it, that test is skipped. PowerShell adapter tests
use `pwsh` on PATH or `PWSH_BINARY`; they are skipped if PowerShell is unavailable.
They parse actual scripts and simulate Hyper-V cmdlets.

Process-crash tests simulate host effects using fsynced test files. The
`src/testdata/protocol-probe` program is a test helper. The shared vector
`src/amqp/testdata/task-v2.json` must match the backend fixture. The backend suite
uses a neighboring agent checkout or an explicit `AGENT_SOURCE_DIR` pointing to
this repository's `src` for its cross-language recovery test.

## Continuous integration

[Agent checks](../.github/workflows/agent.yml) runs on pushes and pull requests.
It starts temporary RabbitMQ, installs Go, runs static analysis, PowerShell syntax
checks, tests with the race detector, and builds the agent plus both helpers for
Windows. It neither publishes release binaries nor installs or deploys the agent.

The backend workflow independently tests a pinned compatible agent commit. Changes
to the protocol require publishing the agent commit and updating that backend pin.
A green agent workflow alone does not establish backend compatibility or validate
execution on real Hyper-V hosts.

## Upgrades

Drain the old command pipeline and coordinate backend/agent protocol upgrades.
Preserve host identity and durable journal, back them up, and reconcile uncertain
operations before making incompatible changes. Follow the
[compatibility rules](task-protocol.md#compatibility); queue migrations and rollback
need explicit operational planning.
