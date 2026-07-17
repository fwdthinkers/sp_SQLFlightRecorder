# Rule index

One page per rule (D-161). Template: [_template.md](_template.md).

| RuleId | Category | Severity | Confidence | Evidence | Lifecycle |
|---|---|---|---|---|---|
| [0001](FR_R0001.md) ActiveBlockingChain | Blocking | High | High | Observed | Active |
| [0002](FR_R0002.md) LongRunningOpenTransaction | Blocking | Medium | High | Observed | Active |
| [0003](FR_R0003.md) TopWaitTypeSpike | Waits | Medium | Medium | Inferred | Active |
| [0004](FR_R0004.md) FileIoLatencySpike | IO | Medium | Medium | Inferred | Active |
| [0005](FR_R0005.md) MemoryGrantsPending | Memory | High | High | Observed | Active |
| [0006](FR_R0006.md) ServerRestartDuringWindow | Configuration | Critical | High | Observed | Active |
| [0007](FR_R0007.md) BlockingStorm | Blocking | Critical | High | Observed | Active |
| [0008](FR_R0008.md) TempdbVersionStoreGrowth | Tempdb | Medium | High | Observed | Active |
| [0009](FR_R0009.md) TempdbFileImbalanceOrPressure | Tempdb | Medium | Medium | Inferred | Active |
| [0010](FR_R0010.md) FailedSqlAgentJobNearIncident | Maintenance | High | High | Observed | Active |
| [0011](FR_R0011.md) MaintenanceJobOverlap | Maintenance | Medium | Medium | Inferred | Active |
| [0012](FR_R0012.md) BackupOverlapWithIncident | Maintenance | Medium | High | Observed | Active |
| [0013](FR_R0013.md) DeadlocksObserved | Blocking | High | High | Observed | Active |
| [0014](FR_R0014.md) AlwaysOnRoleOrStateChange | HA | Critical | High | Observed | Active |
| [0015](FR_R0015.md) QueryPlanRegression | QueryStore | High | Medium | Inferred | Active |
| [0016](FR_R0016.md) TopCpuConsumerInWindow | QueryStore | Medium | High | Observed | Active |
| [0017](FR_R0017.md) QueryStoreDisabledOnUserDbs | Coverage | Informational | High | Observed | Active |
| [0018](FR_R0018.md) FailedPlanForcing | QueryStore | Medium | High | Observed | Active |
| [0019](FR_R0019.md) QueryStoreNearingCapacity | QueryStore | Medium | High | Observed | Active |
| [0020](FR_R0020.md) HighCompilationRate | PlanCache | Medium | Medium | Inferred | Active |
| [0021](FR_R0021.md) ConfigurationChangeInWindow | Configuration | Medium | High | Observed | Active |
| [0022](FR_R0022.md) LogReuseWaitElevated | IO | High | High | Observed | Active |
| [0023](FR_R0023.md) ThreadpoolWaitsObserved | Waits | Critical | High | Observed | Active |
| [0024](FR_R0024.md) ResourceSemaphoreWaits | Memory | High | High | Observed | Active |
| [0025](FR_R0025.md) RecentCheckDbOrBackupAge | Maintenance | Medium | High | Observed | Active |
| [0026](FR_R0026.md) CoverageAndCapabilitySummary | Coverage | Informational | High | Observed | Active |
| [0030](FR_R0030.md) PlanMissingIndex | QueryPlan | Medium | Medium | Inferred | Disabled |
| [0031](FR_R0031.md) PlanImplicitConversion | QueryPlan | Low | Medium | Inferred | Disabled |
| [0032](FR_R0032.md) PlanSpillToTempDb | QueryPlan | Medium | Medium | Inferred | Disabled |
| [0033](FR_R0033.md) PlanWarnings | QueryPlan | Low | Medium | Inferred | Disabled |
| [0034](FR_R0034.md) PlanParallelism | QueryPlan | Low | Low | Inferred | Disabled |
