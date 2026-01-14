# Telemetry Collection from Simulation Infrastructure

## Executive Summary

## Challenge

Simulation game boards operate as **isolated Azure tenants**, each generating valuable telemetry including **Azure platform logs, Entra ID logs, and Microsoft 365 audit logs** that must be analyzed centrally to support detection, validation, and exercise outcomes.

The core challenge is to **collect this telemetry centrally without altering tenant behaviour, weakening isolation boundaries, or introducing operational risk** to the simulation environment.

---

## Solution: Hybrid Collection Architecture

Due to Microsoft’s architectural separation between **Azure Resource Manager, Entra ID,** and **Microsoft 365,** no single mechanism can collect all required telemetry types. A hybrid approach is therefore required, combining three complementary collection methods.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    TENANT A (Simulation Game Board)                          │
│                                                                              │
│   Azure Resources        Virtual Machines        Entra ID        M365       │
│         │                      │                    │             │         │
│         └──────────────────────┼────────────────────┼─────────────┘         │
│                                │                    │                        │
│              Lighthouse + DCR  │    Direct Diag    │   O365 Mgmt API        │
│                                │    Settings       │                        │
└────────────────────────────────┼────────────────────┼────────────────────────┘
                                 │                    │
                                 ▼                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                    TENANT B (Admin Center)                                   │
│                                                                              │
│                    Log Analytics Workspace                                   │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│   │AzureActivity│  │ VM Telemetry│  │ SigninLogs  │  │M365AuditLogs│       │
│   └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘       │
│                                                                              │
│                    Microsoft Sentinel (Optional)                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Collection Methods at a Glance

| Log Type | Method | Access Required | Data Flow |
|----------|--------|-----------------|-----------|
| Azure Activity Logs | Lighthouse + Diagnostic Settings | Delegated RBAC | Push (automatic) |
| Azure Resource Logs | Lighthouse + Diagnostic Settings | Delegated RBAC | Push (automatic) |
| VM Telemetry | Lighthouse + AMA + DCR | Delegated RBAC | Push (automatic) |
| **Entra ID Logs** | Direct Diagnostic Settings | Global Admin (one-time) | Push (automatic) |
| **M365 Audit Logs** | Office 365 Management API | App Registration + Consent | Pull (scheduled) |

---

## Why Lighthouse Alone Is Insufficient

| Log Type | Why Lighthouse Cannot Collect |
|----------|------------------------------|
| **Entra ID** | Tenant‑level identity logs require **Global Administrator** privileges; Lighthouse operates at subscription and resource scope only |
| **M365** | M365 is a **separate platform** accessed via the Office 365 Management API, not Azure Monitor or ARM |

---

## Key Benefits

| Benefit | Description |
|---------|-------------|
| ✅ Complete Telemetry Coverage | Unified ingestion of Azure, Entra ID, and M365 logs |
| ✅ Read‑Only Operational Posture | No intrusive agents or behavioural changes to simulation tenants |
| ✅ Primarily Push‑Based | Only M365 requires scheduled pull automation |
| ✅ Enterprise‑Grade Governance | RBAC, PIM, Managed Identity, Key Vault–backed secrets |
| ✅ Scalable and Repeatable | Aligned with Azure Monitor and Sentinel best practices |

---

## Implementation Summary

| Step | Action | Effort |
|:----:|--------|--------|
| 1 | Deploy Azure Lighthouse delegation | One-time |
| 2 | Configure Activity/Resource Log diagnostic settings | One-time |
| 3 | Deploy AMA + DCR for VM telemetry | One-time |
| 4 | Configure Entra ID Diagnostic Settings | One-time |
| 5 | Deploy M365 audit log collection runbook automation | Ongoing |

---

## Quick Reference: Method Comparison

| Criteria | Event Hub | Lighthouse + DCR | Sentinel Multi-Tenant |
|----------|:---------:|:----------------:|:---------------------:|
| Complexity | Low | Medium | High |
| Security | Medium | High | Very High |
| Ingests to Tenant B | ✅ | ✅ | ❌ |
| Best For | Speed | Governance | SOC Analytics |

---

## Next Steps

1. Review the full technical document: [`Telemetry-Collection-from-Simulation-Infrastructure-v4.md`](Telemetry-Collection-from-Simulation-Infrastructure-v4.md)
2. Follow the implementation guide: [`azure-cross-tenant-log-collection-execution.md`](azure-cross-tenant-log-collection-execution.md)

---

*For detailed architecture diagrams, comparison tables, and step-by-step implementation guidance, refer to the full v4 document.*
