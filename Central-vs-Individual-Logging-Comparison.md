# Central Log Ingestion vs Individual Tenant Logging

> **Architecture Decision Guide** | Multi-Tenant Logging Strategy

---

## Executive Summary

When managing multiple Azure tenants—such as simulation game boards—organisations face a critical architectural decision: **centralise logs into a single workspace** or **keep logs distributed across individual tenants**.

This document provides a comprehensive comparison to support that decision. For simulation environments requiring cross-tenant visibility and threat detection, **central log ingestion is the recommended approach**.

---

## The Challenge: Multi-Tenant Visibility

```mermaid
flowchart TB
    subgraph Problem["❌ Individual Tenant Logging"]
        direction TB
        T1A[("Tenant A<br/>Workspace")]
        T1B[("Tenant B<br/>Workspace")]
        T1C[("Tenant C<br/>Workspace")]
        T1D[("Tenant D<br/>Workspace")]
        
        SOC1["Security Analyst"]
        
        SOC1 -.->|"Switch context"| T1A
        SOC1 -.->|"Switch context"| T1B
        SOC1 -.->|"Switch context"| T1C
        SOC1 -.->|"Switch context"| T1D
        
        Attack1["🔴 Attacker moves<br/>A → B → C"]
        Attack1 -.->|"Invisible"| SOC1
    end
    
    subgraph Solution["✅ Central Log Ingestion"]
        direction TB
        T2A["Tenant A"]
        T2B["Tenant B"]
        T2C["Tenant C"]
        T2D["Tenant D"]
        
        Central[("Central<br/>Workspace")]
        
        T2A -->|"Logs"| Central
        T2B -->|"Logs"| Central
        T2C -->|"Logs"| Central
        T2D -->|"Logs"| Central
        
        SOC2["Security Analyst"]
        Central -->|"Single view"| SOC2
        
        Attack2["🔴 Attacker moves<br/>A → B → C"]
        Attack2 -->|"Detected!"| SOC2
    end
    
    Problem -.->|"Transform to"| Solution
```

**The core problem**: With individual tenant logging, cross-tenant attacks are invisible. An attacker moving laterally between tenants leaves traces in multiple workspaces that no single analyst can correlate in real-time.

---

## Architecture Comparison

| Architecture | Description |
|--------------|-------------|
| **Central Log Ingestion** | All logs from source tenants flow into a single Log Analytics workspace in a managing tenant |
| **Individual Tenant Logging** | Each tenant maintains its own Log Analytics workspace; logs remain in their source tenant |

### Side-by-Side Comparison

| Criteria | Central Log Ingestion | Individual Tenant Logging |
|----------|:---------------------:|:-------------------------:|
| **Unified Visibility** | ✅ Single pane of glass | ❌ Requires switching between tenants |
| **Cross-Tenant Correlation** | ✅ Native queries across all data | ❌ Requires complex cross-workspace queries |
| **Setup Complexity** | ⚠️ Higher (Lighthouse, Event Hub, APIs) | ✅ Lower (standard diagnostic settings) |
| **Ongoing Maintenance** | ✅ Centralised management | ❌ Per-tenant management overhead |
| **Data Sovereignty** | ⚠️ Data leaves source tenant | ✅ Data stays in source tenant |
| **Cost Model** | ✅ Single workspace billing | ❌ Multiple workspace costs |
| **Security Operations** | ✅ Centralised SOC | ❌ Distributed monitoring |
| **Scalability** | ✅ Scales with single workspace | ⚠️ Linear workspace growth |
| **Incident Response** | ✅ Full context in one location | ❌ Context scattered across workspaces |

---

## Central Log Ingestion

### Benefits

| Benefit | Description |
|---------|-------------|
| **Unified Security Monitoring** | Single Microsoft Sentinel instance for threat detection across all tenants |
| **Cross-Tenant Correlation** | Detect attack patterns spanning multiple tenants with simple queries |
| **Operational Efficiency** | One team manages one workspace instead of N workspaces |
| **Consistent Alerting** | Single set of analytics rules applies to all tenant data |
| **Simplified Reporting** | Unified dashboards and workbooks across all environments |
| **Cost Optimisation** | Potential volume discounts; avoid per-workspace overhead |
| **Faster Incident Response** | All context available in one location; reduced MTTR |

### Considerations

| Consideration | Mitigation |
|---------------|------------|
| **Setup Complexity** | One-time investment; use automation scripts |
| **Data Sovereignty** | Implement proper tagging and RBAC segregation |
| **Single Point of Failure** | Use Azure's built-in workspace resilience |
| **Permission Management** | Design RBAC model upfront; use PIM for elevation |

---

## Individual Tenant Logging

### Benefits

| Benefit | Description |
|---------|-------------|
| **Data Sovereignty** | Logs remain in source tenant; meets strict compliance requirements |
| **Natural Isolation** | No risk of cross-tenant data leakage |
| **Simple Setup** | Standard Azure diagnostic settings; no cross-tenant configuration |
| **Tenant Autonomy** | Each tenant controls their own logging configuration |

### Limitations

| Limitation | Impact |
|------------|--------|
| **Fragmented Visibility** | Must switch between tenants to view logs |
| **No Native Correlation** | Cross-tenant attack detection is extremely difficult |
| **Operational Overhead** | N workspaces = N times the management effort |
| **Multiple Sentinel Instances** | Each tenant needs its own Sentinel (if required) |
| **Slower Incident Response** | Context scattered across multiple workspaces |

---

## Decision Framework

### Choose Central Log Ingestion When:

- Security team needs unified visibility across tenants
- Cross-tenant threat detection is a requirement
- Managing multiple simulation or research environments
- Compliance reporting requires a single audit point
- Operational efficiency is prioritised over setup simplicity

### Choose Individual Tenant Logging When:

- Regulations strictly prohibit data leaving the tenant
- Each tenant must manage their own security independently
- Environments are temporary or ephemeral
- Cross-tenant correlation is not required

---

## ✅ Recommendation: Central Log Ingestion

**For simulation environments, security research, and multi-tenant operations, central log ingestion is the clear choice.**

### Why Central Logging Wins

```mermaid
flowchart LR
    subgraph Value["Value of Central Logging"]
        direction TB
        
        V1["🔍 **Detect**<br/>Cross-tenant attacks<br/>visible in single query"]
        V2["⚡ **Respond**<br/>Full context available<br/>Faster MTTR"]
        V3["📊 **Scale**<br/>Adding tenants doesn't<br/>multiply workload"]
        V4["🛡️ **Protect**<br/>Consistent security<br/>across all tenants"]
        V5["✅ **Comply**<br/>Single audit point<br/>Unified reporting"]
        
        V1 --> V2 --> V3 --> V4 --> V5
    end
```

| Capability | With Central Logging | Without Central Logging |
|------------|---------------------|------------------------|
| **Detect cross-tenant attacks** | ✅ Single query correlates activity | ❌ Manual correlation across N workspaces |
| **Respond to incidents** | ✅ Full context; faster MTTR | ❌ Context scattered; slower response |
| **Maintain consistent security** | ✅ One set of detection rules | ❌ N sets of rules to maintain |
| **Scale operations** | ✅ Linear effort regardless of tenant count | ❌ Each tenant adds operational overhead |
| **Demonstrate compliance** | ✅ Single audit point | ❌ Multiple audit trails to consolidate |

### The Bottom Line

> **Without central log ingestion, you cannot effectively:**
> - Detect lateral movement between simulation tenants
> - Correlate identity events (Entra ID) with resource activity (Azure)
> - Maintain a unified security posture across all game boards
> - Respond to incidents with full cross-tenant context
> - Scale security operations as the number of tenants grows

**Central log ingestion transforms fragmented telemetry into actionable intelligence.**

The initial setup complexity is a one-time investment that pays dividends in:
- **Operational efficiency** — manage one workspace, not N
- **Security effectiveness** — detect what individual logging cannot
- **Incident response** — respond faster with full context

For simulation game boards where understanding attacker behaviour across tenant boundaries is critical, **there is no viable alternative to central log ingestion**.

---

## Implementation Path

To implement central log ingestion for your simulation environment:

| Step | Action | Reference |
|:----:|--------|-----------|
| 1 | Review the full technical proposal | [Telemetry Collection v5](Telemetry-Collection-from-Simulation-Infrastructure-v5.md) |
| 2 | Follow the step-by-step execution guide | [Execution Guide](azure-cross-tenant-log-collection-execution.md) |
| 3 | Use the one-pager for stakeholder communication | [One-Pager Summary](Telemetry-Collection-One-Pager.md) |

---

*This document supports the telemetry collection architecture for simulation infrastructure.*
