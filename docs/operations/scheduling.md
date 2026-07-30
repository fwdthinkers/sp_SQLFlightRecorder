# Scheduling guidance by platform

`sp_SQLFlightRecorder` does not schedule itself. The intended pattern is a
**scheduled `Collect`** plus an **on-demand `Report`** (D-024) — running
`CollectAndReport` on a schedule is explicitly not recommended.

Which scheduler to use depends on what the platform actually offers, and that is
a capability question, not a preference. Check your own instance first:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';
```

`HasAgent` and `HasMsdb` in the capability snapshot decide the answer. The
platform sections below match the attested evidence in
[../compatibility/matrix.md](../compatibility/matrix.md).

---

## Linux — SQL Server 2017+ on Linux
No SQL Agent dependency is assumed. Use **`cron` + `sqlcmd`**.

```cron
# /etc/cron.d/sqlflightrecorder — every minute
* * * * * sqlsvc /opt/mssql-tools18/bin/sqlcmd -S localhost -d DBA \
  -Q "EXEC dbo.sp_SQLFlightRecorder @Mode=N'Collect';" \
  >> /var/log/sqlfr/collect.log 2>> /var/log/sqlfr/collect.err
```

Every five minutes instead — a reasonable default on a busy instance:

```cron
*/5 * * * * sqlsvc /opt/mssql-tools18/bin/sqlcmd -S localhost -d DBA \
  -Q "EXEC dbo.sp_SQLFlightRecorder @Mode=N'Collect';" \
  >> /var/log/sqlfr/collect.log 2>> /var/log/sqlfr/collect.err
```

- **Capture both streams.** `>>` for stdout and `2>>` for stderr, as above. A
  silent cron job that has been failing for a week is worse than no job.
- **Least privilege.** Run as a dedicated service account with `VIEW SERVER
  STATE` and write access to the repository database — not `sa`.
- **Secrets.** Prefer integrated auth where available. Otherwise put credentials
  in a file readable only by the job's user and pass `-P` from it, or use an
  environment variable injected by your secret store; never inline a password in
  the crontab, which is world-readable on many systems.
- Rotate `/var/log/sqlfr/*` with `logrotate` like any other service log.

---

## Azure SQL Managed Instance
**SQL Agent is available** (`HasAgent = 1`, `HasMsdb = 1` in the attested
capability snapshot). Use a SQL Agent job — it is the simplest correct answer.

Job step, type *Transact-SQL script (T-SQL)*, database = your repository
database:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';
```

Then attach a schedule — every minute, or every five minutes to start. Nothing
MI-specific is required beyond pointing the step at the right database.

**Alternative:** any external scheduler works equally well if you would rather
keep scheduling outside the database — see the Azure SQL Database section for
options; they all apply to MI too.

---

## Azure SQL Database
**There is no SQL Agent and no msdb** (`HasAgent = 0`, `HasMsdb = 0`). Scheduling
must come from outside the database. Options, roughly in order of how naturally
they fit:

- **Azure Elastic Jobs** — purpose-built for running T-SQL against Azure SQL
  Database on a schedule.
- **Azure Automation** runbook.
- **Azure Function** on a timer trigger.
- **A container or VM running cron**, using the Linux recipe above with `-S`
  pointing at the Azure SQL Database endpoint.

Whatever the host, the statement is the same:

```sql
EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';
```

Elastic Jobs sketch — the shape, not a runnable script; group and credential
setup is Azure-side configuration:

```sql
-- In the Elastic Job agent's job database:
EXEC jobs.sp_add_job
     @job_name = N'sqlfr-collect',
     @description = N'sp_SQLFlightRecorder Collect';

EXEC jobs.sp_add_jobstep
     @job_name    = N'sqlfr-collect',
     @command     = N'EXEC dbo.sp_SQLFlightRecorder @Mode=N''Collect'';',
     @credential_name = N'<job-credential>',
     @target_group_name = N'<target-group>';

EXEC jobs.sp_add_jobschedule
     @job_name = N'sqlfr-collect',
     @enabled  = 1,
     @schedule_interval_type = N'Minutes',
     @schedule_interval_count = 5;
```

**Skipped collectors are normal here.** On Azure SQL Database the attested run
skips four collectors by design, and the `Report` coverage finding
(`FR_R0026`) states each reason:

| Collector | Why it skips |
|---|---|
| `AgentJobs` | msdb and SQL Agent unavailable |
| `BackupHistory` | msdb unavailable |
| `Deadlocks` | no `system_health` ring buffer on Azure SQL Database |
| `AlwaysOnState` | not enabled |

These are capability-gated skips, not failures — the collect run still returns
`Success`. Do not treat them as an incident.

---

## All platforms
- **Leave the expensive collectors off unless you need them.** `CollectErrorLog
  = 0` and `EnableBufferPoolCollector = 0` are the defaults for good reason
  (D-020, D-051). Turn one on deliberately, for a specific question, and
  consider turning it back off afterwards.
- **Run `Report` periodically**, not on the collection schedule — it is the
  on-demand half of the pattern:
  ```sql
  EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report';
  ```
- **Check `Purge` before it surprises you.** Preview first; it never deletes in
  preview mode:
  ```sql
  EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 1;
  ```
- **Times are UTC.** Snapshots are stored in UTC (D-016); the Markdown report
  header shows the offset. Reconcile with local time when comparing against an
  incident timeline.
- **Retention is a setting, not a guess.** Snapshots are kept per the configured
  retention and `FR_RunLog` outlives them 4× (D-035). Review with
  `@Mode = N'Configure'`.
- **Write down the uninstall path before you need it.** Removal is complete and
  reversible-by-omission:
  ```sql
  EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall';                     -- removes all FR_* objects
  EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall', @PreserveRunLog = 1; -- keeps an archived run log
  ```
  Disable or delete the scheduled job **first**, or it will keep firing against a
  database with no procedure. Confirm afterwards that no `FR_*` objects remain —
  both Azure attestations verified `RemainingFrObjects = 0`.

## See also
- [../compatibility/matrix.md](../compatibility/matrix.md) — what is verified, on which platform, with what evidence.
- [../compatibility/support-policy.md](../compatibility/support-policy.md) — the support promises.
- [troubleshooting.md](troubleshooting.md) — failure-mode catalog.
- [../modes/collect.md](../modes/collect.md) · [../modes/report.md](../modes/report.md) · [../modes/purge.md](../modes/purge.md)
