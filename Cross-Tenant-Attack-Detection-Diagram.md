# Cross-Tenant Attack Detection: Central vs Individual Logging

> **Security Scenario Analysis** | Why Central Logging is Critical for Multi-Tenant Threat Detection

---

## Attack Scenario: Lateral Movement Across Simulation Tenants

An attacker compromises credentials in one simulation tenant and moves laterally across multiple tenants, escalating privileges and exfiltrating data. This diagram illustrates how the attack unfolds and why central logging is essential for detection.

---

## Scenario 1: Individual Tenant Logging (Attack Goes Undetected)

```mermaid
sequenceDiagram
    autonumber
    participant Attacker as 🔴 Attacker
    participant TenantA as Tenant A<br/>(Game Board 1)
    participant TenantB as Tenant B<br/>(Game Board 2)
    participant TenantC as Tenant C<br/>(Game Board 3)
    participant WorkspaceA as Workspace A<br/>(Tenant A Logs)
    participant WorkspaceB as Workspace B<br/>(Tenant B Logs)
    participant WorkspaceC as Workspace C<br/>(Tenant C Logs)
    participant SOC as 👤 SOC Analyst

    Note over Attacker,SOC: PHASE 1: Initial Compromise (Tenant A)
    Attacker->>TenantA: Phishing email to user@tenantA.com
    TenantA->>WorkspaceA: Log: Suspicious sign-in from unusual location
    Note over WorkspaceA: ⚠️ Alert generated<br/>but appears isolated

    Note over Attacker,SOC: PHASE 2: Credential Harvesting
    Attacker->>TenantA: Deploy credential harvester
    TenantA->>WorkspaceA: Log: PowerShell execution
    TenantA->>WorkspaceA: Log: Access to Key Vault
    Note over WorkspaceA: Logs exist but<br/>no cross-tenant context

    Note over Attacker,SOC: PHASE 3: Lateral Movement to Tenant B
    Attacker->>TenantB: Use harvested credentials
    TenantB->>WorkspaceB: Log: New sign-in from service principal
    Note over WorkspaceB: ⚠️ Appears as<br/>legitimate activity

    Note over Attacker,SOC: PHASE 4: Privilege Escalation
    Attacker->>TenantB: Escalate to Global Admin
    TenantB->>WorkspaceB: Log: Role assignment change
    Note over WorkspaceB: No link to<br/>Tenant A activity

    Note over Attacker,SOC: PHASE 5: Lateral Movement to Tenant C
    Attacker->>TenantC: Access via compromised admin
    TenantC->>WorkspaceC: Log: Admin sign-in
    TenantC->>WorkspaceC: Log: Data export initiated
    Note over WorkspaceC: Exfiltration begins

    Note over Attacker,SOC: DETECTION FAILURE
    SOC->>WorkspaceA: Review Tenant A alerts
    Note over SOC: Sees isolated<br/>suspicious sign-in
    SOC->>WorkspaceB: Switch to Tenant B
    Note over SOC: Sees role change<br/>but no connection
    SOC->>WorkspaceC: Switch to Tenant C
    Note over SOC: Sees data export<br/>too late!

    Note over Attacker,SOC: ❌ RESULT: Attack chain invisible<br/>Each workspace shows fragments<br/>No analyst can correlate in real-time
```

### Why Detection Failed

| Phase | What Happened | What SOC Saw | Why It Was Missed |
|-------|---------------|--------------|-------------------|
| 1 | Phishing compromise | Suspicious sign-in alert | Appeared as isolated incident |
| 2 | Credential harvesting | PowerShell + Key Vault access | No context of attacker intent |
| 3 | Lateral movement | New service principal sign-in | Looked like legitimate automation |
| 4 | Privilege escalation | Role assignment change | No link to previous activity |
| 5 | Data exfiltration | Data export logs | Discovered after the fact |

**Total Time to Detect**: Hours to days (if ever)
**Data Exfiltrated**: Complete

---

## Scenario 2: Central Log Ingestion (Attack Detected and Stopped)

```mermaid
sequenceDiagram
    autonumber
    participant Attacker as 🔴 Attacker
    participant TenantA as Tenant A<br/>(Game Board 1)
    participant TenantB as Tenant B<br/>(Game Board 2)
    participant TenantC as Tenant C<br/>(Game Board 3)
    participant Central as 🛡️ Central Workspace<br/>(All Tenant Logs)
    participant Sentinel as Microsoft Sentinel<br/>(Analytics Engine)
    participant SOC as 👤 SOC Analyst

    Note over Attacker,SOC: PHASE 1: Initial Compromise (Tenant A)
    Attacker->>TenantA: Phishing email to user@tenantA.com
    TenantA->>Central: Log: Suspicious sign-in from unusual location
    Central->>Sentinel: Trigger: Anomalous sign-in detected
    Note over Sentinel: 🔔 Alert created<br/>Tracking begins

    Note over Attacker,SOC: PHASE 2: Credential Harvesting
    Attacker->>TenantA: Deploy credential harvester
    TenantA->>Central: Log: PowerShell execution
    TenantA->>Central: Log: Access to Key Vault
    Central->>Sentinel: Correlate: Same user + suspicious activity
    Note over Sentinel: 🔔 Incident escalated<br/>User flagged for monitoring

    Note over Attacker,SOC: PHASE 3: Lateral Movement Attempt
    Attacker->>TenantB: Use harvested credentials
    TenantB->>Central: Log: New sign-in from service principal
    Central->>Sentinel: CORRELATION DETECTED!
    Note over Sentinel: 🚨 CRITICAL ALERT<br/>Same credential pattern<br/>across Tenant A → B

    Sentinel->>SOC: High-priority incident
    Note over SOC: Full attack chain visible:<br/>1. Phishing in Tenant A<br/>2. Credential theft<br/>3. Lateral movement to B

    Note over Attacker,SOC: RESPONSE: Attack Blocked
    SOC->>TenantA: Disable compromised account
    SOC->>TenantB: Revoke service principal
    SOC->>TenantC: Preemptive lockdown
    Note over Attacker: ❌ Attack chain broken<br/>Cannot proceed to Tenant C

    Note over Attacker,SOC: ✅ RESULT: Attack detected at Phase 3<br/>Full context available<br/>Lateral movement blocked
```

### Why Detection Succeeded

| Phase | What Happened | What Sentinel Detected | Action Taken |
|-------|---------------|------------------------|--------------|
| 1 | Phishing compromise | Anomalous sign-in | Alert created, tracking started |
| 2 | Credential harvesting | Correlated suspicious activity | Incident escalated |
| 3 | Lateral movement | **Cross-tenant credential reuse** | 🚨 **Critical alert triggered** |
| 4 | — | Attack blocked | Accounts disabled |
| 5 | — | Attack blocked | No exfiltration |

**Total Time to Detect**: Minutes
**Data Exfiltrated**: None

---

## The Detection Difference

```mermaid
flowchart TB
    subgraph Individual["❌ Individual Tenant Logging"]
        direction TB
        I1["Tenant A Workspace"]
        I2["Tenant B Workspace"]
        I3["Tenant C Workspace"]
        
        I1 -.->|"No connection"| I2
        I2 -.->|"No connection"| I3
        
        IA["Attack in A"] --> I1
        IB["Attack in B"] --> I2
        IC["Attack in C"] --> I3
        
        IS["SOC Analyst"]
        IS -.->|"Manual review"| I1
        IS -.->|"Manual review"| I2
        IS -.->|"Manual review"| I3
        
        IR["❌ Result:<br/>Fragments only<br/>No correlation<br/>Attack succeeds"]
    end
    
    subgraph Central["✅ Central Log Ingestion"]
        direction TB
        C1["Tenant A"]
        C2["Tenant B"]
        C3["Tenant C"]
        
        CW[("Central<br/>Workspace")]
        
        C1 -->|"Logs"| CW
        C2 -->|"Logs"| CW
        C3 -->|"Logs"| CW
        
        CA["Attack in A"] --> C1
        CB["Attack in B"] --> C2
        
        CS["Sentinel"]
        CW --> CS
        
        CS -->|"Correlation"| CD["🚨 Cross-tenant<br/>attack detected!"]
        
        CR["✅ Result:<br/>Full chain visible<br/>Real-time correlation<br/>Attack blocked"]
    end
```

---

## Attack Indicators Across Tenants

The following table shows how attack indicators appear differently depending on logging architecture:

| Attack Indicator | Individual Logging View | Central Logging View |
|------------------|------------------------|---------------------|
| **Suspicious sign-in** | Isolated alert in Tenant A | First link in attack chain |
| **Credential access** | PowerShell event in Tenant A | Correlated with sign-in anomaly |
| **Service principal creation** | New identity in Tenant B | Same credential pattern as Tenant A |
| **Role escalation** | Admin change in Tenant B | Linked to compromised identity |
| **Data export** | Activity in Tenant C | **Never happens** — blocked earlier |

---

## Key Correlation Queries (Only Possible with Central Logging)

### Detect Cross-Tenant Credential Reuse

```kusto
// Find the same credential used across multiple tenants
SigninLogs
| where TimeGenerated > ago(24h)
| summarize 
    Tenants = make_set(TenantId),
    TenantCount = dcount(TenantId),
    SignInCount = count()
    by UserPrincipalName, IPAddress
| where TenantCount > 1
| order by TenantCount desc
```

### Track Lateral Movement Chain

```kusto
// Correlate activity across tenants for a specific user
let SuspiciousUser = "compromised@tenantA.com";
union SigninLogs, AuditLogs, AzureActivity
| where TimeGenerated > ago(7d)
| where Identity contains SuspiciousUser or UserPrincipalName == SuspiciousUser
| project TimeGenerated, TenantId, OperationName, ResultType, IPAddress
| order by TimeGenerated asc
```

### Detect Privilege Escalation After Cross-Tenant Movement

```kusto
// Find role assignments that follow cross-tenant sign-ins
let CrossTenantUsers = SigninLogs
    | where TimeGenerated > ago(24h)
    | summarize TenantCount = dcount(TenantId) by UserPrincipalName
    | where TenantCount > 1
    | project UserPrincipalName;
AuditLogs
| where TimeGenerated > ago(24h)
| where OperationName contains "role" or OperationName contains "member"
| where InitiatedBy.user.userPrincipalName in (CrossTenantUsers)
| project TimeGenerated, TenantId, OperationName, TargetResources
```

> ⚠️ **These queries are impossible with individual tenant logging** — the data required to correlate across tenants simply doesn't exist in any single workspace.

---

## Summary: Why Central Logging is Non-Negotiable

| Aspect | Individual Logging | Central Logging |
|--------|:------------------:|:---------------:|
| Cross-tenant attack visibility | ❌ Blind | ✅ Full visibility |
| Time to detect lateral movement | Hours to days | Minutes |
| Correlation queries | ❌ Impossible | ✅ Native |
| Attack chain reconstruction | ❌ Manual, after-the-fact | ✅ Real-time |
| Preemptive blocking | ❌ Cannot anticipate | ✅ Block before escalation |

**For simulation environments where attackers may move between tenants, central log ingestion is the only architecture that enables effective threat detection.**

---

*Related Documents:*
- [Central vs Individual Logging Comparison](Central-vs-Individual-Logging-Comparison.md)
- [Telemetry Collection from Simulation Infrastructure (v5)](Telemetry-Collection-from-Simulation-Infrastructure-v5.md)
- [Azure Cross-Tenant Log Collection Execution Guide](azure-cross-tenant-log-collection-execution.md)
