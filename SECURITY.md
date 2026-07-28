# Security Policy

## Supported versions

Security fixes are provided for the latest released version of
`sp_SQLFlightRecorder`. Because the tool ships as a single T-SQL file with no
runtime service, "patching" means installing an updated `sp_SQLFlightRecorder.sql`
(see [docs/user-guide.md](docs/user-guide.md)).

| Version | Supported |
|---|---|
| Latest release | ✅ |
| Older tags | Best-effort only |

## Reporting a vulnerability

Please report suspected vulnerabilities **privately** — do not open a public
issue for a security problem.

- **If GitHub private vulnerability reporting is enabled** on this repository
  (Security → *Report a vulnerability*), that is the preferred channel. It
  opens a private security advisory visible only to maintainers.
- **If it is not enabled**, this project does not yet have a dedicated private
  security contact. In that case, please do not publish the details. Open a
  normal issue stating only that you have a security concern and asking a
  maintainer to arrange a private channel — withhold the specifics until one
  exists.

Never post secrets, credentials, exploit details, or sensitive production data
in a public issue or discussion.

Non-sensitive **security hardening suggestions** — defence-in-depth improvements
that do not describe an exploitable weakness — are welcome as normal public
issues.

Once you have a private channel, please include: the version/commit, a
description, reproduction steps if you have them, and the impact you observed.
Do not include real production query text or secrets in your report.

> **Tracked before final v1.0.0:** configuring a dedicated private security
> contact, or enabling GitHub private vulnerability reporting, is a release
> blocker for v1.0.0.

## What to expect

This is a community-maintained open-source project (MIT, no paid support tier).
We aim to acknowledge a valid report and begin triage on a best-effort basis;
**we do not commit to a fixed response-time SLA.** For accepted issues we prefer
coordinated disclosure: we will agree a disclosure timeline with the reporter
before any public write-up.

## Scope

In scope: the shipped artifact and the local `FR_*` repository it creates
(for example, unsafe reads, data exposure through repository contents, or a way
to make the tool perform an action the design forbids).

Out of scope: the security of your SQL Server instance, OS, or cloud
control-plane; and behaviors that are documented design decisions (see
[docs/decisions.md](docs/decisions.md)) rather than defects.

Data-sensitivity note: `FR_QueryText` and the opt-in `FR_ErrorLog` may contain
sensitive strings. Restrict `SELECT` on `FR_*` to a scoped role, not `public`.
See the threat model in [docs/design.md §12](docs/design.md#12-security-and-threat-model-q-041).
