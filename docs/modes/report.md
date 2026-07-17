# Report mode

`Report` reads the local `FR_*` repository and returns prioritized **Findings**
and a chronological **Timeline** for a time window. It reads no live DMVs
(D-081), makes no changes, and is deterministic (D-062): the same window over
the same data returns byte-identical output.

## Synopsis
```sql
EXEC dbo.sp_SQLFlightRecorder
    @Mode         = N'Report',
    @StartTime    = NULL,          -- server local time; default: 1 hour back
    @EndTime      = NULL,          -- server local time; default: now
    @MinSeverity  = N'Low',        -- Informational|Low|Medium|High|Critical
    @MaxFindings  = 200,           -- 10..2000
    @DatabaseName = NULL,          -- optional DB filter (post-evaluation)
    @OutputFormat = N'Default',    -- Default|FindingsOnly|TimelineOnly|Markdown
    @IncludeQueryPlans = 0;        -- reserved / no-op (see below)
```

## Parameters
| Parameter | Meaning |
|---|---|
| `@StartTime` / `@EndTime` | Window bounds, **server local time** (D-180); stored/sorted as UTC. Default window is the last hour. `@StartTime` must be `< @EndTime`. |
| `@MinSeverity` | Post-evaluation filter (D-070). **Critical and Coverage rows are never hidden** (D-083). |
| `@MaxFindings` | Final-output cap, 10–2000 (D-087). See truncation below. |
| `@DatabaseName` | Drops DB-bound findings for other databases; instance-level and Coverage rows are retained. |
| `@OutputFormat` | See Output formats. |
| `@IncludeQueryPlans` | **Reserved / no-op.** Plan capture and plan-XML analysis are disabled by design (D-015/046/082/136). `1` emits exactly one Informational coverage finding saying so. |

## Result sets (the public contract)
`Default` returns exactly two result sets (D-006):

1. **Findings — 16 columns (D-067, frozen):** `FindingOrdinal, Severity,
   Confidence, EvidenceType, Category, RuleId, Title, Summary, Evidence,
   Recommendation, DatabaseName, ObjectName, SessionId, StartTimeUtc, EndTimeUtc,
   MoreInfo`.
2. **Timeline — 12 columns (D-071, frozen):** `EventUtc, EventType, Category,
   Severity, Summary, DatabaseName, ObjectName, SessionId, RuleId, RunId,
   SnapshotId, MoreInfo`. Chronological; durations are paired `*Started`/`*Ended`
   events (D-072).

## Deterministic order (D-068)
Findings sort by **Severity → Confidence → EvidenceType → StartTimeUtc → RuleId**,
with Informational last. `FindingOrdinal` is the 1..N display rank in that order.

## `@MaxFindings` overflow (D-087)
If more than `@MaxFindings` findings remain after filtering, the lowest-ranked
**non-Critical, non-Coverage** rows are dropped and one Informational Coverage
row records the truncation. Critical and Coverage rows are never truncated, so
the returned count can exceed `@MaxFindings` when Criticals alone do.

## Coverage honesty
- Fewer than 2 snapshots → a Critical Informational "insufficient coverage"
  finding, and the report still proceeds (D-065).
- Gaps > 2× the interval → graded Coverage findings (D-066).
- No rule fired → a single Informational "no findings" row (D-077/083) — the
  report is never silently empty.

## Output formats
| Format | Returns |
|---|---|
| `Default` | Findings + Timeline (two result sets). |
| `FindingsOnly` | Findings only. |
| `TimelineOnly` | Timeline only. |
| `Markdown` | One `nvarchar(max)` column `Report` with a 14-key machine-parseable header (D-085) plus `## Findings` / `## Timeline` sections. |

## Examples
```sql
-- Last hour, default.
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report';

-- A specific window, high severity only, Markdown for pasting into a ticket.
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report',
    @StartTime = '2026-07-17 01:00', @EndTime = '2026-07-17 02:00',
    @MinSeverity = N'High', @OutputFormat = N'Markdown';
```

## Safety notes
Report is read-only, reads only `FR_*`, and never parses plan XML. See
[operations/troubleshooting.md](../operations/troubleshooting.md) for
"no findings", coverage, and gap symptoms.
