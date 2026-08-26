# Purge mode

Batched retention cleanup of old repository rows. **Purge is mandatory operational maintenance**: without it the `FR_*` tables grow without bound and Report slows or times out.

## Safety

Applock-gated (D-011). Batched 5,000 rows with a 250 ms pause; per-table TRY/CATCH; children before parents (D-141); `FR_QueryText` orphans cleaned; **no** TRUNCATE/shrink/rebuild (D-140). `@WhatIf=1` is read-only. The applock is always released, even on a batch error (`PartialSuccess`). Agent-capable installs created with `@CreateAgentJob=1` run Purge automatically (post-collect step + daily backstop job, D-199); everyone else must schedule `@WhatIf = 0` themselves.

## Parameters

| Parameter | Meaning |
|---|---|
| `@WhatIf` | `1` reports eligible row counts without deleting. `0` (default) performs the deletes. |

## Result set(s)

`@WhatIf`: cutoffs + per-table eligible counts. Otherwise one row `Status, RowsDeleted, SnapshotCutoffUtc, RunLogCutoffUtc, Errors`.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 1;
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 0;
```

## Common failure modes

`RowsDeleted=0` usually means nothing is past retention; large repos converge over multiple runs. Status result set 7 warns when purge is not keeping up. See [operations/troubleshooting.md](../operations/troubleshooting.md).

