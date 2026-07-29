# Wording-lock review (D-076 / D-189, §6.7)

**Date:** 2026-07-21 · **Release:** v1.0.0-rc.1 · **Scope:** all user-facing
recommendation, finding, and message text in `sp_SQLFlightRecorder.sql`.

The §6.7 wording rules (D-076) are human-enforced and, per **D-189**, an ongoing
maintainer responsibility rather than one-time setup. This document records the
systematic pre-v1.0 review pass. Per **D-193**, owner sign-off is sufficient for
the v1.0.0 wording lock — see "Sign-off" below.

## What §6.7 forbids
Recommendation wording must not say: *"kill session," "force the plan," "use
NOLOCK," "shrink," "clear the plan cache," "the root cause is,"* or *"always" /
"never"* without qualification. Wording must stay advisory, evidence-based, and
operationally conservative.

## Method
1. Case-insensitive scans of every `N'…'` string literal for each forbidden
   term and for alarmist/causal phrasing (`immediately`, `urgent`, `you must`,
   `caused by`, `due to`, …).
2. A full read of all 25 finding **Recommendation** strings (the rules that emit
   findings) plus the Help/About/Status text.

## Result — no wording changes required
Every recommendation is advisory and **evidence-gated**: the pattern is
"*consider reviewing … only after validating …*" / "*… before acting*", never a
prescriptive or causal instruction. Where an action would be risky, the text
explicitly warns against doing it reflexively.

| Forbidden term | Result | Evidence in the artifact |
|---|---|---|
| `kill session` | **Absent** | No occurrence. |
| `force the plan` | **Absent** as advice | Only the *guards* "Do not force a plan automatically" (FR_R0015) and "Do not force or unforce plans automatically" (FR_R0018), plus factual description of an already-forced plan's failures. |
| `use NOLOCK` | **Absent** | No occurrence. |
| `shrink` | **Absent** | No occurrence. |
| `clear the plan cache` | **Absent** as advice | Only the guard "Do not clear the plan cache reflexively" (FR_R0020). |
| `the root cause is` | **Absent** | The single `root cause` mention is the disclaimer "Inferred signal; not a confirmed root cause." |
| unqualified `always` / `never` | **Absent** | All occurrences are either the SQL Server **Always On** feature/table/rule name, or *qualified* statements of the tool's own deterministic guarantees (e.g. "never shreds plan XML"; "Coverage … always emitted"; "never truncated (D-070/D-083)") — not claims about the user's system. |

Representative conservative recommendations (unchanged):

- FR_R0015: "Consider reviewing this query in Query Store only after validating
  the regression is real and sustained. **Do not force a plan automatically.**"
- FR_R0020: "Consider reviewing ad hoc workload and parameterization only after
  validating the compilation rate is sustained. **Do not clear the plan cache
  reflexively.**"
- FR_R0025: "Confirm the backup schedule and chain; consider a FULL backup **only
  after validating RPO requirements.**"
- FR_R0023: "Investigate blocking chains and high session counts; consider
  reviewing max worker threads **only after validating sustained starvation.**"

No column, rule ID, category, severity, or logic was touched — this pass is
review-only.

## Sign-off
D-076/D-189 make wording compliance a standing two-maintainer discipline (§6.7,
D-158): the second reviewer on any PR touching `FR_Rules` seed data or rule logic
must have re-read §6.7 and the safety checklist (D-176) within 30 days.

This repository has one maintainer, so that countersignature cannot be obtained.
**D-193** resolves it: owner sign-off is sufficient for the final v1.0.0 wording
lock, and two-maintainer review resumes automatically — D-158 and D-189 applying
again in full, including the 30-day rule — as soon as a second maintainer exists
or the project moves to an organization/team model. D-193 narrows *who signs
off*; it does not weaken what §6.7 requires of the wording.

| | |
|---|---|
| Review recorded | 2026-07-21 (this document); re-confirmed against the unchanged artifact 2026-07-29 |
| Artifact reviewed | `ToolVersion 1.0.0-rc.1`, SHA256 `2ae4c475…` |
| Reviewer | Ysaias Portes / @forward-thinkers-lab, 2026-07-29 |
| Status | ✅ **Owner sign-off complete** |

**Scope of this sign-off against the shipped `1.0.0` artifact.** The signature
above was given on the `1.0.0-rc.1` artifact. The `1.0.0` artifact differs from
it **only in version metadata** — `ToolVersion`, the build date, and three
comment lines — with no change to any recommendation, finding, or message
string. Verified by diff. The wording reviewed above is therefore the wording
that ships in `1.0.0`, and the sign-off carries over unaltered.
