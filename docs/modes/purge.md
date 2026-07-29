# Purge mode

Batched retention cleanup of old repository rows.

## Safety

Applock-gated (D-011). Batched 5,000 rows with a 250 ms pause; per-table TRY/CATCH; children before parents (D-141); `FR_QueryText` orphans cleaned; **no** TRUNCATE/shrink/rebuild (D-140). `@WhatIf=1` is read-only. The applock is always released, even on a batch error (`PartialSuccess`).

## Parameters

| Parameter | Meaning |
|---|---|
| `@WhatIf` | `1` reports eligible row counts without deleting. |

## Result set(s)

`@WhatIf`: cutoffs + per-table eligible counts. Otherwise one row `Status, RowsDeleted, SnapshotCutoffUtc, RunLogCutoffUtc, Errors`.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 1;
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge';
```

## Common failure modes

`RowsDeleted=0` usually means nothing is past retention; large repos converge over multiple runs. See [operations/troubleshooting.md](../operations/troubleshooting.md).

