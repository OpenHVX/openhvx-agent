# Durable task execution — protocol v2

The agent now requires a protocol v2 envelope with a canonical UTF-8 `commandBody`,
SHA-256 `commandFingerprint`, `operationId == taskId`, `eventId` and matching
`agentId`. Only the immutable inner command is executed. The agent announces
`task.protocol.v2` after opening its durable journal.

## Local state

Set `journalPath` in `config.json` to an absolute, persistent path, for example
`D:\DATA\agent-state\operations.db`. If omitted, the agent derives it from an
absolute `basePath`. The journal belongs to one agent identity; one process can open
it at a time. Back it up with the host identity. Never delete it, move to an empty
journal, or reuse the agentId on another host to retry a command of unknown outcome.
Protect the directory and backups with Windows ACLs. There is no automatic retention
expiry because old operation identities must remain deduplicated.

The bbolt transaction before execution persists intent with fsync. The transaction
after execution persists the result and stable event identity. A duplicate returns
the stored result. A crash between those transactions never permits another call
to the effectful handler. Result publication uses a dedicated confirm channel and
mandatory returns; the command is acknowledged only after confirmation and journal
marking. Unpublished reconciled results also survive process loss.

The journal stores recovery identifiers and results, not the complete command data.
Results may contain operational information and must still be protected.

## Outcomes and recovery

- `applied`: the required action completed, or a read-only observation proves the
  desired state. The backend may consume the reservation.
- `not_applied`: a definitive no-effect rejection, currently an unsupported action
  rejected before invoking a script. The backend may release the reservation.
- `unknown`: a script error, crash or inconclusive observation. The backend retains
  the hold and locks and exposes `reconciling`.

Each newer observation gets an increasing sequence and a stable persisted eventId.
The reconciler runs every 15 seconds and only reads host state. It currently proves
VM creation through its final operation/hash marker, deletion through a successful
observation of GUID absence, and power start/stop through desired VM state.
Running does not prove a requested restart occurred. Partial creations, ambiguous
restarts and other unproved outcomes remain unresolved instead of being executed
again. This prioritizes safety; some failures still require operator investigation
or additional observation/compensation adapters.

Hyper-V mutations use the selected VM/component objects rather than rediscovering
by display name. Failed host reads are not treated as absence. PowerShell scripts
are never automatically executed a second time based on their stderr.

## Compatibility

Drain the old command pipeline before updating agent and backend together. Commands
without protocol v2 are durably quarantined in `agent.<agentId>.tasks.invalid` before
acknowledgment. `AMQP_QUEUE_TYPE=classic|quorum` must match the backend and existing
queue declarations; changing the type requires an explicit broker migration.

This is local ACID journaling plus at-least-once transport and reconciliation, not
a distributed ACID transaction with Hyper-V or a guarantee of automatic recovery
from every partial host mutation. SHA-256 is a content identity, not a signature;
RabbitMQ producer permissions and transport authentication remain required.
