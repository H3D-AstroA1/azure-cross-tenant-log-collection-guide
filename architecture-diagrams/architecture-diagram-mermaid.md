# Azure Cross-Tenant Log Collection - Mermaid Diagrams

This file contains Mermaid diagrams for the cross-tenant log collection architecture. These diagrams render in:
- GitHub (automatically)
- VS Code with the "Markdown Preview Mermaid Support" extension
- Mermaid Live Editor: https://mermaid.live

> **VS Code Extension:** Press `Ctrl+Shift+X`, search for "bierner.markdown-mermaid", and install.

---

## Complete Architecture Overview

```mermaid
flowchart TB
    subgraph SOURCE["🔴 SOURCE TENANT - Gameboard1"]
        direction TB
        subgraph AzureRes["Azure Resources"]
            VMs["💻 Virtual Machines"]
            PaaS["📦 PaaS Resources"]
            ActLog["📋 Activity Logs"]
        end
        
        subgraph EntraID["Microsoft Entra ID"]
            SignIn["🔐 Sign-in Logs"]
            Audit["📝 Audit Logs"]
            Risk["⚠️ Risk Events"]
        end
        
        subgraph M365Svc["Microsoft 365"]
            Exchange["📧 Exchange"]
            SharePoint["📁 SharePoint"]
            Teams["💬 Teams"]
        end
        
        subgraph SourceCfg["Source Configuration"]
            LHAssign["Lighthouse Assignment"]
            DCR["Data Collection Rule"]
            DiagSet["Diagnostic Settings"]
            AppCons["App Admin Consent"]
        end
    end
    
    subgraph MANAGING["🟢 MANAGING TENANT - Admin1"]
        direction TB
        subgraph Infra["Infrastructure"]
            LHDef["Lighthouse Definition"]
            SecGrp["Security Group"]
            EHNs["Event Hub Namespace"]
            FuncApp["Azure Function"]
            AutoAcct["Automation Account"]
            KV["Key Vault"]
        end
        
        subgraph LAW["Log Analytics Workspace"]
            AzAct["AzureActivity"]
            PerfTbl["Perf/Event/Syslog"]
            AzDiag["AzureDiagnostics"]
            SignInTbl["SigninLogs"]
            AuditTbl["AuditLogs"]
            M365Tbl["M365AuditLogs_CL"]
        end
        
        subgraph Sentinel["Microsoft Sentinel"]
            Rules["Analytics Rules"]
            Incidents["Incidents"]
            Books["Workbooks"]
        end
    end
    
    %% Lighthouse Flow - Steps 3,4,5
    LHDef --> LHAssign
    SecGrp --> LHDef
    ActLog --> AzAct
    VMs --> DCR
    DCR --> PerfTbl
    PaaS --> AzDiag
    
    %% Event Hub Flow - Step 6
    SignIn --> DiagSet
    Audit --> DiagSet
    Risk --> DiagSet
    DiagSet --> EHNs
    EHNs --> FuncApp
    FuncApp --> SignInTbl
    FuncApp --> AuditTbl
    
    %% M365 API Flow - Step 7
    Exchange --> AppCons
    SharePoint --> AppCons
    Teams --> AppCons
    AppCons --> AutoAcct
    AutoAcct --> M365Tbl
    
    %% Key Vault connections
    KV --> FuncApp
    KV --> AutoAcct
    
    %% To Sentinel
    AzAct --> Rules
    PerfTbl --> Rules
    AzDiag --> Rules
    SignInTbl --> Rules
    AuditTbl --> Rules
    M365Tbl --> Rules
    Rules --> Incidents
    Rules --> Books
```

---

## Setup Sequence

```mermaid
flowchart LR
    subgraph Setup["🔧 SETUP PHASE"]
        S0["Step 0<br/>Register Providers<br/>🔴 SOURCE"]
        S1["Step 1<br/>Create Resources<br/>🟢 MANAGING"]
        S2["Step 2<br/>Deploy Lighthouse<br/>🔴 SOURCE"]
    end
    
    subgraph Collection["📊 COLLECTION PHASE"]
        S3["Step 3<br/>Activity Logs<br/>🟢 MANAGING"]
        S4["Step 4<br/>VM Logs<br/>🟢 MANAGING"]
        S5["Step 5<br/>Resource Logs<br/>🟢 MANAGING"]
        S6["Step 6<br/>Entra ID Logs<br/>🟡 BOTH"]
        S7["Step 7<br/>M365 Logs<br/>🟡 BOTH"]
    end
    
    S0 --> S1
    S1 --> S2
    S2 --> S3
    S3 --> S4
    S4 --> S5
    S5 --> S6
    S6 --> S7
```

---

## Method 1: Azure Lighthouse Flow

```mermaid
flowchart LR
    subgraph Source["🔴 SOURCE TENANT"]
        Res["Azure Resources<br/>VMs, Storage, Key Vault"]
        Assign["Registration<br/>Assignment"]
    end
    
    subgraph Managing["🟢 MANAGING TENANT"]
        Def["Registration<br/>Definition"]
        SG["Security Group<br/>Delegated Admins"]
        LAW["Log Analytics<br/>Workspace"]
    end
    
    SG --> Def
    Def --> Assign
    Res -->|"Diagnostic<br/>Settings"| LAW
    
    Assign -.->|"Enables<br/>Access"| Res
```

---

## Method 2: Event Hub Flow

```mermaid
flowchart LR
    subgraph Source["🔴 SOURCE TENANT"]
        Entra["Microsoft<br/>Entra ID"]
        DS["Diagnostic<br/>Settings"]
    end
    
    subgraph Managing["🟢 MANAGING TENANT"]
        EH["Event Hub<br/>Namespace"]
        Func["Azure<br/>Function"]
        KV["Key Vault"]
        LAW["Log Analytics<br/>Workspace"]
    end
    
    Entra --> DS
    DS -->|"SAS Token"| EH
    EH --> Func
    KV -->|"Connection<br/>String"| Func
    Func -->|"Data Collector<br/>API"| LAW
```

---

## Method 3: O365 Management API Flow

```mermaid
flowchart LR
    subgraph Source["🔴 SOURCE TENANT"]
        M365["Microsoft 365<br/>Exchange, SharePoint, Teams"]
        Consent["Admin<br/>Consent"]
    end
    
    subgraph Managing["🟢 MANAGING TENANT"]
        App["App<br/>Registration"]
        Auto["Automation<br/>Account"]
        KV["Key Vault"]
        LAW["Log Analytics<br/>Workspace"]
    end
    
    M365 --> Consent
    App --> Consent
    Consent -->|"OAuth"| Auto
    KV -->|"App Credentials"| Auto
    Auto -->|"O365 API"| M365
    Auto -->|"Data Collector<br/>API"| LAW
```

---

## Log Tables Mapping

```mermaid
flowchart TB
    subgraph Sources["Log Sources"]
        Act["Activity Logs"]
        VM["VM Logs"]
        Res["Resource Logs"]
        Entra["Entra ID Logs"]
        M365["M365 Logs"]
    end
    
    subgraph Tables["Log Analytics Tables"]
        T1["AzureActivity"]
        T2["Perf / Event / Syslog"]
        T3["AzureDiagnostics"]
        T4["SigninLogs / AuditLogs"]
        T5["M365AuditLogs_CL"]
    end
    
    subgraph Steps["Collection Steps"]
        S3["Step 3"]
        S4["Step 4"]
        S5["Step 5"]
        S6["Step 6"]
        S7["Step 7"]
    end
    
    Act --> S3 --> T1
    VM --> S4 --> T2
    Res --> S5 --> T3
    Entra --> S6 --> T4
    M365 --> S7 --> T5
```

---

## Security Architecture

```mermaid
flowchart TB
    subgraph Auth["Authentication Methods"]
        LH["Azure Lighthouse<br/>Delegated RBAC"]
        SAS["SAS Token<br/>Send-only"]
        OAuth["OAuth 2.0<br/>App Registration"]
    end
    
    subgraph Secrets["Secret Storage"]
        KV["Azure Key Vault<br/>RBAC Authorization"]
    end
    
    subgraph Identity["Managed Identities"]
        FuncMI["Function App<br/>System-Assigned MI"]
        AutoMI["Automation Account<br/>System-Assigned MI"]
    end
    
    subgraph Access["Access Control"]
        RBAC["Azure RBAC<br/>Contributor Role"]
        API["API Permissions<br/>ActivityFeed.Read"]
    end
    
    LH --> RBAC
    SAS --> KV
    OAuth --> KV
    KV --> FuncMI
    KV --> AutoMI
    OAuth --> API
```

---

## Component Deployment Order

```mermaid
gantt
    title Cross-Tenant Log Collection Setup
    dateFormat X
    axisFormat %s
    
    section Setup Phase
    Register Providers (SOURCE)     :s0, 0, 1
    Create Security Group (MANAGING) :s1, 1, 2
    Create Workspace (MANAGING)      :s1b, 1, 2
    Create Key Vault (MANAGING)      :s1c, 1, 2
    Deploy Lighthouse (SOURCE)       :s2, 2, 3
    
    section Collection Phase
    Activity Logs (MANAGING)         :s3, 3, 4
    VM Logs (MANAGING)               :s4, 4, 5
    Resource Logs (MANAGING)         :s5, 5, 6
    Entra ID Logs (BOTH)             :s6, 6, 7
    M365 Logs (BOTH)                 :s7, 7, 8
```

---

## Simplified Overview

```mermaid
flowchart TB
    subgraph SOURCE["SOURCE TENANT"]
        AzRes["Azure Resources"]
        EntraID["Entra ID"]
        M365["Microsoft 365"]
    end
    
    subgraph MANAGING["MANAGING TENANT"]
        LH["Azure Lighthouse"]
        EH["Event Hub + Function"]
        Auto["Automation Account"]
        LAW["Log Analytics Workspace"]
        Sentinel["Microsoft Sentinel"]
    end
    
    AzRes -->|"Steps 3-5<br/>Lighthouse"| LAW
    EntraID -->|"Step 6<br/>Event Hub"| EH
    EH --> LAW
    M365 -->|"Step 7<br/>O365 API"| Auto
    Auto --> LAW
    LAW --> Sentinel
    LH -.->|"Enables"| AzRes
```
