# Install mode

Creates and seeds the `FR_*` repository (tables, views, config, rule catalog) in the current database.

## Safety

**Idempotent** — re-running is safe and does not drop existing tables (forward-only, D-038). Refuses system databases (D-004), read-only databases, and callers lacking `VIEW SERVER STATE` (D-118). Blocks downgrade (D-039). Optionally creates a SQL Agent job (`@CreateAgentJob=1`, D-005), skipped on Express.

## Parameters

| Parameter | Meaning |
|---|---|
| `@CreateAgentJob` | Optional. `1` creates a per-minute Collect Agent job (default 0). |

## Result set(s)

One row: `Status (Success/Error), DatabaseName, SchemaVersion, TableCount, Message`.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install', @CreateAgentJob = 1;
```

## Common failure modes

See troubleshooting: install refused (system DB / read-only / missing permission / downgrade). See [operations/troubleshooting.md](../operations/troubleshooting.md).

