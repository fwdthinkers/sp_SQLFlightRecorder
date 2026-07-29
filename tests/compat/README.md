# Compatibility evidence (Tier-2 attestation helpers)

Helpers for producing a **Tier-2 attestation** — the human-verified evidence for
targets that free CI cannot containerize (SQL Server 2012/2014/2016 Windows,
Azure SQL Managed Instance, Azure SQL Database). The process, status
definitions, and staleness policy live in
[docs/compatibility/tier2-attestation.md](../../docs/compatibility/tier2-attestation.md);
the current matrix is [docs/compatibility/matrix.md](../../docs/compatibility/matrix.md).

These are non-invasive, run by an attester on their own server; they are not CI
and never run automatically (D-121). Tier-1 (automated container) targets are
covered by `tests/rules/` + the Docker matrix instead.

## Produce the evidence
1. In a **sandbox database**, run `sp_SQLFlightRecorder.sql` to create the
   procedure.
2. In that same database, run
   [collect-attestation-evidence.sql](collect-attestation-evidence.sql). It runs
   the minimum command set (About → Install → Status → Collect ×2 → Report →
   Purge @WhatIf → Uninstall) with section headers, and cleans up after itself.

   ```bash
   # sqlcmd example (adjust auth for your target)
   sqlcmd -S <server> -d <sandbox-db> -i tests/compat/collect-attestation-evidence.sql
   ```
   Or open both files in SSMS and run them against the sandbox database.

## Submit
Open a **Version compatibility / Tier-2 attestation** issue and paste in the
`About` version, the `Status` capability snapshot, and the per-step status
(including any Skipped/degraded collector and the `FR_R0026` coverage finding).
Scrub real query text / server names / credentials first — the template
requires confirming you did.

A run counts as a passing attestation when Install succeeds, both Collects
succeed with no error step, Report returns `FR_R0026`, and Uninstall leaves zero
`FR_*` objects. Degraded collectors are expected on cut-down editions and Azure
and do not fail an attestation.
