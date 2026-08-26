# Status mode

Reports installation state, configuration, the rule catalog, recent runs, repository footprint, the capability snapshot, and retention/purge health.

## Safety

Read-only; reads only `FR_*`, allow-listed catalogs, and (where SQL Agent exists) msdb job metadata for the retention-health checks. Returns multiple result sets (Status is exempt from the two-result-set rule, which applies to Report).

## Parameters

| Parameter | Meaning |
|---|---|
| `(none)` | Status takes no tuning parameters. |

## Result set(s)

Seven result sets: installation summary; configuration; rule catalog; recent runs; repository size; capability snapshot; retention and purge health (`CheckName, CheckStatus, Detail` — warns when the oldest snapshot exceeds retention, purge is not keeping up, the collector job lacks a Purge step, the daily purge job is missing, or an `FR_*` table exceeds `RepositoryTableWarnRows`). Reading the health checks: `OK` needs nothing; `Warning` names the fix in `Detail` (schedule or repair Purge, re-run Install `@CreateAgentJob=1`, or lower retention); `NotApplicable` means the check does not apply here (e.g., no SQL Agent — schedule Collect and Purge externally); `Unknown` means msdb job metadata could not be read (permissions).

## Examples

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';
```

## Common failure modes

On a not-installed database, result sets return empty shells (stable shape). See [operations/troubleshooting.md](../operations/troubleshooting.md).

