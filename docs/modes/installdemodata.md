# InstallDemoData mode

Inserts clearly-synthetic demo rows so Report shows sample findings without a real incident.

## Safety

Refuses if **real** (non-demo) snapshots exist — it never mixes demo and real data. Idempotent: re-running replaces prior demo rows. All demo rows carry the `SQLFlightRecorder-DEMO` fingerprint.

## Parameters

| Parameter | Meaning |
|---|---|
| `(none)` | Uses fixed synthetic data. |

## Result set(s)

One row: `Status, Message, SnapshotsCreated, DemoMarker, ToolVersion`.

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'InstallDemoData';
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report';
```

## Common failure modes

`Refused/RealDataPresent` if real snapshots exist — use a dedicated sandbox database. See [operations/troubleshooting.md](../operations/troubleshooting.md).

