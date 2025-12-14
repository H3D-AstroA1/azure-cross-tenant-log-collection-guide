# Azure Cross-Tenant Log Collection Guide
## Collecting Logs from Atevet17 to Atevet12 using Azure Lighthouse

---

## Table of Contents
1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Step 1: Prepare the Managing Tenant (Atevet12)](#step-1-prepare-the-managing-tenant-atevet12)
5. [Step 2: Onboard Customer Tenant (Atevet17) to Azure Lighthouse](#step-2-onboard-customer-tenant-atevet17-to-azure-lighthouse)
6. [Step 3: Configure Activity Log Collection](#step-3-configure-activity-log-collection)
7. [Step 4: Configure Resource Diagnostic Logs](#step-4-configure-resource-diagnostic-logs)
8. [Step 5: Centralize Logs in Log Analytics Workspace](#step-5-centralize-logs-in-log-analytics-workspace)
9. [Step 6: Verify Log Collection](#step-6-verify-log-collection)
10. [Alternative Approaches](#alternative-approaches)
11. [Troubleshooting](#troubleshooting)

---

## Overview

**Scenario:** You want to collect all raw logs from Azure tenant **Atevet17** (source/customer tenant) and centralize them in tenant **Atevet12** (managing/destination tenant).

**Logs to Collect:**
- Subscription Activity Logs (control plane operations)
- Resource Diagnostic Logs:
  - Virtual Machines
  - Key Vaults
  - Storage Accounts
  - Other Azure resources

**Recommended Solution:** Azure Lighthouse is the best approach for this scenario because:
- ✅ Native Azure solution for cross-tenant management
- ✅ No need for guest accounts or B2B collaboration
- ✅ Granular RBAC-based access control
- ✅ Supports delegated resource management
- ✅ Audit trail maintained in both tenants
- ✅ Scalable to multiple subscriptions

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ATEVET12 (Managing Tenant)                        │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Log Analytics Workspace                           │   │
│  │                    (Centralized Log Storage)                         │   │
│  │                                                                       │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │   │
│  │  │Activity Logs │  │ VM Logs      │  │ KeyVault Logs│  ...          │   │
│  │  └──────────────┘  └──────────────┘  └──────────────┘               │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    ▲                                        │
│                                    │                                        │
│  ┌─────────────────────────────────┴───────────────────────────────────┐   │
│  │              Security Group / Users with Delegated Access            │   │
│  │              (e.g., "Lighthouse-Atevet17-Admins")                    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                     │
                                     │ Azure Lighthouse
                                     │ Delegated Access
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ATEVET17 (Customer Tenant)                        │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         Subscriptions                                │   │
│  │                                                                       │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │   │
│  │  │ Subscription │  │ Subscription │  │ Subscription │               │   │
│  │  │      A       │  │      B       │  │      C       │               │   │
│  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘               │   │
│  │         │                 │                 │                        │   │
│  │         ▼                 ▼                 ▼                        │   │
│  │  ┌──────────────────────────────────────────────────────────────┐   │   │
│  │  │                    Azure Resources                            │   │   │
│  │  │  VMs | Key Vaults | Storage Accounts | NSGs | App Services   │   │   │
│  │  └──────────────────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

### In Atevet12 (Managing Tenant)

| Requirement | Description |
|-------------|-------------|
| **Azure AD Security Group** | Create a security group for users who will manage Atevet17 resources |
| **Log Analytics Workspace** | Create or identify existing workspace to receive logs |
| **User/Service Principal** | Users or service principals that need delegated access |
| **Permissions** | Global Administrator or Privileged Role Administrator to create the security group |

### In Atevet17 (Customer Tenant)

| Requirement | Description |
|-------------|-------------|
| **Owner Access** | Owner role on subscriptions to be delegated |
| **Azure AD Permissions** | Ability to accept Lighthouse delegation |
| **Resource Provider** | `Microsoft.ManagedServices` resource provider registered |

---

## Step 1: Prepare the Managing Tenant (Atevet12)

### 1.1 Create a Security Group for Delegated Access

```powershell
# Connect to Azure AD in Atevet12
Connect-AzureAD -TenantId "<Atevet12-Tenant-ID>"

# Create a security group
$group = New-AzureADGroup -DisplayName "Lighthouse-Atevet17-Admins" `
    -Description "Users with delegated access to Atevet17 tenant" `
    -MailEnabled $false `
    -SecurityEnabled $true `
    -MailNickName "lighthouse-atevet17-admins"

# Note the Object ID - you'll need this later
Write-Host "Security Group Object ID: $($group.ObjectId)"
```

**Or via Azure Portal:**
1. Go to **Azure Active Directory** → **Groups** → **New group**
2. Group type: **Security**
3. Group name: `Lighthouse-Atevet17-Admins`
4. Group description: `Users with delegated access to Atevet17 tenant`
5. Click **Create**
6. Note the **Object ID** of the created group

### 1.2 Create a Log Analytics Workspace

```powershell
# Connect to Azure
Connect-AzAccount -TenantId "<Atevet12-Tenant-ID>"

# Create Resource Group (if needed)
New-AzResourceGroup -Name "rg-central-logging" -Location "eastus"

# Create Log Analytics Workspace
$workspace = New-AzOperationalInsightsWorkspace `
    -ResourceGroupName "rg-central-logging" `
    -Name "law-central-atevet12" `
    -Location "eastus" `
    -Sku "PerGB2018"

# Get Workspace ID and Key
$workspaceId = $workspace.CustomerId
$workspaceKey = (Get-AzOperationalInsightsWorkspaceSharedKey `
    -ResourceGroupName "rg-central-logging" `
    -Name "law-central-atevet12").PrimarySharedKey

Write-Host "Workspace ID: $workspaceId"
Write-Host "Workspace Resource ID: $($workspace.ResourceId)"
```

**Or via Azure Portal:**
1. Go to **Log Analytics workspaces** → **Create**
2. Subscription: Select your subscription in Atevet12
3. Resource group: `rg-central-logging` (create new if needed)
4. Name: `law-central-atevet12`
5. Region: Choose your preferred region
6. Click **Review + Create** → **Create**

### 1.3 Get Required IDs

You'll need these IDs for the Lighthouse template:

```powershell
# Get Tenant ID
$tenantId = (Get-AzContext).Tenant.Id
Write-Host "Atevet12 Tenant ID: $tenantId"

# Get Security Group Object ID
$groupId = (Get-AzADGroup -DisplayName "Lighthouse-Atevet17-Admins").Id
Write-Host "Security Group ID: $groupId"

# Get Log Analytics Workspace Resource ID
$workspaceResourceId = (Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName "rg-central-logging" `
    -Name "law-central-atevet12").ResourceId
Write-Host "Workspace Resource ID: $workspaceResourceId"
```

---

## Step 2: Onboard Customer Tenant (Atevet17) to Azure Lighthouse

### 2.1 Create the Azure Lighthouse ARM Template

Create a file named `lighthouse-delegation.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-08-01/subscriptionDeploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "mspOfferName": {
            "type": "string",
            "defaultValue": "Atevet12 Log Collection Delegation"
        },
        "mspOfferDescription": {
            "type": "string",
            "defaultValue": "Delegation for centralized log collection from Atevet17 to Atevet12"
        },
        "managedByTenantId": {
            "type": "string",
            "metadata": {
                "description": "The Tenant ID of the managing tenant (Atevet12)"
            }
        },
        "authorizations": {
            "type": "array",
            "metadata": {
                "description": "Array of authorization objects"
            }
        }
    },
    "variables": {
        "mspRegistrationName": "[guid(parameters('mspOfferName'))]",
        "mspAssignmentName": "[guid(parameters('mspOfferName'))]"
    },
    "resources": [
        {
            "type": "Microsoft.ManagedServices/registrationDefinitions",
            "apiVersion": "2022-10-01",
            "name": "[variables('mspRegistrationName')]",
            "properties": {
                "registrationDefinitionName": "[parameters('mspOfferName')]",
                "description": "[parameters('mspOfferDescription')]",
                "managedByTenantId": "[parameters('managedByTenantId')]",
                "authorizations": "[parameters('authorizations')]"
            }
        },
        {
            "type": "Microsoft.ManagedServices/registrationAssignments",
            "apiVersion": "2022-10-01",
            "name": "[variables('mspAssignmentName')]",
            "dependsOn": [
                "[resourceId('Microsoft.ManagedServices/registrationDefinitions', variables('mspRegistrationName'))]"
            ],
            "properties": {
                "registrationDefinitionId": "[resourceId('Microsoft.ManagedServices/registrationDefinitions', variables('mspRegistrationName'))]"
            }
        }
    ],
    "outputs": {
        "mspOfferName": {
            "type": "string",
            "value": "[parameters('mspOfferName')]"
        },
        "registrationDefinitionId": {
            "type": "string",
            "value": "[resourceId('Microsoft.ManagedServices/registrationDefinitions', variables('mspRegistrationName'))]"
        }
    }
}
```

### 2.2 Create the Parameters File

Create a file named `lighthouse-delegation.parameters.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "mspOfferName": {
            "value": "Atevet12 Log Collection Delegation"
        },
        "mspOfferDescription": {
            "value": "Delegation for centralized log collection from Atevet17 to Atevet12"
        },
        "managedByTenantId": {
            "value": "<ATEVET12-TENANT-ID>"
        },
        "authorizations": {
            "value": [
                {
                    "principalId": "<SECURITY-GROUP-OBJECT-ID>",
                    "principalIdDisplayName": "Lighthouse-Atevet17-Admins",
                    "roleDefinitionId": "b24988ac-6180-42a0-ab88-20f7382dd24c"
                },
                {
                    "principalId": "<SECURITY-GROUP-OBJECT-ID>",
                    "principalIdDisplayName": "Lighthouse-Atevet17-Admins",
                    "roleDefinitionId": "92aaf0da-9dab-42b6-94a3-d43ce8d16293"
                },
                {
                    "principalId": "<SECURITY-GROUP-OBJECT-ID>",
                    "principalIdDisplayName": "Lighthouse-Atevet17-Admins",
                    "roleDefinitionId": "749f88d5-cbae-40b8-bcfc-e573ddc772fa"
                }
            ]
        }
    }
}
```

**Role Definitions Explained:**

| Role | Role Definition ID | Purpose |
|------|-------------------|---------|
| **Contributor** | `b24988ac-6180-42a0-ab88-20f7382dd24c` | Manage resources and configure diagnostic settings |
| **Log Analytics Contributor** | `92aaf0da-9dab-42b6-94a3-d43ce8d16293` | Configure log collection and manage Log Analytics |
| **Monitoring Contributor** | `749f88d5-cbae-40b8-bcfc-e573ddc772fa` | Configure monitoring and diagnostic settings |

**Replace the placeholders:**
- `<ATEVET12-TENANT-ID>`: Your Atevet12 tenant ID
- `<SECURITY-GROUP-OBJECT-ID>`: The Object ID of the security group created in Step 1.1

### 2.3 Deploy the Lighthouse Template in Atevet17

**Option A: Using Azure CLI (Recommended)**

```bash
# Login to Atevet17 tenant
az login --tenant "<Atevet17-Tenant-ID>"

# Set the subscription you want to delegate
az account set --subscription "<Atevet17-Subscription-ID>"

# Deploy the template at subscription level
az deployment sub create \
    --name "LighthouseDeployment" \
    --location "eastus" \
    --template-file "lighthouse-delegation.json" \
    --parameters "lighthouse-delegation.parameters.json"
```

**Option B: Using PowerShell**

```powershell
# Login to Atevet17 tenant
Connect-AzAccount -TenantId "<Atevet17-Tenant-ID>"

# Set the subscription context
Set-AzContext -SubscriptionId "<Atevet17-Subscription-ID>"

# Deploy the template
New-AzSubscriptionDeployment `
    -Name "LighthouseDeployment" `
    -Location "eastus" `
    -TemplateFile "lighthouse-delegation.json" `
    -TemplateParameterFile "lighthouse-delegation.parameters.json"
```

**Option C: Using Azure Portal**

1. In Atevet17 tenant, go to **Subscriptions** → Select the subscription
2. Go to **Service providers** → **Service provider offers**
3. Click **Add offer** → **Add via template**
4. Upload the `lighthouse-delegation.json` template
5. Fill in the parameters
6. Click **Review + Create** → **Create**

### 2.4 Repeat for Each Subscription

If you have multiple subscriptions in Atevet17, repeat Step 2.3 for each subscription you want to delegate.

### 2.5 Verify Delegation

**In Atevet12 (Managing Tenant):**

```powershell
# Login to Atevet12
Connect-AzAccount -TenantId "<Atevet12-Tenant-ID>"

# List all delegated subscriptions
Get-AzManagedServicesAssignment | Format-Table
```

**In Azure Portal (Atevet12):**
1. Go to **My customers** (search in the portal)
2. You should see Atevet17 subscriptions listed under **Customers**

---

## Step 3: Configure Activity Log Collection

Activity Logs capture control plane operations (who did what, when, and on which resources).

### 3.1 Create Diagnostic Setting for Activity Logs

**For each delegated subscription in Atevet17:**

```powershell
# Login to Atevet12 (managing tenant)
Connect-AzAccount -TenantId "<Atevet12-Tenant-ID>"

# Get the delegated subscription from Atevet17
$subscriptionId = "<Atevet17-Subscription-ID>"

# Set context to the delegated subscription
Set-AzContext -SubscriptionId $subscriptionId

# Get the Log Analytics Workspace in Atevet12
$workspaceResourceId = "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

# Create diagnostic setting for Activity Log
$params = @{
    Name = "SendActivityLogsToAtevet12"
    SubscriptionId = $subscriptionId
    WorkspaceId = $workspaceResourceId
    Category = @(
        "Administrative",
        "Security",
        "ServiceHealth",
        "Alert",
        "Recommendation",
        "Policy",
        "Autoscale",
        "ResourceHealth"
    )
}

# Using Azure CLI (more reliable for cross-tenant)
az monitor diagnostic-settings subscription create `
    --name "SendActivityLogsToAtevet12" `
    --subscription $subscriptionId `
    --workspace $workspaceResourceId `
    --logs '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"ServiceHealth","enabled":true},{"category":"Alert","enabled":true},{"category":"Recommendation","enabled":true},{"category":"Policy","enabled":true},{"category":"Autoscale","enabled":true},{"category":"ResourceHealth","enabled":true}]'
```

**Or via Azure Portal:**

1. In Atevet12, go to **My customers** → Select the Atevet17 subscription
2. Go to **Activity log** → **Diagnostic settings**
3. Click **Add diagnostic setting**
4. Name: `SendActivityLogsToAtevet12`
5. Select all log categories:
   - ☑️ Administrative
   - ☑️ Security
   - ☑️ ServiceHealth
   - ☑️ Alert
   - ☑️ Recommendation
   - ☑️ Policy
   - ☑️ Autoscale
   - ☑️ ResourceHealth
6. Destination: **Send to Log Analytics workspace**
7. Subscription: Select Atevet12 subscription
8. Log Analytics workspace: `law-central-atevet12`
9. Click **Save**

---

## Step 4: Configure Resource Diagnostic Logs

### 4.1 Virtual Machines

For VMs, you need to install the Azure Monitor Agent and configure Data Collection Rules.

#### 4.1.1 Create a Data Collection Rule

```powershell
# In Atevet12 tenant
Connect-AzAccount -TenantId "<Atevet12-Tenant-ID>"

# Create Data Collection Rule
$dcrParams = @{
    Name = "dcr-vm-logs-atevet17"
    ResourceGroupName = "rg-central-logging"
    Location = "eastus"
    DataFlow = @(
        @{
            Streams = @("Microsoft-Perf", "Microsoft-Event", "Microsoft-Syslog")
            Destinations = @("law-central-atevet12")
        }
    )
    DataSourcePerformanceCounter = @(
        @{
            Name = "perfCounterDataSource"
            Streams = @("Microsoft-Perf")
            SamplingFrequencyInSeconds = 60
            CounterSpecifiers = @(
                "\Processor(_Total)\% Processor Time",
                "\Memory\Available MBytes",
                "\LogicalDisk(_Total)\% Free Space"
            )
        }
    )
    DataSourceWindowsEventLog = @(
        @{
            Name = "windowsEventLogs"
            Streams = @("Microsoft-Event")
            XPathQueries = @(
                "Application!*[System[(Level=1 or Level=2 or Level=3)]]",
                "Security!*[System[(band(Keywords,13510798882111488))]]",
                "System!*[System[(Level=1 or Level=2 or Level=3)]]"
            )
        }
    )
    DestinationLogAnalytic = @(
        @{
            Name = "law-central-atevet12"
            WorkspaceResourceId = "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
        }
    )
}

New-AzDataCollectionRule @dcrParams
```

#### 4.1.2 Install Azure Monitor Agent on VMs

**For Windows VMs:**

```powershell
# Set context to delegated Atevet17 subscription
Set-AzContext -SubscriptionId "<Atevet17-Subscription-ID>"

# Get all Windows VMs
$vms = Get-AzVM | Where-Object { $_.StorageProfile.OsDisk.OsType -eq "Windows" }

foreach ($vm in $vms) {
    # Install Azure Monitor Agent
    Set-AzVMExtension `
        -ResourceGroupName $vm.ResourceGroupName `
        -VMName $vm.Name `
        -Name "AzureMonitorWindowsAgent" `
        -Publisher "Microsoft.Azure.Monitor" `
        -ExtensionType "AzureMonitorWindowsAgent" `
        -TypeHandlerVersion "1.0" `
        -Location $vm.Location `
        -EnableAutomaticUpgrade $true
}
```

**For Linux VMs:**

```powershell
# Get all Linux VMs
$vms = Get-AzVM | Where-Object { $_.StorageProfile.OsDisk.OsType -eq "Linux" }

foreach ($vm in $vms) {
    # Install Azure Monitor Agent
    Set-AzVMExtension `
        -ResourceGroupName $vm.ResourceGroupName `
        -VMName $vm.Name `
        -Name "AzureMonitorLinuxAgent" `
        -Publisher "Microsoft.Azure.Monitor" `
        -ExtensionType "AzureMonitorLinuxAgent" `
        -TypeHandlerVersion "1.0" `
        -Location $vm.Location `
        -EnableAutomaticUpgrade $true
}
```

#### 4.1.3 Associate VMs with Data Collection Rule

```powershell
# Get the DCR resource ID
$dcrId = "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.Insights/dataCollectionRules/dcr-vm-logs-atevet17"

# Associate each VM with the DCR
foreach ($vm in $vms) {
    New-AzDataCollectionRuleAssociation `
        -TargetResourceId $vm.Id `
        -AssociationName "dcr-association-$($vm.Name)" `
        -RuleId $dcrId
}
```

### 4.2 Key Vaults

```powershell
# Set context to delegated Atevet17 subscription
Set-AzContext -SubscriptionId "<Atevet17-Subscription-ID>"

# Get all Key Vaults
$keyVaults = Get-AzKeyVault

# Log Analytics Workspace in Atevet12
$workspaceResourceId = "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

foreach ($kv in $keyVaults) {
    $kvResourceId = (Get-AzKeyVault -VaultName $kv.VaultName).ResourceId
    
    # Create diagnostic setting
    $log = @(
        @{
            Category = "AuditEvent"
            Enabled = $true
        },
        @{
            Category = "AzurePolicyEvaluationDetails"
            Enabled = $true
        }
    )
    
    $metric = @(
        @{
            Category = "AllMetrics"
            Enabled = $true
        }
    )
    
    Set-AzDiagnosticSetting `
        -ResourceId $kvResourceId `
        -Name "SendToAtevet12" `
        -WorkspaceId $workspaceResourceId `
        -Log $log `
        -Metric $metric
}
```

### 4.3 Storage Accounts

```powershell
# Get all Storage Accounts
$storageAccounts = Get-AzStorageAccount

foreach ($sa in $storageAccounts) {
    # Enable diagnostic settings for blob, queue, table, and file services
    $services = @("blob", "queue", "table", "file")
    
    foreach ($service in $services) {
        $resourceId = "$($sa.Id)/${service}Services/default"
        
        $log = @(
            @{
                Category = "StorageRead"
                Enabled = $true
            },
            @{
                Category = "StorageWrite"
                Enabled = $true
            },
            @{
                Category = "StorageDelete"
                Enabled = $true
            }
        )
        
        $metric = @(
            @{
                Category = "Transaction"
                Enabled = $true
            }
        )
        
        try {
            Set-AzDiagnosticSetting `
                -ResourceId $resourceId `
                -Name "SendToAtevet12" `
                -WorkspaceId $workspaceResourceId `
                -Log $log `
                -Metric $metric
        } catch {
            Write-Warning "Could not configure $service for $($sa.StorageAccountName): $_"
        }
    }
}
```

### 4.4 Azure Policy for Automatic Diagnostic Settings

To automatically configure diagnostic settings for new resources, deploy an Azure Policy:

```json
{
    "mode": "Indexed",
    "policyRule": {
        "if": {
            "field": "type",
            "equals": "Microsoft.KeyVault/vaults"
        },
        "then": {
            "effect": "deployIfNotExists",
            "details": {
                "type": "Microsoft.Insights/diagnosticSettings",
                "name": "SendToAtevet12",
                "existenceCondition": {
                    "field": "Microsoft.Insights/diagnosticSettings/workspaceId",
                    "equals": "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
                },
                "roleDefinitionIds": [
                    "/providers/Microsoft.Authorization/roleDefinitions/749f88d5-cbae-40b8-bcfc-e573ddc772fa"
                ],
                "deployment": {
                    "properties": {
                        "mode": "incremental",
                        "template": {
                            "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
                            "contentVersion": "1.0.0.0",
                            "parameters": {
                                "resourceName": {
                                    "type": "string"
                                },
                                "workspaceId": {
                                    "type": "string"
                                }
                            },
                            "resources": [
                                {
                                    "type": "Microsoft.KeyVault/vaults/providers/diagnosticSettings",
                                    "apiVersion": "2021-05-01-preview",
                                    "name": "[concat(parameters('resourceName'), '/Microsoft.Insights/SendToAtevet12')]",
                                    "properties": {
                                        "workspaceId": "[parameters('workspaceId')]",
                                        "logs": [
                                            {
                                                "category": "AuditEvent",
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
                            "resourceName": {
                                "value": "[field('name')]"
                            },
                            "workspaceId": {
                                "value": "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
                            }
                        }
                    }
                }
            }
        }
    }
}
```

---

## Step 5: Centralize Logs in Log Analytics Workspace

### 5.1 Verify Log Tables

After configuration, the following tables should be populated in your Log Analytics workspace:

| Table Name | Description |
|------------|-------------|
| `AzureActivity` | Subscription activity logs |
| `AzureDiagnostics` | Resource diagnostic logs |
| `AzureMetrics` | Resource metrics |
| `Event` | Windows Event Logs (from VMs) |
| `Syslog` | Linux Syslog (from VMs) |
| `Perf` | Performance counters (from VMs) |
| `AzureKeyVaultAuditLogs` | Key Vault audit events |
| `StorageBlobLogs` | Storage blob operations |

### 5.2 Sample Queries

**Query Activity Logs from Atevet17:**

```kusto
AzureActivity
| where SubscriptionId == "<Atevet17-Subscription-ID>"
| where TimeGenerated > ago(24h)
| summarize count() by OperationNameValue, ActivityStatusValue
| order by count_ desc
```

**Query Key Vault Operations:**

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where TimeGenerated > ago(24h)
| project TimeGenerated, OperationName, ResultType, CallerIPAddress, identity_claim_upn_s
| order by TimeGenerated desc
```

**Query VM Performance:**

```kusto
Perf
| where TimeGenerated > ago(1h)
| where ObjectName == "Processor" and CounterName == "% Processor Time"
| summarize avg(CounterValue) by Computer, bin(TimeGenerated, 5m)
| render timechart
```

---

## Step 6: Verify Log Collection

### 6.1 Check Diagnostic Settings

```powershell
# List all diagnostic settings for a subscription
Get-AzDiagnosticSetting -SubscriptionId "<Atevet17-Subscription-ID>"

# List diagnostic settings for a specific resource
Get-AzDiagnosticSetting -ResourceId "<Resource-ID>"
```

### 6.2 Verify Data in Log Analytics

```powershell
# Query Log Analytics
$query = "AzureActivity | where TimeGenerated > ago(1h) | count"

$workspace = Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName "rg-central-logging" `
    -Name "law-central-atevet12"

$result = Invoke-AzOperationalInsightsQuery `
    -WorkspaceId $workspace.CustomerId `
    -Query $query

$result.Results
```

### 6.3 Monitor Data Ingestion

In Azure Portal:
1. Go to **Log Analytics workspace** → `law-central-atevet12`
2. Go to **Usage and estimated costs**
3. Check **Data ingestion** to see volume trends
4. Go to **Logs** and run: `Usage | where TimeGenerated > ago(24h) | summarize sum(Quantity) by DataType`

---

## Alternative Approaches

### Option 1: Azure Event Hubs (For Real-time Streaming)

**When to use:** If you need real-time log streaming or want to integrate with third-party SIEM solutions.

```
Atevet17 Resources → Diagnostic Settings → Event Hub →
    → Azure Function/Stream Analytics → Log Analytics (Atevet12)
    → Third-party SIEM (Splunk, etc.)
```

**Pros:**
- Real-time streaming
- Can fan out to multiple destinations
- Better for high-volume scenarios

**Cons:**
- More complex architecture
- Additional costs for Event Hubs
- Requires custom processing logic

### Option 2: Azure Monitor Private Link Scope (AMPLS)

**When to use:** If you need private connectivity between tenants.

**Note:** This requires Azure ExpressRoute or VPN connectivity between tenants.

### Option 3: Microsoft Sentinel Multi-Workspace

**When to use:** If you're using Microsoft Sentinel for security operations.

```powershell
# In Atevet12, create a Sentinel workspace
# Then use Sentinel's multi-workspace feature to query across workspaces
```

**Pros:**
- Built-in security analytics
- Cross-workspace queries
- Incident management

**Cons:**
- Additional Sentinel costs
- May be overkill for simple log collection

### Option 4: Azure Data Export Rules

**When to use:** For continuous export to Azure Storage or Event Hubs.

```powershell
# Create data export rule
New-AzOperationalInsightsDataExport `
    -ResourceGroupName "rg-central-logging" `
    -WorkspaceName "law-central-atevet12" `
    -DataExportName "export-to-storage" `
    -TableName @("AzureActivity", "AzureDiagnostics") `
    -StorageAccountResourceId "<Storage-Account-Resource-ID>"
```

### Comparison Table

| Approach | Complexity | Cost | Real-time | Best For |
|----------|------------|------|-----------|----------|
| **Azure Lighthouse** | Low | Low | Near real-time | Cross-tenant management & logging |
| **Event Hubs** | Medium | Medium | Yes | High-volume, real-time streaming |
| **AMPLS** | High | Medium | Near real-time | Private network requirements |
| **Sentinel** | Medium | High | Near real-time | Security operations |

**Recommendation:** Azure Lighthouse is the best choice for your scenario because:
1. Native cross-tenant management
2. No additional infrastructure required
3. Direct integration with Log Analytics
4. Lower complexity and cost

---

## Troubleshooting

### Common Issues and Solutions

#### Issue 1: Delegation Not Appearing

**Symptoms:** Atevet17 subscriptions don't appear in "My customers" in Atevet12.

**Solutions:**
1. Verify the ARM template deployed successfully:
   ```powershell
   Get-AzSubscriptionDeployment -Name "LighthouseDeployment"
   ```
2. Check that the `Microsoft.ManagedServices` resource provider is registered:
   ```powershell
   Get-AzResourceProvider -ProviderNamespace Microsoft.ManagedServices
   ```
3. Ensure the user deploying has Owner role on the subscription

#### Issue 2: Cannot Configure Diagnostic Settings

**Symptoms:** Error when creating diagnostic settings across tenants.

**Solutions:**
1. Verify the delegated roles include `Monitoring Contributor`
2. Check that the Log Analytics workspace allows cross-tenant access
3. Ensure the workspace resource ID is correct

#### Issue 3: Logs Not Appearing in Workspace

**Symptoms:** Diagnostic settings configured but no data in Log Analytics.

**Solutions:**
1. Wait 5-15 minutes for initial data ingestion
2. Verify the diagnostic setting is enabled:
   ```powershell
   Get-AzDiagnosticSetting -ResourceId "<Resource-ID>"
   ```
3. Check for any errors in the Activity Log
4. Verify network connectivity (if using private endpoints)

#### Issue 4: Azure Monitor Agent Not Reporting

**Symptoms:** VMs have agent installed but no data in workspace.

**Solutions:**
1. Check agent status:
   ```powershell
   Get-AzVMExtension -ResourceGroupName "<RG>" -VMName "<VM>" -Name "AzureMonitorWindowsAgent"
   ```
2. Verify Data Collection Rule association:
   ```powershell
   Get-AzDataCollectionRuleAssociation -TargetResourceId "<VM-Resource-ID>"
   ```
3. Check VM connectivity to Azure Monitor endpoints

#### Issue 5: Permission Denied Errors

**Symptoms:** "Authorization failed" when managing delegated resources.

**Solutions:**
1. Verify user is member of the delegated security group
2. Check the roles assigned in the Lighthouse delegation
3. Ensure the delegation hasn't been revoked

### Useful Diagnostic Commands

```powershell
# Check Lighthouse delegations
Get-AzManagedServicesDefinition
Get-AzManagedServicesAssignment

# Check diagnostic settings
Get-AzDiagnosticSetting -ResourceId "<Resource-ID>"

# Check Data Collection Rules
Get-AzDataCollectionRule -ResourceGroupName "rg-central-logging"

# Check agent status on VM
Invoke-AzVMRunCommand -ResourceGroupName "<RG>" -VMName "<VM>" `
    -CommandId "RunPowerShellScript" `
    -ScriptString "Get-Service AzureMonitorAgent | Select Status"

# Query for ingestion errors
# Run in Log Analytics:
# AzureDiagnostics
# | where Category == "IngestionErrors"
# | project TimeGenerated, Message, _ResourceId
```

---

## Security Considerations

### 1. Principle of Least Privilege

Only grant the minimum required roles:
- Use `Monitoring Reader` instead of `Monitoring Contributor` if only read access is needed
- Consider using custom roles for more granular control

### 2. Audit Delegated Access

Regularly review delegated access:
```kusto
AzureActivity
| where OperationNameValue contains "Microsoft.ManagedServices"
| project TimeGenerated, OperationNameValue, Caller, ActivityStatusValue
```

### 3. Protect the Managing Tenant

- Use Conditional Access policies for users with delegated access
- Enable MFA for all users in the delegated security group
- Monitor sign-in logs for suspicious activity

### 4. Data Residency

Ensure your Log Analytics workspace location complies with data residency requirements.

---

## Cost Estimation

### Log Analytics Costs

| Component | Pricing Model |
|-----------|---------------|
| Data Ingestion | ~$2.76 per GB (Pay-as-you-go) |
| Data Retention | First 31 days free, then ~$0.12 per GB/month |
| Queries | Free for most scenarios |

### Estimated Monthly Costs

| Log Type | Estimated Volume | Monthly Cost |
|----------|------------------|--------------|
| Activity Logs | ~1-5 GB | $3-14 |
| VM Logs (10 VMs) | ~10-50 GB | $28-138 |
| Key Vault Logs | ~0.5-2 GB | $1-6 |
| Storage Logs | ~5-20 GB | $14-55 |
| **Total Estimate** | **~16-77 GB** | **$46-213** |

**Cost Optimization Tips:**
1. Use Basic Logs tier for high-volume, low-query data
2. Set appropriate retention periods
3. Use sampling for verbose logs
4. Archive old data to Storage Account

---

## Maintenance Checklist

### Weekly
- [ ] Review data ingestion volumes
- [ ] Check for any failed diagnostic settings
- [ ] Verify agent health on VMs

### Monthly
- [ ] Review and optimize queries
- [ ] Check for new resources needing diagnostic settings
- [ ] Review delegated access permissions
- [ ] Update Azure Monitor Agent if needed

### Quarterly
- [ ] Review and update Azure Policy assignments
- [ ] Audit Lighthouse delegations
- [ ] Review cost trends and optimize
- [ ] Test disaster recovery procedures

---

## Quick Reference Commands

```powershell
# === LIGHTHOUSE ===
# List delegations
Get-AzManagedServicesAssignment

# Remove delegation (run in Atevet17)
Remove-AzManagedServicesAssignment -Name "<Assignment-Name>"

# === DIAGNOSTIC SETTINGS ===
# List all diagnostic settings for a resource
Get-AzDiagnosticSetting -ResourceId "<Resource-ID>"

# Remove diagnostic setting
Remove-AzDiagnosticSetting -ResourceId "<Resource-ID>" -Name "SendToAtevet12"

# === LOG ANALYTICS ===
# Query workspace
Invoke-AzOperationalInsightsQuery -WorkspaceId "<Workspace-ID>" -Query "AzureActivity | take 10"

# Check data ingestion (run in Log Analytics)
# Usage | where TimeGenerated > ago(24h) | summarize sum(Quantity) by DataType | order by sum_Quantity desc

# === AZURE MONITOR AGENT ===
# Check agent status
Get-AzVMExtension -ResourceGroupName "<RG>" -VMName "<VM>" | Where-Object {$_.Publisher -eq "Microsoft.Azure.Monitor"}

# Remove agent
Remove-AzVMExtension -ResourceGroupName "<RG>" -VMName "<VM>" -Name "AzureMonitorWindowsAgent"
```

---

## Summary

You have now configured cross-tenant log collection from **Atevet17** to **Atevet12** using Azure Lighthouse. Here's what was accomplished:

1. ✅ Created security group in Atevet12 for delegated access
2. ✅ Created centralized Log Analytics workspace in Atevet12
3. ✅ Onboarded Atevet17 subscriptions to Azure Lighthouse
4. ✅ Configured Activity Log collection
5. ✅ Configured Resource Diagnostic Logs (VMs, Key Vaults, Storage)
6. ✅ Set up Azure Monitor Agent for VM-level logs

**Next Steps:**
1. Deploy Azure Policy for automatic diagnostic settings on new resources
2. Set up alerts for critical events
3. Create dashboards for monitoring
4. Consider Microsoft Sentinel for advanced security analytics

---

## Additional Resources

- [Azure Lighthouse Documentation](https://docs.microsoft.com/azure/lighthouse/)
- [Azure Monitor Documentation](https://docs.microsoft.com/azure/azure-monitor/)
- [Log Analytics Query Language (KQL)](https://docs.microsoft.com/azure/data-explorer/kusto/query/)
- [Azure Monitor Agent Documentation](https://docs.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-overview)
- [Diagnostic Settings Schema](https://docs.microsoft.com/azure/azure-monitor/essentials/resource-logs-schema)