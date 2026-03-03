# Telemetry Collection from Simulation Infrastructure

> **One-Pager Summary** | Aligned with v5 Proposal | Last Updated: 2026-03-03

---

## Executive Summary

This document summarises the hybrid telemetry collection architecture for gathering logs from distributed simulation game boards (Azure tenants) into a central Admin Center.

### Recommended Approach

| Log Type | Recommended Method | Why |
|----------|-------------------|-----|
| **Azure Resource Logs** | Azure Lighthouse + DCR | Enterprise-grade governance, RBAC, native ingestion |
| **Entra ID Logs** | Event Hub + Azure Function | Required due to `LinkedAuthorizationFailed` API limitation |
| **M365 Audit Logs** | Office 365 Management API | Only supported method for M365 workloads |

This hybrid approach ensures **complete coverage** while maintaining a **read-only, non-intrusive posture**.

---

## Challenge

Simulation game boards operate as **isolated Azure tenants**, each generating valuable telemetry including **Azure platform logs, Entra ID logs, and Microsoft 365 audit logs** that must be analysed centrally to support detection, validation, and exercise outcomes.

The core challenge is to **collect this telemetry centrally without altering tenant behaviour, weakening isolation boundaries, or introducing operational risk** to the simulation environment.

---

## Solution: Hybrid Collection Architecture

Due to Microsoft's architectural separation between **Azure Resource Manager, Entra ID,** and **Microsoft 365,** no single mechanism can collect all required telemetry types. A hybrid approach is therefore required, combining three complementary collection methods.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    TENANT A (Simulation Game Board)                              │
│                                                                                  │
│   Azure Resources        Virtual Machines        Entra ID           M365        │
│         │                      │                    │                │          │
│         │                      │                    │                │          │
│    Diagnostic             AMA + DCR            Diagnostic        O365 Mgmt     │
│    Settings                                    Settings           API          │
│         │                      │                    │                │          │
│         └──────────────────────┤                    │                │          │
│                                │                    │                │          │
│              Azure Lighthouse  │                    │                │          │
│              Delegation        │                    │                │          │
└────────────────────────────────┼────────────────────┼────────────────┼──────────┘
                                 │                    │                │
                                 │                    │ Event Hub      │
                                 │                    │ (SAS Token)    │
                                 ▼                    ▼                ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                    TENANT B (Admin Center)                                       │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                    Event Hub Namespace                                    │   │
│  │                    (eh-ns-entra-logs)                                    │   │
│  │                           │                                               │   │
│  │                    Azure Function                                         │   │
│  │                    (Event Hub Trigger)                                    │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                      │                                           │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                    Log Analytics Workspace                                │   │
│  │                                                                           │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │   │
│  │  │AzureActivity│  │ VM Telemetry│  │EntraID      │  │M365AuditLogs│      │   │
│  │  │             │  │ (Perf,Event)│  │SignInLogs_CL│  │    _CL      │      │   │
│  │  │             │  │             │  │AuditLogs_CL │  │             │      │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘      │   │
│  │       ▲                 ▲                ▲                ▲               │   │
│  │       │                 │                │                │               │   │
│  │   Lighthouse        Lighthouse       Event Hub +     Automation           │   │
│  │   + Diag Settings   + AMA + DCR     Azure Function   Runbook             │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│                    Microsoft Sentinel (Optional)                                 │
│                    Analytics | Hunting | Incidents                               │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Collection Methods at a Glance

| Log Type | Method | Access Required | Data Flow |
|----------|--------|-----------------|-----------|
| Azure Activity Logs | Lighthouse + Diagnostic Settings | Delegated RBAC | Push (automatic) |
| Azure Resource Logs | Lighthouse + Diagnostic Settings | Delegated RBAC | Push (automatic) |
| VM Telemetry | Lighthouse + AMA + DCR | Delegated RBAC | Push (automatic) |
| **Entra ID Logs** | **Event Hub + Azure Function** | Global Admin (one-time) | Push (automatic) |
| **M365 Audit Logs** | Office 365 Management API | App Registration + Consent | Pull (scheduled) |

> **Note**: Entra ID logs use Event Hub + Azure Function due to `LinkedAuthorizationFailed` errors with direct cross-tenant Log Analytics configuration.

---

## Why Lighthouse Alone Is Insufficient

| Log Type | Why Lighthouse Cannot Collect |
|----------|------------------------------|
| **Entra ID** | Tenant-level identity logs require **Global Administrator** privileges; Lighthouse operates at subscription and resource scope only. Additionally, direct cross-tenant Log Analytics configuration fails with `LinkedAuthorizationFailed` errors. |
| **M365** | M365 is a **separate platform** accessed via the Office 365 Management API, not Azure Monitor or ARM |

---

## Why Event Hub for Entra ID Logs?

| Method | Result | Reason |
|--------|--------|--------|
| Direct REST API | ❌ FAILS | `LinkedAuthorizationFailed` |
| ARM Templates | ❌ FAILS | `LinkedAuthorizationFailed` |
| Lighthouse Delegation | ❌ FAILS | Lighthouse doesn't cover Entra ID |
| Azure Portal (Manual) | ✅ Works | Requires manual configuration |
| **Event Hub** | ✅ **Works** | **Fully automated, SAS token auth** |

The Event Hub method works because:
- Entra ID diagnostic settings **can** send logs to an Event Hub using a connection string
- SAS token authentication bypasses cross-tenant authorisation issues
- An Azure Function in the managing tenant processes and forwards logs to Log Analytics

---

## Key Benefits

| Benefit | Description |
|---------|-------------|
| ✅ **Complete Telemetry Coverage** | Unified ingestion of Azure, Entra ID, and M365 logs |
| ✅ **Read-Only Operational Posture** | No intrusive agents or behavioural changes to simulation tenants |
| ✅ **Primarily Push-Based** | Azure logs via Lighthouse; Entra ID via Event Hub; only M365 requires scheduled pull |
| ✅ **Enterprise-Grade Governance** | RBAC, PIM, Managed Identity, Key Vault–backed secrets |
| ✅ **Scalable and Repeatable** | Aligned with Azure Monitor and Sentinel best practices |

---

## Implementation Summary

| Step | Action | Effort |
|:----:|--------|--------|
| 0 | Register resource providers in source tenant | One-time |
| 1 | Create security group and Log Analytics workspace in managing tenant | One-time |
| 2 | Deploy Azure Lighthouse delegation | One-time |
| 3 | Configure Activity Log diagnostic settings | One-time |
| 4 | Deploy AMA + DCR for VM telemetry | One-time |
| 5 | Configure Azure Resource diagnostic logs | One-time |
| 6 | **Configure Entra ID logs via Event Hub + Azure Function** | One-time |
| 7 | Deploy M365 audit log collection runbook automation | Ongoing |

---

## Quick Reference: Method Comparison

| Criteria | Event Hub | Lighthouse + DCR | Sentinel Multi-Tenant |
|----------|:---------:|:----------------:|:---------------------:|
| Complexity | Low | Medium | High |
| Security | Medium | High | Very High |
| Ingests to Tenant B | ✅ | ✅ | ❌ |
| Best For | Entra ID logs | Azure resource logs | SOC Analytics (no ingestion) |

### ✅ Recommendation Summary

| Log Type | Use This Method | Reason |
|----------|-----------------|--------|
| Azure Activity/Resource Logs | **Lighthouse + DCR** | Enterprise governance, RBAC, native ingestion |
| VM Telemetry | **Lighthouse + AMA + DCR** | Scalable, no intermediate infrastructure |
| Entra ID Logs | **Event Hub + Azure Function** | **Required** – direct methods fail with `LinkedAuthorizationFailed` |
| M365 Audit Logs | **Office 365 Management API** | Only supported method for M365 workloads |

---

## Next Steps

1. Review the full technical document: [`Telemetry-Collection-from-Simulation-Infrastructure-v5.md`](Telemetry-Collection-from-Simulation-Infrastructure-v5.md)
2. Follow the implementation guide: [`azure-cross-tenant-log-collection-execution.md`](azure-cross-tenant-log-collection-execution.md)

---

*For detailed architecture diagrams, comparison tables, and step-by-step implementation guidance, refer to the full v5 document.*
