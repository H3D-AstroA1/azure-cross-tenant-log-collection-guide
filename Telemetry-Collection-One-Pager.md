# Telemetry Collection from Simulation Infrastructure – Executive Summary

## Challenge

Simulation game boards operate as isolated Azure tenants generating critical telemetry (Azure logs, Entra ID logs, M365 audit logs) that must be collected centrally for analysis. The challenge: collect telemetry securely without modifying tenant behaviour or compromising isolation.

---

## Solution: Hybrid Collection Architecture

**No single method can collect all log types** due to Microsoft's architectural separation of Azure Resource Manager, Entra ID, and Microsoft 365. A hybrid approach combining three mechanisms is required:

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
| Azure Activity Logs | Lighthouse + Diagnostic Settings | Delegated RBAC | Push (auto) |
| Azure Resource Logs | Lighthouse + Diagnostic Settings | Delegated RBAC | Push (auto) |
| VM Telemetry | Lighthouse + AMA + DCR | Delegated RBAC | Push (auto) |
| **Entra ID Logs** | Direct Diagnostic Settings | Global Admin (one-time) | Push (auto) |
| **M365 Audit Logs** | Office 365 Management API | App Registration + Consent | Pull (scheduled) |

---

## Why Lighthouse Alone Is Insufficient

| Log Type | Why Lighthouse Cannot Collect |
|----------|------------------------------|
| **Entra ID** | Tenant-level logs require Global Admin; Lighthouse operates at subscription/resource level |
| **M365** | Separate platform accessed via Office 365 Management API, not Azure APIs |

---

## Key Benefits

| Benefit | Description |
|---------|-------------|
| ✅ Complete Coverage | All Azure, Entra ID, and M365 logs collected |
| ✅ Read-Only Posture | Non-intrusive to simulation tenants |
| ✅ Push-Based (mostly) | Only M365 requires scheduled automation |
| ✅ Enterprise Governance | RBAC, PIM, Managed Identity, Key Vault |
| ✅ Scalable | Aligned with Azure Monitor best practices |

---

## Implementation Summary

| Step | Action | Effort |
|:----:|--------|--------|
| 1 | Deploy Azure Lighthouse delegation | One-time |
| 2 | Configure Activity/Resource Log diagnostic settings | One-time |
| 3 | Deploy AMA + DCR for VM telemetry | One-time |
| 4 | Configure Entra ID diagnostic settings (Global Admin) | One-time |
| 5 | Deploy M365 audit log collection runbook | Ongoing |

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
