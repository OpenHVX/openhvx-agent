# OpenHVX Agent

Agent that executes Hyper-V actions with PowerShell and communicates with the Controller via AMQP (RabbitMQ).


## Requirements

### Build & move openhvx-cloudinit-iso.exe to src/powershell/bin

```powershell
cd tools/cloudinit-iso/src && go build && mv ./openhvx-cloudinit-iso.exe ../../../src/powershell/bin
```