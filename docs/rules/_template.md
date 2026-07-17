<!--
Rule doc template (D-161). Copy to docs/rules/<RuleId>.md and fill every
section. All nine sections are required; write "n/a — <reason>" if one does not
apply. See docs/rules/FR_R0003.md for a filled example.
-->
# FR_R#### ShortName

| Field | Value |
|---|---|
| RuleId | `FR_R####_ShortName` |
| Category | <!-- Blocking / Waits / IO / Memory / Tempdb / Maintenance / HA / QueryStore / PlanCache / Configuration / Coverage / QueryPlan --> |
| Severity | <!-- constant base; note "(escalates High)" if applicable --> |
| Confidence | <!-- High / Medium / Low, and any runtime downgrade --> |
| Evidence type | <!-- Observed / Inferred --> |
| Introduced in | <!-- version --> |
| Lifecycle | <!-- Active / Disabled / Deprecated / Retired --> |
| Data source | <!-- FR_* tables read --> |
| Dedup anchor | <!-- session / query+plan / db+object / 60s bucket (D-074) --> |

## What it detects
One paragraph: the pattern, in plain language.

## How it is computed
Repository-only (D-014/D-081). The exact delta/aggregation, the window, and any
`@DeltaStartUtc` (restart-split, D-064) or baseline (D-092) behavior.

## Severity rationale
Why this severity; if it escalates, the exact criterion and the decision behind it.

## Confidence rationale
Why this confidence; any runtime downgrade (e.g., insufficient baseline samples).

## Evidence-type rationale
Why Observed vs Inferred.

## False-positive risks
Concrete situations where it may fire but not indicate a problem.

## False-negative risks
Concrete situations where a real problem may not fire (cadence, caps, gating).

## Drill-down guidance
What a DBA should look at next; any read-only follow-up query (never plan-forcing
or mutation — D-086).

## Suppress / disable
`EXEC dbo.sp_SQLFlightRecorder @Mode='Configure', @ConfigKey='DisabledRules',
@ConfigValue='<RuleId>;...';` — semicolon-delimited (D-099). Note if the rule
cannot be disabled (e.g., FR_R0026, D-098).

## Related config keys
The `FR_Config` keys that tune this rule (link to docs/configuration.md).

## Example
A minimal seed + Report showing the finding (see tests/rules/).
