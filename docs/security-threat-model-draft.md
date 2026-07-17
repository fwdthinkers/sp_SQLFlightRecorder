# Security & Threat Model — DRAFT (staging for design.md §12/§13)

> **Status: DRAFT / structure sample.** This staging document establishes the
> structure and representative content for the two design-doc sections deferred
> to v1.0 (Q-041, Q-042). Before v1.0.0 it folds into `docs/design.md`:
> the security/threat model becomes **§12** and the appendices become **§13**.
> `SECURITY.md` at the repo root carries the disclosure process; this document
> carries the analysis. Prose marked *(representative)* is a sample of the
> intended depth, not the final complete text.

---

## §12 — Security & Threat Model (Q-041)

### 12.1 Purpose and scope
What this tool does and does not defend against, why its default behavior is
safe, and what an operator must do to keep it safe. Scope is the shipped
artifact and the local `FR_*` repository — not the SQL Server instance's own
security posture.

### 12.2 Assets
| Asset | Sensitivity | Notes |
|---|---|---|
| `FR_QueryText` | **High** | May contain literal parameter values embedded in ad-hoc SQL (PII, secrets). |
| `FR_Request` / `FR_QueryStoreTopN` | Medium | Query hashes, session IDs, database IDs; no plan XML (never captured). |
| `FR_ErrorLog` (opt-in) | Medium–High | Error-log text may contain object names, paths, principal names. |
| Shipped artifact (`sp_SQLFlightRecorder.sql`) | Integrity-critical | A tampered artifact runs with the installer's permissions. |
| Caller permissions | — | `VIEW SERVER STATE` required; sysadmin discouraged (D-118). |

### 12.3 Threat actors and trust boundaries
| Actor | Capability | In-scope concern | Posture |
|---|---|---|---|
| Installer / operating DBA | Can install and run all modes; holds `VIEW SERVER STATE` | That the tool over-reaches or makes permanent changes | Least privilege: sysadmin is discouraged (D-118); no permanent server/security changes by default (D-003/D-021); opt-in for anything sensitive. |
| Non-DBA with read access to the repository DB | Can `SELECT` from `FR_*` | Exposure of query text / error-log text | The repository can hold sensitive strings; restrict `SELECT` on `FR_*` to a scoped role, not `public` (12.5). |
| Contributor / supply chain | Submits changes to the artifact | A malicious or unsafe change reaching users | Single-file, human-reviewable artifact (D-110/D-152); CI static analysis rejects forbidden DMVs / plan shredding (D-136/D-144); two-reviewer rule for the artifact (D-158). |
| Scheduler / automation identity | Runs `Collect` on a schedule | Excess privilege on the job account | Collect needs only `VIEW SERVER STATE`; the optional Agent job is opt-in (D-005). |

**Trust boundaries.** The tool trusts the SQL Server instance it runs in and the
account that installs it. It does **not** attempt to defend against a compromised
instance, OS, or cloud control-plane — those are the platform's remit and are out
of scope. The security-relevant boundary is between the `FR_*` repository (which
may hold sensitive data) and whoever can read that database.

### 12.4 Controls (threat → control → decision)
| Risk | Control | Decision |
|---|---|---|
| Plan-cache OOM / stalls from plan shredding | No plan APPLY DMVs; no plan-XML parsing; `@IncludeQueryPlans` is a reserved no-op | D-015/046/082/136 |
| Unbounded / lock-heavy reads | Every external SELECT bounded by `TOP(n) ORDER BY` or a small-DMV allow-list; forbidden-DMV list CI-enforced | D-136/137/144 |
| Blocking user workload | `READ UNCOMMITTED`, `LOCK_TIMEOUT`, `DEADLOCK_PRIORITY LOW`; diagnostic always loses | D-017/133/134 |
| Permanent server changes | Nothing permanent by default; error-log scrape, buffer pool, Agent job, CHECKDB capture all opt-in | D-003/005/020/051/060 |
| Sensitive data at rest | Bounded fields, no `NVARCHAR(MAX)` on hot rows; retention configurable; full `Uninstall` | D-040/183 |
| Unsafe recommendations | Wording rules forbid `KILL`/force-plan/NOLOCK/shrink; drill-down queries are read-only | D-076/086 |

### 12.5 Data-sensitivity handling & recommendations
- Treat `FR_QueryText` and `FR_ErrorLog` as potentially sensitive.
- Recommended: a dedicated `FR_reader` role; do not grant repository `SELECT` to
  `public`; consider a shorter `SnapshotRetentionDays` where query text is
  sensitive; `Uninstall` removes everything (D-183).

### 12.6 Residual risks
Human-enforced wording discipline (D-076/D-189) and the modeled-not-measured
storage/latency envelopes (D-188) are tracked risks, not guarantees.

### 12.7 Reporting a vulnerability
See [`SECURITY.md`](../SECURITY.md).

---

## §13 — Appendices (Q-042)

### A. Glossary (starter)
| Term | Meaning |
|---|---|
| Finding | A prioritized observation with Severity/Confidence/EvidenceType (Findings result set). |
| Timeline | Chronological events for the window (Timeline result set). |
| Coverage finding | A finding about data completeness (gaps, skipped collectors), not an incident. |
| Observed vs Inferred | Evidence type: directly captured vs. reasoned from a signal. |
| Tier 1 / 2 / 3 | Automated CI / manual attestation / community reports (D-120/121/166). |
| Headline vs contributor rule | A rule that folds others' findings into its `MoreInfo` vs. the folded rule (§7.13). |
| Capability snapshot | The closed key set describing the engine, persisted per run (D-127). |

### B. References (starter)
- Microsoft Learn: the DMVs each collector reads (`sys.dm_os_wait_stats`,
  `sys.dm_io_virtual_file_stats`, `sys.dm_exec_requests`, Query Store views).
- Community: Paul Randal on wait statistics; Query Store guidance.
- Keep a Changelog 1.1.0 (CHANGELOG format, D-175).

### C. Master Charter
Literal quotation of the original charter, so the design doc is self-contained
(to be inserted at fold-in time).

### D. Failure-mode catalog
Canonical reprint of [`docs/operations/troubleshooting.md`](operations/troubleshooting.md)
(D-147).

---

### Fold-in plan
1. Move §12 content into `docs/design.md` §12 (replacing the deferred stub),
   trimming duplication with the decisions it cites.
2. Move §13 outline into `docs/design.md` §13; the failure-mode catalog stays
   authored in `docs/operations/troubleshooting.md` and is reprinted in §13.D.
3. Delete this staging file once folded, or leave a redirect note.
