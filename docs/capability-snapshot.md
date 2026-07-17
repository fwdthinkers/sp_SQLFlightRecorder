# Capability snapshot

The tool branches on **capabilities**, never on `@@VERSION` string parsing
(D-111). A capability probe runs once per invocation (D-008) and is persisted to
`FR_RunLog.CapabilitySnapshot` per run (D-115), so old data still renders
correctly. The key set is **closed and documented per release; additive in
minors** (D-127). `Status` mode renders it as its sixth result set.

## Probe keys (persisted in `CapabilitySnapshot`)
| Key | Meaning |
|---|---|
| `EngineEdition` | `SERVERPROPERTY('EngineEdition')`: 2=Standard, 3=Enterprise/Developer, 4=Express, 5=Azure SQL DB, 8=Azure SQL MI. |
| `ProductMajorVersion` | Engine major (11=2012 … 17=2025). |
| `ProductLevel` | RTM/SP/CU level. |
| `Platform` | `Windows` or `Linux` (from `sys.dm_os_host_info` on 2017+; Windows otherwise). |
| `IsAzureSqlDb` / `IsAzureManagedInstance` | Azure SQL DB / MI flags. |
| `HasMsdb` / `HasAgent` | msdb / SQL Agent availability (absent on Azure SQL DB, Express Agent). |
| `IsHadrEnabled` | Always On availability. |
| `HasQueryStoreSupport` | Query Store available (2016+ / Azure). |
| `HasAdvancedHaSupport` | Advanced AG DMVs available (Box/MI; not Azure SQL DB). |
| `HasBufferPoolSupport` | Buffer-pool descriptors available (not Azure SQL DB). |
| `HasTimeZoneSupport` | `AT TIME ZONE` available (2016+/Azure); display-only (D-180). |
| `TargetServerMemoryMb` | Target server memory (gates the buffer-pool collector, D-051). |
| `SchemaVersion` | Installed repository schema version. |

## Additional keys rendered by `Status`
`Tool-Version`, `Part-Number`, `Schema-Version`, `Installed`, and the current
values of the collector/display config keys (`CollectQueryStore`,
`CollectErrorLog`, `CollectSchemaActivity`, `CollectPlanCacheSummary`,
`EnableAdvancedHaCollector`, `EnableBufferPoolCollector`, `BaselineLookbackHours`,
`TimeZoneMode`).

- **`PlanAnalysisSupport` is always `0`.** Plan capture and plan-XML analysis are
  disabled by design (D-015/046/082/136); the key stays in the closed set and
  reports `0` in every build. See [rules/FR_R0030.md](rules/FR_R0030.md).

## How to read it
```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';   -- 6th result set
-- or, per run:
SELECT CapabilitySnapshot FROM dbo.FR_RunLog WHERE Mode = N'Collect' ORDER BY RunId DESC;
```

Adding a probe key in a v1.x minor is an additive key-list bump (D-127); keys are
never removed or renamed within a major.
