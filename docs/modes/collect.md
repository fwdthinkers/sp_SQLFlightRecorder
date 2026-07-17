# Collect mode

Captures one bounded diagnostic snapshot into the `FR_*` repository.

## Safety

Applock-gated so collects cannot pile up (D-011); each collector is TRY/CATCH-isolated (D-009); bounded reads only; the parent `FR_Snapshot` is written after its children (D-135). No plan XML is captured; `@IncludeQueryPlans=1` records one Skipped step (reserved).

## Parameters

| Parameter | Meaning |
|---|---|
| `@TopN` | Per-collector row cap (default 50). |
| `@IncludeQueryPlans` | Reserved no-op; `1` records a Skipped QueryPlans step. |
| `@Debug` | `1` routes to CollectDebug (no collector rows). |

## Result set(s)

One row: `Status (Success/PartialSuccess/Skipped), RunId, SnapshotId, SnapshotUtc, Message`.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect', @TopN = 25;
```

## Common failure modes

`Skipped` when another Collect holds the applock; `PartialSuccess` when a collector fails (see `FR_RunLogStep`). See [operations/troubleshooting.md](../operations/troubleshooting.md).

