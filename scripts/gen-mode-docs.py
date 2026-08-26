#!/usr/bin/env python3
# =============================================================================
# scripts/gen-mode-docs.py
# -----------------------------------------------------------------------------
# Generates docs/modes/<mode>.md for every mode except the hand-authored
# flagship report.md. Build-pipeline tooling (D-148; D-169). Content is authored
# here; docs/modes/report.md is the style reference and is not overwritten.
#
# Usage:  python scripts/gen-mode-docs.py            # write pages
#         python scripts/gen-mode-docs.py --check    # fail if out of date
# =============================================================================
from __future__ import annotations
import sys
from pathlib import Path

MODES_DIR = Path(__file__).resolve().parents[1] / "docs" / "modes"
KEEP = {"report"}

# mode -> dict(title, purpose, safety, params[(name,desc)], results, examples[],
#              failure)
M = {
 "help": dict(
   title="Help mode",
   purpose="Prints usage, the mode list, parameters, and the charter pillars to the Messages tab. This is the **default** mode, so accidentally executing the procedure does nothing harmful (D-003).",
   safety="Read-only and inert. No repository, no DMV reads. Output is via PRINT (Messages tab), not a result set.",
   params=[("(none)","Help ignores other parameters.")],
   results="No result set; text on the Messages tab.",
   examples=["EXEC dbo.sp_SQLFlightRecorder;", "EXEC dbo.sp_SQLFlightRecorder @Mode = N'Help';"],
   failure="If your client suppresses PRINT output, use `About` for a machine-readable one-row result instead."),
 "about": dict(
   title="About mode (alias: Version)",
   purpose="Returns tool version and build metadata as one row, so a DBA can answer \"what version is this?\" without opening the file.",
   safety="Read-only and inert.",
   params=[("@Mode","`About` or its alias `Version`.")],
   results="One row: `ToolVersion, BuildDateUtc, SupportedSqlServerRange, ImplementationPart, InvocationUtc`.",
   examples=["EXEC dbo.sp_SQLFlightRecorder @Mode = N'About';","EXEC dbo.sp_SQLFlightRecorder @Mode = N'Version';"],
   failure="n/a."),
 "install": dict(
   title="Install mode",
   purpose="Creates and seeds the `FR_*` repository (tables, indexes, views, config, rule catalog) in the current database.",
   safety="**Idempotent** — re-running is safe and does not drop existing tables (forward-only, D-038); upgrades add the v1.1 retention/purge-support indexes in place (D-199). Refuses system databases (D-004), read-only databases, and callers lacking `VIEW SERVER STATE` (D-118). Blocks downgrade (D-039). Optionally creates/updates SQL Agent jobs (`@CreateAgentJob=1`, D-005), skipped with external-scheduling guidance on Express and Azure SQL Database.",
   params=[("@CreateAgentJob","Optional. `1` ensures two Agent jobs (idempotent; no duplicate jobs/steps/schedules): the per-minute `SQLFlightRecorder Collect` job with a Collect step followed by a Purge step, and the daily `SQLFlightRecorder Purge` backstop job (02:30 server time). Default 0." )],
   results="One row: `Status (Success/Error), DatabaseName, SchemaVersion, TableCount, Message`. With `@CreateAgentJob=1`, `Message` also states which jobs were ensured, or the external-scheduling guidance where SQL Agent is unavailable.",
   examples=["EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install';","EXEC dbo.sp_SQLFlightRecorder @Mode = N'Install', @CreateAgentJob = 1;"],
   failure="See troubleshooting: install refused (system DB / read-only / missing permission / downgrade)."),
 "uninstall": dict(
   title="Uninstall mode",
   purpose="Removes all `FR_*` objects, and both Agent jobs (collector and daily purge) if this tool created them.",
   safety="**Reversible-by-design cleanup.** `@WhatIf=1` previews without dropping, including both Agent jobs. `@PreserveRunLog=1` renames the run-log tables to timestamped archives instead of dropping them (D-183). Idempotent: an already-missing job or object never fails Uninstall. Safe on a database where Install never ran (returns a clean empty result).",
   params=[("@WhatIf","`1` lists what would be dropped without dropping."),("@PreserveRunLog","`1` archives `FR_RunLog`/`FR_RunLogStep` with a timestamped rename (default 0).")],
   results="`@WhatIf`: one row per object with the planned action. Otherwise one row: `Status, DatabaseName, Message`.",
   examples=["EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall', @WhatIf = 1;","EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall';","EXEC dbo.sp_SQLFlightRecorder @Mode = N'Uninstall', @PreserveRunLog = 1;"],
   failure="Refuses while a Collect is in progress. See troubleshooting."),
 "status": dict(
   title="Status mode",
   purpose="Reports installation state, configuration, the rule catalog, recent runs, repository footprint, the capability snapshot, and retention/purge health.",
   safety="Read-only; reads only `FR_*`, allow-listed catalogs, and (where SQL Agent exists) msdb job metadata for the retention-health checks. Returns multiple result sets (Status is exempt from the two-result-set rule, which applies to Report).",
   params=[("(none)","Status takes no tuning parameters.")],
   results="Seven result sets: installation summary; configuration; rule catalog; recent runs; repository size; capability snapshot; retention and purge health (`CheckName, CheckStatus, Detail` — warns when the oldest snapshot exceeds retention, purge is not keeping up, the collector job lacks a Purge step, the daily purge job is missing, or an `FR_*` table exceeds `RepositoryTableWarnRows`).",
   examples=["EXEC dbo.sp_SQLFlightRecorder @Mode = N'Status';"],
   failure="On a not-installed database, result sets return empty shells (stable shape)."),
 "configure": dict(
   title="Configure mode",
   purpose="Reads or updates a known `FR_Config` key.",
   safety="Writes only `FR_Config`; validates the key against the known set, integer keys against an integer value, and retention keys against their allowed ranges (`SnapshotRetentionDays` 1-31, `RunLogRetentionDays` 1-124, D-199); audits the change in `FR_RunLog`. Unknown keys and out-of-range values are refused without updating `FR_Config`.",
   params=[("@ConfigKey","The key to update. NULL returns all config."),("@ConfigValue","The new value (required when `@ConfigKey` is given).")],
   results="Read (no key): the full config. Write: one row `Status, ConfigKey, OldConfigValue, NewConfigValue, Message`.",
   examples=["EXEC dbo.sp_SQLFlightRecorder @Mode = N'Configure';","EXEC dbo.sp_SQLFlightRecorder @Mode = N'Configure', @ConfigKey = N'SnapshotRetentionDays', @ConfigValue = N'7';"],
   failure="Unknown key -> `UnknownConfigKey`; non-integer for an integer key or an out-of-range retention value -> `InvalidConfigValue`. See [configuration.md](../configuration.md)."),
 "collect": dict(
   title="Collect mode",
   purpose="Captures one bounded diagnostic snapshot into the `FR_*` repository.",
   safety="Applock-gated so collects cannot pile up (D-011); each collector is TRY/CATCH-isolated (D-009); bounded reads only; the parent `FR_Snapshot` is written after its children (D-135). No plan XML is captured; `@IncludeQueryPlans=1` records one Skipped step (reserved).",
   params=[("@TopN","Per-collector row cap (default 50)."),("@IncludeQueryPlans","Reserved no-op; `1` records a Skipped QueryPlans step."),("@Debug","`1` routes to CollectDebug (no collector rows).")],
   results="One row: `Status (Success/PartialSuccess/Skipped), RunId, SnapshotId, SnapshotUtc, Message`.",
   examples=["EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect';","EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect', @TopN = 25;"],
   failure="`Skipped` when another Collect holds the applock; `PartialSuccess` when a collector fails (see `FR_RunLogStep`). See troubleshooting."),
 "collectdebug": dict(
   title="CollectDebug mode",
   purpose="Validates collector readiness without writing collector rows; the safe way to check a new install.",
   safety="Writes a single `FR_RunLog` row with `Mode='CollectDebug'` and **no** collector/snapshot rows (D-128). Reached via `@Mode='CollectDebug'` or `@Mode='Collect', @Debug=1`.",
   params=[("@Debug","With `@Mode='Collect'`, routes here.")],
   results="One status row plus a readiness result set listing which `FR_*` tables are present.",
   examples=["EXEC dbo.sp_SQLFlightRecorder @Mode = N'CollectDebug';","EXEC dbo.sp_SQLFlightRecorder @Mode = N'Collect', @Debug = 1;"],
   failure="Requires Install first."),
 "purge": dict(
   title="Purge mode",
   purpose="Batched retention cleanup of old repository rows. **Purge is mandatory operational maintenance**: without it the `FR_*` tables grow without bound and Report slows or times out.",
   safety="Applock-gated (D-011). Batched 5,000 rows with a 250 ms pause; per-table TRY/CATCH; children before parents (D-141); `FR_QueryText` orphans cleaned; **no** TRUNCATE/shrink/rebuild (D-140). `@WhatIf=1` is read-only. The applock is always released, even on a batch error (`PartialSuccess`). Agent-capable installs created with `@CreateAgentJob=1` run Purge automatically (post-collect step + daily backstop job, D-199); everyone else must schedule `@WhatIf = 0` themselves.",
   params=[("@WhatIf","`1` reports eligible row counts without deleting. `0` (default) performs the deletes.")],
   results="`@WhatIf`: cutoffs + per-table eligible counts. Otherwise one row `Status, RowsDeleted, SnapshotCutoffUtc, RunLogCutoffUtc, Errors`.",
   examples=["EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 1;","EXEC dbo.sp_SQLFlightRecorder @Mode = N'Purge', @WhatIf = 0;"],
   failure="`RowsDeleted=0` usually means nothing is past retention; large repos converge over multiple runs. Status result set 7 warns when purge is not keeping up. See troubleshooting."),
 "installdemodata": dict(
   title="InstallDemoData mode",
   purpose="Inserts clearly-synthetic demo rows so Report shows sample findings without a real incident.",
   safety="Refuses if **real** (non-demo) snapshots exist — it never mixes demo and real data. Idempotent: re-running replaces prior demo rows. All demo rows carry the `SQLFlightRecorder-DEMO` fingerprint.",
   params=[("(none)","Uses fixed synthetic data.")],
   results="One row: `Status, Message, SnapshotsCreated, DemoMarker, ToolVersion`.",
   examples=["EXEC dbo.sp_SQLFlightRecorder @Mode = N'InstallDemoData';","EXEC dbo.sp_SQLFlightRecorder @Mode = N'Report';"],
   failure="`Refused/RealDataPresent` if real snapshots exist — use a dedicated sandbox database."),
 "collectandreport": dict(
   title="CollectAndReport mode",
   purpose="Runs a bounded Collect then a Report in one call. **Documented as non-recommended** (D-024): the real value is scheduled Collect + on-demand Report.",
   safety="Re-invokes the procedure for Collect then Report; `@Debug` routes the inner Collect to CollectDebug. Same safety as the two modes it chains.",
   params=[("@TopN / @IncludeQueryPlans / @Debug","Forwarded to Collect."),("@DatabaseName / @StartTime / @EndTime / @MinSeverity / @MaxFindings / @OutputFormat","Forwarded to Report.")],
   results="Collect's status row, then Report's result sets.",
   examples=["EXEC dbo.sp_SQLFlightRecorder @Mode = N'CollectAndReport';"],
   failure="Requires Install first. Prefer scheduled Collect + on-demand Report."),
}

def page(mode, d):
    lines = [f"# {d['title']}", "", d["purpose"], "",
             "## Safety", "", d["safety"], "",
             "## Parameters", "", "| Parameter | Meaning |", "|---|---|"]
    for name, desc in d["params"]:
        lines.append(f"| `{name}` | {desc} |")
    lines += ["", "## Result set(s)", "", d["results"], "",
              "## Examples", "", "```sql"]
    lines += d["examples"]
    fail = d["failure"].replace(" See troubleshooting.", "").rstrip()
    lines += ["```", "",
              "## Common failure modes", "", fail +
              " See [operations/troubleshooting.md](../operations/troubleshooting.md).", ""]
    return "\n".join(lines)

def main():
    check = "--check" in sys.argv
    MODES_DIR.mkdir(parents=True, exist_ok=True)
    stale = []
    for mode, d in M.items():
        p = MODES_DIR / f"{mode}.md"
        new = page(mode, d) + "\n"
        if check:
            if not p.exists() or p.read_text(encoding="utf-8") != new:
                stale.append(p.name)
        else:
            p.write_text(new, encoding="utf-8", newline="\n")
    if check:
        if stale:
            print("STALE mode docs (run scripts/gen-mode-docs.py):", ", ".join(stale)); return 1
        print("mode docs up to date."); return 0
    print(f"generated {len(M)} mode pages (kept {sorted(KEEP)}).")
    return 0

if __name__ == "__main__":
    sys.exit(main())
