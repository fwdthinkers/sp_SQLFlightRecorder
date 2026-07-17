# Safety review checklist (D-176)

Single source for "did we stay safe?". Paste this verbatim into a PR review when
the change touches the shipped artifact, a collector, a rule, or Purge. Every box
must be ticked or explicitly `n/a — <reason>` by a **maintainer** (D-158). It
mirrors the §9 forbidden lists and the charter pillars; keep it in sync with them.

## Reads and DMVs
- [ ] No forbidden DMVs/procs (D-136): `sys.dm_exec_query_plan`,
      `sys.dm_exec_text_query_plan`, `DBCC FREEPROCCACHE`, `sys.fn_dblog`,
      `xp_cmdshell`, `OPENROWSET`, cache-flush / shrink DBCCs, etc.
- [ ] No plan-XML shredding in T-SQL (D-015/D-046/D-082). `@IncludeQueryPlans`
      stays the reserved no-op.
- [ ] Every external `SELECT` is bounded: explicit `TOP(n) ORDER BY`, or a
      documented small-DMV allow-list entry (D-137).
- [ ] No reads of user-database tables (only `FR_*` and allow-listed catalogs).

## Session and concurrency
- [ ] `READ UNCOMMITTED` session-wide; no `NOLOCK` hints in output (D-017).
- [ ] `LOCK_TIMEOUT` / `DEADLOCK_PRIORITY LOW` / `XACT_ABORT` set (D-132/133/134).
- [ ] No stray `BEGIN TRAN` outside the sanctioned handlers; applock is released
      on every path, including errors (D-011).

## No permanent / risky changes
- [ ] No `sp_configure`, `ALTER SERVER/DATABASE`, `KILL`, `sp_query_store_force_plan`,
      index/stats mutation, shrink, or `TRUNCATE`.
- [ ] Anything sensitive is opt-in and surfaced in Help/Status with its cost
      (D-020/D-051/D-060/D-142).

## Rules and wording (§6.7)
- [ ] Recommendation text avoids "kill", "force the plan", "use NOLOCK",
      "shrink", "clear the plan cache", "the root cause is", unqualified
      "always"/"never".
- [ ] Uses "consider … only after validating that …", "correlates with",
      "is consistent with".
- [ ] Severity is per-rule constant, never auto-promoted by row count (D-069);
      any documented magnitude/class escalation is by criterion, not count.
- [ ] New rule reads FR_* only (D-014/D-081); RuleId is new and permanent (D-089).

## Purge
- [ ] Batched with an inter-batch pause and per-table TRY/CATCH; no `TRUNCATE`,
      no shrink, no index rebuild (D-139/D-140); children before parents (D-141).

## Contracts and schema
- [ ] Findings (16 col), Timeline (12 col), Markdown header (14 keys) unchanged
      (D-067/071/085).
- [ ] Schema change (if any) is forward-only and bumps `SchemaVersion` (D-038).
