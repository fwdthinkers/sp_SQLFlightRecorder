# Open Questions — SQL Server DBA Flight Recorder

This file tracks **unresolved** design and process questions only. Questions resolved during the design conversation appear in `docs/decisions.md` (each resolution is the D-### that became the answer) and in `docs/design.md` Appendix A (the cross-reference table).

**Status at last update (post design lock review):** No design-time questions remain open. Q-001 through Q-040 are all resolved. Q-041, Q-042, and Q-043 below are *new* questions raised by the design lock review or by the deferred sections of the design document. They are non-blocking for v0.1 implementation.

---

## Open question template

Each open question carries:

- **Q-###** — stable identifier (append-only, never reused, never renumbered, matching the convention of resolved questions in `docs/decisions.md`).
- **Question** — the specific decision needed.
- **Why it matters** — what's blocked or at risk if it stays unresolved.
- **Tentative lean** — the current best guess; not binding.
- **Target resolution phase** — the release or milestone by which this must be answered.

---

## Open questions

### Q-041 — Security/threat model for §12 of the design doc

- **Question:** What is the explicit threat model the tool defends against, and what is the security posture documentation (SECURITY.md content, data-sensitivity disclosures for repository contents including cached query text and parameter values)?
- **Why it matters:** Section 12 of the design doc is currently marked Deferred. The design lock review (`docs/design-lock-review.md` §5) explicitly called out that no security review was performed. Without this, v1.0 cannot ship a credible security posture statement, and organizations with formal security review gates may be unable to adopt the tool.
- **Why it's not blocking v0.1:** v0.1 already operates under the strict charter pillars (permission tiers D-118, no permanent changes by default, opt-in for anything sensitive). The *behavior* is conservative; what's missing is the *documented threat model* explaining why that behavior is sufficient.
- **Tentative lean:** Write Section 12 before v1.0. Scope likely includes:
  - Threat model (insider DBA with VSS; non-DBA with read access to repository; supply-chain risk on the shipped artifact)
  - Data sensitivity classification of `FR_QueryText` and related tables (query text may contain literal parameter values that are PII / secrets)
  - Repository access controls recommendation (grant `SELECT` on `FR_*` to a tightly-scoped role, not to public)
  - SECURITY.md disclosure process (private reporting channel, expected response time, coordinated disclosure)
  - Permissions audit walkthrough (how to verify the tool is not doing more than D-118 allows)
- **Target resolution phase:** v1.0 (must be resolved before v1.0 GA per §11.6 acceptance criteria; not required for v0.1, v0.2, v0.3, or v0.4).

---

### Q-042 — Appendices content for §13 of the design doc

- **Question:** What goes into Section 13 (Appendices) of the design document? Glossary, references, charter quotation, reprint of failure-mode catalog?
- **Why it matters:** Section 13 is currently marked Deferred. Without it, the design document is not fully self-contained for someone reading it outside the GitHub repository. The Master Charter language is referenced throughout the design but never quoted in full inside `docs/design.md`.
- **Why it's not blocking v0.1:** Implementation does not depend on glossary or charter quotation; the decision log and the design body carry sufficient context.
- **Tentative lean:** Write Section 13 before v1.0. Likely content:
  - **A. Glossary** — Findings vs Timeline vs Coverage; Observed vs Inferred vs Possible vs Needs Validation; Tier 1/2/3; Headline rule vs contributor rule; Capability snapshot
  - **B. References** — Microsoft documentation pointers per DMV used; community references for the rule pack (e.g., Paul Randal on wait stats, Erik Darling on Query Store); Keep a Changelog 1.1.0 spec
  - **C. Master Charter** — literal quotation of the original charter so the design doc is self-contained
  - **D. Failure-mode catalog** — reprint of §9.9, currently held in `docs/operations/troubleshooting.md` per the §10.1 repo layout, canonically reproduced in the design doc
- **Target resolution phase:** v1.0 (must be resolved before v1.0 GA; not required for v0.1, v0.2, v0.3, or v0.4).

---

### Q-043 — How is D-188 empirical validation actually solicited and verified?

- **Question:** D-188 commits the project to reporting observed Collect durations and repository growth from "at least one external production-class install" before tagging v0.2. What is the concrete mechanism? A GitHub Discussions thread with a fixed template? A dedicated issue label (`empirical-attestation`) parallel to the Tier 2 compatibility attestation flow (D-164)? A required field in the v0.2 release-notes generation script?
- **Why it matters:** D-188 is a release-process gate. Without a concrete mechanism, it risks becoming an informal "we should…" rather than a real blocker. The design lock review made it binding; v0.2 release planning needs to know *how* to satisfy it.
- **Why it's not blocking v0.1:** v0.1 release does not have this requirement. The gate applies at v0.2 tag time.
- **Tentative lean:** Mirror the Tier 2 attestation process (D-164):
  - A GitHub issue template `empirical-attestation.yml` (a 9th issue template, additive to the 8 listed in D-156)
  - Auto-opened by the same workflow that opens Tier 2 attestation issues at each RC
  - Fields: SQL Server version, edition, platform, approximate workload class (OLTP/DW/mixed), observed median Collect duration over a stated observation period, observed repository growth per day at default retention, any notable FR_R0026 findings
  - Closed by the reporter when filled in; release-notes script reads closed `empirical-attestation` issues for the current RC and includes a summary
  - Same staleness rule as Tier 2: if no attestations for 3 consecutive minors, the project should consider whether the operating-envelope claim is honest
- **Target resolution phase:** v0.2 release-planning (before v0.2 RC opens; not blocking v0.1 implementation).

---

## Summary

| Open Q | Subject | Blocking v0.1? | Target phase |
|---|---|---|---|
| Q-041 | Security/threat model (§12) | No | v1.0 |
| Q-042 | Appendices content (§13) | No | v1.0 |
| Q-043 | D-188 empirical-validation mechanism | No | v0.2 release planning |

**No open question blocks v0.1 implementation.** v0.1 implementation planning may proceed.

When any of these is resolved, append the resolution as a new D-### entry in `docs/decisions.md`, update `docs/design.md` Appendix A with the cross-reference, and remove the question from this file.

---

*Append-only file. Do not edit or renumber resolved questions; they live in `docs/decisions.md`.*
