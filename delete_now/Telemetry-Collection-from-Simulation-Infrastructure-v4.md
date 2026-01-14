# Telemetry Collection from Simulation Infrastructure

## Problem Statement

### Background

The simulation infrastructure operates across multiple Azure tenants, where each "game board" represents an isolated tenant environment used for security research, attack simulation, and defensive validation exercises. These environments generate critical telemetry—including Azure Activity Logs, Resource Diagnostic Logs, Virtual Machine telemetry, Microsoft Entra ID (Azure AD) sign-in and audit logs, and Microsoft 365 audit logs—that must be collected centrally for analysis, correlation, and validation of security controls.

### Challenge

Collecting telemetry from distributed simulation tenants presents several operational and security challenges:

| Challenge | Description |
|-----------|-------------|
| **Tenant Isolation** | Each simulation game board operates as an independent Azure tenant with its own identity boundary, requiring cross-tenant access mechanisms |
| **Configuration Integrity** | Modifying target tenant configurations (e.g., installing agents, changing diagnostic settings) may alter tenant behaviour and invalidate simulation results |
| **Compliance & Governance** | Direct access to source tenants raises compliance concerns around data residency, access auditing, and separation of duties |
| **Log Type Diversity** | Different log types (Azure Resource, Entra ID, M365) are exposed through fundamentally different APIs and authentication mechanisms |
| **Operational Overhead** | Manual log collection across multiple tenants is unsustainable and error-prone at scale |

### Objective

Design and implement a telemetry collection architecture that:

1. **Maintains Read-Only Posture** – Operates without modifying tenant behaviour or existing configurations beyond minimal, auditable changes
2. **Ensures Complete Coverage** – Collects all required log types (Azure, Entra ID, M365) from source tenants
3. **Preserves Tenant Isolation** – Prevents cross-contamination between simulation environments
4. **Centralizes Custody** – Ingests telemetry into a central Log Analytics workspace in the Admin Center tenant for unified analysis
5. **Supports Governance** – Provides full audit trails, RBAC-based access control, and compliance with enterprise security standards

## Proposed Solution

### Solution Overview

To address the challenges outlined above, we propose implementing a **non-intrusive, multi-method telemetry collection architecture** that leverages Azure-native capabilities to collect logs from simulation game boards (Tenant A) into a central Admin Center (Tenant B). This architecture is designed around the following core principles:

| Principle | Implementation |
|-----------|----------------|
| **Read-Only Posture** | Delegated access via Azure Lighthouse with minimal, auditable configuration changes |
| **Passive Collection** | Logs flow automatically via diagnostic settings and Data Collection Rules (DCRs) after one-time setup |
| **Tenant Isolation** | Each simulation tenant remains independent; telemetry is tagged and segregated in the central workspace |
| **Automated Ingestion** | Push-based mechanisms for Azure and Entra ID logs; scheduled automation for M365 logs |
| **Centralized Custody** | All telemetry ingested into a single Log Analytics workspace in Tenant B for unified analysis |

### Available Collection Methods

Three primary methods are available for transferring telemetry from simulation game boards (Tenant A) to the Admin Center (Tenant B). Each method has distinct characteristics, trade-offs, and applicability depending on the log type and operational requirements.

#### Method 1: Continuous Export via Event Hub

A lightweight, infrastructure-based approach where Tenant A streams Azure platform logs (Activity Logs, Resource Logs, diagnostic telemetry) into an Event Hub namespace. Tenant B consumes these events using an Azure Function or Logic App, transforming and ingesting them into its Log Analytics workspace via the Data Collector API or Logs Ingestion API.

**Characteristics:**
- Low complexity, fast deployment
- Requires Event Hub infrastructure and ingestion application
- Best suited for scenarios prioritizing speed over governance
- Does not require Azure Lighthouse delegation

#### Method 2: Azure Lighthouse + Log Analytics Delegation

A secure, enterprise-grade approach where Tenant A delegates controlled access to Tenant B using Azure Lighthouse. With this delegated access, Tenant B can configure diagnostic settings and Data Collection Rules (DCRs) to ingest logs directly from Tenant A's resources into its own Log Analytics workspace—without intermediate infrastructure such as Event Hub.

**Characteristics:**
- Medium complexity, requires Lighthouse setup and DCR/AMA configuration
- Strong security posture: RBAC-based delegation, Managed Identities, PIM/JIT elevation
- Native log ingestion via Azure Monitor Agent (AMA) and DCRs
- Recommended for enterprise-grade, governed telemetry pipelines

#### Method 3: Microsoft Sentinel Multi-Tenant Integration

A comprehensive SOC-grade model where Tenant B operates Microsoft Sentinel centrally and, through Azure Lighthouse, can query, hunt, detect, and manage incidents across Tenant A and other connected tenants. This model enables unified security operations with cross-workspace analytics, advanced correlation, and integrated automation.

**Characteristics:**
- High complexity, requires Sentinel enablement and cross-workspace query configuration
- Very high security posture with SOC-grade controls
- **Does not ingest logs into Tenant B**—data remains in source tenant workspaces
- Best suited for centralized SOC operations, not telemetry ingestion pipelines

---

## Method Comparison Summary

The table below provides a quick-reference comparison of the three available methods. For a comprehensive side-by-side analysis across 14 criteria, see [Appendix A – Detailed Comparison Table](#appendix-a--detailed-comparison-table).

| Method | Complexity | Security | Data Flow | Ingests to Tenant B? | Best For |
|--------|------------|----------|-----------|---------------------|----------|
| **Event Hub** | Low | Medium | Tenant A → Event Hub → Function/Logic App → Tenant B | ✅ Yes | Speed over governance; quick deployment |
| **Lighthouse + DCR** | Medium | High | Tenant A → AMA/DCR → Tenant B (native) | ✅ Yes | Enterprise-grade ingestion with governance |
| **Sentinel Multi-Tenant** | High | Very High | Query in place (no data movement) | ❌ No | SOC operations; analytics-only scenarios |

### Key Decision Factors

| If You Need... | Recommended Method |
|----------------|-------------------|
| Fastest deployment with minimal prerequisites | Event Hub |
| Centralized custody with enterprise governance | Lighthouse + DCR |
| SOC analytics without data transfer | Sentinel Multi-Tenant |
| **Complete telemetry coverage (Azure + Entra ID + M365)** | **Hybrid Approach** (see below) |

---

## Recommended Approach for Simulation Scenarios

### Overview

Based on the analysis of available methods and the specific requirements of simulation telemetry collection, we recommend a **hybrid approach** that combines multiple collection mechanisms to achieve complete log coverage. This approach is necessary because Microsoft's platform architecture exposes different log types through fundamentally different APIs and authentication boundaries.

### Why a Hybrid Approach Is Required

> ⚠️ **Critical Architectural Limitation**: No single method can collect all telemetry types due to how Microsoft separates Azure Resource Manager, Microsoft Entra ID, and Microsoft 365 into distinct control planes with different access models.

The following matrix illustrates which collection method is required for each log type:

| Log Type | Azure Lighthouse + DCR | Direct Diagnostic Settings | Office 365 Management API |
|----------|:----------------------:|:--------------------------:|:-------------------------:|
| Azure Activity Logs | ✅ Supported | — | — |
| Azure Resource Logs | ✅ Supported | — | — |
| VM Logs (via AMA) | ✅ Supported | — | — |
| **Entra ID Logs** | ❌ Not Supported | ✅ Required | — |
| **M365 Audit Logs** | ❌ Not Supported | — | ✅ Required |

**Key Insight**: Lighthouse operates at the Azure subscription/resource level and cannot access tenant-level services (Entra ID) or non-Azure services (Microsoft 365).

---

### Component 1: Azure Lighthouse + Log Analytics Delegation (Primary)

**Purpose**: Collect all Azure resource-level telemetry with enterprise-grade governance.

This component serves as the foundation of the hybrid approach, enabling direct, native log ingestion from simulation game boards (Tenant A) into the central Log Analytics workspace (Tenant B) using Azure Monitor Agent (AMA) and Data Collection Rules (DCRs).

**Telemetry Covered:**

| Log Category | Examples | Collection Mechanism |
|--------------|----------|---------------------|
| Activity Logs | Subscription-level control plane operations | Diagnostic Settings → Tenant B workspace |
| Resource Logs | Key Vault access, Storage operations, SQL audits | Diagnostic Settings → Tenant B workspace |
| VM Telemetry | Performance counters, Windows Events, Linux Syslog | AMA + DCR → Tenant B workspace |

**Security & Governance Features:**
- RBAC-based delegation via Lighthouse Registration Definition
- Just-In-Time (JIT) access elevation via PIM
- Full audit trail in both source and destination tenants
- No credential sharing between tenants

---

### Component 2: Entra ID Logs (Supplementary – Required)

**Purpose**: Collect identity and authentication telemetry from the source tenant.

**Why Lighthouse Cannot Collect Entra ID Logs:**

| Limitation | Explanation |
|------------|-------------|
| **Scope Mismatch** | Entra ID logs are tenant-level, not resource-level |
| **Authentication Boundary** | Requires Global Administrator in the source tenant |
| **API Separation** | Entra ID diagnostic settings are not accessible via Azure Resource Manager delegation |

**Collection Mechanism:**
1. Authenticate as Global Administrator in the source tenant (one-time)
2. Configure Entra ID Diagnostic Settings to send logs to Tenant B workspace
3. Logs flow automatically via Azure's native cross-tenant diagnostic settings capability
4. No ongoing automation required—this is a push-based, fire-and-forget configuration

**Available Log Categories:**

| Category | License Requirement | Description |
|----------|---------------------|-------------|
| AuditLogs | Free | Directory changes, app registrations, role assignments |
| SignInLogs | Entra ID P1/P2 | Interactive user sign-ins |
| NonInteractiveUserSignInLogs | Entra ID P1/P2 | Background/service sign-ins |
| ServicePrincipalSignInLogs | Entra ID P1/P2 | Application/service principal authentications |
| ManagedIdentitySignInLogs | Entra ID P1/P2 | Managed Identity authentications |
| ProvisioningLogs | Entra ID P1/P2 | User provisioning events |
| RiskyUsers | Entra ID P2 | Users flagged for risk |
| UserRiskEvents | Entra ID P2 | Risk detection events |
| RiskyServicePrincipals | Entra ID P2 | Service principals flagged for risk |
| ServicePrincipalRiskEvents | Entra ID P2 | Service principal risk events |
| MicrosoftGraphActivityLogs | Entra ID P1/P2 | Graph API call telemetry |

---

### Component 3: M365 Audit Logs (Supplementary – Required)

**Purpose**: Collect Microsoft 365 workload telemetry (Exchange, SharePoint, Teams, etc.).

**Why Lighthouse Cannot Collect M365 Audit Logs:**

| Limitation | Explanation |
|------------|-------------|
| **Platform Separation** | M365 is completely separate from Azure Resource Manager |
| **API Boundary** | Accessed via Office 365 Management API, not Azure APIs |
| **Authentication Model** | Requires app registration with M365-specific permissions |

**Collection Mechanism:**
1. Create a multi-tenant app registration in the managing tenant (Tenant B)
2. Configure Office 365 Management API permissions (`ActivityFeed.Read`)
3. Grant admin consent in each source tenant
4. Deploy an Azure Automation Runbook to pull logs on a schedule (e.g., every 15 minutes)
5. Store app credentials securely in Azure Key Vault
6. Ingest logs into Log Analytics using the Data Collector API or Logs Ingestion API

**Available Content Types:**

| Content Type | Description | Examples |
|--------------|-------------|----------|
| Audit.AzureActiveDirectory | Entra ID events via M365 API | Sign-ins, directory changes |
| Audit.Exchange | Exchange Online operations | Mailbox access, mail flow rules |
| Audit.SharePoint | SharePoint & OneDrive activities | File access, sharing, permissions |
| Audit.General | Cross-workload events | Teams, Power Platform, Dynamics 365 |
| DLP.All | Data Loss Prevention events | Policy matches, sensitive data detection |

---

### Hybrid Approach Summary

The following table summarizes the complete telemetry collection architecture:

| Step | Log Type | Collection Method | Data Flow | Operational Model |
|:----:|----------|-------------------|-----------|-------------------|
| 1 | Azure Activity Logs | Lighthouse + Diagnostic Settings | Push (auto) | One-time setup |
| 2 | Azure Resource Logs | Lighthouse + Diagnostic Settings | Push (auto) | One-time setup |
| 3 | VM Telemetry | Lighthouse + AMA + DCR | Push (auto) | One-time setup |
| 4 | **Entra ID Logs** | Direct Diagnostic Settings | Push (auto) | One-time setup (Global Admin) |
| 5 | **M365 Audit Logs** | Office 365 Management API | Pull (scheduled) | Ongoing (Runbook) |

---

### Key Benefits of the Hybrid Approach

| Benefit | How It's Achieved |
|---------|-------------------|
| **Complete Coverage** | All Azure, Entra ID, and M365 logs collected through appropriate mechanisms |
| **Native Ingestion** | AMA + DCR for Azure logs eliminates need for Event Hub infrastructure |
| **Push-Based Where Possible** | Azure and Entra ID logs flow automatically after one-time configuration |
| **Pull-Based Only Where Required** | M365 logs use scheduled runbook (Microsoft architectural limitation) |
| **Read-Only Posture** | Non-intrusive to simulation tenants; minimal configuration changes |
| **Strong Security** | RBAC + PIM for Azure; Managed Identity where possible; Key Vault for M365 credentials |
| **Tenant Isolation** | Clear custody boundaries; telemetry tagged by source tenant |
| **Scalable & Auditable** | Aligned with Azure Monitor best practices; full audit trails |

---

### Conclusion

The hybrid approach represents the optimal balance between security, completeness, operational simplicity, and compliance. By combining Azure Lighthouse for resource-level logs, direct diagnostic settings for Entra ID, and the Office 365 Management API for M365 workloads, this architecture ensures **complete telemetry coverage** while maintaining the read-only, non-intrusive posture required for simulation environments.

---

## Contingency Option – Continuous Export via Event Hub

While the hybrid approach (Lighthouse + Direct Diagnostic Settings + M365 API) is the recommended primary approach for simulation telemetry ingestion, Continuous Export via Event Hub should be retained as a secondary contingency option to address specific edge cases where the primary methods may have limitations.

This model serves as a fallback mechanism to:

- Provide coverage for log types or sources that cannot be collected via the primary methods
- Support high volume or near real time streaming scenarios where push based Event Hub ingestion may be operationally preferable
- Ensure comprehensive telemetry coverage across all simulation scenarios by maintaining an alternative ingestion path

The Event Hub–based approach should not be treated as the default but preserved as an on-demand exception path to ensure robustness, flexibility, and completeness of the overall telemetry architecture.

---

## Next Steps

### 1. Validate Delegation Model (Azure Lighthouse)

- Confirm Azure Lighthouse Registration Definition and Assignment from Tenant A (Simulation Game Board) to Tenant B (Admin Center)
- Validate delegated scopes (Subscription vs Resource Group)
- Ensure required RBAC roles:
  - Monitoring Contributor
  - Log Analytics Contributor
  - Contributor (for diagnostic settings configuration)
- Confirm Just In Time (JIT) elevation via PIM

### 2. Define Ingestion Scope

- Identify required log sources:
  - Activity Logs
  - Resource / Platform Logs
  - VM / AMA supported telemetry
  - Entra ID logs (AuditLogs, SignInLogs, etc.)
  - M365 audit logs (Exchange, SharePoint, Teams)
- Confirm target tables in Tenant B Log Analytics workspace
- Validate retention, transformation, and compliance requirements

### 3. Prepare AMA & DCR Configuration

- Define Data Collection Rules (DCRs) scoped to delegated Tenant A resources
- Validate Azure Monitor Agent (AMA) compatibility and deployment mechanisms
- Confirm no tenant configuration changes beyond standard AMA enablement

### 4. Configure Entra ID Log Collection

- Obtain Global Administrator credentials for source tenant
- Configure Entra ID Diagnostic Settings to send logs to Tenant B workspace
- Validate log categories based on available licenses (P1/P2)
- Verify logs appear in SigninLogs, AuditLogs tables

### 5. Configure M365 Audit Log Collection

- Create multi-tenant app registration in managing tenant
- Configure Office 365 Management API permissions
- Grant admin consent in source tenant
- Deploy Azure Automation Runbook for log collection
- Store credentials in Key Vault
- Verify logs appear in custom Log Analytics table

### 6. Validate Security & Isolation Controls

- Ensure read only operational posture
- Confirm no cross tenant data commingling
- Validate audit logs and access traceability in Tenant B

### 7. Optional – Sentinel Enablement (Post Ingestion)

- Enable Microsoft Sentinel only after ingestion is validated
- Use Sentinel for:
  - Analytics
  - Hunting
  - Correlation
  - Response automation
- Maintain ingestion pipeline independence from SOC tooling

---

## Implementation Reference

For detailed implementation scripts and step-by-step guidance, refer to:

- [Azure Cross-Tenant Log Collection Execution Guide](azure-cross-tenant-log-collection-execution.md)
  - Step 0-2: Azure Lighthouse setup
  - Step 3: Activity Log collection
  - Step 4: VM diagnostic logs (AMA + DCR)
  - Step 5: Azure Resource diagnostic logs
  - Step 6: Entra ID logs (Direct Diagnostic Settings)
  - Step 7: M365 Audit logs (Office 365 Management API)

---

## Appendix A – Detailed Comparison Table

> **Scope**: Comprehensive side-by-side comparison of all three cross-tenant log collection methods across multiple criteria. Use this table to understand the trade-offs and select the appropriate method(s) for your scenario.

| Criteria | Continuous Export via Event Hub | Azure Lighthouse + Log Analytics Delegation | Microsoft Sentinel Multi-Tenant |
|----------|--------------------------------|---------------------------------------------|--------------------------------|
| **High-Level Description** | Uses Diagnostic Settings in Tenant A to stream logs to Event Hub; Tenant B ingests using Function or DCR. | Tenant A delegates subscription/RG access to Tenant B via Azure Lighthouse; Tenant B directly ingests logs into its Log Analytics workspace using AMA + DCR. | Tenant B operates Microsoft Sentinel centrally and queries/analyzes logs that remain in Tenant A workspaces via Lighthouse; no log ingestion into Tenant B. |
| **Complexity Level** | Low (quick deployment, minimal prerequisites) | Medium (requires Lighthouse delegation and DCR/AMA configuration) | High (Sentinel enablement, Lighthouse, cross-workspace queries, analytics rules, automation) |
| **Security Posture** | Medium – secure but depends on SAS keys unless Managed Identity and private endpoints are configured | High – RBAC-based delegation, Managed Identities, PIM/JIT elevation, audited access | Very High – SOC-grade RBAC, PIM, Sentinel controls, cross-tenant access governance |
| **Access Model** | Event Hub access via SAS or Managed Identity | Delegated access via Lighthouse Registration Definition + Assignment | Delegated access + Sentinel-specific RBAC |
| **Data Flow** | Tenant A → Event Hub → Tenant B ingestion → Log Analytics | Tenant A resources → AMA/DCR → Tenant B Log Analytics workspace directly | Tenant A & B workspaces → Sentinel (Tenant B) via cross-workspace (union) queries |
| **Works With** | Azure Activity Logs, Resource Logs, Diagnostic logs | AMA-supported logs, Diagnostic Settings, VM and platform telemetry | Any data already stored in either tenant's Log Analytics workspaces (security events, telemetry) |
| **Requires Lighthouse?** | ❌ No | ✅ Yes | ✅ Yes |
| **Requires Event Hub?** | ✅ Yes | ❌ No | ❌ No |
| **Ingestion Method** | Azure Function / Logic App → Log Analytics Data Collector API | Native ingestion via AMA + DCR | No ingestion – Sentinel analytics and cross-workspace queries only |
| **Use Cases** | Quick log export, testing, raw telemetry forwarding | Secure enterprise log ingestion, centralized custody, multi-tenant telemetry pipelines | Central SOC operations, threat detection, hunting, incident management |
| **Best For** | Simplicity and speed when governance is less critical | Security, governance, scalability, and centralized ingestion for simulations | Advanced security analytics and SOC workflows (not ingestion pipelines) |
| **Costs** | Event Hub + Function App + Log Analytics ingestion | Standard Log Analytics ingestion + AMA overhead | Sentinel + Log Analytics ingestion + analytics rules |
| **Limitations** | Requires extra infrastructure and key management; less governed | Requires Lighthouse setup and identity architecture | Not suitable for raw or near-raw log ingestion into Tenant B |
| **Scalability** | Good (Event Hub scales well) | Excellent (DCR/AMA designed for scale) | Excellent for analytics; limited for ingestion scenarios |

---

## Appendix B – Hybrid Approach Architecture Diagram

> **Scope**: High-level overview showing ALL three collection methods (Lighthouse, Direct Diagnostic Settings, M365 API) and how they combine to provide complete telemetry coverage. See Appendix C for detailed Lighthouse-specific flow.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           TENANT A (Simulation Game Board)                       │
│                                                                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐                  │
│  │ Azure Resources │  │   Virtual       │  │  Entra ID       │                  │
│  │ (Key Vault,     │  │   Machines      │  │  (Tenant-Level) │                  │
│  │  Storage, SQL)  │  │                 │  │                 │                  │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘                  │
│           │                    │                    │                            │
│           │ Diagnostic         │ AMA + DCR         │ Diagnostic                  │
│           │ Settings           │                    │ Settings                    │
│           │                    │                    │ (Global Admin)              │
│           │                    │                    │                            │
│  ┌────────┴────────────────────┴────────────────────┴────────┐                  │
│  │              Azure Lighthouse Delegation                   │                  │
│  │              (Subscription/Resource Level)                 │                  │
│  └────────────────────────────┬───────────────────────────────┘                  │
│                               │                                                  │
│  ┌────────────────────────────┴───────────────────────────────┐                  │
│  │                    M365 Services                            │                  │
│  │  (Exchange, SharePoint, Teams, OneDrive)                   │                  │
│  │  → Office 365 Management API (separate from Azure)         │                  │
│  └────────────────────────────┬───────────────────────────────┘                  │
│                               │                                                  │
└───────────────────────────────┼──────────────────────────────────────────────────┘
                                │
                                │ Logs flow via:
                                │ • Lighthouse (Azure logs)
                                │ • Direct Diagnostic Settings (Entra ID)
                                │ • Office 365 Management API (M365)
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           TENANT B (Admin Center)                                │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                    Log Analytics Workspace                                │   │
│  │                                                                           │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │   │
│  │  │ AzureActivity│  │    Perf     │  │ SigninLogs  │  │M365AuditLogs│      │   │
│  │  │             │  │   Event     │  │  AuditLogs  │  │    _CL      │      │   │
│  │  │             │  │   Syslog    │  │             │  │             │      │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘      │   │
│  │       ▲                 ▲                ▲                ▲               │   │
│  │       │                 │                │                │               │   │
│  │   Lighthouse        Lighthouse       Direct DS      Automation           │   │
│  │   + Diag Settings   + AMA + DCR     (Global Admin)   Runbook             │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                      │                                           │
│                                      ▼                                           │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                    Microsoft Sentinel (Optional)                          │   │
│  │                    Analytics | Hunting | Incidents                        │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Appendix C – Azure Lighthouse + Log Analytics Delegation – Detailed Flow Diagram

> **Scope**: Deep-dive into the Lighthouse delegation process, showing the step-by-step operational flow from offer creation to log ingestion. This is a detailed view of the Lighthouse component shown in Appendix B.

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                        Admin (Tenant B – Provider)                                │
│                                                                                   │
│  • Security team / MSP managing cross-tenant telemetry                           │
│  • Creates and publishes Lighthouse offer                                        │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (1) Create Lighthouse Offer
                                    │     • Define authorizations (RBAC roles)
                                    │     • Specify principal IDs (security group)
                                    │     • Set scope (subscription or RG level)
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                  Registration Definition (Tenant B)                               │
│                                                                                   │
│  • ARM template defining delegated access                                        │
│  • Roles: Monitoring Contributor, Log Analytics Contributor                      │
│  • Optional: PIM-eligible authorizations for JIT access                          │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (2) Tenant A consumes offer
                                    │     • Customer admin deploys assignment
                                    │     • Can be automated via ARM/Bicep/Terraform
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│              Registration Assignment (Tenant A – Customer)                        │
│                                                                                   │
│  • Links Tenant A subscription/RG to Tenant B's definition                       │
│  • Grants delegated access without sharing credentials                           │
│  • Auditable in both tenants                                                     │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (3) Delegation activated
                                    │     • Tenant B can now see Tenant A resources
                                    │     • Access scoped to delegated subscription/RG
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│           Delegated Subscription / RG visible in Tenant B                         │
│                                                                                   │
│  • Appears in Azure Portal under "My customers"                                  │
│  • Accessible via Azure CLI, PowerShell, REST API                                │
│  • Full resource visibility within delegated scope                               │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (4) RBAC granted:
                                    │     • Monitoring Contributor
                                    │     • Log Analytics Contributor
                                    │     • Reader (for resource discovery)
                                    │     • Optional: Contributor (for diagnostic settings)
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│            Tenant B Azure Monitor – DCR & AMA Management                          │
│                                                                                   │
│  • Create Data Collection Rules targeting Tenant A resources                     │
│  • Deploy Azure Monitor Agent via Azure Policy                                   │
│  • Configure diagnostic settings on Tenant A resources                           │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (5) Create Data Collection Rules
                                    │     • Select delegated scopes (Tenant A)
                                    │     • Define data sources (Perf, Events, Syslog)
                                    │     • Set destination (Tenant B workspace)
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│              Azure Monitor Agent (Tenant A resources)                             │
│                                                                                   │
│  • Installed on VMs in Tenant A                                                  │
│  • Configured via DCR to collect specified telemetry                             │
│  • Uses Managed Identity for authentication                                      │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (6) AMA sends logs directly
                                    │     • No intermediate infrastructure
                                    │     • Secure TLS connection
                                    │     • Cross-tenant data flow supported natively
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│          Log Analytics Workspace (Tenant B – Central Workspace)                   │
│                                                                                   │
│  • Receives logs from Tenant A resources                                         │
│  • Standard tables: Perf, Event, Syslog, AzureActivity, AzureDiagnostics        │
│  • Full query and analytics capabilities                                         │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (7) Logs arrive natively
                                    │     • No Event Hub required
                                    │     • No Function App required
                                    │     • No custom ingestion code
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                        Sentinel (Optional)                                        │
│                                                                                   │
│  • Analytics Rules for threat detection                                          │
│  • Workbooks for visualization                                                   │
│  • Incidents and automated response                                              │
│  • Hunting queries across all ingested data                                      │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### Lighthouse Approach – Key Characteristics

| Characteristic | Description |
|----------------|-------------|
| **Security Model** | Secure operational model with fine-grained RBAC |
| **Infrastructure** | No Event Hub / Function App dependency |
| **Authentication** | Uses RBAC + PIM and Managed Identity |
| **Ingestion** | Native log ingestion via AMA + DCR |
| **Governance** | Full audit trail in both tenants |
| **Access Control** | Just-In-Time (JIT) elevation via PIM supported |
| **Scalability** | Scales with Azure Monitor infrastructure |
| **Cost** | No additional infrastructure costs beyond AMA |

### When to Use Lighthouse (Recommended for Most Scenarios)

| Scenario | Why Lighthouse Is Preferred |
|----------|----------------------------|
| Enterprise governance | Strong RBAC, audit trails, and compliance |
| Security-sensitive environments | No shared secrets, PIM support |
| Long-term operations | Sustainable, low-maintenance model |
| Multi-tenant MSP scenarios | Centralized management of multiple customers |
| Compliance requirements | Clear separation of duties, auditable access |

---

## Appendix D – Microsoft Sentinel Multi-Tenant Integration – Detailed Flow Diagram

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                        Tenant A – GameBoard                                       │
│                                                                                   │
│  • Simulation environment with Azure resources                                   │
│  • Logs stored in local Log Analytics Workspace                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (1) Logs stored in Workspace A
                                    │     • Activity Logs, Resource Logs
                                    │     • VM telemetry (Perf, Events, Syslog)
                                    │     • Entra ID logs (if configured)
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                  Log Analytics Workspace A (Tenant A)                             │
│                                                                                   │
│  • Data remains in Tenant A                                                      │
│  • No cross-tenant data transfer                                                 │
│  • Retention and compliance managed locally                                      │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (2) Delegated access via Lighthouse
                                    │     • Tenant B granted read access to Workspace A
                                    │     • No data movement required
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                  Tenant B – Central Admin Center                                  │
│                                                                                   │
│  • Central SOC operations                                                        │
│  • Manages security across multiple tenants                                      │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (3) Enable Sentinel on Workspace B
                                    │     • Central Sentinel instance
                                    │     • Connects to delegated workspaces
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                  Microsoft Sentinel (Tenant B)                                    │
│                                                                                   │
│  • Centralized security operations                                               │
│  • Cross-workspace visibility via Lighthouse                                     │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (4) Cross-workspace queries
                                    │     • union workspace('TenantA-WS').SecurityEvent
                                    │     • Query data across all delegated workspaces
                                    │     • No data duplication
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│          Analytics Rules / Hunting / UEBA / Fusion                                │
│                                                                                   │
│  • Analytics Rules: Detect threats across tenants                                │
│  • Hunting: Proactive threat hunting across workspaces                           │
│  • UEBA: User and entity behavior analytics                                      │
│  • Fusion: ML-based multi-stage attack detection                                 │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (5) Generate incidents centrally
                                    │     • Single pane of glass for all tenants
                                    │     • Unified incident queue
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                  SOC Analysts – Tenant B                                          │
│                                                                                   │
│  • Investigate incidents across all tenants                                      │
│  • Triage and respond from central location                                      │
│  • Full context from delegated workspaces                                        │
└──────────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ (6) Automate response (Logic Apps)
                                    │     • Playbooks triggered by incidents
                                    │     • Cross-tenant remediation actions
                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────┐
│                  Playbooks / Workflows                                            │
│                                                                                   │
│  • Logic Apps for automated response                                             │
│  • Integration with ticketing systems                                            │
│  • Notification and escalation workflows                                         │
└──────────────────────────────────────────────────────────────────────────────────┘
```

### Sentinel Multi-Tenant – Key Characteristics

| Characteristic | Description |
|----------------|-------------|
| **Architecture** | True centralized SOC spanning tenants |
| **Data Location** | Data remains in source tenant workspaces |
| **Capabilities** | Cross-tenant analytics, hunting, automation |
| **Access Model** | Uses Lighthouse for delegated workspace visibility |
| **Ingestion** | No direct raw log forwarding requirement |
| **Best For** | Simulation, security research, multi-tenant defence |

### When to Use Sentinel Multi-Tenant

| Scenario | Why Sentinel Multi-Tenant Is Appropriate |
|----------|------------------------------------------|
| Centralized SOC operations | Single pane of glass for security across tenants |
| Security research | Cross-tenant threat hunting and correlation |
| Multi-tenant defence | Unified incident management and response |
| Data sovereignty requirements | Data stays in source tenant (no transfer) |
| Analytics-focused use cases | When querying is sufficient (no ingestion needed) |

### ⚠️ Microsoft Sentinel Role Clarification

> **Important**: Microsoft Sentinel Multi-Tenant capability is primarily designed for **centralized security operations**, including analytics, hunting, correlation, and incident response across multiple tenants using Azure Lighthouse–based delegated access.
>
> **Sentinel does NOT provide a mechanism for ingesting raw or near-raw telemetry into a central Log Analytics workspace in another tenant.**
>
> As such, Sentinel should be positioned as a **post-ingestion analytics and SOC layer**, not as a cross-tenant telemetry ingestion pipeline.

**For scenarios that require:**
- Centralized custody of telemetry
- Retention in a central workspace
- Transformation of logs
- Downstream analysis beyond SOC use cases

**→ Use Azure Lighthouse + Log Analytics Delegation (AMA + DCR) for ingestion, with Sentinel enabled optionally after ingestion for analytics and detection use cases.**

---

## Appendix E – Continuous Export via Azure Event Hub – Detailed Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           TENANT A (Simulation Game Board)                       │
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                      Azure Resources                                     │    │
│  │  (VMs, Key Vault, Storage, SQL, App Services, etc.)                     │    │
│  └────────────────────────────────┬────────────────────────────────────────┘    │
│                                   │                                              │
│                                   │ (1) Platform / Resource Logs Generated       │
│                                   ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                 Azure Monitor Diagnostic Settings                        │    │
│  │                 (Configured to route to Event Hub)                       │    │
│  └────────────────────────────────┬────────────────────────────────────────┘    │
│                                   │                                              │
│                                   │ (2) Diagnostic Setting routes logs           │
│                                   │     to Event Hub                             │
│                                   ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │              Event Hub Namespace + Event Hub                             │    │
│  │                                                                          │    │
│  │  • Namespace: eh-ns-telemetry-export                                    │    │
│  │  • Event Hub: eh-azure-logs                                             │    │
│  │  • Partitions: 4-32 (based on throughput)                               │    │
│  │  • Retention: 1-7 days                                                  │    │
│  └────────────────────────────────┬────────────────────────────────────────┘    │
│                                   │                                              │
│                                   │ (3) Raw log batches emitted to Event Hub     │
│                                   ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                    Secure Access Mechanism                               │    │
│  │                                                                          │    │
│  │  Option A: Shared Access Policy (Send-only)                             │    │
│  │            • Connection string stored in Key Vault                      │    │
│  │            • Rotate keys periodically                                   │    │
│  │                                                                          │    │
│  │  Option B: Managed Identity (Preferred)                                 │    │
│  │            • Azure RBAC: "Azure Event Hubs Data Receiver"               │    │
│  │            • No secrets to manage                                       │    │
│  │            • Cross-tenant MI requires federation setup                  │    │
│  └────────────────────────────────┬────────────────────────────────────────┘    │
│                                   │                                              │
└───────────────────────────────────┼──────────────────────────────────────────────┘
                                    │
                                    │ Event Hub connection (SAS or MI)
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           TENANT B (Admin Center)                                │
│                                                                                  │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                    Ingestion Application                                 │    │
│  │                                                                          │    │
│  │  Option A: Azure Function (Event Hub Trigger)                           │    │
│  │            • Triggered automatically on new events                      │    │
│  │            • Scales based on partition count                            │    │
│  │            • Checkpointing for exactly-once processing                  │    │
│  │                                                                          │    │
│  │  Option B: Logic App (Event Hub → HTTP Post)                            │    │
│  │            • Low-code option                                            │    │
│  │            • Built-in retry logic                                       │    │
│  │            • Good for lower volume scenarios                            │    │
│  └────────────────────────────────┬────────────────────────────────────────┘    │
│                                   │                                              │
│                                   │ (4) App transforms or wraps log payload      │
│                                   │     • Parse JSON                             │
│                                   │     • Add metadata (source tenant, etc.)     │
│                                   │     • Filter/enrich as needed                │
│                                   ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                    Log Analytics Workspace                               │    │
│  │                                                                          │    │
│  │  (5) Ingest via Data Collector API                                      │    │
│  │      → Custom Table: EH_RawLogs_CL                                      │    │
│  │                                                                          │    │
│  │  Alternative: Logs Ingestion API (newer)                                │    │
│  │      → DCR-based ingestion                                              │    │
│  │      → Standard or custom tables                                        │    │
│  └────────────────────────────────┬────────────────────────────────────────┘    │
│                                   │                                              │
│                                   ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │                    Microsoft Sentinel (Optional)                         │    │
│  │                                                                          │    │
│  │  • Analytics Rules (detect threats in ingested logs)                    │    │
│  │  • Workbooks (visualize cross-tenant telemetry)                         │    │
│  │  • Alerts & Incidents (automated response)                              │    │
│  │  • Hunting queries (proactive threat hunting)                           │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Event Hub Approach – Key Characteristics

| Characteristic | Description |
|----------------|-------------|
| **Data Flow** | Push-based from Tenant A → Event Hub → Tenant B |
| **Infrastructure** | Requires Event Hub namespace + Function App or Logic App |
| **Setup Speed** | Fast - can be operational within hours |
| **Security** | Medium - depends on SAS key management unless Managed Identity is used |
| **Latency** | Near real-time (seconds to minutes) |
| **Scalability** | High - Event Hub supports millions of events/second |
| **Cost** | Event Hub + Function App compute costs |
| **Governance** | Lower - no built-in RBAC delegation like Lighthouse |

### When to Use Event Hub (Contingency Scenarios)

| Scenario | Why Event Hub May Be Preferred |
|----------|-------------------------------|
| High-volume streaming | Event Hub handles massive throughput better than diagnostic settings |
| Real-time requirements | Sub-second latency for critical alerts |
| Custom transformation | Need to transform/filter logs before ingestion |
| Lighthouse not available | Source tenant cannot or will not enable Lighthouse delegation |
| Legacy integration | Existing Event Hub infrastructure already in place |

---

## Document History

| Version | Date | Changes |
|---------|------|---------|
| v3 | - | Original document |
| v4 | 2026-01-13 | Added Entra ID and M365 log collection requirements; clarified that no single method covers all log types; updated recommended approach to hybrid model |
| v4.1 | 2026-01-13 | Added Appendix A (Hybrid Approach Architecture Diagram) and Appendix B (Event Hub Detailed Flow Diagram) |
| v4.2 | 2026-01-13 | Added Appendix B (Azure Lighthouse Detailed Flow), Appendix C (Microsoft Sentinel Multi-Tenant with role clarification), renumbered Event Hub to Appendix D |
| v4.3 | 2026-01-13 | Added Appendix A (Detailed Comparison Table), renumbered all appendices (A→B, B→C, C→D, D→E) |
