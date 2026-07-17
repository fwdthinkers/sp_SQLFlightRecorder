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

### 12.3 Threat actors and trust boundaries *(representative)*
- **Insider DBA with `VIEW SERVER STATE`.** In-scope for *least privilege*: the
  tool never requires sysadmin for its default feature set (D-118) and makes no
  permanent server/security changes by default (charter pillar, D-003/D-021).
- **Non-DBA with read access to the repository database.** Can read `FR_*`
  including `FR_QueryText`. Mitigation: **grant `SELECT` on `FR_*` to a scoped
  role, not `public`** (see 12.5).
- **Supply-chain / artifact tampering.** The single-file model (D-110/D-152)
  makes the artifact easy to review and hash before install; the CI static
  analysis (D-136/D-144) rejects forbidden DMVs/plan shredding.
- **Out of scope:** network attackers against SQL Server itself, OS-level
  compromise, and Azure control-plane threats — these are the platform's remit.

### 12.4 Security posture (already enforced) *(representative)*
- No permanent security/config changes by default; every sensitive collector is
  opt-in (`xp_readerrorlog` D-020/D-060; buffer pool D-051; Agent job D-005;
  `@IncludeQueryPlans` reserved/disabled D-015/D-046/D-082/D-136).
- Plans are never shredded; the forbidden-DMV list is CI-enforced (D-136/D-144).
- `READ UNCOMMITTED` session-wide with no `NOLOCK` hints in output (D-017);
  bounded reads only (D-137); `LOCK_TIMEOUT`/`DEADLOCK_PRIORITY LOW` (D-133/134).

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

- **A. Glossary** — Findings vs Timeline vs Coverage; Observed / Inferred /
  Possible / Needs-Validation; Tier 1/2/3; headline vs contributor rule;
  capability snapshot.
- **B. References** — Microsoft DMV docs per collector; community wait-stats /
  Query Store references; Keep a Changelog 1.1.0.
- **C. Master Charter** — literal quotation so the design doc is self-contained.
- **D. Failure-mode catalog** — canonical reprint of
  [`docs/operations/troubleshooting.md`](operations/troubleshooting.md) (D-147).

---

### Fold-in plan
1. Move §12 content into `docs/design.md` §12 (replacing the deferred stub),
   trimming duplication with the decisions it cites.
2. Move §13 outline into `docs/design.md` §13; the failure-mode catalog stays
   authored in `docs/operations/troubleshooting.md` and is reprinted in §13.D.
3. Delete this staging file once folded, or leave a redirect note.
