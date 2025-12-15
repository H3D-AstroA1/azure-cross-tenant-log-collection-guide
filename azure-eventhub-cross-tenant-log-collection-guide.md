# Azure Event Hub Cross-Tenant Log Collection Guide
## Real-Time Log Collection from Atevet17 to Atevet12 using Azure Event Hubs

---

## Table of Contents
1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Event Hub vs Lighthouse Comparison](#event-hub-vs-lighthouse-comparison)
4. [Prerequisites](#prerequisites)
5. [Step 1: Create Event Hub Namespace in Atevet12](#step-1-create-event-hub-namespace-in-atevet12)
6. [Step 2: Create Event Hubs for Different Log Types](#step-2-create-event-hubs-for-different-log-types)
7. [Step 3: Configure Shared Access Policies](#step-3-configure-shared-access-policies)
8. [Step 4: Configure Diagnostic Settings in Atevet17](#step-4-configure-diagnostic-settings-in-atevet17)
9. [Step 5: Set Up Log Analytics Ingestion](#step-5-set-up-log-analytics-ingestion)
10. [Step 6: Configure Azure Function for Log Processing](#step-6-configure-azure-function-for-log-processing)
11. [Step 7: Verify Real-Time Log Collection](#step-7-verify-real-time-log-collection)
12. [Advanced Configuration](#advanced-configuration)
13. [Troubleshooting](#troubleshooting)
14. [Security Considerations](#security-considerations)
15. [Cost Estimation](#cost-estimation)
16. [Summary](#summary)

---

## Overview

**Scenario:** You want to collect all raw logs from Azure tenant **Atevet17** (source/customer tenant) and stream them in **real-time** to tenant **Atevet12** (managing/destination tenant) using Azure Event Hubs.

**Logs to Collect:**
- Subscription Activity Logs (control plane operations)
- Resource Diagnostic Logs:
  - Virtual Machines
  - Key Vaults
  - Storage Accounts
  - Network Security Groups
  - Azure AD Sign-in and Audit Logs
  - Other Azure resources

**Why Event Hubs for Real-Time Collection:**
- ✅ **True real-time streaming** - Sub-second latency
- ✅ **High throughput** - Millions of events per second
- ✅ **Cross-tenant native support** - Direct streaming via connection strings
- ✅ **Multiple consumers** - Fan out to SIEM, Log Analytics, Storage simultaneously
- ✅ **Event replay** - Configurable retention for reprocessing
- ✅ **No Lighthouse delegation required** - Works with connection string authentication
- ✅ **Scalable partitioning** - Handle variable load patterns

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              ATEVET12 (Destination Tenant)                           │
│                                                                                      │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                        Event Hub Namespace                                      │ │
│  │                    (eh-namespace-central-atevet12)                              │ │
│  │                                                                                  │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │ │
│  │  │ eh-activity  │  │ eh-keyvault  │  │ eh-storage   │  │ eh-aad-logs  │        │ │
│  │  │    -logs     │  │    -logs     │  │    -logs     │  │              │        │ │
│  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘        │ │
│  │         │                 │                 │                 │                 │ │
│  └─────────┼─────────────────┼─────────────────┼─────────────────┼─────────────────┘ │
│            │                 │                 │                 │                   │
│            └─────────────────┴────────┬────────┴─────────────────┘                   │
│                                       │                                              │
│                                       ▼                                              │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                         Azure Function App                                      │ │
│  │                    (Event Hub Trigger → Log Analytics)                          │ │
│  │                                                                                  │ │
│  │  • Parses incoming events                                                       │ │
│  │  • Transforms to Log Analytics schema                                           │ │
│  │  • Sends to Data Collection Endpoint                                            │ │
│  └────────────────────────────────────────────────────────────────────────────────┘ │
│                                       │                                              │
│                                       ▼                                              │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                      Log Analytics Workspace                                    │ │
│  │                    (law-central-atevet12)                                       │ │
│  │                                                                                  │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │ │
│  │  │AzureActivity │  │AzureDiagnos- │  │ Custom_CL    │  │SigninLogs    │        │ │
│  │  │              │  │    tics      │  │   Tables     │  │AuditLogs     │        │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘        │ │
│  └────────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────┘
                                        ▲
                                        │ Event Hub Connection String
                                        │ (SAS Token Authentication)
                                        │
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              ATEVET17 (Source Tenant)                                │
│                                                                                      │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                         Diagnostic Settings                                     │ │
│  │              (Configured to stream to Event Hub in Atevet12)                    │ │
│  └────────────────────────────────────────────────────────────────────────────────┘ │
│                                        ▲                                             │
│                                        │                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐             │
│  │ Subscription │  │  Key Vaults  │  │   Storage    │  │    VMs &     │             │
│  │Activity Logs │  │              │  │  Accounts    │  │  Other Res.  │             │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘             │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Event Hub vs Lighthouse Comparison

### Detailed Comparison Table

| Feature | Event Hub Method | Lighthouse Method |
|---------|------------------|-------------------|
| **Latency** | **Sub-second (real-time)** | Near real-time (1-5 minutes) |
| **Throughput** | Millions of events/second | Limited by diagnostic settings |
| **Cross-Tenant Auth** | Connection string (SAS) | Azure AD delegation |
| **Setup Complexity** | Medium-High | Low-Medium |
| **Delegation Required** | ❌ No | ✅ Yes |
| **Multiple Destinations** | ✅ Yes (fan-out) | ❌ Single destination |
| **Event Replay** | ✅ Yes (configurable retention) | ❌ No |
| **SIEM Integration** | ✅ Native support | Requires additional config |
| **Cost** | Higher (Event Hub + Function) | Lower (direct to Log Analytics) |
| **Maintenance** | Higher (Function code) | Lower (managed service) |
| **Data Transformation** | ✅ Full control | ❌ Limited |
| **Buffering** | ✅ Built-in | ❌ No |
| **Ordering Guarantee** | ✅ Per partition | ❌ No |
| **Schema Control** | ✅ Full control | ❌ Azure-defined |

### When to Use Each Method

| Use Case | Recommended Method | Reason |
|----------|-------------------|--------|
| **Real-time security monitoring** | Event Hub | Sub-second latency critical |
| **SIEM integration (Splunk, QRadar)** | Event Hub | Native connectors available |
| **Simple log aggregation** | Lighthouse | Lower complexity |
| **High-volume logging (>100GB/day)** | Event Hub | Better throughput handling |
| **Budget-constrained** | Lighthouse | Lower operational cost |
| **Custom log transformation** | Event Hub | Full processing control |
| **Multiple downstream consumers** | Event Hub | Fan-out capability |
| **Compliance with data residency** | Either | Both support region selection |
| **No cross-tenant delegation allowed** | Event Hub | Works with connection strings only |
| **Quick setup needed** | Lighthouse | Faster to configure |

### Cost Comparison (Estimated Monthly)

| Component | Event Hub Method | Lighthouse Method |
|-----------|------------------|-------------------|
| **Event Hub Namespace (Standard)** | ~$22/month base | N/A |
| **Event Hub Throughput Units** | ~$22/TU/month | N/A |
| **Azure Function (Consumption)** | ~$5-50/month | N/A |
| **Log Analytics Ingestion** | ~$2.76/GB | ~$2.76/GB |
| **Total (50GB/month logs)** | ~$190-250/month | ~$138/month |
| **Total (500GB/month logs)** | ~$1,450-1,550/month | ~$1,380/month |

**Note:** Event Hub method has higher fixed costs but scales better for high-volume scenarios.

---

## Prerequisites

### In Atevet12 (Destination Tenant)

| Requirement | Description | How to Verify/Create |
|-------------|-------------|---------------------|
| **Azure Subscription** | Active subscription with billing | Azure Portal → Subscriptions |
| **Resource Group** | For Event Hub and related resources | Create: `rg-eventhub-central` |
| **Contributor Role** | On the subscription/resource group | Check IAM assignments |
| **Log Analytics Workspace** | To store processed logs | Create or use existing |
| **Azure Function App** | For event processing (optional) | Will create in Step 6 |

### In Atevet17 (Source Tenant)

| Requirement | Description | How to Verify/Create |
|-------------|-------------|---------------------|
| **Azure Subscription** | Active subscription | Azure Portal → Subscriptions |
| **Owner/Contributor Role** | On resources to configure diagnostics | Check IAM assignments |
| **Resource Provider** | `Microsoft.Insights` registered | Register if needed |
| **Network Access** | Outbound to Event Hub endpoint | Check NSG/Firewall rules |

### Information to Gather

Before starting, collect the following information:

```
ATEVET12 (Destination):
├── Tenant ID: ________________________________
├── Subscription ID: __________________________
├── Resource Group Name: rg-eventhub-central
├── Region: __________________________________ (e.g., eastus)
└── Log Analytics Workspace Name: law-central-atevet12

ATEVET17 (Source):
├── Tenant ID: ________________________________
├── Subscription ID(s): _______________________
└── Resources to monitor:
    ├── Key Vaults: ___________________________
    ├── Storage Accounts: _____________________
    └── Other resources: ______________________
```

---

## Step 1: Create Event Hub Namespace in Atevet12

### 1.1 Create Resource Group (if not exists)

**Azure Portal:**
1. Navigate to **Resource groups** → **Create**
2. Subscription: Select your Atevet12 subscription
3. Resource group: `rg-eventhub-central`
4. Region: Select your preferred region (e.g., `East US`)
5. Click **Review + Create** → **Create**

**Azure CLI:**
```bash
# Login to Atevet12 tenant
az login --tenant "<Atevet12-Tenant-ID>"

# Set subscription
az account set --subscription "<Atevet12-Subscription-ID>"

# Create resource group
az group create \
    --name "rg-eventhub-central" \
    --location "eastus"
```

**PowerShell:**
```powershell
# Login to Atevet12 tenant
Connect-AzAccount -TenantId "<Atevet12-Tenant-ID>"

# Set subscription context
Set-AzContext -SubscriptionId "<Atevet12-Subscription-ID>"

# Create resource group
New-AzResourceGroup `
    -Name "rg-eventhub-central" `
    -Location "eastus"
```

### 1.2 Create Event Hub Namespace

**Azure Portal:**
1. Navigate to **Event Hubs** → **Create**
2. **Basics tab:**
   - Subscription: Select your Atevet12 subscription
   - Resource group: `rg-eventhub-central`
   - Namespace name: `eh-namespace-central-atevet12` (must be globally unique)
   - Location: Same as resource group
   - Pricing tier: **Standard** (required for cross-tenant)
   - Throughput Units: Start with **1** (auto-inflate recommended)
3. **Advanced tab:**
   - Enable Auto-Inflate: ✅ **Yes**
   - Auto-Inflate Maximum Throughput Units: **10** (adjust based on expected volume)
4. **Networking tab:**
   - Connectivity method: **Public endpoint (all networks)** for initial setup
   - (Can restrict later with Private Endpoints)
5. Click **Review + Create** → **Create**

**Azure CLI:**
```bash
# Create Event Hub Namespace
az eventhubs namespace create \
    --name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --location "eastus" \
    --sku "Standard" \
    --capacity 1 \
    --enable-auto-inflate true \
    --maximum-throughput-units 10
```

**PowerShell:**
```powershell
# Create Event Hub Namespace
New-AzEventHubNamespace `
    -ResourceGroupName "rg-eventhub-central" `
    -Name "eh-namespace-central-atevet12" `
    -Location "eastus" `
    -SkuName "Standard" `
    -SkuCapacity 1 `
    -EnableAutoInflate $true `
    -MaximumThroughputUnits 10
```

### 1.3 Verify Namespace Creation

```bash
# Get namespace details
az eventhubs namespace show \
    --name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --query "{Name:name, Status:status, Endpoint:serviceBusEndpoint}"
```

**Expected Output:**
```json
{
  "Name": "eh-namespace-central-atevet12",
  "Status": "Active",
  "Endpoint": "sb://eh-namespace-central-atevet12.servicebus.windows.net/"
}
```

---

## Step 2: Create Event Hubs for Different Log Types

Create separate Event Hubs for different log categories to enable:
- Independent scaling per log type
- Separate consumer groups for different processing needs
- Easier troubleshooting and monitoring

### 2.1 Create Event Hubs

**Azure Portal:**
1. Navigate to your Event Hub Namespace → **Event Hubs** → **+ Event Hub**
2. Create the following Event Hubs:

| Event Hub Name | Partition Count | Message Retention | Purpose |
|----------------|-----------------|-------------------|---------|
| `eh-activity-logs` | 4 | 7 days | Subscription Activity Logs |
| `eh-keyvault-logs` | 2 | 7 days | Key Vault Audit Logs |
| `eh-storage-logs` | 4 | 3 days | Storage Account Logs |
| `eh-vm-logs` | 4 | 3 days | VM Diagnostic Logs |
| `eh-aad-logs` | 4 | 7 days | Azure AD Sign-in/Audit Logs |
| `eh-nsg-logs` | 4 | 3 days | NSG Flow Logs |

**Azure CLI (Create all Event Hubs):**
```bash
# Create Event Hubs one by one
az eventhubs eventhub create \
    --name "eh-activity-logs" \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --partition-count 4 \
    --message-retention 7

az eventhubs eventhub create \
    --name "eh-keyvault-logs" \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --partition-count 2 \
    --message-retention 7

az eventhubs eventhub create \
    --name "eh-storage-logs" \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --partition-count 4 \
    --message-retention 3

az eventhubs eventhub create \
    --name "eh-vm-logs" \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --partition-count 4 \
    --message-retention 3

az eventhubs eventhub create \
    --name "eh-aad-logs" \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --partition-count 4 \
    --message-retention 7

az eventhubs eventhub create \
    --name "eh-nsg-logs" \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --partition-count 4 \
    --message-retention 3
```

**PowerShell (Create all Event Hubs):**
```powershell
# Define Event Hubs configuration
$eventHubs = @{
    "eh-activity-logs" = @{ Partitions = 4; Retention = 7 }
    "eh-keyvault-logs" = @{ Partitions = 2; Retention = 7 }
    "eh-storage-logs"  = @{ Partitions = 4; Retention = 3 }
    "eh-vm-logs"       = @{ Partitions = 4; Retention = 3 }
    "eh-aad-logs"      = @{ Partitions = 4; Retention = 7 }
    "eh-nsg-logs"      = @{ Partitions = 4; Retention = 3 }
}

# Create each Event Hub
foreach ($hubName in $eventHubs.Keys) {
    $config = $eventHubs[$hubName]
    
    New-AzEventHub `
        -ResourceGroupName "rg-eventhub-central" `
        -NamespaceName "eh-namespace-central-atevet12" `
        -Name $hubName `
        -PartitionCount $config.Partitions `
        -MessageRetentionInDays $config.Retention
    
    Write-Host "Created Event Hub: $hubName"
}
```

### 2.2 Create Consumer Groups

Consumer groups allow multiple applications to read from the same Event Hub independently.

**Azure CLI:**
```bash
# Create consumer groups for each Event Hub
for hub in eh-activity-logs eh-keyvault-logs eh-storage-logs eh-vm-logs eh-aad-logs eh-nsg-logs; do
    # Consumer group for Log Analytics ingestion
    az eventhubs eventhub consumer-group create \
        --name "cg-loganalytics" \
        --eventhub-name "$hub" \
        --namespace-name "eh-namespace-central-atevet12" \
        --resource-group "rg-eventhub-central"
    
    # Consumer group for SIEM (if needed)
    az eventhubs eventhub consumer-group create \
        --name "cg-siem" \
        --eventhub-name "$hub" \
        --namespace-name "eh-namespace-central-atevet12" \
        --resource-group "rg-eventhub-central"
    
    echo "Created consumer groups for: $hub"
done
```

### 2.3 Verify Event Hubs Creation

```bash
# List all Event Hubs in the namespace
az eventhubs eventhub list \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --query "[].{Name:name, Partitions:partitionCount, Retention:messageRetentionInDays}" \
    --output table
```

**Expected Output:**
```
Name               Partitions    Retention
-----------------  ------------  -----------
eh-activity-logs   4             7
eh-keyvault-logs   2             7
eh-storage-logs    4             3
eh-vm-logs         4             3
eh-aad-logs        4             7
eh-nsg-logs        4             3
```

---

## Step 3: Configure Shared Access Policies

Shared Access Signatures (SAS) provide secure, delegated access to Event Hub resources without sharing account keys.

### 3.1 Create Namespace-Level Policy (for Atevet17 to Send)

**Azure Portal:**
1. Navigate to Event Hub Namespace → **Shared access policies**
2. Click **+ Add**
3. Policy name: `atevet17-send-policy`
4. Claims: ☑️ **Send** only (principle of least privilege)
5. Click **Create**
6. Click on the created policy and copy the **Connection string–primary key**

**Azure CLI:**
```bash
# Create send-only policy for Atevet17
az eventhubs namespace authorization-rule create \
    --name "atevet17-send-policy" \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --rights Send

# Get the connection string
az eventhubs namespace authorization-rule keys list \
    --name "atevet17-send-policy" \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --query "primaryConnectionString" \
    --output tsv
```

**PowerShell:**
```powershell
# Create send-only policy for Atevet17
New-AzEventHubAuthorizationRule `
    -ResourceGroupName "rg-eventhub-central" `
    -NamespaceName "eh-namespace-central-atevet12" `
    -Name "atevet17-send-policy" `
    -Rights @("Send")

# Get the connection string
$keys = Get-AzEventHubKey `
    -ResourceGroupName "rg-eventhub-central" `
    -NamespaceName "eh-namespace-central-atevet12" `
    -Name "atevet17-send-policy"

Write-Host "Connection String: $($keys.PrimaryConnectionString)"
```

### 3.2 Store Connection Strings Securely

**IMPORTANT:** Store connection strings in Azure Key Vault for security.

```bash
# Create Key Vault (if not exists)
az keyvault create \
    --name "kv-eventhub-secrets" \
    --resource-group "rg-eventhub-central" \
    --location "eastus"

# Store the connection string as a secret
CONNECTION_STRING=$(az eventhubs namespace authorization-rule keys list \
    --name "atevet17-send-policy" \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --query "primaryConnectionString" \
    --output tsv)

az keyvault secret set \
    --vault-name "kv-eventhub-secrets" \
    --name "eventhub-atevet17-send-connection" \
    --value "$CONNECTION_STRING"
```

### 3.3 Connection String Format Reference

The connection string format for diagnostic settings:

```
Endpoint=sb://eh-namespace-central-atevet12.servicebus.windows.net/;SharedAccessKeyName=atevet17-send-policy;SharedAccessKey=<key>
```

**Components:**
| Component | Description | Example |
|-----------|-------------|---------|
| `Endpoint` | Service Bus endpoint | `sb://eh-namespace-central-atevet12.servicebus.windows.net/` |
| `SharedAccessKeyName` | Policy name | `atevet17-send-policy` |
| `SharedAccessKey` | The actual key | `<base64-encoded-key>` |

---

## Step 4: Configure Diagnostic Settings in Atevet17

Now configure resources in Atevet17 to stream logs to the Event Hub in Atevet12.

### 4.1 Get Event Hub Authorization Rule ID

First, get the authorization rule resource ID from Atevet12:

```bash
# In Atevet12 tenant
az eventhubs namespace authorization-rule show \
    --name "atevet17-send-policy" \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --query "id" \
    --output tsv
```

**Save this ID - you'll need it for diagnostic settings:**
```
/subscriptions/<Atevet12-Sub-ID>/resourceGroups/rg-eventhub-central/providers/Microsoft.EventHub/namespaces/eh-namespace-central-atevet12/authorizationRules/atevet17-send-policy
```

### 4.2 Configure Subscription Activity Logs

**Azure Portal (in Atevet17):**
1. Navigate to **Monitor** → **Activity log** → **Export Activity Logs**
2. Click **+ Add diagnostic setting**
3. Configure:
   - Diagnostic setting name: `stream-to-atevet12-eventhub`
   - **Log categories:** Select all:
     - ☑️ Administrative
     - ☑️ Security
     - ☑️ ServiceHealth
     - ☑️ Alert
     - ☑️ Recommendation
     - ☑️ Policy
     - ☑️ Autoscale
     - ☑️ ResourceHealth
   - **Destination details:**
     - ☑️ Stream to an event hub
     - Event hub namespace: Enter the authorization rule ID from Step 4.1
     - Event hub name: `eh-activity-logs`
     - Event hub policy name: `atevet17-send-policy`
4. Click **Save**

**Azure CLI (in Atevet17):**
```bash
# Login to Atevet17 tenant
az login --tenant "<Atevet17-Tenant-ID>"
az account set --subscription "<Atevet17-Subscription-ID>"

# Create diagnostic setting for Activity Logs
az monitor diagnostic-settings subscription create \
    --name "stream-to-atevet12-eventhub" \
    --subscription "<Atevet17-Subscription-ID>" \
    --event-hub "eh-activity-logs" \
    --event-hub-auth-rule "/subscriptions/<Atevet12-Sub-ID>/resourceGroups/rg-eventhub-central/providers/Microsoft.EventHub/namespaces/eh-namespace-central-atevet12/authorizationRules/atevet17-send-policy" \
    --logs '[
        {"category": "Administrative", "enabled": true},
        {"category": "Security", "enabled": true},
        {"category": "ServiceHealth", "enabled": true},
        {"category": "Alert", "enabled": true},
        {"category": "Recommendation", "enabled": true},
        {"category": "Policy", "enabled": true},
        {"category": "Autoscale", "enabled": true},
        {"category": "ResourceHealth", "enabled": true}
    ]'
```

### 4.3 Configure Key Vault Diagnostic Settings

**Azure CLI:**
```bash
# Get all Key Vaults in Atevet17
KEY_VAULTS=$(az keyvault list --query "[].id" --output tsv)

# Event Hub Authorization Rule ID
EVENT_HUB_AUTH_RULE="/subscriptions/<Atevet12-Sub-ID>/resourceGroups/rg-eventhub-central/providers/Microsoft.EventHub/namespaces/eh-namespace-central-atevet12/authorizationRules/atevet17-send-policy"

# Configure diagnostic settings for each Key Vault
for KV_ID in $KEY_VAULTS; do
    KV_NAME=$(echo $KV_ID | rev | cut -d'/' -f1 | rev)
    
    az monitor diagnostic-settings create \
        --name "stream-to-atevet12-eventhub" \
        --resource "$KV_ID" \
        --event-hub "eh-keyvault-logs" \
        --event-hub-rule "$EVENT_HUB_AUTH_RULE" \
        --logs '[
            {"category": "AuditEvent", "enabled": true},
            {"category": "AzurePolicyEvaluationDetails", "enabled": true}
        ]' \
        --metrics '[
            {"category": "AllMetrics", "enabled": true}
        ]'
    
    echo "Configured diagnostic settings for Key Vault: $KV_NAME"
done
```

**PowerShell:**
```powershell
# Get all Key Vaults in Atevet17
$keyVaults = Get-AzKeyVault

# Event Hub Authorization Rule ID
$eventHubAuthRuleId = "/subscriptions/<Atevet12-Sub-ID>/resourceGroups/rg-eventhub-central/providers/Microsoft.EventHub/namespaces/eh-namespace-central-atevet12/authorizationRules/atevet17-send-policy"

foreach ($kv in $keyVaults) {
    $kvResourceId = (Get-AzKeyVault -VaultName $kv.VaultName).ResourceId
    
    Set-AzDiagnosticSetting `
        -ResourceId $kvResourceId `
        -Name "stream-to-atevet12-eventhub" `
        -EventHubName "eh-keyvault-logs" `
        -EventHubAuthorizationRuleId $eventHubAuthRuleId `
        -Enabled $true `
        -Category @("AuditEvent", "AzurePolicyEvaluationDetails")
    
    Write-Host "Configured diagnostic settings for Key Vault: $($kv.VaultName)"
}
```

### 4.4 Configure Storage Account Diagnostic Settings

**Azure CLI:**
```bash
# Get all Storage Accounts in Atevet17
STORAGE_ACCOUNTS=$(az storage account list --query "[].id" --output tsv)

# Event Hub Authorization Rule ID
EVENT_HUB_AUTH_RULE="/subscriptions/<Atevet12-Sub-ID>/resourceGroups/rg-eventhub-central/providers/Microsoft.EventHub/namespaces/eh-namespace-central-atevet12/authorizationRules/atevet17-send-policy"

# Configure diagnostic settings for each Storage Account
for SA_ID in $STORAGE_ACCOUNTS; do
    SA_NAME=$(echo $SA_ID | rev | cut -d'/' -f1 | rev)
    
    # Configure for blob service
    az monitor diagnostic-settings create \
        --name "stream-to-atevet12-eventhub" \
        --resource "${SA_ID}/blobServices/default" \
        --event-hub "eh-storage-logs" \
        --event-hub-rule "$EVENT_HUB_AUTH_RULE" \
        --logs '[
            {"category": "StorageRead", "enabled": true},
            {"category": "StorageWrite", "enabled": true},
            {"category": "StorageDelete", "enabled": true}
        ]' \
        --metrics '[
            {"category": "Transaction", "enabled": true}
        ]'
    
    echo "Configured diagnostic settings for Storage Account: $SA_NAME"
done
```

### 4.5 Configure ALL Resource Types (Universal Script)

The following script automatically discovers and configures diagnostic settings for **all supported Azure resource types** in your subscription. This is the recommended approach for comprehensive logging.

**Azure CLI - Universal Diagnostic Settings Script:**
```bash
#!/bin/bash
# configure-all-resources-diagnostics.sh
# This script configures diagnostic settings for ALL supported resource types
# Run this in Atevet17 tenant

set -e

# Configuration - UPDATE THESE VALUES
ATEVET12_SUB_ID="<Atevet12-Subscription-ID>"
EVENT_HUB_NAMESPACE="eh-namespace-central-atevet12"
EVENT_HUB_RG="rg-eventhub-central"
EVENT_HUB_AUTH_RULE="/subscriptions/${ATEVET12_SUB_ID}/resourceGroups/${EVENT_HUB_RG}/providers/Microsoft.EventHub/namespaces/${EVENT_HUB_NAMESPACE}/authorizationRules/atevet17-send-policy"
DIAGNOSTIC_SETTING_NAME="stream-to-atevet12-eventhub"
DEFAULT_EVENT_HUB="eh-activity-logs"

echo "=========================================="
echo "Configuring Diagnostic Settings for ALL Resources"
echo "Destination: Event Hub in Atevet12"
echo "=========================================="

# Function to get available log categories for a resource
get_log_categories() {
    local RESOURCE_ID=$1
    az monitor diagnostic-settings categories list \
        --resource "$RESOURCE_ID" \
        --query "[?categoryType=='Logs'].category" \
        --output tsv 2>/dev/null || echo ""
}

# Function to get available metric categories for a resource
get_metric_categories() {
    local RESOURCE_ID=$1
    az monitor diagnostic-settings categories list \
        --resource "$RESOURCE_ID" \
        --query "[?categoryType=='Metrics'].category" \
        --output tsv 2>/dev/null || echo ""
}

# Function to build logs JSON array
build_logs_json() {
    local CATEGORIES=$1
    local JSON="["
    local FIRST=true
    
    for CAT in $CATEGORIES; do
        if [ "$FIRST" = true ]; then
            FIRST=false
        else
            JSON+=","
        fi
        JSON+="{\"category\":\"$CAT\",\"enabled\":true}"
    done
    
    JSON+="]"
    echo "$JSON"
}

# Function to build metrics JSON array
build_metrics_json() {
    local CATEGORIES=$1
    local JSON="["
    local FIRST=true
    
    for CAT in $CATEGORIES; do
        if [ "$FIRST" = true ]; then
            FIRST=false
        else
            JSON+=","
        fi
        JSON+="{\"category\":\"$CAT\",\"enabled\":true}"
    done
    
    JSON+="]"
    echo "$JSON"
}

# Function to configure diagnostic settings for a resource
configure_resource() {
    local RESOURCE_ID=$1
    local EVENT_HUB_NAME=$2
    local RESOURCE_NAME=$(echo "$RESOURCE_ID" | rev | cut -d'/' -f1 | rev)
    local RESOURCE_TYPE=$(echo "$RESOURCE_ID" | grep -oP 'providers/\K[^/]+/[^/]+' | head -1)
    
    # Get available categories
    LOG_CATS=$(get_log_categories "$RESOURCE_ID")
    METRIC_CATS=$(get_metric_categories "$RESOURCE_ID")
    
    if [ -z "$LOG_CATS" ] && [ -z "$METRIC_CATS" ]; then
        echo "  ⚠ $RESOURCE_NAME ($RESOURCE_TYPE) - No diagnostic categories available"
        return
    fi
    
    # Build JSON arrays
    LOGS_JSON=$(build_logs_json "$LOG_CATS")
    METRICS_JSON=$(build_metrics_json "$METRIC_CATS")
    
    # Create diagnostic setting
    if [ -n "$LOG_CATS" ] && [ -n "$METRIC_CATS" ]; then
        az monitor diagnostic-settings create \
            --name "$DIAGNOSTIC_SETTING_NAME" \
            --resource "$RESOURCE_ID" \
            --event-hub "$EVENT_HUB_NAME" \
            --event-hub-rule "$EVENT_HUB_AUTH_RULE" \
            --logs "$LOGS_JSON" \
            --metrics "$METRICS_JSON" \
            2>/dev/null && echo "  ✓ $RESOURCE_NAME ($RESOURCE_TYPE)" || echo "  ✗ $RESOURCE_NAME - Failed"
    elif [ -n "$LOG_CATS" ]; then
        az monitor diagnostic-settings create \
            --name "$DIAGNOSTIC_SETTING_NAME" \
            --resource "$RESOURCE_ID" \
            --event-hub "$EVENT_HUB_NAME" \
            --event-hub-rule "$EVENT_HUB_AUTH_RULE" \
            --logs "$LOGS_JSON" \
            2>/dev/null && echo "  ✓ $RESOURCE_NAME ($RESOURCE_TYPE)" || echo "  ✗ $RESOURCE_NAME - Failed"
    elif [ -n "$METRIC_CATS" ]; then
        az monitor diagnostic-settings create \
            --name "$DIAGNOSTIC_SETTING_NAME" \
            --resource "$RESOURCE_ID" \
            --event-hub "$EVENT_HUB_NAME" \
            --event-hub-rule "$EVENT_HUB_AUTH_RULE" \
            --metrics "$METRICS_JSON" \
            2>/dev/null && echo "  ✓ $RESOURCE_NAME ($RESOURCE_TYPE)" || echo "  ✗ $RESOURCE_NAME - Failed"
    fi
}

# Get all resources in the subscription
echo ""
echo "Discovering all resources..."
ALL_RESOURCES=$(az resource list --query "[].id" --output tsv)
TOTAL_COUNT=$(echo "$ALL_RESOURCES" | wc -l)
echo "Found $TOTAL_COUNT resources"

# Resource type to Event Hub mapping
declare -A EVENT_HUB_MAP=(
    ["Microsoft.KeyVault/vaults"]="eh-keyvault-logs"
    ["Microsoft.Storage/storageAccounts"]="eh-storage-logs"
    ["Microsoft.Compute/virtualMachines"]="eh-vm-logs"
    ["Microsoft.Network/networkSecurityGroups"]="eh-nsg-logs"
    ["Microsoft.Sql/servers"]="eh-activity-logs"
    ["Microsoft.Web/sites"]="eh-activity-logs"
    ["Microsoft.ContainerService/managedClusters"]="eh-activity-logs"
    ["Microsoft.EventHub/namespaces"]="eh-activity-logs"
    ["Microsoft.ServiceBus/namespaces"]="eh-activity-logs"
    ["Microsoft.Cdn/profiles"]="eh-activity-logs"
    ["Microsoft.Network/applicationGateways"]="eh-activity-logs"
    ["Microsoft.Network/loadBalancers"]="eh-activity-logs"
    ["Microsoft.Network/publicIPAddresses"]="eh-activity-logs"
    ["Microsoft.Network/virtualNetworks"]="eh-activity-logs"
    ["Microsoft.ContainerRegistry/registries"]="eh-activity-logs"
    ["Microsoft.DocumentDB/databaseAccounts"]="eh-activity-logs"
    ["Microsoft.Cache/Redis"]="eh-activity-logs"
    ["Microsoft.ApiManagement/service"]="eh-activity-logs"
    ["Microsoft.Logic/workflows"]="eh-activity-logs"
    ["Microsoft.DataFactory/factories"]="eh-activity-logs"
)

# Process each resource
echo ""
echo "Configuring diagnostic settings..."
CONFIGURED=0
SKIPPED=0

for RESOURCE_ID in $ALL_RESOURCES; do
    # Get resource type
    RESOURCE_TYPE=$(echo "$RESOURCE_ID" | grep -oP 'providers/\K[^/]+/[^/]+' | head -1)
    
    # Determine Event Hub based on resource type
    EVENT_HUB_NAME="${EVENT_HUB_MAP[$RESOURCE_TYPE]:-$DEFAULT_EVENT_HUB}"
    
    # Configure the resource
    configure_resource "$RESOURCE_ID" "$EVENT_HUB_NAME"
    
    ((CONFIGURED++)) || true
done

echo ""
echo "=========================================="
echo "Configuration Complete!"
echo "Processed: $CONFIGURED resources"
echo "=========================================="
```

**PowerShell - Universal Diagnostic Settings Script:**
```powershell
# Configure-AllResourcesDiagnostics.ps1
# This script configures diagnostic settings for ALL supported resource types
# Run this in Atevet17 tenant

param(
    [Parameter(Mandatory=$true)]
    [string]$Atevet12SubscriptionId,
    
    [string]$EventHubNamespace = "eh-namespace-central-atevet12",
    [string]$EventHubResourceGroup = "rg-eventhub-central",
    [string]$DiagnosticSettingName = "stream-to-atevet12-eventhub",
    [string]$DefaultEventHub = "eh-activity-logs"
)

# Event Hub Authorization Rule ID
$EventHubAuthRuleId = "/subscriptions/$Atevet12SubscriptionId/resourceGroups/$EventHubResourceGroup/providers/Microsoft.EventHub/namespaces/$EventHubNamespace/authorizationRules/atevet17-send-policy"

# Resource type to Event Hub mapping
$EventHubMap = @{
    "Microsoft.KeyVault/vaults" = "eh-keyvault-logs"
    "Microsoft.Storage/storageAccounts" = "eh-storage-logs"
    "Microsoft.Compute/virtualMachines" = "eh-vm-logs"
    "Microsoft.Network/networkSecurityGroups" = "eh-nsg-logs"
    "Microsoft.Sql/servers" = "eh-activity-logs"
    "Microsoft.Web/sites" = "eh-activity-logs"
    "Microsoft.ContainerService/managedClusters" = "eh-activity-logs"
    "Microsoft.EventHub/namespaces" = "eh-activity-logs"
    "Microsoft.ServiceBus/namespaces" = "eh-activity-logs"
    "Microsoft.Cdn/profiles" = "eh-activity-logs"
    "Microsoft.Network/applicationGateways" = "eh-activity-logs"
    "Microsoft.Network/loadBalancers" = "eh-activity-logs"
    "Microsoft.Network/publicIPAddresses" = "eh-activity-logs"
    "Microsoft.Network/virtualNetworks" = "eh-activity-logs"
    "Microsoft.ContainerRegistry/registries" = "eh-activity-logs"
    "Microsoft.DocumentDB/databaseAccounts" = "eh-activity-logs"
    "Microsoft.Cache/Redis" = "eh-activity-logs"
    "Microsoft.ApiManagement/service" = "eh-activity-logs"
    "Microsoft.Logic/workflows" = "eh-activity-logs"
    "Microsoft.DataFactory/factories" = "eh-activity-logs"
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Configuring Diagnostic Settings for ALL Resources" -ForegroundColor Cyan
Write-Host "Destination: Event Hub in Atevet12" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# Get all resources in the subscription
Write-Host "`nDiscovering all resources..." -ForegroundColor Yellow
$allResources = Get-AzResource
Write-Host "Found $($allResources.Count) resources" -ForegroundColor Green

$configured = 0
$skipped = 0
$failed = 0

foreach ($resource in $allResources) {
    $resourceId = $resource.ResourceId
    $resourceName = $resource.Name
    $resourceType = $resource.ResourceType
    
    # Determine Event Hub based on resource type
    $eventHubName = if ($EventHubMap.ContainsKey($resourceType)) {
        $EventHubMap[$resourceType]
    } else {
        $DefaultEventHub
    }
    
    try {
        # Get available diagnostic categories
        $categories = Get-AzDiagnosticSettingCategory -ResourceId $resourceId -ErrorAction SilentlyContinue
        
        if (-not $categories) {
            Write-Host "  ⚠ $resourceName ($resourceType) - No diagnostic categories available" -ForegroundColor Yellow
            $skipped++
            continue
        }
        
        # Separate log and metric categories
        $logCategories = $categories | Where-Object { $_.CategoryType -eq "Logs" }
        $metricCategories = $categories | Where-Object { $_.CategoryType -eq "Metrics" }
        
        # Build log settings
        $logSettings = @()
        foreach ($cat in $logCategories) {
            $logSettings += New-AzDiagnosticSettingLogSettingsObject -Category $cat.Name -Enabled $true
        }
        
        # Build metric settings
        $metricSettings = @()
        foreach ($cat in $metricCategories) {
            $metricSettings += New-AzDiagnosticSettingMetricSettingsObject -Category $cat.Name -Enabled $true
        }
        
        # Create diagnostic setting
        $params = @{
            Name = $DiagnosticSettingName
            ResourceId = $resourceId
            EventHubName = $eventHubName
            EventHubAuthorizationRuleId = $EventHubAuthRuleId
        }
        
        if ($logSettings.Count -gt 0) {
            $params.Log = $logSettings
        }
        
        if ($metricSettings.Count -gt 0) {
            $params.Metric = $metricSettings
        }
        
        New-AzDiagnosticSetting @params -ErrorAction Stop | Out-Null
        Write-Host "  ✓ $resourceName ($resourceType)" -ForegroundColor Green
        $configured++
    }
    catch {
        Write-Host "  ✗ $resourceName ($resourceType) - $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }
}

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Configuration Complete!" -ForegroundColor Cyan
Write-Host "Configured: $configured resources" -ForegroundColor Green
Write-Host "Skipped: $skipped resources (no diagnostic support)" -ForegroundColor Yellow
Write-Host "Failed: $failed resources" -ForegroundColor Red
Write-Host "==========================================" -ForegroundColor Cyan
```

### 4.6 Supported Resource Types Reference

The following Azure resource types support diagnostic settings:

| Resource Type | Log Categories | Metrics |
|---------------|----------------|---------|
| **Microsoft.KeyVault/vaults** | AuditEvent, AzurePolicyEvaluationDetails | AllMetrics |
| **Microsoft.Storage/storageAccounts** | StorageRead, StorageWrite, StorageDelete | Transaction |
| **Microsoft.Compute/virtualMachines** | (via Azure Monitor Agent) | AllMetrics |
| **Microsoft.Network/networkSecurityGroups** | NetworkSecurityGroupEvent, NetworkSecurityGroupRuleCounter | - |
| **Microsoft.Sql/servers/databases** | SQLInsights, AutomaticTuning, QueryStoreRuntimeStatistics | AllMetrics |
| **Microsoft.Web/sites** | AppServiceHTTPLogs, AppServiceConsoleLogs, AppServiceAppLogs | AllMetrics |
| **Microsoft.ContainerService/managedClusters** | kube-apiserver, kube-controller-manager, kube-scheduler | AllMetrics |
| **Microsoft.EventHub/namespaces** | ArchiveLogs, OperationalLogs, AutoScaleLogs | AllMetrics |
| **Microsoft.ServiceBus/namespaces** | OperationalLogs | AllMetrics |
| **Microsoft.Cdn/profiles/endpoints** | CoreAnalytics | AllMetrics |
| **Microsoft.Network/applicationGateways** | ApplicationGatewayAccessLog, ApplicationGatewayPerformanceLog | AllMetrics |
| **Microsoft.Network/loadBalancers** | LoadBalancerAlertEvent, LoadBalancerProbeHealthStatus | AllMetrics |
| **Microsoft.Network/publicIPAddresses** | DDoSProtectionNotifications, DDoSMitigationFlowLogs | AllMetrics |
| **Microsoft.Network/virtualNetworks** | VMProtectionAlerts | AllMetrics |
| **Microsoft.ContainerRegistry/registries** | ContainerRegistryRepositoryEvents, ContainerRegistryLoginEvents | AllMetrics |
| **Microsoft.DocumentDB/databaseAccounts** | DataPlaneRequests, MongoRequests, QueryRuntimeStatistics | AllMetrics |
| **Microsoft.Cache/Redis** | ConnectedClientList | AllMetrics |
| **Microsoft.ApiManagement/service** | GatewayLogs | AllMetrics |
| **Microsoft.Logic/workflows** | WorkflowRuntime | AllMetrics |
| **Microsoft.DataFactory/factories** | ActivityRuns, PipelineRuns, TriggerRuns | AllMetrics |
| **Microsoft.Batch/batchAccounts** | ServiceLog | AllMetrics |
| **Microsoft.CognitiveServices/accounts** | Audit, RequestResponse | AllMetrics |
| **Microsoft.Search/searchServices** | OperationLogs | AllMetrics |
| **Microsoft.SignalRService/SignalR** | AllLogs | AllMetrics |
| **Microsoft.StreamAnalytics/streamingjobs** | Execution, Authoring | AllMetrics |

### 4.7 Azure Policy for Automatic Configuration

Deploy an Azure Policy to automatically configure diagnostic settings for all new resources:

```json
{
    "mode": "All",
    "policyRule": {
        "if": {
            "field": "type",
            "in": [
                "Microsoft.KeyVault/vaults",
                "Microsoft.Storage/storageAccounts",
                "Microsoft.Sql/servers/databases",
                "Microsoft.Web/sites",
                "Microsoft.ContainerService/managedClusters",
                "Microsoft.Network/applicationGateways",
                "Microsoft.Network/loadBalancers",
                "Microsoft.DocumentDB/databaseAccounts",
                "Microsoft.Cache/Redis",
                "Microsoft.ApiManagement/service"
            ]
        },
        "then": {
            "effect": "deployIfNotExists",
            "details": {
                "type": "Microsoft.Insights/diagnosticSettings",
                "name": "stream-to-atevet12-eventhub",
                "existenceCondition": {
                    "allOf": [
                        {
                            "field": "Microsoft.Insights/diagnosticSettings/eventHubAuthorizationRuleId",
                            "equals": "[parameters('eventHubAuthorizationRuleId')]"
                        }
                    ]
                },
                "roleDefinitionIds": [
                    "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"
                ],
                "deployment": {
                    "properties": {
                        "mode": "incremental",
                        "template": {
                            "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
                            "contentVersion": "1.0.0.0",
                            "parameters": {
                                "resourceName": { "type": "string" },
                                "resourceId": { "type": "string" },
                                "eventHubAuthorizationRuleId": { "type": "string" },
                                "eventHubName": { "type": "string" }
                            },
                            "resources": [
                                {
                                    "type": "Microsoft.Insights/diagnosticSettings",
                                    "apiVersion": "2021-05-01-preview",
                                    "name": "stream-to-atevet12-eventhub",
                                    "scope": "[parameters('resourceId')]",
                                    "properties": {
                                        "eventHubAuthorizationRuleId": "[parameters('eventHubAuthorizationRuleId')]",
                                        "eventHubName": "[parameters('eventHubName')]",
                                        "logs": [
                                            {
                                                "categoryGroup": "allLogs",
                                                "enabled": true
                                            }
                                        ],
                                        "metrics": [
                                            {
                                                "category": "AllMetrics",
                                                "enabled": true
                                            }
                                        ]
                                    }
                                }
                            ]
                        },
                        "parameters": {
                            "resourceName": { "value": "[field('name')]" },
                            "resourceId": { "value": "[field('id')]" },
                            "eventHubAuthorizationRuleId": { "value": "[parameters('eventHubAuthorizationRuleId')]" },
                            "eventHubName": { "value": "[parameters('eventHubName')]" }
                        }
                    }
                }
            }
        }
    },
    "parameters": {
        "eventHubAuthorizationRuleId": {
            "type": "String",
            "metadata": {
                "displayName": "Event Hub Authorization Rule ID",
                "description": "The resource ID of the Event Hub authorization rule"
            }
        },
        "eventHubName": {
            "type": "String",
            "metadata": {
                "displayName": "Event Hub Name",
                "description": "The name of the Event Hub to send logs to"
            },
            "defaultValue": "eh-activity-logs"
        }
    }
}
```

**Deploy the Policy:**
```bash
# Create policy definition
az policy definition create \
    --name "configure-diagnostic-settings-eventhub" \
    --display-name "Configure diagnostic settings to stream to Event Hub" \
    --description "Automatically configure diagnostic settings for supported resources to stream to Event Hub" \
    --rules policy-rule.json \
    --params policy-params.json \
    --mode All

# Assign the policy to a subscription
az policy assignment create \
    --name "diag-settings-eventhub-assignment" \
    --policy "configure-diagnostic-settings-eventhub" \
    --scope "/subscriptions/<Atevet17-Subscription-ID>" \
    --params '{
        "eventHubAuthorizationRuleId": "/subscriptions/<Atevet12-Sub-ID>/resourceGroups/rg-eventhub-central/providers/Microsoft.EventHub/namespaces/eh-namespace-central-atevet12/authorizationRules/atevet17-send-policy",
        "eventHubName": "eh-activity-logs"
    }' \
    --assign-identity \
    --location "eastus"
```

### 4.8 Configure Azure AD Sign-in and Audit Logs

**IMPORTANT:** Azure AD logs require **Azure AD Premium P1 or P2** license.

**Azure Portal (in Atevet17):**
1. Navigate to **Azure Active Directory** → **Diagnostic settings**
2. Click **+ Add diagnostic setting**
3. Configure:
   - Diagnostic setting name: `stream-to-atevet12-eventhub`
   - **Log categories:**
     - ☑️ AuditLogs
     - ☑️ SignInLogs
     - ☑️ NonInteractiveUserSignInLogs
     - ☑️ ServicePrincipalSignInLogs
     - ☑️ ManagedIdentitySignInLogs
     - ☑️ ProvisioningLogs
     - ☑️ RiskyUsers
     - ☑️ UserRiskEvents
   - **Destination details:**
     - ☑️ Stream to an event hub
     - Event hub namespace: Enter the authorization rule ID
     - Event hub name: `eh-aad-logs`
     - Event hub policy name: `atevet17-send-policy`
4. Click **Save**

---

## Step 5: Set Up Log Analytics Ingestion

Now configure the destination in Atevet12 to receive and store the logs.

### 5.1 Create Log Analytics Workspace (if not exists)

**Azure CLI (in Atevet12):**
```bash
# Login to Atevet12 tenant
az login --tenant "<Atevet12-Tenant-ID>"
az account set --subscription "<Atevet12-Subscription-ID>"

# Create Log Analytics Workspace
az monitor log-analytics workspace create \
    --resource-group "rg-eventhub-central" \
    --workspace-name "law-central-atevet12" \
    --location "eastus" \
    --sku "PerGB2018" \
    --retention-time 90

# Get Workspace ID and Key
WORKSPACE_ID=$(az monitor log-analytics workspace show \
    --resource-group "rg-eventhub-central" \
    --workspace-name "law-central-atevet12" \
    --query "customerId" --output tsv)

WORKSPACE_KEY=$(az monitor log-analytics workspace get-shared-keys \
    --resource-group "rg-eventhub-central" \
    --workspace-name "law-central-atevet12" \
    --query "primarySharedKey" --output tsv)

echo "Workspace ID: $WORKSPACE_ID"
echo "Workspace Key: $WORKSPACE_KEY"
```

---

## Step 6: Configure Azure Function for Log Processing

The Azure Function acts as a bridge between Event Hub and Log Analytics, transforming and forwarding events.

### 6.1 Create Azure Function App

**Azure CLI:**
```bash
# Create Storage Account for Function App
az storage account create \
    --name "stfunceventhubproc" \
    --resource-group "rg-eventhub-central" \
    --location "eastus" \
    --sku "Standard_LRS"

# Create Function App (Consumption Plan)
az functionapp create \
    --name "func-eventhub-processor" \
    --resource-group "rg-eventhub-central" \
    --storage-account "stfunceventhubproc" \
    --consumption-plan-location "eastus" \
    --runtime "python" \
    --runtime-version "3.9" \
    --functions-version "4" \
    --os-type "Linux"

# Enable System-Assigned Managed Identity
az functionapp identity assign \
    --name "func-eventhub-processor" \
    --resource-group "rg-eventhub-central"
```

### 6.2 Configure Function App Settings

```bash
# Get Event Hub connection string (Listen)
EH_CONNECTION=$(az eventhubs namespace authorization-rule keys list \
    --name "RootManageSharedAccessKey" \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --query "primaryConnectionString" --output tsv)

# Get Log Analytics Workspace details
WORKSPACE_ID=$(az monitor log-analytics workspace show \
    --resource-group "rg-eventhub-central" \
    --workspace-name "law-central-atevet12" \
    --query "customerId" --output tsv)

WORKSPACE_KEY=$(az monitor log-analytics workspace get-shared-keys \
    --resource-group "rg-eventhub-central" \
    --workspace-name "law-central-atevet12" \
    --query "primarySharedKey" --output tsv)

# Configure app settings
az functionapp config appsettings set \
    --name "func-eventhub-processor" \
    --resource-group "rg-eventhub-central" \
    --settings \
        "EventHubConnection=$EH_CONNECTION" \
        "LOG_ANALYTICS_WORKSPACE_ID=$WORKSPACE_ID" \
        "LOG_ANALYTICS_WORKSPACE_KEY=$WORKSPACE_KEY" \
        "SOURCE_TENANT=Atevet17"
```

### 6.3 Create the Function Code

Create the following files for your Azure Function:

**`requirements.txt`:**
```
azure-functions
azure-eventhub
requests
```

**`host.json`:**
```json
{
    "version": "2.0",
    "logging": {
        "applicationInsights": {
            "samplingSettings": {
                "isEnabled": true,
                "excludedTypes": "Request"
            }
        }
    },
    "extensionBundle": {
        "id": "Microsoft.Azure.Functions.ExtensionBundle",
        "version": "[3.*, 4.0.0)"
    }
}
```

**`ActivityLogsProcessor/function.json`:**
```json
{
    "scriptFile": "__init__.py",
    "bindings": [
        {
            "type": "eventHubTrigger",
            "name": "events",
            "direction": "in",
            "eventHubName": "eh-activity-logs",
            "connection": "EventHubConnection",
            "consumerGroup": "cg-loganalytics",
            "cardinality": "many",
            "dataType": "string"
        }
    ]
}
```

**`ActivityLogsProcessor/__init__.py`:**
```python
import azure.functions as func
import logging
import json
import hashlib
import hmac
import base64
import requests
import datetime
import os
from typing import List

# Log Analytics Data Collector API
WORKSPACE_ID = os.environ.get('LOG_ANALYTICS_WORKSPACE_ID')
WORKSPACE_KEY = os.environ.get('LOG_ANALYTICS_WORKSPACE_KEY')
LOG_TYPE = 'Atevet17ActivityLogs'
SOURCE_TENANT = os.environ.get('SOURCE_TENANT', 'Atevet17')

def build_signature(workspace_id, workspace_key, date, content_length, method, content_type, resource):
    """Build the authorization signature for Log Analytics API"""
    x_headers = f'x-ms-date:{date}'
    string_to_hash = f'{method}\n{content_length}\n{content_type}\n{x_headers}\n{resource}'
    bytes_to_hash = bytes(string_to_hash, encoding='utf-8')
    decoded_key = base64.b64decode(workspace_key)
    encoded_hash = base64.b64encode(
        hmac.new(decoded_key, bytes_to_hash, digestmod=hashlib.sha256).digest()
    ).decode('utf-8')
    authorization = f'SharedKey {workspace_id}:{encoded_hash}'
    return authorization

def post_data(workspace_id, workspace_key, body, log_type):
    """Post data to Log Analytics workspace"""
    method = 'POST'
    content_type = 'application/json'
    resource = '/api/logs'
    rfc1123date = datetime.datetime.utcnow().strftime('%a, %d %b %Y %H:%M:%S GMT')
    content_length = len(body)
    signature = build_signature(workspace_id, workspace_key, rfc1123date,
                                content_length, method, content_type, resource)
    
    uri = f'https://{workspace_id}.ods.opinsights.azure.com{resource}?api-version=2016-04-01'
    
    headers = {
        'content-type': content_type,
        'Authorization': signature,
        'Log-Type': log_type,
        'x-ms-date': rfc1123date,
        'time-generated-field': 'TimeGenerated'
    }
    
    response = requests.post(uri, data=body, headers=headers)
    return response.status_code >= 200 and response.status_code <= 299

def transform_event(event_data):
    """Transform Event Hub event to Log Analytics format"""
    try:
        if isinstance(event_data, str):
            event = json.loads(event_data)
        else:
            event = event_data
        
        if 'records' in event:
            return [transform_single_record(record) for record in event['records']]
        else:
            return [transform_single_record(event)]
    except Exception as e:
        logging.error(f'Error transforming event: {e}')
        return []

def transform_single_record(record):
    """Transform a single record to Log Analytics format"""
    return {
        'TimeGenerated': record.get('time', datetime.datetime.utcnow().isoformat()),
        'SourceTenant': SOURCE_TENANT,
        'TenantId': record.get('tenantId', ''),
        'SubscriptionId': record.get('subscriptionId', ''),
        'ResourceGroup': record.get('resourceGroup', ''),
        'ResourceId': record.get('resourceId', ''),
        'OperationName': record.get('operationName', ''),
        'Status': str(record.get('status', '')),
        'Caller': record.get('caller', ''),
        'CallerIpAddress': record.get('callerIpAddress', ''),
        'Category': record.get('category', ''),
        'Level': record.get('level', ''),
        'Properties': json.dumps(record.get('properties', {})),
        'RawData': json.dumps(record)
    }

def main(events: List[str]):
    """Main function triggered by Event Hub"""
    logging.info(f'Processing {len(events)} events from Event Hub')
    
    all_records = []
    for event in events:
        transformed = transform_event(event)
        all_records.extend(transformed)
    
    if all_records:
        body = json.dumps(all_records)
        success = post_data(WORKSPACE_ID, WORKSPACE_KEY, body, LOG_TYPE)
        logging.info(f'Processed {len(all_records)} records, success: {success}')
```

### 6.4 Deploy the Function

```bash
# Navigate to your function app directory
cd func-eventhub-processor

# Deploy using Azure Functions Core Tools
func azure functionapp publish func-eventhub-processor --python

# Or using Azure CLI with zip deployment
zip -r function.zip .
az functionapp deployment source config-zip \
    --name "func-eventhub-processor" \
    --resource-group "rg-eventhub-central" \
    --src "function.zip"
```

---

## Step 7: Verify Real-Time Log Collection

### 7.1 Generate Test Events in Atevet17

```bash
# Login to Atevet17
az login --tenant "<Atevet17-Tenant-ID>"

# Create a test resource group (generates Activity Log)
az group create --name "test-logging-rg" --location "eastus"

# Delete the test resource group
az group delete --name "test-logging-rg" --yes --no-wait
```

### 7.2 Monitor Event Hub Metrics

**Azure Portal (in Atevet12):**
1. Navigate to Event Hub Namespace → **Metrics**
2. Add metrics:
   - Incoming Messages
   - Outgoing Messages
   - Incoming Bytes
3. Set time range to last 30 minutes
4. You should see incoming messages within seconds of generating events

### 7.3 Query Logs in Log Analytics

**KQL Queries:**
```kusto
// Check for Activity Logs from Atevet17
Atevet17ActivityLogs_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, OperationName, Status, Caller, ResourceId
| order by TimeGenerated desc
| take 100

// Count events by operation
Atevet17ActivityLogs_CL
| where TimeGenerated > ago(24h)
| summarize Count = count() by OperationName
| order by Count desc
```

---

## Advanced Configuration

### 8.1 Enable Capture for Long-term Storage

Event Hub Capture automatically saves events to Azure Storage:

```bash
# Enable Capture on Event Hub
az eventhubs eventhub update \
    --name "eh-activity-logs" \
    --namespace-name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --enable-capture true \
    --capture-interval 300 \
    --capture-size-limit 314572800 \
    --destination-name "EventHubArchive.AzureBlockBlob" \
    --storage-account "/subscriptions/<Sub-ID>/resourceGroups/rg-eventhub-central/providers/Microsoft.Storage/storageAccounts/<storage-account>" \
    --blob-container "eventhub-capture"
```

### 8.2 Configure Private Endpoints

For enhanced security, use Private Endpoints:

```bash
# Create Private Endpoint for Event Hub
az network private-endpoint create \
    --name "pe-eventhub-central" \
    --resource-group "rg-eventhub-central" \
    --vnet-name "vnet-central" \
    --subnet "subnet-private-endpoints" \
    --private-connection-resource-id "/subscriptions/<Sub-ID>/resourceGroups/rg-eventhub-central/providers/Microsoft.EventHub/namespaces/eh-namespace-central-atevet12" \
    --group-id "namespace" \
    --connection-name "eventhub-connection"
```

---

## Troubleshooting

### Common Issues and Solutions

| Issue | Symptoms | Solution |
|-------|----------|----------|
| **Events not arriving** | No incoming messages in Event Hub | Verify diagnostic settings, check authorization rule ID |
| **Function not processing** | Events in Event Hub but not in Log Analytics | Check Function logs, verify connection strings |
| **High latency** | Events delayed | Increase throughput units, check Function scaling |
| **Missing events** | Some events not appearing | Check Event Hub retention, verify consumer group |
| **Permission denied** | Authorization errors | Verify SAS policy has correct permissions |

### Diagnostic Commands

```bash
# Check Event Hub health
az eventhubs namespace show \
    --name "eh-namespace-central-atevet12" \
    --resource-group "rg-eventhub-central" \
    --query "{Status:status, ProvisioningState:provisioningState}"

# List diagnostic settings
az monitor diagnostic-settings list \
    --resource "<Resource-ID>" \
    --query "[].{Name:name, EventHub:eventHubName}"

# Check Function App status
az functionapp show \
    --name "func-eventhub-processor" \
    --resource-group "rg-eventhub-central" \
    --query "{State:state, DefaultHostName:defaultHostName}"
```

---

## Security Considerations

### 1. Principle of Least Privilege

- Use **Send-only** SAS policies for source tenant
- Use **Listen-only** SAS policies for consumers
- Rotate SAS keys regularly (every 90 days)

### 2. Network Security

- Enable Private Endpoints for production
- Configure NSG rules to restrict access
- Use Service Endpoints as minimum

### 3. Key Rotation Schedule

| Component | Rotation Frequency | Method |
|-----------|-------------------|--------|
| SAS Keys | Every 90 days | Regenerate secondary, update configs, regenerate primary |
| Log Analytics Key | Every 90 days | Regenerate and update Function App settings |

---

## Cost Estimation

### Event Hub Costs

| Component | Unit | Price (East US) |
|-----------|------|-----------------|
| Namespace (Standard) | Per hour | ~$0.03 |
| Throughput Unit | Per hour | ~$0.03 |
| Ingress Events | Per million | $0.028 |
| Capture | Per hour | $0.10 |

### Function App Costs (Consumption)

| Component | Unit | Price |
|-----------|------|-------|
| Executions | Per million | $0.20 |
| Execution Time | Per GB-s | $0.000016 |

### Log Analytics Costs

| Component | Unit | Price |
|-----------|------|-------|
| Data Ingestion | Per GB | $2.76 |
| Data Retention | Per GB/month (>31 days) | $0.12 |

### Estimated Monthly Total

| Log Volume | Event Hub | Function | Log Analytics | Total |
|------------|-----------|----------|---------------|-------|
| 10 GB/month | ~$25 | ~$5 | ~$28 | ~$58 |
| 50 GB/month | ~$30 | ~$15 | ~$138 | ~$183 |
| 100 GB/month | ~$40 | ~$25 | ~$276 | ~$341 |
| 500 GB/month | ~$80 | ~$75 | ~$1,380 | ~$1,535 |

---

## Summary

You have now configured real-time cross-tenant log collection from **Atevet17** to **Atevet12** using Azure Event Hubs. Here's what was accomplished:

### Completed Steps

1. ✅ Created Event Hub Namespace in Atevet12
2. ✅ Created separate Event Hubs for different log types
3. ✅ Configured Shared Access Policies with least privilege
4. ✅ Configured Diagnostic Settings in Atevet17 to stream to Event Hub
5. ✅ Set up Log Analytics Workspace for log storage
6. ✅ Deployed Azure Function for event processing
7. ✅ Verified real-time log collection

### Key Benefits Achieved

- **Real-time streaming** with sub-second latency
- **No Lighthouse delegation required** - works with connection strings
- **Multiple consumer support** - can fan out to SIEM, storage, etc.
- **Event replay capability** - configurable retention for reprocessing
- **Full schema control** - transform logs as needed

### Next Steps

1. Set up alerts for critical events
2. Create dashboards for monitoring
3. Configure additional resource types
4. Implement key rotation automation
5. Consider Microsoft Sentinel for advanced security analytics

---

## Quick Reference

### Important Resource IDs

```
Event Hub Namespace:
/subscriptions/<Atevet12-Sub-ID>/resourceGroups/rg-eventhub-central/providers/Microsoft.EventHub/namespaces/eh-namespace-central-atevet12

Authorization Rule:
/subscriptions/<Atevet12-Sub-ID>/resourceGroups/rg-eventhub-central/providers/Microsoft.EventHub/namespaces/eh-namespace-central-atevet12/authorizationRules/atevet17-send-policy

Log Analytics Workspace:
/subscriptions/<Atevet12-Sub-ID>/resourceGroups/rg-eventhub-central/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12
```

### Useful Commands

```bash
# Check Event Hub metrics
az monitor metrics list --resource "<Event-Hub-Namespace-ID>" --metric "IncomingMessages"

# View Function logs
az functionapp log tail --name "func-eventhub-processor" --resource-group "rg-eventhub-central"

# List diagnostic settings
az monitor diagnostic-settings list --resource "<Resource-ID>"
```

---

## Additional Resources

- [Azure Event Hubs Documentation](https://docs.microsoft.com/azure/event-hubs/)
- [Azure Monitor Diagnostic Settings](https://docs.microsoft.com/azure/azure-monitor/essentials/diagnostic-settings)
- [Log Analytics Data Collector API](https://docs.microsoft.com/azure/azure-monitor/logs/data-collector-api)
- [Azure Functions Event Hub Trigger](https://docs.microsoft.com/azure/azure-functions/functions-bindings-event-hubs-trigger)