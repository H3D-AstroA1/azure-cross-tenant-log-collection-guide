# Central Log Ingestion vs Individual Tenant Logging

> **Quick Reference** | Comparison of logging architectures for multi-tenant environments

---

## Overview

When managing multiple Azure tenants (e.g., simulation game boards), organisations must decide between two primary logging architectures:

| Architecture | Description |
|--------------|-------------|
| **Central Log Ingestion** | All logs from source tenants are collected into a single Log Analytics workspace in a managing tenant |
| **Individual Tenant Logging** | Each tenant maintains its own Log Analytics workspace; logs remain in their source tenant |

---

## Comparison Matrix

| Criteria | Central Log Ingestion | Individual Tenant Logging |
|----------|:---------------------:|:-------------------------:|
| **Unified Visibility** | ✅ Single pane of glass | ❌ Requires switching between tenants |
| **Cross-Tenant Correlation** | ✅ Native queries across all data | ⚠️ Requires cross-workspace queries |
| **Setup Complexity** | ⚠️ Higher (Lighthouse, Event Hub, APIs) | ✅ Lower (standard diagnostic settings) |
| **Ongoing Maintenance** | ✅ Centralised management | ❌ Per-tenant management overhead |
| **Data Sovereignty** | ⚠️ Data leaves source tenant | ✅ Data stays in source tenant |
| **Cost Model** | ✅ Single workspace billing | ❌ Multiple workspace costs |
| **Retention Control** | ✅ Unified retention policies | ⚠️ Per-tenant retention management |
| **Security Operations** | ✅ Centralised SOC | ❌ Distributed monitoring |
| **Compliance Auditing** | ✅ Single audit point | ❌ Multiple audit points |
| **Tenant Isolation** | ⚠️ Requires tagging/segregation | ✅ Natural isolation |
| **Scalability** | ✅ Scales with single workspace | ⚠️ Linear workspace growth |
| **Disaster Recovery** | ✅ Single backup strategy | ❌ Per-tenant DR planning |

---

## Central Log Ingestion

### ✅ Pros

| Benefit | Description |
|---------|-------------|
| **Unified Security Monitoring** | Single Microsoft Sentinel instance for threat detection across all tenants |
| **Cross-Tenant Correlation** | Detect attack patterns spanning multiple tenants without complex queries |
| **Operational Efficiency** | One team manages one workspace instead of N workspaces |
| **Consistent Alerting** | Single set of analytics rules applies to all tenant data |
| **Simplified Reporting** | Unified dashboards and workbooks across all environments |
| **Cost Optimisation** | Potential volume discounts; avoid per-workspace overhead |
| **Centralised Retention** | Single retention policy; easier compliance management |
| **Faster Incident Response** | All context available in one location |

### ❌ Cons

| Drawback | Description |
|----------|-------------|
| **Setup Complexity** | Requires Azure Lighthouse, Event Hub, and API integrations |
| **Data Sovereignty Concerns** | Logs leave source tenant; may conflict with compliance requirements |
| **Single Point of Failure** | Central workspace outage affects all monitoring |
| **Cross-Tenant Dependencies** | Source tenant changes can break collection pipelines |
| **Permission Management** | Complex RBAC to ensure proper access segregation |
| **Ingestion Costs** | All data ingested into one workspace; can be expensive at scale |
| **Latency** | Cross-tenant data transfer adds slight delay |

---

## Individual Tenant Logging

### ✅ Pros

| Benefit | Description |
|---------|-------------|
| **Data Sovereignty** | Logs remain in source tenant; meets strict compliance requirements |
| **Natural Isolation** | No risk of cross-tenant data leakage |
| **Simple Setup** | Standard Azure diagnostic settings; no cross-tenant configuration |
| **Tenant Autonomy** | Each tenant controls their own logging configuration |
| **Resilience** | One tenant's logging issues don't affect others |
| **Granular Retention** | Per-tenant retention policies based on specific requirements |
| **Lower Initial Complexity** | No Lighthouse, Event Hub, or API setup required |

### ❌ Cons

| Drawback | Description |
|----------|-------------|
| **Fragmented Visibility** | Must switch between tenants to view logs |
| **No Native Correlation** | Cross-tenant attack detection requires complex queries |
| **Operational Overhead** | N workspaces = N times the management effort |
| **Inconsistent Configuration** | Risk of configuration drift between tenants |
| **Multiple Sentinel Instances** | Each tenant needs its own Sentinel (if required) |
| **Higher Total Cost** | Per-workspace costs multiply with tenant count |
| **Distributed Alerting** | Must maintain alert rules in each tenant |
| **Slower Incident Response** | Context scattered across multiple workspaces |

---

## Decision Framework

### Choose Central Log Ingestion When:

| Scenario | Why Central Works |
|----------|-------------------|
| **Centralised SOC** | Security team needs unified visibility |
| **Multi-Tenant MSP** | Managing multiple customer environments |
| **Simulation/Research** | Analysing behaviour across isolated environments |
| **Compliance Reporting** | Single audit point for all environments |
| **Cost Optimisation** | Volume discounts outweigh setup complexity |
| **Cross-Tenant Threat Detection** | Detecting lateral movement across tenants |

### Choose Individual Tenant Logging When:

| Scenario | Why Individual Works |
|----------|----------------------|
| **Strict Data Sovereignty** | Regulations prohibit data leaving tenant |
| **Tenant Autonomy Required** | Each tenant manages their own security |
| **Simple Environments** | Few tenants with minimal correlation needs |
| **Temporary/Ephemeral Tenants** | Short-lived environments not worth centralising |
| **Compliance Isolation** | Each tenant has different compliance requirements |

---

## Hybrid Approach (Recommended for Simulation Scenarios)

For simulation game boards, a **hybrid approach** is recommended:

| Component | Approach | Reason |
|-----------|----------|--------|
| **Azure Resource Logs** | Central Ingestion | Unified visibility via Lighthouse |
| **Entra ID Logs** | Central Ingestion | Cross-tenant identity correlation |
| **M365 Audit Logs** | Central Ingestion | Unified workload monitoring |
| **Sentinel Analytics** | Central | Single detection engine |
| **Raw Data Retention** | Central | Simplified compliance |

This provides the benefits of central visibility while maintaining clear custody boundaries through proper tagging and RBAC.

---

## Summary

| Factor | Central Ingestion | Individual Logging |
|--------|:-----------------:|:------------------:|
| Best for SOC operations | ✅ | ❌ |
| Best for data sovereignty | ❌ | ✅ |
| Best for cross-tenant correlation | ✅ | ❌ |
| Best for simple setup | ❌ | ✅ |
| Best for operational efficiency | ✅ | ❌ |
| Best for tenant autonomy | ❌ | ✅ |

---

## ✅ Recommendation: Central Log Ingestion

**For simulation environments, security research, and multi-tenant operations, central log ingestion is the clear choice.**

### Why Central Logging Wins

| Capability | With Central Logging | Without Central Logging |
|------------|---------------------|------------------------|
| **Detect cross-tenant attacks** | ✅ Single query correlates activity across all tenants | ❌ Manual correlation across N workspaces |
| **Respond to incidents** | ✅ Full context in one location; faster MTTR | ❌ Context scattered; slower response |
| **Maintain consistent security** | ✅ One set of detection rules for all tenants | ❌ N sets of rules to maintain and sync |
| **Scale operations** | ✅ Adding tenants doesn't multiply workload | ❌ Each tenant adds operational overhead |
| **Demonstrate compliance** | ✅ Single audit point; unified reporting | ❌ Multiple audit trails to consolidate |

### The Bottom Line

> **Without central log ingestion, you cannot effectively:**
> - Detect lateral movement between simulation tenants
> - Correlate identity events (Entra ID) with resource activity (Azure)
> - Maintain a unified security posture across all game boards
> - Respond to incidents with full cross-tenant context
> - Scale security operations as the number of tenants grows

**Central log ingestion transforms fragmented telemetry into actionable intelligence.** The initial setup complexity is a one-time investment that pays dividends in operational efficiency, security effectiveness, and incident response capability.

For simulation game boards where understanding attacker behaviour across tenant boundaries is critical, **there is no viable alternative to central log ingestion**.

---

*Related Documents:*
- [Telemetry Collection from Simulation Infrastructure (v5)](Telemetry-Collection-from-Simulation-Infrastructure-v5.md)
- [Azure Cross-Tenant Log Collection Execution Guide](azure-cross-tenant-log-collection-execution.md)
