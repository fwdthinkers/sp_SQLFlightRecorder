# Uninstall mode

Removes all `FR_*` objects, and both Agent jobs (collector and daily purge) if this tool created them.

## Safety

**Reversible-by-design cleanup.** `@WhatIf=1` previews without dropping, including both Agent jobs. `@PreserveRunLog=1` renames the run-log tables to timestamped archives instead of dropping them (D-183). Idempotent: an already-missing job or object never fails Uninstall. Safe on a database where Install never ran (returns a clean empty result).

## Parameters

| Parameter | Meaning |
|---|---|
| `@WhatIf` | `1` lists what would be dropped without dropping. |
| `@PreserveRunLog` | `1` archives `FR_RunLog`/`FR_RunLogStep` with a timestamped rename (default 0). |

## Result set(s)

`@WhatIf`: one row per object with the planned action. Otherwise one row: `Status, DatabaseName, Message`.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall', @WhatIf = 1;
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall', @PreserveRunLog = 1;
```

## Common failure modes

Refuses while a Collect is in progress. See [operations/troubleshooting.md](../operations/troubleshooting.md).

