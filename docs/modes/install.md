# Install mode

Creates and seeds the `FR_*` repository (tables, indexes, views, config, rule catalog) in the current database.

## Safety

**Idempotent** — re-running is safe and does not drop existing tables (forward-only, D-038); upgrades add the v1.1 retention/purge-support indexes in place (D-199). Refuses system databases (D-004), read-only databases, and callers lacking `VIEW SERVER STATE` (D-118). Blocks downgrade (D-039). Optionally creates/updates SQL Agent jobs (`@CreateAgentJob=1`, D-005), skipped with external-scheduling guidance on Express and Azure SQL Database.

## Parameters

| Parameter | Meaning |
|---|---|
| `@CreateAgentJob` | Optional. `1` ensures two Agent jobs (idempotent; no duplicate jobs/steps/schedules): the per-minute `SQLFlightRecorder Collect` job with a Collect step followed by a Purge step, and the daily `SQLFlightRecorder Purge` backstop job (02:30 server time). Default 0. |

## Result set(s)

One row: `Status (Success/Error), DatabaseName, SchemaVersion, TableCount, Message`. With `@CreateAgentJob=1`, `Message` also states which jobs were ensured, or the external-scheduling guidance where SQL Agent is unavailable.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install', @CreateAgentJob = 1;
```

## Common failure modes

See troubleshooting: install refused (system DB / read-only / missing permission / downgrade). See [operations/troubleshooting.md](../operations/troubleshooting.md).

