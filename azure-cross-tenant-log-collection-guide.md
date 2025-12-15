# Azure Cross-Tenant Log Collection Guide
## Collecting Logs from Atevet17 to Atevet12 using Azure Lighthouse

---

## Table of Contents
1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Prerequisites](#prerequisites)
4. [Step 0: Register Required Resource Providers](#step-0-register-required-resource-providers)
5. [Step 1: Prepare the Managing Tenant (Atevet12)](#step-1-prepare-the-managing-tenant-atevet12)
6. [Step 2: Onboard Customer Tenant (Atevet17) to Azure Lighthouse](#step-2-onboard-customer-tenant-atevet17-to-azure-lighthouse)
7. [Step 3: Configure Activity Log Collection](#step-3-configure-activity-log-collection)
8. [Step 4: Configure Resource Diagnostic Logs](#step-4-configure-resource-diagnostic-logs)
9. [Step 5: Configure Microsoft Entra ID (Azure AD) Logs](#step-5-configure-microsoft-entra-id-azure-ad-logs)
10. [Step 6: Configure Microsoft 365 Audit Logs](#step-6-configure-microsoft-365-audit-logs)
11. [Step 7: Centralize Logs in Log Analytics Workspace](#step-7-centralize-logs-in-log-analytics-workspace)
12. [Step 8: Verify Log Collection](#step-8-verify-log-collection)
13. [Alternative Approaches](#alternative-approaches)
14. [Troubleshooting](#troubleshooting)

---

## Overview

**Scenario:** You want to collect all raw logs from Azure tenant **Atevet17** (source/customer tenant) and centralize them in tenant **Atevet12** (managing/destination tenant).

**Logs to Collect:**
- Subscription Activity Logs (control plane operations)
- Microsoft Entra ID (Azure AD) Logs:
  - Sign-in Logs
  - Audit Logs
  - Provisioning Logs
  - Identity Protection Logs
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

## Step 0: Register Required Resource Providers

Before deploying Azure Lighthouse, you must ensure the `Microsoft.ManagedServices` resource provider is registered in the **customer tenant (Atevet17)**. This resource provider is required for Azure Lighthouse delegations to work.

### 0.1 Check Resource Provider Registration Status

**Using PowerShell:**

```powershell
# Connect to Atevet17 tenant
Connect-AzAccount -TenantId "<Atevet17-Tenant-ID>"

# Set the subscription context
Set-AzContext -SubscriptionId "<Atevet17-Subscription-ID>"

# Check if Microsoft.ManagedServices is registered
$provider = Get-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"

# Display registration status
$provider | Select-Object ProviderNamespace, RegistrationState

# Expected output if registered:
# ProviderNamespace           RegistrationState
# -----------------           -----------------
# Microsoft.ManagedServices   Registered
```

**Using Azure CLI:**

```bash
# Login to Atevet17 tenant
az login --tenant "<Atevet17-Tenant-ID>"

# Set the subscription
az account set --subscription "<Atevet17-Subscription-ID>"

# Check registration status
az provider show --namespace Microsoft.ManagedServices --query "registrationState" -o tsv

# Expected output if registered: Registered
```

**Using Azure Portal:**

1. Sign in to the **Azure Portal** in the **Atevet17** tenant
2. Navigate to **Subscriptions** → Select your subscription
3. Go to **Settings** → **Resource providers**
4. Search for `Microsoft.ManagedServices`
5. Check the **Status** column:
   - ✅ **Registered** - Ready to use
   - ⚠️ **NotRegistered** - Needs to be registered
   - 🔄 **Registering** - Registration in progress

### 0.2 Register the Resource Provider (If Not Registered)

If the resource provider is not registered, you need to register it before proceeding with Azure Lighthouse deployment.

**Using PowerShell:**

```powershell
# Connect to Atevet17 tenant (if not already connected)
Connect-AzAccount -TenantId "<Atevet17-Tenant-ID>"
Set-AzContext -SubscriptionId "<Atevet17-Subscription-ID>"

# Register the Microsoft.ManagedServices resource provider
Register-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"

# Wait for registration to complete (usually takes 1-2 minutes)
Write-Host "Waiting for registration to complete..."

do {
    Start-Sleep -Seconds 10
    $provider = Get-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"
    $status = $provider.RegistrationState
    Write-Host "Current status: $status"
} while ($status -eq "Registering")

if ($status -eq "Registered") {
    Write-Host "✓ Microsoft.ManagedServices is now registered!" -ForegroundColor Green
} else {
    Write-Host "✗ Registration failed. Status: $status" -ForegroundColor Red
}
```

**Using Azure CLI:**

```bash
# Login to Atevet17 tenant (if not already logged in)
az login --tenant "<Atevet17-Tenant-ID>"
az account set --subscription "<Atevet17-Subscription-ID>"

# Register the resource provider
az provider register --namespace Microsoft.ManagedServices

# Wait for registration to complete
echo "Waiting for registration to complete..."
az provider show --namespace Microsoft.ManagedServices --query "registrationState" -o tsv

# Poll until registered (optional - for scripting)
while [ "$(az provider show --namespace Microsoft.ManagedServices --query 'registrationState' -o tsv)" != "Registered" ]; do
    echo "Still registering..."
    sleep 10
done
echo "✓ Microsoft.ManagedServices is now registered!"
```

**Using Azure Portal:**

1. Sign in to the **Azure Portal** in the **Atevet17** tenant
2. Navigate to **Subscriptions** → Select your subscription
3. Go to **Settings** → **Resource providers**
4. Search for `Microsoft.ManagedServices`
5. Select the provider and click **Register**
6. Wait for the status to change to **Registered** (refresh the page if needed)

### 0.3 Verify Registration for All Subscriptions

If you plan to delegate multiple subscriptions, you need to register the resource provider in **each subscription**:

**PowerShell Script for Multiple Subscriptions:**

```powershell
# Connect to Atevet17 tenant
Connect-AzAccount -TenantId "<Atevet17-Tenant-ID>"

# Get all subscriptions in the tenant
$subscriptions = Get-AzSubscription -TenantId "<Atevet17-Tenant-ID>"

foreach ($sub in $subscriptions) {
    Write-Host "`nProcessing subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan
    
    # Set context to this subscription
    Set-AzContext -SubscriptionId $sub.Id
    
    # Check current status
    $provider = Get-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"
    
    if ($provider.RegistrationState -eq "Registered") {
        Write-Host "  ✓ Already registered" -ForegroundColor Green
    } else {
        Write-Host "  Registering..." -ForegroundColor Yellow
        Register-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"
        
        # Wait for registration
        do {
            Start-Sleep -Seconds 5
            $provider = Get-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"
        } while ($provider.RegistrationState -eq "Registering")
        
        if ($provider.RegistrationState -eq "Registered") {
            Write-Host "  ✓ Successfully registered" -ForegroundColor Green
        } else {
            Write-Host "  ✗ Failed to register: $($provider.RegistrationState)" -ForegroundColor Red
        }
    }
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "All subscriptions have been processed."
```

**Azure CLI Script for Multiple Subscriptions:**

```bash
#!/bin/bash

# Login to Atevet17 tenant
az login --tenant "<Atevet17-Tenant-ID>"

# Get all subscriptions
subscriptions=$(az account list --query "[].id" -o tsv)

for sub in $subscriptions; do
    echo ""
    echo "Processing subscription: $sub"
    az account set --subscription "$sub"
    
    status=$(az provider show --namespace Microsoft.ManagedServices --query "registrationState" -o tsv 2>/dev/null)
    
    if [ "$status" == "Registered" ]; then
        echo "  ✓ Already registered"
    else
        echo "  Registering..."
        az provider register --namespace Microsoft.ManagedServices
        
        # Wait for registration
        while [ "$(az provider show --namespace Microsoft.ManagedServices --query 'registrationState' -o tsv)" != "Registered" ]; do
            sleep 5
        done
        echo "  ✓ Successfully registered"
    fi
done

echo ""
echo "=== All subscriptions processed ==="
```

### 0.4 Required Permissions

To register a resource provider, you need one of the following roles on the subscription:

| Role | Can Register Resource Providers |
|------|--------------------------------|
| **Owner** | ✅ Yes |
| **Contributor** | ✅ Yes |
| **Custom Role** with `Microsoft.Resources/subscriptions/providers/register/action` | ✅ Yes |
| **Reader** | ❌ No |

### 0.5 Troubleshooting Resource Provider Registration

**Issue: "The subscription is not registered to use namespace 'Microsoft.ManagedServices'"**

This error occurs when deploying Azure Lighthouse before registering the resource provider.

**Solution:**
```powershell
# Register the provider and wait
Register-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"
Start-Sleep -Seconds 60
# Then retry the Lighthouse deployment
```

**Issue: Registration stuck in "Registering" state**

If registration takes more than 10 minutes:

```powershell
# Check for any errors
Get-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices" | Format-List *

# Try unregistering and re-registering
Unregister-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"
Start-Sleep -Seconds 30
Register-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"
```

**Issue: "AuthorizationFailed" when registering**

You don't have sufficient permissions. Contact your subscription Owner or Contributor to register the provider, or request the necessary role assignment.

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
New-AzResourceGroup -Name "rg-central-logging" -Location "westus2"

# Create Log Analytics Workspace
$workspace = New-AzOperationalInsightsWorkspace `
    -ResourceGroupName "rg-central-logging" `
    -Name "law-central-atevet12" `
    -Location "westus2" `
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
                    "roleDefinitionId": "acdd72a7-3385-48ef-bd42-f606fba81ae7"
                },
                {
                    "principalId": "<SECURITY-GROUP-OBJECT-ID>",
                    "principalIdDisplayName": "Lighthouse-Atevet17-Admins",
                    "roleDefinitionId": "b24988ac-6180-42a0-ab88-20f7382dd24c"
                },
                {
                    "principalId": "<SECURITY-GROUP-OBJECT-ID>",
                    "principalIdDisplayName": "Lighthouse-Atevet17-Admins",
                    "roleDefinitionId": "43d0d8ad-25c7-4714-9337-8ba259a9fe05"
                },
                {
                    "principalId": "<SECURITY-GROUP-OBJECT-ID>",
                    "principalIdDisplayName": "Lighthouse-Atevet17-Admins",
                    "roleDefinitionId": "73c42c96-874c-492b-b04d-ab87d138a893"
                }
            ]
        }
    }
}
```

**Role Definitions Explained:**

| Role | Role Definition ID | Purpose |
|------|-------------------|---------|
| **Reader** | `acdd72a7-3385-48ef-bd42-f606fba81ae7` | Read access to resources for log collection visibility |
| **Contributor** | `b24988ac-6180-42a0-ab88-20f7382dd24c` | Write access to configure diagnostic settings and manage resources |
| **Monitoring Reader** | `43d0d8ad-25c7-4714-9337-8ba259a9fe05` | Read monitoring data and diagnostic settings |
| **Log Analytics Reader** | `73c42c96-874c-492b-b04d-ab87d138a893` | Read Log Analytics data and query logs |

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
    --location "westus2" \
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
    -Location "westus2" `
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
    Location = "westus2"
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

### 4.2 Enable Diagnostic Logging for All Resource Types

Azure supports diagnostic logging for many resource types. This section provides a generic approach to enable diagnostic settings for **all supported resources** in your subscription, plus specific examples for common resource types.

#### 4.2.1 Generic Script for All Resources

The following PowerShell script discovers all resources that support diagnostic settings and enables logging for them:

```powershell
# Set context to delegated Atevet17 subscription
Set-AzContext -SubscriptionId "<Atevet17-Subscription-ID>"

# Log Analytics Workspace in Atevet12
$workspaceResourceId = "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

# Get all resources in the subscription
$resources = Get-AzResource

# Track results
$successCount = 0
$failCount = 0
$skippedCount = 0

foreach ($resource in $resources) {
    try {
        # Check if the resource supports diagnostic settings
        $diagnosticCategories = Get-AzDiagnosticSettingCategory -ResourceId $resource.ResourceId -ErrorAction SilentlyContinue
        
        if ($null -eq $diagnosticCategories -or $diagnosticCategories.Count -eq 0) {
            Write-Host "Skipping $($resource.Name) ($($resource.ResourceType)) - No diagnostic categories available" -ForegroundColor Yellow
            $skippedCount++
            continue
        }
        
        # Build log categories array
        $logCategories = @()
        $metricCategories = @()
        
        foreach ($category in $diagnosticCategories) {
            if ($category.CategoryType -eq "Logs") {
                $logCategories += @{
                    Category = $category.Name
                    Enabled = $true
                }
            } elseif ($category.CategoryType -eq "Metrics") {
                $metricCategories += @{
                    Category = $category.Name
                    Enabled = $true
                }
            }
        }
        
        # Create diagnostic setting
        $params = @{
            ResourceId = $resource.ResourceId
            Name = "SendToAtevet12"
            WorkspaceId = $workspaceResourceId
        }
        
        if ($logCategories.Count -gt 0) {
            $params.Log = $logCategories
        }
        
        if ($metricCategories.Count -gt 0) {
            $params.Metric = $metricCategories
        }
        
        Set-AzDiagnosticSetting @params
        Write-Host "✓ Configured diagnostic settings for $($resource.Name) ($($resource.ResourceType))" -ForegroundColor Green
        $successCount++
        
    } catch {
        Write-Warning "✗ Failed to configure $($resource.Name) ($($resource.ResourceType)): $_"
        $failCount++
    }
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Successfully configured: $successCount" -ForegroundColor Green
Write-Host "Failed: $failCount" -ForegroundColor Red
Write-Host "Skipped (no diagnostic support): $skippedCount" -ForegroundColor Yellow
```

#### 4.2.2 Azure CLI Alternative

```bash
# Set subscription context
az account set --subscription "<Atevet17-Subscription-ID>"

# Log Analytics Workspace Resource ID
WORKSPACE_ID="/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

# Get all resources and configure diagnostic settings
az resource list --query "[].id" -o tsv | while read resource_id; do
    # Get diagnostic categories for the resource
    categories=$(az monitor diagnostic-settings categories list --resource "$resource_id" --query "[?categoryType=='Logs'].name" -o tsv 2>/dev/null)
    
    if [ -n "$categories" ]; then
        # Build logs JSON
        logs_json="["
        first=true
        for cat in $categories; do
            if [ "$first" = true ]; then
                first=false
            else
                logs_json+=","
            fi
            logs_json+="{\"category\":\"$cat\",\"enabled\":true}"
        done
        logs_json+="]"
        
        # Create diagnostic setting
        az monitor diagnostic-settings create \
            --name "SendToAtevet12" \
            --resource "$resource_id" \
            --workspace "$WORKSPACE_ID" \
            --logs "$logs_json" \
            --metrics '[{"category":"AllMetrics","enabled":true}]' 2>/dev/null && \
            echo "✓ Configured: $resource_id" || \
            echo "✗ Failed: $resource_id"
    fi
done
```

#### 4.2.3 Specific Resource Type Examples

Below are specific examples for common Azure resource types with their available log categories:

##### Key Vaults

```powershell
$keyVaults = Get-AzKeyVault

foreach ($kv in $keyVaults) {
    $kvResourceId = (Get-AzKeyVault -VaultName $kv.VaultName).ResourceId
    
    $log = @(
        @{ Category = "AuditEvent"; Enabled = $true },
        @{ Category = "AzurePolicyEvaluationDetails"; Enabled = $true }
    )
    
    $metric = @(
        @{ Category = "AllMetrics"; Enabled = $true }
    )
    
    Set-AzDiagnosticSetting -ResourceId $kvResourceId -Name "SendToAtevet12" `
        -WorkspaceId $workspaceResourceId -Log $log -Metric $metric
}
```

##### Storage Accounts

```powershell
$storageAccounts = Get-AzStorageAccount

foreach ($sa in $storageAccounts) {
    # Enable for blob, queue, table, and file services
    $services = @("blob", "queue", "table", "file")
    
    foreach ($service in $services) {
        $resourceId = "$($sa.Id)/${service}Services/default"
        
        $log = @(
            @{ Category = "StorageRead"; Enabled = $true },
            @{ Category = "StorageWrite"; Enabled = $true },
            @{ Category = "StorageDelete"; Enabled = $true }
        )
        
        $metric = @(
            @{ Category = "Transaction"; Enabled = $true }
        )
        
        try {
            Set-AzDiagnosticSetting -ResourceId $resourceId -Name "SendToAtevet12" `
                -WorkspaceId $workspaceResourceId -Log $log -Metric $metric
        } catch {
            Write-Warning "Could not configure $service for $($sa.StorageAccountName): $_"
        }
    }
}
```

##### App Services / Web Apps

```powershell
$webApps = Get-AzWebApp

foreach ($app in $webApps) {
    $log = @(
        @{ Category = "AppServiceHTTPLogs"; Enabled = $true },
        @{ Category = "AppServiceConsoleLogs"; Enabled = $true },
        @{ Category = "AppServiceAppLogs"; Enabled = $true },
        @{ Category = "AppServiceAuditLogs"; Enabled = $true },
        @{ Category = "AppServiceIPSecAuditLogs"; Enabled = $true },
        @{ Category = "AppServicePlatformLogs"; Enabled = $true }
    )
    
    $metric = @(
        @{ Category = "AllMetrics"; Enabled = $true }
    )
    
    Set-AzDiagnosticSetting -ResourceId $app.Id -Name "SendToAtevet12" `
        -WorkspaceId $workspaceResourceId -Log $log -Metric $metric
}
```

##### SQL Databases

```powershell
$sqlServers = Get-AzSqlServer

foreach ($server in $sqlServers) {
    $databases = Get-AzSqlDatabase -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName
    
    foreach ($db in $databases) {
        if ($db.DatabaseName -eq "master") { continue }
        
        $log = @(
            @{ Category = "SQLInsights"; Enabled = $true },
            @{ Category = "AutomaticTuning"; Enabled = $true },
            @{ Category = "QueryStoreRuntimeStatistics"; Enabled = $true },
            @{ Category = "QueryStoreWaitStatistics"; Enabled = $true },
            @{ Category = "Errors"; Enabled = $true },
            @{ Category = "DatabaseWaitStatistics"; Enabled = $true },
            @{ Category = "Timeouts"; Enabled = $true },
            @{ Category = "Blocks"; Enabled = $true },
            @{ Category = "Deadlocks"; Enabled = $true }
        )
        
        $metric = @(
            @{ Category = "Basic"; Enabled = $true },
            @{ Category = "InstanceAndAppAdvanced"; Enabled = $true },
            @{ Category = "WorkloadManagement"; Enabled = $true }
        )
        
        Set-AzDiagnosticSetting -ResourceId $db.ResourceId -Name "SendToAtevet12" `
            -WorkspaceId $workspaceResourceId -Log $log -Metric $metric
    }
}
```

##### Network Security Groups (NSGs)

```powershell
$nsgs = Get-AzNetworkSecurityGroup

foreach ($nsg in $nsgs) {
    $log = @(
        @{ Category = "NetworkSecurityGroupEvent"; Enabled = $true },
        @{ Category = "NetworkSecurityGroupRuleCounter"; Enabled = $true }
    )
    
    Set-AzDiagnosticSetting -ResourceId $nsg.Id -Name "SendToAtevet12" `
        -WorkspaceId $workspaceResourceId -Log $log
}
```

##### Azure Kubernetes Service (AKS)

```powershell
$aksClusters = Get-AzAksCluster

foreach ($aks in $aksClusters) {
    $log = @(
        @{ Category = "kube-apiserver"; Enabled = $true },
        @{ Category = "kube-audit"; Enabled = $true },
        @{ Category = "kube-audit-admin"; Enabled = $true },
        @{ Category = "kube-controller-manager"; Enabled = $true },
        @{ Category = "kube-scheduler"; Enabled = $true },
        @{ Category = "cluster-autoscaler"; Enabled = $true },
        @{ Category = "guard"; Enabled = $true }
    )
    
    $metric = @(
        @{ Category = "AllMetrics"; Enabled = $true }
    )
    
    Set-AzDiagnosticSetting -ResourceId $aks.Id -Name "SendToAtevet12" `
        -WorkspaceId $workspaceResourceId -Log $log -Metric $metric
}
```

##### Azure Functions

```powershell
$functionApps = Get-AzFunctionApp

foreach ($func in $functionApps) {
    $log = @(
        @{ Category = "FunctionAppLogs"; Enabled = $true }
    )
    
    $metric = @(
        @{ Category = "AllMetrics"; Enabled = $true }
    )
    
    Set-AzDiagnosticSetting -ResourceId $func.Id -Name "SendToAtevet12" `
        -WorkspaceId $workspaceResourceId -Log $log -Metric $metric
}
```

##### Cosmos DB

```powershell
$cosmosAccounts = Get-AzCosmosDBAccount

foreach ($cosmos in $cosmosAccounts) {
    $log = @(
        @{ Category = "DataPlaneRequests"; Enabled = $true },
        @{ Category = "QueryRuntimeStatistics"; Enabled = $true },
        @{ Category = "PartitionKeyStatistics"; Enabled = $true },
        @{ Category = "PartitionKeyRUConsumption"; Enabled = $true },
        @{ Category = "ControlPlaneRequests"; Enabled = $true }
    )
    
    $metric = @(
        @{ Category = "Requests"; Enabled = $true }
    )
    
    Set-AzDiagnosticSetting -ResourceId $cosmos.Id -Name "SendToAtevet12" `
        -WorkspaceId $workspaceResourceId -Log $log -Metric $metric
}
```

##### Event Hubs

```powershell
$eventHubNamespaces = Get-AzEventHubNamespace

foreach ($ns in $eventHubNamespaces) {
    $log = @(
        @{ Category = "ArchiveLogs"; Enabled = $true },
        @{ Category = "OperationalLogs"; Enabled = $true },
        @{ Category = "AutoScaleLogs"; Enabled = $true },
        @{ Category = "KafkaCoordinatorLogs"; Enabled = $true },
        @{ Category = "KafkaUserErrorLogs"; Enabled = $true },
        @{ Category = "EventHubVNetConnectionEvent"; Enabled = $true },
        @{ Category = "CustomerManagedKeyUserLogs"; Enabled = $true }
    )
    
    $metric = @(
        @{ Category = "AllMetrics"; Enabled = $true }
    )
    
    Set-AzDiagnosticSetting -ResourceId $ns.Id -Name "SendToAtevet12" `
        -WorkspaceId $workspaceResourceId -Log $log -Metric $metric
}
```

##### Service Bus

```powershell
$serviceBusNamespaces = Get-AzServiceBusNamespace

foreach ($ns in $serviceBusNamespaces) {
    $log = @(
        @{ Category = "OperationalLogs"; Enabled = $true },
        @{ Category = "VNetAndIPFilteringLogs"; Enabled = $true }
    )
    
    $metric = @(
        @{ Category = "AllMetrics"; Enabled = $true }
    )
    
    Set-AzDiagnosticSetting -ResourceId $ns.Id -Name "SendToAtevet12" `
        -WorkspaceId $workspaceResourceId -Log $log -Metric $metric
}
```

##### Application Gateway

```powershell
$appGateways = Get-AzApplicationGateway

foreach ($gw in $appGateways) {
    $log = @(
        @{ Category = "ApplicationGatewayAccessLog"; Enabled = $true },
        @{ Category = "ApplicationGatewayPerformanceLog"; Enabled = $true },
        @{ Category = "ApplicationGatewayFirewallLog"; Enabled = $true }
    )
    
    $metric = @(
        @{ Category = "AllMetrics"; Enabled = $true }
    )
    
    Set-AzDiagnosticSetting -ResourceId $gw.Id -Name "SendToAtevet12" `
        -WorkspaceId $workspaceResourceId -Log $log -Metric $metric
}
```

##### Azure Firewall

```powershell
$firewalls = Get-AzFirewall

foreach ($fw in $firewalls) {
    $log = @(
        @{ Category = "AzureFirewallApplicationRule"; Enabled = $true },
        @{ Category = "AzureFirewallNetworkRule"; Enabled = $true },
        @{ Category = "AzureFirewallDnsProxy"; Enabled = $true },
        @{ Category = "AZFWNetworkRule"; Enabled = $true },
        @{ Category = "AZFWApplicationRule"; Enabled = $true },
        @{ Category = "AZFWNatRule"; Enabled = $true },
        @{ Category = "AZFWThreatIntel"; Enabled = $true },
        @{ Category = "AZFWIdpsSignature"; Enabled = $true },
        @{ Category = "AZFWDnsQuery"; Enabled = $true },
        @{ Category = "AZFWFqdnResolveFailure"; Enabled = $true },
        @{ Category = "AZFWFatFlow"; Enabled = $true },
        @{ Category = "AZFWFlowTrace"; Enabled = $true }
    )
    
    $metric = @(
        @{ Category = "AllMetrics"; Enabled = $true }
    )
    
    Set-AzDiagnosticSetting -ResourceId $fw.Id -Name "SendToAtevet12" `
        -WorkspaceId $workspaceResourceId -Log $log -Metric $metric
}
```

#### 4.2.4 Supported Resource Types Reference

The following table lists common Azure resource types and their diagnostic log categories:

| Resource Type | Log Categories |
|--------------|----------------|
| **Key Vault** | AuditEvent, AzurePolicyEvaluationDetails |
| **Storage Account** | StorageRead, StorageWrite, StorageDelete |
| **App Service** | AppServiceHTTPLogs, AppServiceConsoleLogs, AppServiceAppLogs, AppServiceAuditLogs |
| **SQL Database** | SQLInsights, AutomaticTuning, QueryStoreRuntimeStatistics, Errors, Deadlocks |
| **NSG** | NetworkSecurityGroupEvent, NetworkSecurityGroupRuleCounter |
| **AKS** | kube-apiserver, kube-audit, kube-controller-manager, kube-scheduler |
| **Azure Functions** | FunctionAppLogs |
| **Cosmos DB** | DataPlaneRequests, QueryRuntimeStatistics, ControlPlaneRequests |
| **Event Hubs** | ArchiveLogs, OperationalLogs, AutoScaleLogs |
| **Service Bus** | OperationalLogs, VNetAndIPFilteringLogs |
| **Application Gateway** | ApplicationGatewayAccessLog, ApplicationGatewayPerformanceLog, ApplicationGatewayFirewallLog |
| **Azure Firewall** | AzureFirewallApplicationRule, AzureFirewallNetworkRule, AZFWThreatIntel |
| **Load Balancer** | LoadBalancerAlertEvent, LoadBalancerProbeHealthStatus |
| **Virtual Network** | VMProtectionAlerts |
| **API Management** | GatewayLogs, WebSocketConnectionLogs |
| **Logic Apps** | WorkflowRuntime |
| **Container Registry** | ContainerRegistryRepositoryEvents, ContainerRegistryLoginEvents |
| **Redis Cache** | ConnectedClientList |

### 4.3 Azure Policy for Automatic Diagnostic Settings (All Resource Types)

To automatically configure diagnostic settings for **ALL new resources** that support diagnostics, you can use Azure Policy. This section provides multiple approaches:

#### 4.3.1 Using Built-in Policy Initiative (Recommended)

Azure provides a built-in policy initiative that enables diagnostic settings for multiple resource types. This is the easiest approach:

```powershell
# Set context to delegated Atevet17 subscription
Set-AzContext -SubscriptionId "<Atevet17-Subscription-ID>"

# Log Analytics Workspace Resource ID
$workspaceResourceId = "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

# Get the built-in policy initiative for diagnostic settings
$initiative = Get-AzPolicySetDefinition | Where-Object {
    $_.Properties.DisplayName -like "*Enable Azure Monitor*" -or
    $_.Properties.DisplayName -like "*diagnostic*"
}

# Assign the initiative
New-AzPolicyAssignment `
    -Name "EnableDiagnosticsForAllResources" `
    -DisplayName "Enable Diagnostic Settings for All Resources" `
    -PolicySetDefinition $initiative `
    -Scope "/subscriptions/<Atevet17-Subscription-ID>" `
    -PolicyParameterObject @{
        "logAnalytics" = $workspaceResourceId
    } `
    -Location "westus2" `
    -IdentityType "SystemAssigned"

# Grant the managed identity the required permissions
$assignment = Get-AzPolicyAssignment -Name "EnableDiagnosticsForAllResources"
New-AzRoleAssignment `
    -ObjectId $assignment.Identity.PrincipalId `
    -RoleDefinitionName "Monitoring Contributor" `
    -Scope "/subscriptions/<Atevet17-Subscription-ID>"

New-AzRoleAssignment `
    -ObjectId $assignment.Identity.PrincipalId `
    -RoleDefinitionName "Log Analytics Contributor" `
    -Scope $workspaceResourceId
```

#### 4.3.2 Custom Policy Initiative for All Resource Types

Create a custom policy initiative that covers all resource types supporting diagnostic settings:

**Step 1: Create the Policy Initiative Definition**

Save this as `diagnostic-settings-initiative.json`:

```json
{
    "properties": {
        "displayName": "Enable Diagnostic Settings for All Supported Resources",
        "description": "This initiative deploys diagnostic settings to all supported Azure resource types to send logs to a Log Analytics workspace.",
        "metadata": {
            "category": "Monitoring",
            "version": "1.0.0"
        },
        "parameters": {
            "logAnalyticsWorkspaceId": {
                "type": "String",
                "metadata": {
                    "displayName": "Log Analytics Workspace ID",
                    "description": "The resource ID of the Log Analytics workspace to send diagnostics to"
                }
            },
            "effect": {
                "type": "String",
                "defaultValue": "DeployIfNotExists",
                "allowedValues": ["DeployIfNotExists", "AuditIfNotExists", "Disabled"],
                "metadata": {
                    "displayName": "Effect",
                    "description": "Enable or disable the execution of the policy"
                }
            }
        },
        "policyDefinitions": []
    }
}
```

**Step 2: Create Individual Policy Definitions**

Below is a generic policy template that can be adapted for any resource type. Save as `diagnostic-policy-template.json`:

```json
{
    "mode": "Indexed",
    "parameters": {
        "logAnalyticsWorkspaceId": {
            "type": "String",
            "metadata": {
                "displayName": "Log Analytics Workspace ID",
                "description": "The resource ID of the Log Analytics workspace"
            }
        },
        "effect": {
            "type": "String",
            "defaultValue": "DeployIfNotExists",
            "allowedValues": ["DeployIfNotExists", "AuditIfNotExists", "Disabled"]
        },
        "diagnosticSettingName": {
            "type": "String",
            "defaultValue": "SendToLogAnalytics"
        }
    },
    "policyRule": {
        "if": {
            "field": "type",
            "equals": "RESOURCE_TYPE_PLACEHOLDER"
        },
        "then": {
            "effect": "[parameters('effect')]",
            "details": {
                "type": "Microsoft.Insights/diagnosticSettings",
                "name": "[parameters('diagnosticSettingName')]",
                "existenceCondition": {
                    "allOf": [
                        {
                            "field": "Microsoft.Insights/diagnosticSettings/workspaceId",
                            "equals": "[parameters('logAnalyticsWorkspaceId')]"
                        },
                        {
                            "field": "Microsoft.Insights/diagnosticSettings/logs.enabled",
                            "equals": "true"
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
                                "logAnalyticsWorkspaceId": { "type": "string" },
                                "location": { "type": "string" },
                                "diagnosticSettingName": { "type": "string" }
                            },
                            "resources": [
                                {
                                    "type": "RESOURCE_TYPE_PLACEHOLDER/providers/diagnosticSettings",
                                    "apiVersion": "2021-05-01-preview",
                                    "name": "[concat(parameters('resourceName'), '/Microsoft.Insights/', parameters('diagnosticSettingName'))]",
                                    "location": "[parameters('location')]",
                                    "properties": {
                                        "workspaceId": "[parameters('logAnalyticsWorkspaceId')]",
                                        "logs": "LOG_CATEGORIES_PLACEHOLDER",
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
                            "logAnalyticsWorkspaceId": { "value": "[parameters('logAnalyticsWorkspaceId')]" },
                            "location": { "value": "[field('location')]" },
                            "diagnosticSettingName": { "value": "[parameters('diagnosticSettingName')]" }
                        }
                    }
                }
            }
        }
    }
}
```

**Step 3: Deploy Policies for Common Resource Types**

Here's a PowerShell script that creates and assigns policies for multiple resource types:

```powershell
# Define resource types and their log categories
$resourceTypes = @{
    "Microsoft.KeyVault/vaults" = @(
        @{ category = "AuditEvent"; enabled = $true },
        @{ category = "AzurePolicyEvaluationDetails"; enabled = $true }
    )
    "Microsoft.Storage/storageAccounts/blobServices" = @(
        @{ category = "StorageRead"; enabled = $true },
        @{ category = "StorageWrite"; enabled = $true },
        @{ category = "StorageDelete"; enabled = $true }
    )
    "Microsoft.Web/sites" = @(
        @{ category = "AppServiceHTTPLogs"; enabled = $true },
        @{ category = "AppServiceConsoleLogs"; enabled = $true },
        @{ category = "AppServiceAppLogs"; enabled = $true },
        @{ category = "AppServiceAuditLogs"; enabled = $true }
    )
    "Microsoft.Sql/servers/databases" = @(
        @{ category = "SQLInsights"; enabled = $true },
        @{ category = "AutomaticTuning"; enabled = $true },
        @{ category = "Errors"; enabled = $true },
        @{ category = "Deadlocks"; enabled = $true }
    )
    "Microsoft.Network/networkSecurityGroups" = @(
        @{ category = "NetworkSecurityGroupEvent"; enabled = $true },
        @{ category = "NetworkSecurityGroupRuleCounter"; enabled = $true }
    )
    "Microsoft.ContainerService/managedClusters" = @(
        @{ category = "kube-apiserver"; enabled = $true },
        @{ category = "kube-audit"; enabled = $true },
        @{ category = "kube-controller-manager"; enabled = $true },
        @{ category = "kube-scheduler"; enabled = $true },
        @{ category = "cluster-autoscaler"; enabled = $true }
    )
    "Microsoft.DocumentDB/databaseAccounts" = @(
        @{ category = "DataPlaneRequests"; enabled = $true },
        @{ category = "QueryRuntimeStatistics"; enabled = $true },
        @{ category = "ControlPlaneRequests"; enabled = $true }
    )
    "Microsoft.EventHub/namespaces" = @(
        @{ category = "ArchiveLogs"; enabled = $true },
        @{ category = "OperationalLogs"; enabled = $true },
        @{ category = "AutoScaleLogs"; enabled = $true }
    )
    "Microsoft.ServiceBus/namespaces" = @(
        @{ category = "OperationalLogs"; enabled = $true }
    )
    "Microsoft.Network/applicationGateways" = @(
        @{ category = "ApplicationGatewayAccessLog"; enabled = $true },
        @{ category = "ApplicationGatewayPerformanceLog"; enabled = $true },
        @{ category = "ApplicationGatewayFirewallLog"; enabled = $true }
    )
    "Microsoft.Network/azureFirewalls" = @(
        @{ category = "AzureFirewallApplicationRule"; enabled = $true },
        @{ category = "AzureFirewallNetworkRule"; enabled = $true },
        @{ category = "AzureFirewallDnsProxy"; enabled = $true }
    )
    "Microsoft.Cdn/profiles" = @(
        @{ category = "AzureCdnAccessLog"; enabled = $true }
    )
    "Microsoft.ApiManagement/service" = @(
        @{ category = "GatewayLogs"; enabled = $true }
    )
    "Microsoft.Logic/workflows" = @(
        @{ category = "WorkflowRuntime"; enabled = $true }
    )
    "Microsoft.ContainerRegistry/registries" = @(
        @{ category = "ContainerRegistryRepositoryEvents"; enabled = $true },
        @{ category = "ContainerRegistryLoginEvents"; enabled = $true }
    )
    "Microsoft.Cache/redis" = @(
        @{ category = "ConnectedClientList"; enabled = $true }
    )
    "Microsoft.Batch/batchAccounts" = @(
        @{ category = "ServiceLog"; enabled = $true }
    )
    "Microsoft.DataFactory/factories" = @(
        @{ category = "ActivityRuns"; enabled = $true },
        @{ category = "PipelineRuns"; enabled = $true },
        @{ category = "TriggerRuns"; enabled = $true }
    )
    "Microsoft.SignalRService/SignalR" = @(
        @{ category = "AllLogs"; enabled = $true }
    )
    "Microsoft.CognitiveServices/accounts" = @(
        @{ category = "Audit"; enabled = $true },
        @{ category = "RequestResponse"; enabled = $true }
    )
}

$workspaceResourceId = "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
$subscriptionId = "<Atevet17-Subscription-ID>"

foreach ($resourceType in $resourceTypes.Keys) {
    $logCategories = $resourceTypes[$resourceType]
    $policyName = "DiagSettings-$($resourceType.Replace('/', '-').Replace('.', '-'))"
    
    # Create policy definition JSON
    $logsJson = $logCategories | ConvertTo-Json -Compress
    
    $policyDefinition = @{
        "mode" = "Indexed"
        "parameters" = @{
            "logAnalyticsWorkspaceId" = @{
                "type" = "String"
                "metadata" = @{
                    "displayName" = "Log Analytics Workspace ID"
                }
            }
        }
        "policyRule" = @{
            "if" = @{
                "field" = "type"
                "equals" = $resourceType
            }
            "then" = @{
                "effect" = "deployIfNotExists"
                "details" = @{
                    "type" = "Microsoft.Insights/diagnosticSettings"
                    "name" = "SendToAtevet12"
                    "existenceCondition" = @{
                        "field" = "Microsoft.Insights/diagnosticSettings/workspaceId"
                        "equals" = "[parameters('logAnalyticsWorkspaceId')]"
                    }
                    "roleDefinitionIds" = @(
                        "/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"
                    )
                    "deployment" = @{
                        "properties" = @{
                            "mode" = "incremental"
                            "template" = @{
                                "`$schema" = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
                                "contentVersion" = "1.0.0.0"
                                "parameters" = @{
                                    "resourceName" = @{ "type" = "string" }
                                    "logAnalyticsWorkspaceId" = @{ "type" = "string" }
                                }
                                "resources" = @(
                                    @{
                                        "type" = "$resourceType/providers/diagnosticSettings"
                                        "apiVersion" = "2021-05-01-preview"
                                        "name" = "[concat(parameters('resourceName'), '/Microsoft.Insights/SendToAtevet12')]"
                                        "properties" = @{
                                            "workspaceId" = "[parameters('logAnalyticsWorkspaceId')]"
                                            "logs" = $logCategories
                                            "metrics" = @(
                                                @{
                                                    "category" = "AllMetrics"
                                                    "enabled" = $true
                                                }
                                            )
                                        }
                                    }
                                )
                            }
                            "parameters" = @{
                                "resourceName" = @{ "value" = "[field('name')]" }
                                "logAnalyticsWorkspaceId" = @{ "value" = "[parameters('logAnalyticsWorkspaceId')]" }
                            }
                        }
                    }
                }
            }
        }
    }
    
    # Create the policy definition
    $policyJson = $policyDefinition | ConvertTo-Json -Depth 20
    
    try {
        $policy = New-AzPolicyDefinition `
            -Name $policyName `
            -DisplayName "Enable diagnostic settings for $resourceType" `
            -Policy $policyJson `
            -Mode "Indexed"
        
        # Assign the policy
        New-AzPolicyAssignment `
            -Name "$policyName-assignment" `
            -PolicyDefinition $policy `
            -Scope "/subscriptions/$subscriptionId" `
            -PolicyParameterObject @{
                "logAnalyticsWorkspaceId" = $workspaceResourceId
            } `
            -Location "westus2" `
            -IdentityType "SystemAssigned"
        
        Write-Host "✓ Created and assigned policy for $resourceType" -ForegroundColor Green
    } catch {
        Write-Warning "✗ Failed to create policy for $resourceType : $_"
    }
}
```

#### 4.3.3 Azure CLI Alternative for Policy Deployment

```bash
# Variables
WORKSPACE_ID="/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
SUBSCRIPTION_ID="<Atevet17-Subscription-ID>"

# Create a policy definition for all resources that support diagnostics
cat > all-resources-diagnostic-policy.json << 'EOF'
{
    "mode": "All",
    "parameters": {
        "logAnalyticsWorkspaceId": {
            "type": "String",
            "metadata": {
                "displayName": "Log Analytics Workspace ID",
                "description": "The resource ID of the Log Analytics workspace"
            }
        }
    },
    "policyRule": {
        "if": {
            "allOf": [
                {
                    "field": "type",
                    "notIn": [
                        "Microsoft.Resources/subscriptions",
                        "Microsoft.Resources/resourceGroups"
                    ]
                },
                {
                    "field": "location",
                    "notEquals": "global"
                }
            ]
        },
        "then": {
            "effect": "auditIfNotExists",
            "details": {
                "type": "Microsoft.Insights/diagnosticSettings",
                "existenceCondition": {
                    "field": "Microsoft.Insights/diagnosticSettings/workspaceId",
                    "equals": "[parameters('logAnalyticsWorkspaceId')]"
                }
            }
        }
    }
}
EOF

# Create the policy definition
az policy definition create \
    --name "audit-diagnostic-settings-all-resources" \
    --display-name "Audit diagnostic settings for all resources" \
    --description "Audits that diagnostic settings are configured for all resources" \
    --rules all-resources-diagnostic-policy.json \
    --mode All

# Assign the policy
az policy assignment create \
    --name "audit-diagnostics-assignment" \
    --policy "audit-diagnostic-settings-all-resources" \
    --scope "/subscriptions/$SUBSCRIPTION_ID" \
    --params "{\"logAnalyticsWorkspaceId\": {\"value\": \"$WORKSPACE_ID\"}}"
```

#### 4.3.4 Using Azure Policy Initiative from Azure Portal

1. Go to **Azure Policy** in the Azure Portal
2. Navigate to **Definitions** → **Initiative definitions**
3. Click **+ Initiative definition**
4. Fill in the basics:
   - Name: `Enable Diagnostic Settings for All Resources`
   - Category: `Monitoring`
5. Add policies for each resource type you want to cover
6. Go to **Assignments** → **Assign initiative**
7. Select the initiative and assign to the subscription scope
8. Configure parameters (Log Analytics Workspace ID)
9. Enable remediation to fix existing non-compliant resources

#### 4.3.5 Remediation for Existing Resources

After assigning policies, create remediation tasks to apply diagnostic settings to existing resources:

```powershell
# Get all non-compliant resources
$nonCompliantResources = Get-AzPolicyState `
    -SubscriptionId "<Atevet17-Subscription-ID>" `
    -Filter "ComplianceState eq 'NonCompliant'"

# Create remediation task for each policy assignment
$policyAssignments = Get-AzPolicyAssignment -Scope "/subscriptions/<Atevet17-Subscription-ID>"

foreach ($assignment in $policyAssignments) {
    if ($assignment.Properties.DisplayName -like "*diagnostic*") {
        Start-AzPolicyRemediation `
            -Name "remediate-$($assignment.Name)" `
            -PolicyAssignmentId $assignment.PolicyAssignmentId `
            -Scope "/subscriptions/<Atevet17-Subscription-ID>"
        
        Write-Host "Started remediation for: $($assignment.Properties.DisplayName)"
    }
}
```

Or via Azure CLI:

```bash
# List policy assignments
az policy assignment list --scope "/subscriptions/<Atevet17-Subscription-ID>" --query "[?contains(displayName, 'diagnostic')]"

# Create remediation task
az policy remediation create \
    --name "remediate-diagnostics" \
    --policy-assignment "<policy-assignment-id>" \
    --resource-group "" \
    --scope "/subscriptions/<Atevet17-Subscription-ID>"
```

#### 4.3.6 Monitor Policy Compliance

Track the compliance status of your diagnostic settings policies:

```powershell
# Get compliance summary
Get-AzPolicyStateSummary -SubscriptionId "<Atevet17-Subscription-ID>" |
    Select-Object -ExpandProperty PolicyAssignments |
    Where-Object { $_.PolicyAssignmentId -like "*diagnostic*" } |
    Format-Table PolicyAssignmentId, Results

# Get detailed non-compliant resources
Get-AzPolicyState -SubscriptionId "<Atevet17-Subscription-ID>" `
    -Filter "ComplianceState eq 'NonCompliant'" |
    Select-Object ResourceId, PolicyDefinitionName, ComplianceState |
    Format-Table
```

**KQL Query for Policy Compliance:**

```kusto
AzureActivity
| where OperationNameValue contains "Microsoft.PolicyInsights"
| where TimeGenerated > ago(7d)
| summarize count() by OperationNameValue, ActivityStatusValue
| order by count_ desc
```

#### 4.3.7 Complete Resource Type Coverage Table

The following table shows all Azure resource types that support diagnostic settings and their policy definition IDs:

| Resource Type | Built-in Policy ID | Log Categories |
|--------------|-------------------|----------------|
| Key Vault | `951af2fa-529b-416e-ab6e-066fd85ac459` | AuditEvent |
| Storage Account | `b4fe1a3b-0715-4c6c-a5ea-ffc33cf823cb` | StorageRead, StorageWrite, StorageDelete |
| App Service | `b607c5de-e7d9-4eee-9e5c-83f1bcee4fa0` | AppServiceHTTPLogs, AppServiceAppLogs |
| SQL Database | `b79fa14e-238a-4c2d-b376-442ce508fc84` | SQLInsights, Errors, Deadlocks |
| NSG | `c9c29499-c1d1-4195-99bd-2ec9e3a9dc89` | NetworkSecurityGroupEvent |
| AKS | `6c66c325-74c8-42fd-a286-a74b0e2939d8` | kube-apiserver, kube-audit |
| Cosmos DB | `7f89b1eb-583c-429a-8828-af049802c1d9` | DataPlaneRequests |
| Event Hub | `1f6e93e8-6b31-41b1-83f6-36e93f1e0d8f` | OperationalLogs |
| Service Bus | `04d53d87-841c-4f23-8a5b-21564380b55e` | OperationalLogs |
| Application Gateway | `e8e3c3d0-3b3a-4b3a-8b3a-3b3a3b3a3b3a` | AccessLog, PerformanceLog |
| Azure Firewall | `a]f3a3b3a-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | AzureFirewallApplicationRule |
| Load Balancer | `b3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | LoadBalancerAlertEvent |
| Virtual Network | `c3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | VMProtectionAlerts |
| API Management | `d3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | GatewayLogs |
| Logic Apps | `e3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | WorkflowRuntime |
| Container Registry | `f3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | ContainerRegistryRepositoryEvents |
| Redis Cache | `g3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | ConnectedClientList |
| Data Factory | `h3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | ActivityRuns, PipelineRuns |
| Cognitive Services | `i3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | Audit, RequestResponse |
| SignalR | `j3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | AllLogs |
| Batch Account | `k3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | ServiceLog |
| IoT Hub | `l3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | Connections, DeviceTelemetry |
| Stream Analytics | `m3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | Execution, Authoring |
| Machine Learning | `n3a3b3a3-3b3a-3b3a-3b3a-3b3a3b3a3b3a` | AmlComputeClusterEvent |

> **Note:** Use `Get-AzPolicyDefinition | Where-Object { $_.Properties.DisplayName -like "*diagnostic*" }` to get the current list of built-in policies for diagnostic settings.

---

## Step 5: Configure Microsoft Entra ID (Azure AD) Logs

Microsoft Entra ID (formerly Azure Active Directory) logs are **tenant-level logs** and require a different configuration approach than Azure resource logs. These logs are critical for security monitoring and include sign-in activities, directory changes, and identity protection events.

> **Important:** Entra ID diagnostic settings must be configured **in the source tenant (Atevet17)** by a user with appropriate permissions in that tenant. Azure Lighthouse does NOT provide access to configure Entra ID diagnostic settings cross-tenant.

### 5.1 Prerequisites for Entra ID Logs

| Requirement | Description |
|-------------|-------------|
| **License** | Microsoft Entra ID P1 or P2 license (for sign-in logs) |
| **Permissions** | Global Administrator or Security Administrator in Atevet17 |
| **Log Analytics Workspace** | Can send to workspace in Atevet12 (cross-tenant supported for data destination) |

### 5.2 Available Entra ID Log Categories

| Log Category | Description | License Required |
|--------------|-------------|------------------|
| **AuditLogs** | Directory changes (user/group/app management) | Free |
| **SignInLogs** | Interactive user sign-ins | P1/P2 |
| **NonInteractiveUserSignInLogs** | Sign-ins by clients on behalf of users | P1/P2 |
| **ServicePrincipalSignInLogs** | Sign-ins by apps and service principals | P1/P2 |
| **ManagedIdentitySignInLogs** | Sign-ins by managed identities | P1/P2 |
| **ProvisioningLogs** | User provisioning activities | P1/P2 |
| **ADFSSignInLogs** | AD FS sign-in logs | P1/P2 |
| **RiskyUsers** | Users flagged for risk | P2 |
| **UserRiskEvents** | Risk detection events | P2 |
| **RiskyServicePrincipals** | Service principals flagged for risk | P2 |
| **ServicePrincipalRiskEvents** | Service principal risk events | P2 |
| **EnrichedOffice365AuditLogs** | Enriched Office 365 audit logs | E5 |
| **MicrosoftGraphActivityLogs** | Microsoft Graph API activity | P1/P2 |
| **NetworkAccessTrafficLogs** | Global Secure Access traffic logs | P1/P2 |

### 5.3 Configure Entra ID Diagnostic Settings via Azure Portal

**This must be done by an administrator in Atevet17:**

1. Sign in to the **Azure Portal** as a Global Administrator in **Atevet17**
2. Navigate to **Microsoft Entra ID** (or search for "Azure Active Directory")
3. Go to **Monitoring** → **Diagnostic settings**
4. Click **+ Add diagnostic setting**
5. Configure the setting:
   - **Diagnostic setting name:** `SendEntraLogsToAtevet12`
   - **Log categories:** Select all applicable categories:
     - ☑️ AuditLogs
     - ☑️ SignInLogs
     - ☑️ NonInteractiveUserSignInLogs
     - ☑️ ServicePrincipalSignInLogs
     - ☑️ ManagedIdentitySignInLogs
     - ☑️ ProvisioningLogs
     - ☑️ RiskyUsers (if P2)
     - ☑️ UserRiskEvents (if P2)
     - ☑️ MicrosoftGraphActivityLogs
   - **Destination details:**
     - ☑️ Send to Log Analytics workspace
     - **Subscription:** Select the Atevet12 subscription
     - **Log Analytics workspace:** `law-central-atevet12`
6. Click **Save**

### 5.4 Configure Entra ID Diagnostic Settings via PowerShell

```powershell
# Connect to Atevet17 tenant as Global Administrator
Connect-AzAccount -TenantId "<Atevet17-Tenant-ID>"

# Get the Entra ID resource ID (this is a special format for tenant-level resources)
$entraResourceId = "/providers/Microsoft.aadiam/diagnosticSettings"

# Log Analytics Workspace in Atevet12
$workspaceResourceId = "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

# Define log categories to enable
$logs = @(
    @{ Category = "AuditLogs"; Enabled = $true },
    @{ Category = "SignInLogs"; Enabled = $true },
    @{ Category = "NonInteractiveUserSignInLogs"; Enabled = $true },
    @{ Category = "ServicePrincipalSignInLogs"; Enabled = $true },
    @{ Category = "ManagedIdentitySignInLogs"; Enabled = $true },
    @{ Category = "ProvisioningLogs"; Enabled = $true },
    @{ Category = "RiskyUsers"; Enabled = $true },
    @{ Category = "UserRiskEvents"; Enabled = $true },
    @{ Category = "RiskyServicePrincipals"; Enabled = $true },
    @{ Category = "ServicePrincipalRiskEvents"; Enabled = $true },
    @{ Category = "MicrosoftGraphActivityLogs"; Enabled = $true }
)

# Create the diagnostic setting using REST API (PowerShell cmdlets have limited support)
$token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

$body = @{
    properties = @{
        workspaceId = $workspaceResourceId
        logs = $logs
    }
} | ConvertTo-Json -Depth 10

$uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/SendEntraLogsToAtevet12?api-version=2017-04-01"

Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $body
```

### 5.5 Configure Entra ID Diagnostic Settings via Azure CLI

```bash
# Login to Atevet17 tenant
az login --tenant "<Atevet17-Tenant-ID>"

# Variables
WORKSPACE_ID="/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

# Create diagnostic setting for Entra ID
az rest --method PUT \
    --uri "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/SendEntraLogsToAtevet12?api-version=2017-04-01" \
    --body "{
        \"properties\": {
            \"workspaceId\": \"$WORKSPACE_ID\",
            \"logs\": [
                {\"category\": \"AuditLogs\", \"enabled\": true},
                {\"category\": \"SignInLogs\", \"enabled\": true},
                {\"category\": \"NonInteractiveUserSignInLogs\", \"enabled\": true},
                {\"category\": \"ServicePrincipalSignInLogs\", \"enabled\": true},
                {\"category\": \"ManagedIdentitySignInLogs\", \"enabled\": true},
                {\"category\": \"ProvisioningLogs\", \"enabled\": true},
                {\"category\": \"RiskyUsers\", \"enabled\": true},
                {\"category\": \"UserRiskEvents\", \"enabled\": true},
                {\"category\": \"MicrosoftGraphActivityLogs\", \"enabled\": true}
            ]
        }
    }"
```

### 5.6 Configure via Microsoft Graph API

For automation scenarios, you can use Microsoft Graph API:

```powershell
# Install Microsoft Graph PowerShell module
Install-Module Microsoft.Graph -Scope CurrentUser

# Connect with required permissions
Connect-MgGraph -TenantId "<Atevet17-Tenant-ID>" -Scopes "AuditLog.Read.All", "Directory.Read.All"

# Note: Diagnostic settings configuration requires Azure Resource Manager API
# Use the REST API approach shown above for programmatic configuration
```

### 5.7 Verify Entra ID Diagnostic Settings

**Via Azure Portal:**
1. Go to **Microsoft Entra ID** → **Monitoring** → **Diagnostic settings**
2. Verify the setting `SendEntraLogsToAtevet12` is listed and enabled

**Via Azure CLI:**
```bash
az rest --method GET \
    --uri "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01"
```

**Via PowerShell:**
```powershell
$token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
$headers = @{ "Authorization" = "Bearer $token" }
$uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01"
Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
```

### 5.8 Query Entra ID Logs in Log Analytics

Once configured, Entra ID logs will appear in the following tables in your Log Analytics workspace:

| Table Name | Description |
|------------|-------------|
| `SigninLogs` | Interactive user sign-ins |
| `AADNonInteractiveUserSignInLogs` | Non-interactive sign-ins |
| `AADServicePrincipalSignInLogs` | Service principal sign-ins |
| `AADManagedIdentitySignInLogs` | Managed identity sign-ins |
| `AuditLogs` | Directory audit events |
| `AADProvisioningLogs` | Provisioning activities |
| `AADRiskyUsers` | Risky user information |
| `AADUserRiskEvents` | User risk events |
| `AADRiskyServicePrincipals` | Risky service principals |
| `AADServicePrincipalRiskEvents` | Service principal risk events |
| `MicrosoftGraphActivityLogs` | Graph API activity |

**Sample Queries:**

**Query Sign-in Logs from Atevet17:**
```kusto
SigninLogs
| where TimeGenerated > ago(24h)
| where AADTenantId == "<Atevet17-Tenant-ID>"
| summarize count() by ResultType, AppDisplayName
| order by count_ desc
```

**Query Failed Sign-ins:**
```kusto
SigninLogs
| where TimeGenerated > ago(24h)
| where ResultType != "0"  // Non-successful sign-ins
| project TimeGenerated, UserPrincipalName, AppDisplayName, ResultType, ResultDescription, IPAddress, Location
| order by TimeGenerated desc
```

**Query Audit Logs for User Changes:**
```kusto
AuditLogs
| where TimeGenerated > ago(24h)
| where Category == "UserManagement"
| project TimeGenerated, OperationName, Result, InitiatedBy, TargetResources
| order by TimeGenerated desc
```

**Query Risky Sign-ins:**
```kusto
SigninLogs
| where TimeGenerated > ago(7d)
| where RiskLevelDuringSignIn in ("high", "medium")
| project TimeGenerated, UserPrincipalName, RiskLevelDuringSignIn, RiskState, IPAddress, Location
| order by TimeGenerated desc
```

**Query Service Principal Sign-ins:**
```kusto
AADServicePrincipalSignInLogs
| where TimeGenerated > ago(24h)
| summarize count() by ServicePrincipalName, ResourceDisplayName
| order by count_ desc
```

**Query Microsoft Graph API Activity:**
```kusto
MicrosoftGraphActivityLogs
| where TimeGenerated > ago(24h)
| summarize count() by RequestMethod, ApiVersion
| order by count_ desc
```

### 5.9 Important Considerations for Cross-Tenant Entra ID Logs

1. **Permissions:** The user configuring diagnostic settings must be a Global Administrator or Security Administrator in Atevet17. Azure Lighthouse delegation does NOT grant these permissions.

2. **Licensing:** Sign-in logs require Microsoft Entra ID P1 or P2 licenses. Without proper licensing, only AuditLogs will be available.

3. **Data Residency:** Entra ID logs will be stored in the Log Analytics workspace region (Atevet12). Ensure this complies with your data residency requirements.

4. **Latency:** Entra ID logs may have a latency of 2-15 minutes before appearing in Log Analytics.

5. **Retention:** Configure appropriate retention in your Log Analytics workspace. Entra ID logs can be verbose, especially sign-in logs.

6. **Cost:** Sign-in logs can generate significant data volume. Monitor ingestion costs and consider:
   - Using Basic Logs tier for high-volume tables
   - Filtering unnecessary log categories
   - Setting appropriate retention periods

### 5.10 Automate Entra ID Diagnostic Settings with ARM Template

For repeatable deployments, use this ARM template:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "settingName": {
            "type": "string",
            "defaultValue": "SendEntraLogsToAtevet12"
        },
        "workspaceId": {
            "type": "string",
            "metadata": {
                "description": "Resource ID of the Log Analytics workspace"
            }
        }
    },
    "resources": [
        {
            "type": "microsoft.aadiam/diagnosticSettings",
            "apiVersion": "2017-04-01",
            "name": "[parameters('settingName')]",
            "properties": {
                "workspaceId": "[parameters('workspaceId')]",
                "logs": [
                    { "category": "AuditLogs", "enabled": true },
                    { "category": "SignInLogs", "enabled": true },
                    { "category": "NonInteractiveUserSignInLogs", "enabled": true },
                    { "category": "ServicePrincipalSignInLogs", "enabled": true },
                    { "category": "ManagedIdentitySignInLogs", "enabled": true },
                    { "category": "ProvisioningLogs", "enabled": true },
                    { "category": "RiskyUsers", "enabled": true },
                    { "category": "UserRiskEvents", "enabled": true },
                    { "category": "RiskyServicePrincipals", "enabled": true },
                    { "category": "ServicePrincipalRiskEvents", "enabled": true },
                    { "category": "MicrosoftGraphActivityLogs", "enabled": true }
                ]
            }
        }
    ]
}
```

**Deploy the template:**
```bash
# Deploy at tenant level (requires Global Administrator)
az deployment tenant create \
    --name "EntraIDDiagnostics" \
    --location "westus2" \
    --template-file "entra-diagnostic-settings.json" \
    --parameters workspaceId="/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
```

---

## Step 6: Configure Microsoft 365 Audit Logs

Microsoft 365 (Office 365) Audit Logs capture user and admin activities across Microsoft 365 services including Exchange Online, SharePoint Online, OneDrive for Business, Microsoft Teams, Power Platform, and more. These logs are essential for security monitoring, compliance, and incident investigation.

> **Important:** Microsoft 365 Audit Logs are separate from Azure resource logs and Microsoft Entra ID logs. They require configuration through the Microsoft 365 Compliance Center or Microsoft Sentinel, and cannot be configured via Azure Lighthouse delegation.

### 6.1 Prerequisites for Microsoft 365 Audit Logs

| Requirement | Description |
|-------------|-------------|
| **License** | Microsoft 365 E3/E5, Office 365 E3/E5, or standalone audit license |
| **Permissions** | Global Administrator or Compliance Administrator in Atevet17 |
| **Audit Logging** | Must be enabled in Microsoft 365 (enabled by default for most tenants) |
| **Retention** | E3: 90 days, E5: 1 year (up to 10 years with add-on) |

### 6.2 Available Microsoft 365 Log Categories

| Service | Log Types | Description |
|---------|-----------|-------------|
| **Exchange Online** | Mailbox audit, Admin audit | Email access, mailbox changes, admin operations |
| **SharePoint Online** | File operations, Sharing | Document access, sharing, site administration |
| **OneDrive for Business** | File operations, Sync | File access, sync activities, sharing |
| **Microsoft Teams** | Team operations, Channel, Chat | Team creation, membership, meetings, messaging |
| **Azure AD** | User management, App consent | Directory changes (also in Entra ID logs) |
| **Power Platform** | Power Apps, Power Automate | App usage, flow executions |
| **Microsoft Defender** | Security alerts, Incidents | Threat detection, security events |
| **eDiscovery** | Search, Export, Hold | Legal discovery activities |
| **Data Loss Prevention** | Policy matches, Overrides | DLP policy violations |
| **Information Protection** | Label changes, Access | Sensitivity label activities |
| **Compliance Manager** | Assessment activities | Compliance score changes |

### 6.3 Enable Microsoft 365 Audit Logging

**Verify Audit Logging is Enabled:**

```powershell
# Connect to Exchange Online PowerShell
Install-Module -Name ExchangeOnlineManagement -Force
Connect-ExchangeOnline -UserPrincipalName admin@atevet17.onmicrosoft.com

# Check if unified audit logging is enabled
Get-AdminAuditLogConfig | Format-List UnifiedAuditLogIngestionEnabled

# Enable if not already enabled
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true
```

**Via Microsoft 365 Admin Center:**
1. Go to https://compliance.microsoft.com
2. Navigate to **Audit** (under Solutions)
3. If you see "Start recording user and admin activity", click it to enable
4. Audit logging is enabled when you see the search interface

### 6.4 Option A: Stream M365 Logs to Log Analytics via Microsoft Sentinel

The recommended approach for cross-tenant log collection is using Microsoft Sentinel with the Office 365 data connector.

**Step 1: Enable Microsoft Sentinel in Atevet12**

```powershell
# Connect to Atevet12
Connect-AzAccount -TenantId "<Atevet12-Tenant-ID>"

# Enable Microsoft Sentinel on the Log Analytics workspace
$workspace = Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName "rg-central-logging" `
    -Name "law-central-atevet12"

# Install Sentinel solution
Set-AzSentinel -ResourceGroupName "rg-central-logging" -WorkspaceName "law-central-atevet12"
```

**Step 2: Configure Office 365 Data Connector in Atevet17**

Since M365 logs are tenant-specific, you need to configure the connector in Atevet17 and export to Atevet12's workspace:

```powershell
# This requires configuration in Atevet17 tenant
# Connect to Atevet17
Connect-AzAccount -TenantId "<Atevet17-Tenant-ID>"

# Create a Log Analytics workspace in Atevet17 (if not exists) or use cross-tenant export
# Option 1: Use Sentinel in Atevet17 with data export to Atevet12
# Option 2: Use Management Activity API (see Option B below)
```

**Via Azure Portal (Atevet17):**
1. Go to **Microsoft Sentinel** in Atevet17 (or create a workspace)
2. Navigate to **Data connectors**
3. Search for **Office 365**
4. Click **Open connector page**
5. Select the log types to enable:
   - ☑️ Exchange
   - ☑️ SharePoint
   - ☑️ Teams
6. Click **Apply Changes**

**Cross-Tenant Export Configuration:**

To send M365 logs from Atevet17 to Atevet12's Log Analytics workspace:

```powershell
# In Atevet17, create a data export rule to Atevet12's workspace
# Note: This requires the workspace in Atevet12 to allow cross-tenant data ingestion

# Get the workspace resource ID in Atevet12
$targetWorkspaceId = "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

# Create diagnostic setting for M365 (via Azure AD diagnostic settings)
# M365 audit logs flow through the Office 365 connector, not diagnostic settings
```

### 6.5 Option B: Use Management Activity API for Custom Integration

For more control over M365 log collection, use the Office 365 Management Activity API:

**Step 1: Register an Application in Atevet17**

```powershell
# Connect to Atevet17 Azure AD
Connect-AzureAD -TenantId "<Atevet17-Tenant-ID>"

# Create app registration
$app = New-AzureADApplication -DisplayName "M365-Audit-Log-Collector" `
    -IdentifierUris "https://atevet17.onmicrosoft.com/m365-audit-collector"

# Create service principal
$sp = New-AzureADServicePrincipal -AppId $app.AppId

# Create client secret
$secret = New-AzureADApplicationPasswordCredential -ObjectId $app.ObjectId `
    -CustomKeyIdentifier "M365AuditSecret" `
    -EndDate (Get-Date).AddYears(2)

Write-Host "Application ID: $($app.AppId)"
Write-Host "Client Secret: $($secret.Value)"
Write-Host "Tenant ID: <Atevet17-Tenant-ID>"
```

**Step 2: Grant API Permissions**

```powershell
# Required permissions for Office 365 Management APIs
$requiredPermissions = @(
    "ActivityFeed.Read",           # Read activity data
    "ActivityFeed.ReadDlp",        # Read DLP policy events
    "ServiceHealth.Read"           # Read service health
)

# Grant permissions via Azure Portal:
# 1. Go to Azure AD > App registrations > M365-Audit-Log-Collector
# 2. API permissions > Add permission > Office 365 Management APIs
# 3. Select: ActivityFeed.Read, ActivityFeed.ReadDlp, ServiceHealth.Read
# 4. Grant admin consent
```

**Step 3: Start Subscriptions to Content Types**

```powershell
# PowerShell script to start M365 audit log subscriptions
$tenantId = "<Atevet17-Tenant-ID>"
$clientId = "<Application-ID>"
$clientSecret = "<Client-Secret>"

# Get OAuth token
$tokenBody = @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSecret
    resource      = "https://manage.office.com"
}

$tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/token" `
    -Method Post -Body $tokenBody
$accessToken = $tokenResponse.access_token

$headers = @{
    "Authorization" = "Bearer $accessToken"
    "Content-Type"  = "application/json"
}

# Content types to subscribe to
$contentTypes = @(
    "Audit.AzureActiveDirectory",
    "Audit.Exchange",
    "Audit.SharePoint",
    "Audit.General",
    "DLP.All"
)

# Start subscriptions
foreach ($contentType in $contentTypes) {
    $uri = "https://manage.office.com/api/v1.0/$tenantId/activity/feed/subscriptions/start?contentType=$contentType"
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers
        Write-Host "✓ Started subscription for $contentType" -ForegroundColor Green
    } catch {
        Write-Warning "✗ Failed to start subscription for $contentType : $_"
    }
}
```

**Step 4: Create Azure Function to Collect and Forward Logs**

Create an Azure Function in Atevet12 to pull logs from Atevet17 and ingest into Log Analytics:

```powershell
# Function App code (PowerShell)
# Save as run.ps1 in your Azure Function

param($Timer)

$tenantId = $env:M365_TENANT_ID
$clientId = $env:M365_CLIENT_ID
$clientSecret = $env:M365_CLIENT_SECRET
$workspaceId = $env:LOG_ANALYTICS_WORKSPACE_ID
$workspaceKey = $env:LOG_ANALYTICS_WORKSPACE_KEY

# Get OAuth token for M365 Management API
$tokenBody = @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSecret
    resource      = "https://manage.office.com"
}

$tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/token" `
    -Method Post -Body $tokenBody
$accessToken = $tokenResponse.access_token

$headers = @{
    "Authorization" = "Bearer $accessToken"
    "Content-Type"  = "application/json"
}

# Content types to collect
$contentTypes = @("Audit.AzureActiveDirectory", "Audit.Exchange", "Audit.SharePoint", "Audit.General")

foreach ($contentType in $contentTypes) {
    # Get available content
    $startTime = (Get-Date).AddHours(-24).ToString("yyyy-MM-ddTHH:mm:ss")
    $endTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    
    $uri = "https://manage.office.com/api/v1.0/$tenantId/activity/feed/subscriptions/content?contentType=$contentType&startTime=$startTime&endTime=$endTime"
    
    try {
        $contentList = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
        
        foreach ($content in $contentList) {
            # Get the actual audit records
            $auditRecords = Invoke-RestMethod -Uri $content.contentUri -Method Get -Headers $headers
            
            # Send to Log Analytics
            $logType = "M365AuditLog_$($contentType.Replace('.', '_'))"
            Send-LogAnalyticsData -WorkspaceId $workspaceId -WorkspaceKey $workspaceKey `
                -LogType $logType -Data $auditRecords
        }
    } catch {
        Write-Error "Failed to collect $contentType : $_"
    }
}

# Function to send data to Log Analytics
function Send-LogAnalyticsData {
    param(
        [string]$WorkspaceId,
        [string]$WorkspaceKey,
        [string]$LogType,
        [array]$Data
    )
    
    $json = $Data | ConvertTo-Json -Depth 10
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    
    $stringToHash = "$method`n$contentLength`n$contentType`nx-ms-date:$rfc1123date`n$resource"
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = "SharedKey ${WorkspaceId}:${encodedHash}"
    
    $uri = "https://$WorkspaceId.ods.opinsights.azure.com$resource`?api-version=2016-04-01"
    
    $headers = @{
        "Authorization"        = $authorization
        "Log-Type"            = $LogType
        "x-ms-date"           = $rfc1123date
        "time-generated-field" = "CreationTime"
    }
    
    Invoke-RestMethod -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body
}
```

### 6.6 Option C: Use Microsoft Graph API for Audit Logs

For programmatic access to M365 audit logs:

```powershell
# Install Microsoft Graph PowerShell
Install-Module Microsoft.Graph -Scope CurrentUser

# Connect with required permissions
Connect-MgGraph -TenantId "<Atevet17-Tenant-ID>" -Scopes "AuditLog.Read.All", "Directory.Read.All"

# Query directory audit logs (overlaps with Entra ID)
$auditLogs = Get-MgAuditLogDirectoryAudit -Top 100

# Query sign-in logs
$signInLogs = Get-MgAuditLogSignIn -Top 100

# Note: For Exchange, SharePoint, Teams specific logs, use Management Activity API
```

### 6.7 Configure Audit Log Retention in Microsoft 365

**Via Microsoft 365 Compliance Center:**
1. Go to https://compliance.microsoft.com
2. Navigate to **Audit** → **Audit retention policies**
3. Click **+ Create an audit retention policy**
4. Configure:
   - Policy name: `Extended Audit Retention`
   - Record types: Select all relevant types
   - Duration: Up to 10 years (with E5 or add-on license)
5. Click **Save**

**Via PowerShell:**
```powershell
# Connect to Security & Compliance PowerShell
Connect-IPPSSession -UserPrincipalName admin@atevet17.onmicrosoft.com

# Create audit retention policy
New-UnifiedAuditLogRetentionPolicy -Name "Extended Retention - All Logs" `
    -Description "Retain all audit logs for 1 year" `
    -RecordTypes @("ExchangeAdmin", "ExchangeItem", "SharePoint", "OneDrive", "MicrosoftTeams") `
    -RetentionDuration OneYear `
    -Priority 100
```

### 6.8 Query Microsoft 365 Audit Logs

**Via Microsoft 365 Compliance Center:**
1. Go to https://compliance.microsoft.com
2. Navigate to **Audit**
3. Set date range and filters
4. Click **Search**
5. Export results as needed

**Via PowerShell (Search-UnifiedAuditLog):**
```powershell
# Connect to Exchange Online
Connect-ExchangeOnline -UserPrincipalName admin@atevet17.onmicrosoft.com

# Search audit logs
$startDate = (Get-Date).AddDays(-7)
$endDate = Get-Date

# Search for all Exchange activities
$exchangeLogs = Search-UnifiedAuditLog -StartDate $startDate -EndDate $endDate `
    -RecordType ExchangeAdmin -ResultSize 5000

# Search for SharePoint file activities
$sharePointLogs = Search-UnifiedAuditLog -StartDate $startDate -EndDate $endDate `
    -RecordType SharePointFileOperation -ResultSize 5000

# Search for Teams activities
$teamsLogs = Search-UnifiedAuditLog -StartDate $startDate -EndDate $endDate `
    -RecordType MicrosoftTeams -ResultSize 5000

# Search for specific user activities
$userLogs = Search-UnifiedAuditLog -StartDate $startDate -EndDate $endDate `
    -UserIds "user@atevet17.onmicrosoft.com" -ResultSize 5000

# Export to CSV
$exchangeLogs | Export-Csv -Path "ExchangeAuditLogs.csv" -NoTypeInformation
```

### 6.9 M365 Audit Log Tables in Log Analytics

When using Microsoft Sentinel Office 365 connector, logs appear in these tables:

| Table Name | Description |
|------------|-------------|
| `OfficeActivity` | All Office 365 audit events |
| `SecurityEvent` | Security-related events |
| `SigninLogs` | Sign-in events (also from Entra ID) |

**Sample KQL Queries:**

**Query Exchange Mailbox Access:**
```kusto
OfficeActivity
| where TimeGenerated > ago(24h)
| where RecordType == "ExchangeItem"
| where Operation in ("MailItemsAccessed", "Send", "SendAs", "SendOnBehalf")
| project TimeGenerated, UserId, Operation, ClientIP, MailboxOwnerUPN, Subject
| order by TimeGenerated desc
```

**Query SharePoint File Operations:**
```kusto
OfficeActivity
| where TimeGenerated > ago(24h)
| where RecordType == "SharePointFileOperation"
| where Operation in ("FileDownloaded", "FileUploaded", "FileDeleted", "FileModified")
| project TimeGenerated, UserId, Operation, SourceFileName, Site_Url, ClientIP
| order by TimeGenerated desc
```

**Query Teams Activities:**
```kusto
OfficeActivity
| where TimeGenerated > ago(24h)
| where RecordType == "MicrosoftTeams"
| project TimeGenerated, UserId, Operation, TeamName, ChannelName, ClientIP
| order by TimeGenerated desc
```

**Query Suspicious Activities:**
```kusto
OfficeActivity
| where TimeGenerated > ago(7d)
| where Operation in ("Add-MailboxPermission", "Set-Mailbox", "New-InboxRule", "Set-InboxRule")
| project TimeGenerated, UserId, Operation, Parameters, ClientIP
| order by TimeGenerated desc
```

**Query External Sharing:**
```kusto
OfficeActivity
| where TimeGenerated > ago(24h)
| where RecordType == "SharePointSharingOperation"
| where Operation contains "Sharing"
| project TimeGenerated, UserId, Operation, TargetUserOrGroupName, Site_Url, SourceFileName
| order by TimeGenerated desc
```

### 6.10 Cross-Tenant M365 Log Collection Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ATEVET17 (Source Tenant)                          │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Microsoft 365 Services                            │   │
│  │  Exchange | SharePoint | Teams | OneDrive | Power Platform           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │              Microsoft 365 Unified Audit Log                         │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│              ┌─────────────────────┼─────────────────────┐                 │
│              ▼                     ▼                     ▼                 │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐         │
│  │ Option A:        │  │ Option B:        │  │ Option C:        │         │
│  │ Sentinel         │  │ Management       │  │ Graph API        │         │
│  │ Connector        │  │ Activity API     │  │                  │         │
│  └────────┬─────────┘  └────────┬─────────┘  └────────┬─────────┘         │
└───────────┼─────────────────────┼─────────────────────┼─────────────────────┘
            │                     │                     │
            │                     ▼                     │
            │         ┌──────────────────────┐          │
            │         │ Azure Function       │          │
            │         │ (Log Forwarder)      │          │
            │         └──────────┬───────────┘          │
            │                    │                      │
            ▼                    ▼                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ATEVET12 (Managing Tenant)                        │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Log Analytics Workspace                           │   │
│  │                    (law-central-atevet12)                            │   │
│  │                                                                       │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐               │   │
│  │  │OfficeActivity│  │M365AuditLog_ │  │ SigninLogs   │  ...          │   │
│  │  │              │  │ Exchange     │  │              │               │   │
│  │  └──────────────┘  └──────────────┘  └──────────────┘               │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.11 Important Considerations for M365 Audit Logs

1. **Licensing Requirements:**
   - E3/G3: 90-day audit log retention
   - E5/G5: 1-year default retention, up to 10 years with Advanced Audit
   - Some audit events require specific licenses (e.g., MailItemsAccessed requires E5)

2. **Latency:**
   - Audit logs may take 30 minutes to 24 hours to appear
   - Most logs appear within 60-90 minutes

3. **Data Volume:**
   - M365 audit logs can be very high volume
   - Consider filtering to essential events
   - Monitor Log Analytics ingestion costs

4. **Cross-Tenant Limitations:**
   - M365 audit logs cannot be directly sent to another tenant's Log Analytics
   - Requires intermediate collection (Sentinel connector, API, or Function)
   - Consider data residency and compliance requirements

5. **Permissions:**
   - Audit log access requires Global Admin, Compliance Admin, or Audit Log role
   - API access requires app registration with appropriate permissions

6. **Retention:**
   - Configure retention policies before logs expire
   - Export historical logs if needed before enabling new collection

---

## Step 7: Centralize Logs in Log Analytics Workspace

### 7.1 Verify Log Tables

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
| `SigninLogs` | Entra ID interactive sign-ins |
| `AADNonInteractiveUserSignInLogs` | Entra ID non-interactive sign-ins |
| `AADServicePrincipalSignInLogs` | Entra ID service principal sign-ins |
| `AuditLogs` | Entra ID audit events |
| `AADProvisioningLogs` | Entra ID provisioning logs |
| `AADRiskyUsers` | Entra ID risky users |
| `AADUserRiskEvents` | Entra ID user risk events |
| `OfficeActivity` | Microsoft 365 audit events |
| `M365AuditLog_*` | Custom M365 logs (if using API) |

### 7.2 Sample Queries

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

## Step 8: Verify Log Collection

### 8.1 Check Diagnostic Settings

```powershell
# List all diagnostic settings for a subscription
Get-AzDiagnosticSetting -SubscriptionId "<Atevet17-Subscription-ID>"

# List diagnostic settings for a specific resource
Get-AzDiagnosticSetting -ResourceId "<Resource-ID>"
```

### 8.2 Verify Data in Log Analytics

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

### 8.3 Monitor Data Ingestion

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
5. ✅ Configured Resource Diagnostic Logs (VMs, Key Vaults, Storage, and all other resource types)
6. ✅ Set up Azure Monitor Agent for VM-level logs
7. ✅ Configured Microsoft Entra ID (Azure AD) diagnostic logs (Sign-in, Audit, Risk events)
8. ✅ Configured Microsoft 365 Audit Logs (Exchange, SharePoint, Teams, OneDrive)
9. ✅ Set up Azure Policy for automatic diagnostic settings on new resources

**Next Steps:**
1. Set up alerts for critical events
2. Create dashboards for monitoring
3. Consider Microsoft Sentinel for advanced security analytics
4. Review and optimize log retention and costs

---

## Appendix: Complete Azure Log Types Reference

This appendix provides a comprehensive reference of all Azure log types that can be collected, their importance level, and whether they are covered in this guide.

### Log Categories Overview

| Log Category | Description | Priority | Covered in Guide |
|--------------|-------------|----------|------------------|
| **Subscription Activity Logs** | Control plane operations (ARM) | 🔴 Critical | ✅ Yes (Step 3) |
| **Microsoft Entra ID Logs** | Identity and access events | 🔴 Critical | ✅ Yes (Step 5) |
| **Resource Diagnostic Logs** | Data plane operations per resource | 🔴 Critical | ✅ Yes (Step 4) |
| **Azure Platform Logs** | Azure platform-level events | 🟡 Important | ✅ Yes (via Activity Logs) |
| **Microsoft Defender for Cloud** | Security alerts and recommendations | 🟡 Important | ⚠️ Partial |
| **Azure Policy Logs** | Policy compliance events | 🟡 Important | ✅ Yes (via Activity Logs) |
| **Microsoft 365 Audit Logs** | Office 365 activities | 🟡 Important | ✅ Yes (Step 6) |
| **Azure Service Health** | Service incidents and maintenance | 🟢 Optional | ✅ Yes (via Activity Logs) |
| **Cost Management Logs** | Billing and cost data | 🟢 Optional | ❌ No |

### Detailed Log Types Reference

#### 🔴 Critical Logs (Must Enable)

| Log Type | Source | Log Analytics Table | Priority | Notes |
|----------|--------|---------------------|----------|-------|
| Activity Logs | Subscription | `AzureActivity` | 🔴 Critical | All ARM operations |
| Sign-in Logs | Entra ID | `SigninLogs` | 🔴 Critical | Requires P1/P2 license |
| Audit Logs | Entra ID | `AuditLogs` | 🔴 Critical | Directory changes |
| Non-Interactive Sign-ins | Entra ID | `AADNonInteractiveUserSignInLogs` | 🔴 Critical | Background authentications |
| Service Principal Sign-ins | Entra ID | `AADServicePrincipalSignInLogs` | 🔴 Critical | App authentications |
| Key Vault Audit | Key Vault | `AzureDiagnostics` | 🔴 Critical | Secret/key access |
| Storage Account Logs | Storage | `StorageBlobLogs`, etc. | 🔴 Critical | Data access patterns |
| NSG Flow Logs | Network | `AzureNetworkAnalytics_CL` | 🔴 Critical | Network traffic |
| Firewall Logs | Azure Firewall | `AzureDiagnostics` | 🔴 Critical | Network security |

#### 🟡 Important Logs (Should Enable)

| Log Type | Source | Log Analytics Table | Priority | Notes |
|----------|--------|---------------------|----------|-------|
| Managed Identity Sign-ins | Entra ID | `AADManagedIdentitySignInLogs` | 🟡 Important | MI authentications |
| Provisioning Logs | Entra ID | `AADProvisioningLogs` | 🟡 Important | User provisioning |
| Risky Users | Entra ID | `AADRiskyUsers` | 🟡 Important | Requires P2 license |
| User Risk Events | Entra ID | `AADUserRiskEvents` | 🟡 Important | Requires P2 license |
| Graph API Activity | Entra ID | `MicrosoftGraphActivityLogs` | 🟡 Important | API calls |
| SQL Audit Logs | SQL Database | `AzureDiagnostics` | 🟡 Important | Database access |
| App Service Logs | App Service | `AppServiceHTTPLogs` | 🟡 Important | Web app access |
| AKS Logs | Kubernetes | `AzureDiagnostics` | 🟡 Important | Container orchestration |
| VM Performance | Virtual Machines | `Perf` | 🟡 Important | Resource utilization |
| VM Security Events | Virtual Machines | `Event` | 🟡 Important | Windows Security log |
| Defender Alerts | Defender for Cloud | `SecurityAlert` | 🟡 Important | Security threats |
| Policy Compliance | Azure Policy | `AzureActivity` | 🟡 Important | Compliance state |

#### 🟢 Optional Logs (Enable as Needed)

| Log Type | Source | Log Analytics Table | Priority | Notes |
|----------|--------|---------------------|----------|-------|
| Service Health | Azure | `AzureActivity` | 🟢 Optional | Service incidents |
| Advisor Recommendations | Azure Advisor | `AzureActivity` | 🟢 Optional | Best practices |
| Autoscale Events | Various | `AzureActivity` | 🟢 Optional | Scaling operations |
| Cosmos DB Logs | Cosmos DB | `AzureDiagnostics` | 🟢 Optional | Database operations |
| Event Hub Logs | Event Hubs | `AzureDiagnostics` | 🟢 Optional | Messaging |
| Service Bus Logs | Service Bus | `AzureDiagnostics` | 🟢 Optional | Messaging |
| Logic App Logs | Logic Apps | `AzureDiagnostics` | 🟢 Optional | Workflow execution |
| API Management Logs | APIM | `AzureDiagnostics` | 🟢 Optional | API gateway |
| CDN Logs | Azure CDN | `AzureDiagnostics` | 🟢 Optional | Content delivery |
| Front Door Logs | Front Door | `AzureDiagnostics` | 🟢 Optional | Global load balancing |

### Additional Log Sources Not Covered in This Guide

The following log sources require separate configuration and are not covered by Azure Lighthouse or standard diagnostic settings:

| Log Source | Description | Configuration Method | Priority |
|------------|-------------|---------------------|----------|
| **Microsoft 365 Unified Audit Log** | Exchange, SharePoint, Teams, OneDrive activities | Microsoft 365 Compliance Center or Microsoft Sentinel connector | 🟡 Important |
| **Microsoft Defender for Endpoint** | Endpoint detection and response | Microsoft 365 Defender portal or Sentinel connector | 🟡 Important |
| **Microsoft Defender for Identity** | On-premises AD monitoring | Defender for Identity portal or Sentinel connector | 🟡 Important |
| **Microsoft Defender for Cloud Apps** | Cloud app security (CASB) | Defender for Cloud Apps portal or Sentinel connector | 🟡 Important |
| **Microsoft Intune** | Device management logs | Intune portal or Sentinel connector | 🟢 Optional |
| **Azure DevOps** | CI/CD pipeline logs | Azure DevOps Auditing or Sentinel connector | 🟢 Optional |
| **GitHub Enterprise** | Repository and action logs | GitHub audit log streaming | 🟢 Optional |
| **Power Platform** | Power Apps, Power Automate logs | Power Platform admin center | 🟢 Optional |
| **Dynamics 365** | CRM/ERP application logs | Dynamics 365 admin center | 🟢 Optional |

### Microsoft Sentinel Data Connectors

If using Microsoft Sentinel, these additional connectors can enhance log collection:

| Connector | Log Types | Priority |
|-----------|-----------|----------|
| Azure Activity | Activity Logs | 🔴 Critical |
| Microsoft Entra ID | Sign-in, Audit, Provisioning | 🔴 Critical |
| Microsoft Entra ID Identity Protection | Risk events | 🟡 Important |
| Microsoft 365 Defender | Incidents, alerts | 🟡 Important |
| Microsoft Defender for Cloud | Security alerts | 🟡 Important |
| Microsoft Defender for Endpoint | Device events | 🟡 Important |
| Office 365 | Exchange, SharePoint, Teams | 🟡 Important |
| Azure Key Vault | Vault access | 🔴 Critical |
| Azure Firewall | Network logs | 🔴 Critical |
| Azure WAF | Web application firewall | 🟡 Important |
| DNS | DNS queries | 🟢 Optional |
| Syslog | Linux system logs | 🟡 Important |
| Windows Security Events | Windows event logs | 🟡 Important |
| Common Event Format (CEF) | Third-party security devices | 🟢 Optional |

### Log Retention Recommendations

| Log Type | Minimum Retention | Recommended Retention | Compliance Requirement |
|----------|-------------------|----------------------|------------------------|
| Sign-in Logs | 30 days | 90-365 days | SOC 2, ISO 27001 |
| Audit Logs | 30 days | 365 days | Most compliance frameworks |
| Activity Logs | 90 days | 365 days | Azure default |
| Security Logs | 90 days | 1-7 years | PCI-DSS, HIPAA |
| Resource Logs | 30 days | 90 days | Varies by resource |

### Quick Reference: What to Enable First

**Phase 1 - Immediate (Security Critical):**
1. ✅ Subscription Activity Logs
2. ✅ Entra ID Sign-in Logs
3. ✅ Entra ID Audit Logs
4. ✅ Key Vault Diagnostic Logs
5. ✅ NSG Flow Logs (if applicable)

**Phase 2 - Short Term (Within 30 days):**
1. ✅ All Entra ID log categories
2. ✅ Storage Account Diagnostic Logs
3. ✅ SQL/Database Audit Logs
4. ✅ Azure Firewall Logs (if applicable)
5. ✅ VM Security Event Logs

**Phase 3 - Medium Term (Within 90 days):**
1. ✅ All resource diagnostic logs via Azure Policy
2. ✅ Microsoft Defender for Cloud integration
3. ✅ Application-specific logs (App Service, AKS, etc.)

**Phase 4 - Long Term (As needed):**
1. ✅ Microsoft 365 audit logs (covered in Step 6)
2. ⬜ Third-party security tool integration
3. ⬜ Custom application logs

---

## Additional Resources

- [Azure Lighthouse Documentation](https://docs.microsoft.com/azure/lighthouse/)
- [Azure Monitor Documentation](https://docs.microsoft.com/azure/azure-monitor/)
- [Log Analytics Query Language (KQL)](https://docs.microsoft.com/azure/data-explorer/kusto/query/)
- [Azure Monitor Agent Documentation](https://docs.microsoft.com/azure/azure-monitor/agents/azure-monitor-agent-overview)
- [Diagnostic Settings Schema](https://docs.microsoft.com/azure/azure-monitor/essentials/resource-logs-schema)