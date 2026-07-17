# Contributing to sp_SQLFlightRecorder

Thanks for your interest. This project is deliberately **boring, transparent,
and safe on production** — those pillars, not novelty, are the bar every change
is held to. Please read this before opening a PR.

The authoritative context is [docs/design.md](docs/design.md) and
[docs/decisions.md](docs/decisions.md); disputes are resolved by quoting them
(D-178).

## Minimum local environment (D-187)

- SSMS or Azure Data Studio, plus a writable SQL Server instance (Developer
  Edition or a Linux container).
- Docker + Python are recommended for running the Tier-1 matrix and the static
  linter locally, but are **not required** to submit a PR.

## Ground rules

- **No new product features outside the roadmap.** The design (§11) is phased
  and its exclusion lists are binding. If you want something new, open a
  proposal issue first.
- **Preserve the contracts.** The 16-column Findings, 12-column Timeline, and
  14-key Markdown header are frozen (D-067/071/085). Rule IDs are never renamed,
  reused, or retired outside a major release (D-089).
- **No forbidden DMVs / no plan-XML shredding** (D-015/046/082/136). The CI
  static analysis enforces this; run it locally:
  `python tests/static-analysis/lint.py sp_SQLFlightRecorder.sql`.
- **Coding style (D-153):** UPPERCASE keywords, original-case identifiers,
  4-space indent, ~120-char lines, schema-qualified names, no `SELECT *`, no
  commented-out code. There is no auto-formatter (none handle dynamic SQL well).
- **TODO/FIXME must reference a GitHub issue** (D-155).

## Submitting a change

1. Branch from `main`.
2. Keep the change small and reviewable; one implementation-plan part per PR.
3. Run locally: the static linter (above), the linter self-test
   (`--self-test`), and — if you have Docker — `scripts/run-local-tier1.sh` and
   `tests/rules/run-rule-fixtures.sh`.
4. Fill in the PR template, including the charter-compliance checklist (D-157).
5. Reviews: two reviewers for the shipped artifact, one for docs/examples;
   safety-checklist items require a maintainer (D-158). The
   [safety checklist](docs/contributing/safety-checklist.md) is pasted into
   reviews when relevant (D-176).

## Contributing a rule (D-160)

A new-rule PR is a five-part bundle: the `FR_Rules` metadata row, the T-SQL
logic, a docs page from [docs/rules/_template.md](docs/rules/_template.md),
**both** a positive and a negative test, golden updates, and a wording
self-review against §6.7. New rule IDs are permanent.

## Licensing / sign-off

MIT licensed. There is **no CLA and no DCO** requirement at v1 (D-179); by
contributing you agree your contribution is under the project's MIT license.

## Code of Conduct

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).
