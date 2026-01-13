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

Implement a non-intrusive telemetry collection layer:

- **Read-Only Mode**: Operates without changing tenant existing settings.
- **Proxy/Shadow Environment**: Captures telemetry passively.
- **Multi-Tenant Isolation**: Prevents cross-contamination.
- **Automated Export**: Sends data to central storage for analysis.

We have several approaches available for collecting logs; however, there are three primary options for transferring complete raw logs from Azure Tenant A (the simulation game board) to Azure Tenant B (the Admin Center):

- **Continuous Export via Event Hub** - A lightweight and straightforward option where Tenant A streams raw Azure logs such as Activity Logs, Resource Logs, and platform telemetry into an Event Hub namespace. Tenant B then ingests these events into its own Log Analytics workspace using an Azure Function or a Data Collection Rule (DCR) configured to pull from the Event Hub. This model is ideal for quick, minimal infrastructure cross tenant log forwarding and suits scenarios where simplicity and fast enablement are priorities.

- **Azure Lighthouse + Log Analytics Delegation** - A secure, enterprise grade approach where Tenant A delegates-controlled access to Tenant B using Azure Lighthouse. With this delegated access, Tenant B can create Data Collection Rules (DCRs) to ingest logs directly from Tenant A's resources into its own Log Analytics workspace, without relying on Event Hub or intermediate infrastructure. This model provides strong security assurances through fine grained RBAC, Just In Time access via PIM, and clear separation of duties, making it a robust choice for cross tenant log collection.

- **Microsoft Sentinel Multi Tenant Integration** - A comprehensive SOC grade model in which Tenant B centrally operates Sentinel and, through Azure Lighthouse, can query, hunt, detect, and manage incidents across Tenant A and other connected tenants. It enables unified security operations with cross workspace analytics, advanced correlation, and integrated automation.

---

## Comparison Table

| Method | Complexity | Security | What It Does | Best For |
|--------|------------|----------|--------------|----------|
| 1. Continuous Export via Event Hub | Low | Medium | Streams platform and resource logs from Tenant A → Event Hub → Tenant B using a Function or DCR for ingestion. | Fastest and simplest option for raw log forwarding where speed matters more than governance. |
| 2. Azure Lighthouse + Log Analytics Delegation | Medium | High | Tenant A delegates controlled access to Tenant B via Azure Lighthouse; Tenant B natively ingests logs directly into its Log Analytics workspace using AMA + DCR, without intermediary infrastructure. | Secure, enterprise grade cross tenant log ingestion with centralized ownership, governance, and compliance. |
| 3. Microsoft Sentinel Multi Tenant | High | Very High | Tenant B operates Microsoft Sentinel centrally and queries, hunts, and analyzes data that remains in Tenant A workspaces via Lighthouse; no direct log ingestion into Tenant B. | Centralized SOC operations, analytics, hunting, and detections across tenants (not for ingestion pipelines). |

---

## Recommended Approach for Simulation Scenarios

For simulation scenarios that require secure ingestion of raw or near-raw telemetry into a central analysis environment, a **hybrid approach combining multiple methods** is required to achieve complete log coverage.

### Critical Limitation: No Single Method Covers All Log Types

> ⚠️ **Important**: Due to architectural differences in how Microsoft exposes different log types, **no single method can collect all telemetry**. The table below shows which methods are required for each log type:

| Log Type | Lighthouse + DCR | Direct Diagnostic Settings | Office 365 Management API |
|----------|------------------|---------------------------|---------------------------|
| Azure Activity Logs | ✅ | - | - |
| Azure Resource Logs | ✅ | - | - |
| VM Logs (via AMA) | ✅ | - | - |
| **Entra ID Logs** | ❌ | ✅ (requires Global Admin) | - |
| **M365 Audit Logs** | ❌ | - | ✅ (requires separate API) |

### Primary Method: Azure Lighthouse + Log Analytics Delegation

This model enables direct, native log ingestion from Tenant A (simulation game boards) into a central Log Analytics workspace in Tenant B using Azure Monitor Agent (AMA) and Data Collection Rules (DCRs), without introducing intermediary infrastructure or modifying tenant behavior. Delegated access is implemented via Azure Lighthouse, providing strong separation of duties, fine-grained RBAC, and Just-In-Time (JIT) elevation through PIM.

**Covers:**
- Azure Activity Logs (subscription-level control plane operations)
- Azure Resource Diagnostic Logs (Key Vault, Storage, SQL, etc.)
- Virtual Machine telemetry (performance counters, Windows Event Logs, Linux Syslog)

### Required Supplementary Method 1: Entra ID Logs

**Why Lighthouse Cannot Collect Entra ID Logs:**
- Entra ID logs are **tenant-level logs**, not resource-level logs
- They require **Global Administrator** credentials in the source tenant
- Lighthouse delegation operates at the subscription/resource level and cannot access tenant-level diagnostic settings

**Collection Method:**
- Configure Entra ID Diagnostic Settings directly in the source tenant
- Requires one-time Global Admin authentication to source tenant
- Logs flow automatically via Azure's native cross-tenant diagnostic settings capability
- No ongoing runbook or automation required (push-based)

**Log Categories Available:**

| Category | License Required |
|----------|------------------|
| AuditLogs | Free |
| SignInLogs | P1/P2 |
| NonInteractiveUserSignInLogs | P1/P2 |
| ServicePrincipalSignInLogs | P1/P2 |
| ManagedIdentitySignInLogs | P1/P2 |
| ProvisioningLogs | P1/P2 |
| RiskyUsers | P2 |
| UserRiskEvents | P2 |
| RiskyServicePrincipals | P2 |
| ServicePrincipalRiskEvents | P2 |
| MicrosoftGraphActivityLogs | P1/P2 |

### Required Supplementary Method 2: M365 Audit Logs

**Why Lighthouse Cannot Collect M365 Audit Logs:**
- Microsoft 365 audit logs are **completely separate from Azure Resource Manager**
- They are accessed via the **Office 365 Management API**, not Azure APIs
- No Azure authentication mechanism (including Lighthouse) can access M365 audit data

**Collection Method:**
- Create a multi-tenant app registration with Office 365 Management API permissions
- Deploy an Azure Automation Runbook to pull logs on a schedule
- Store credentials securely in Key Vault
- Ingest logs into Log Analytics using the Data Collector API

**Log Categories Available:**

| Content Type | Description |
|--------------|-------------|
| Audit.AzureActiveDirectory | Entra ID events (via M365 API) |
| Audit.Exchange | Exchange Online operations |
| Audit.SharePoint | SharePoint & OneDrive activities |
| Audit.General | Teams, Power Platform, Dynamics 365 |
| DLP.All | Data Loss Prevention events |

---

### Key Benefits of the Hybrid Approach

| Benefit | Description |
|---------|-------------|
| **Complete Coverage** | All Azure, Entra ID, and M365 logs collected |
| **Native Ingestion** | AMA + DCR for Azure logs (no Event Hub required) |
| **Push-Based Where Possible** | Azure and Entra ID logs flow automatically after one-time setup |
| **Pull-Based Only Where Required** | M365 logs require scheduled runbook (architectural limitation) |
| **Read-Only Access** | Non-intrusive to simulation tenants |
| **Strong Security** | RBAC, Managed Identity, PIM for Azure; App credentials in Key Vault for M365 |
| **Multi-Tenant Isolation** | Clear custody of collected telemetry |
| **Scalable & Auditable** | Aligned with Azure Monitor best practices |

---

### Summary: Methods Required for Complete Telemetry

| Step | Log Type | Method | Operational Overhead |
|------|----------|--------|---------------------|
| 1 | Azure Activity Logs | Lighthouse + Diagnostic Settings | One-time setup, auto-push |
| 2 | Azure Resource Logs | Lighthouse + Diagnostic Settings | One-time setup, auto-push |
| 3 | VM Logs | Lighthouse + DCR + AMA + Azure Policy | One-time setup, auto-push |
| 4 | **Entra ID Logs** | Direct Diagnostic Settings (Global Admin) | One-time setup, auto-push |
| 5 | **M365 Audit Logs** | Office 365 Management API + Runbook | Ongoing (scheduled runbook) |

This hybrid approach strikes the optimal balance between security, ingestion capability, operational simplicity, and compliance, making it the most appropriate choice for **complete** simulation telemetry collection and analysis.

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
