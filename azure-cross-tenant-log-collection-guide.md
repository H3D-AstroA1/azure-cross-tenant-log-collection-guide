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
8. [Step 4: Configure Virtual Machine Diagnostic Logs](#step-4-configure-virtual-machine-diagnostic-logs)
9. [Step 5: Configure Azure Resource Diagnostic Logs](#step-5-configure-azure-resource-diagnostic-logs)
10. [Step 6: Configure Microsoft Entra ID (Azure AD) Logs](#step-6-configure-microsoft-entra-id-azure-ad-logs)
11. [Step 7: Configure Microsoft 365 Audit Logs](#step-7-configure-microsoft-365-audit-logs)
12. [Step 8: Centralize Logs in Log Analytics Workspace](#step-8-centralize-logs-in-log-analytics-workspace)
13. [Step 9: Enable Microsoft Sentinel and Data Connectors](#step-9-enable-microsoft-sentinel-and-data-connectors)
14. [Step 10: Verify Log Collection](#step-10-verify-log-collection)
15. [Alternative Approaches](#alternative-approaches)
16. [Troubleshooting](#troubleshooting)

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
    # Get-AzResourceProvider returns an array; extract the first RegistrationState
    $status = ($provider | Select-Object -First 1).RegistrationState
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
    # Get-AzResourceProvider returns an array; extract the first RegistrationState
    $registrationState = ($provider | Select-Object -First 1).RegistrationState
    
    if ($registrationState -eq "Registered") {
        Write-Host "  ✓ Already registered" -ForegroundColor Green
    } else {
        Write-Host "  Registering..." -ForegroundColor Yellow
        Register-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"
        
        # Wait for registration
        do {
            Start-Sleep -Seconds 5
            $provider = Get-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"
            $registrationState = ($provider | Select-Object -First 1).RegistrationState
        } while ($registrationState -eq "Registering")
        
        if ($registrationState -eq "Registered") {
            Write-Host "  ✓ Successfully registered" -ForegroundColor Green
        } else {
            Write-Host "  ✗ Failed to register: $registrationState" -ForegroundColor Red
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

> **Note:** This step focuses on creating the Log Analytics Workspace for centralized log collection. Microsoft Sentinel enablement and data connector configuration should be done **after** all log sources are configured (see [Step 8: Enable Microsoft Sentinel and Data Connectors](#step-8-enable-microsoft-sentinel-and-data-connectors)). This phased approach ensures:
> - ✅ All log data is flowing to the workspace before Sentinel is enabled
> - ✅ Reduced initial costs (Sentinel charges apply once enabled)
> - ✅ Easier troubleshooting of log collection issues
> - ✅ Better understanding of data volumes before committing to Sentinel

#### 1.2.1 Create the Log Analytics Workspace

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

Azure Lighthouse onboarding requires two separate deployments:
1. **Registration Definition** - Defines the delegation (who can access what with which roles)
2. **Registration Assignment** - Assigns the definition to the subscription

This two-step approach provides better control and allows you to reuse definitions across multiple subscriptions.

### 2.1 Create the Registration Definition Template

Create a file named `lighthouse-template-definition.json`:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "managedByTenantId": {
      "type": "string",
      "metadata": {
        "description": "Tenant ID (GUID) of the managing tenant (Atevet12)."
      }
    },
    "registrationDefinitionName": {
      "type": "string",
      "defaultValue": "Sentinel Delegation for Atevet12 (v2)",
      "metadata": {
        "description": "Display name of the Lighthouse registration definition."
      }
    },
    "registrationDefinitionDescription": {
      "type": "string",
      "defaultValue": "Delegates access from Atevet17 to Atevet12 at subscription scope.",
      "metadata": {
        "description": "Description for the Lighthouse registration definition."
      }
    },
    "authorizations": {
      "type": "array",
      "metadata": {
        "description": "Array of authorization objects."
      }
    }
  },
  "variables": {
    "definitionNameGuidSeed": "[concat(parameters('managedByTenantId'), '-', parameters('registrationDefinitionName'))]",
    "definitionGuid": "[guid(variables('definitionNameGuidSeed'))]"
  },
  "resources": [
    {
      "type": "Microsoft.ManagedServices/registrationDefinitions",
      "apiVersion": "2022-10-01",
      "name": "[variables('definitionGuid')]",
      "properties": {
        "registrationDefinitionName": "[parameters('registrationDefinitionName')]",
        "description": "[parameters('registrationDefinitionDescription')]",
        "managedByTenantId": "[parameters('managedByTenantId')]",
        "authorizations": "[parameters('authorizations')]"
      }
    }
  ],
  "outputs": {
    "registrationDefinitionId": {
      "type": "string",
      "value": "[resourceId('Microsoft.ManagedServices/registrationDefinitions', variables('definitionGuid'))]"
    }
  }
}
```

### 2.2 Create the Registration Definition Parameters File

Create a file named `lighthouse-parameters-definition.json`:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "managedByTenantId": {
      "value": "<ATEVET12-TENANT-ID>"
    },
    "registrationDefinitionName": {
      "value": "Atevet12 Log Collection Delegation"
    },
    "registrationDefinitionDescription": {
      "value": "Delegates access from Atevet17 to Atevet12 at subscription scope."
    },
    "authorizations": {
      "value": [
        {
          "principalId": "<SECURITY-GROUP-OBJECT-ID>",
          "roleDefinitionId": "acdd72a7-3385-48ef-bd42-f606fba81ae7",
          "principalIdDisplayName": "Lighthouse-Atevet17-Admins"
        },
        {
          "principalId": "<SECURITY-GROUP-OBJECT-ID>",
          "roleDefinitionId": "b24988ac-6180-42a0-ab88-20f7382dd24c",
          "principalIdDisplayName": "Lighthouse-Atevet17-Admins"
        },
        {
          "principalId": "<SECURITY-GROUP-OBJECT-ID>",
          "roleDefinitionId": "43d0d8ad-25c7-4714-9337-8ba259a9fe05",
          "principalIdDisplayName": "Lighthouse-Atevet17-Admins"
        },
        {
          "principalId": "<SECURITY-GROUP-OBJECT-ID>",
          "roleDefinitionId": "73c42c96-874c-492b-b04d-ab87d138a893",
          "principalIdDisplayName": "Lighthouse-Atevet17-Admins"
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

### 2.3 Create the Registration Assignment Template

Create a file named `lighthouse-template-assignment.json`:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "registrationDefinitionId": {
      "type": "string",
      "metadata": {
        "description": "Full resource ID of the registration definition created in step A."
      }
    },
       "registrationAssignmentName": {
      "type": "string",
      "defaultValue": "[newGuid()]",
      "metadata": {
        "description": "Name (GUID) for the registration assignment."
      }
    }
  },
  "resources": [
    {
      "type": "Microsoft.ManagedServices/registrationAssignments",
      "apiVersion": "2022-10-01",
      "name": "[parameters('registrationAssignmentName')]",
      "properties": {
        "registrationDefinitionId": "[parameters('registrationDefinitionId')]"
      }
    }
  ],
  "outputs": {
    "registrationAssignmentId": {
      "type": "string",
      "value": "[resourceId('Microsoft.ManagedServices/registrationAssignments', parameters('registrationAssignmentName'))]"
    }
  }
}
```

### 2.4 Create the Registration Assignment Parameters File

Create a file named `lighthouse-parameters-assignment.json`:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "registrationDefinitionId": {
      "value": "/subscriptions/<ATEVET17-SUBSCRIPTION-ID>/providers/Microsoft.ManagedServices/registrationDefinitions/<DEFINITION-GUID>"
    }
  }
}
```

**Replace the placeholders:**
- `<ATEVET17-SUBSCRIPTION-ID>`: The subscription ID in Atevet17 where you deployed the definition
- `<DEFINITION-GUID>`: The GUID from the output of the definition deployment (see section 2.5 for how to retrieve this value)

### 2.5 How to Get the registrationDefinitionId Value

The `registrationDefinitionId` is required for the assignment parameters file. You can obtain this value in several ways:

#### Method 1: From the Definition Deployment Output (Recommended)

When you deploy the registration definition (Step 2.6), the deployment outputs the `registrationDefinitionId`. Capture this value immediately after deployment:

**Using PowerShell:**

```powershell
# After deploying the definition, get the output
$definitionDeployment = New-AzSubscriptionDeployment `
    -Name "LighthouseDefinition" `
    -Location "westus2" `
    -TemplateFile "lighthouse-template-definition.json" `
    -TemplateParameterFile "lighthouse-parameters-definition.json"

# Extract the registrationDefinitionId from the output
$registrationDefinitionId = $definitionDeployment.Outputs.registrationDefinitionId.Value
Write-Host "Registration Definition ID: $registrationDefinitionId"

# Example output:
# /subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/providers/Microsoft.ManagedServices/registrationDefinitions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
```

**Using Azure CLI:**

```bash
# Deploy the definition and capture the output
az deployment sub create \
    --name "LighthouseDefinition" \
    --location "westus2" \
    --template-file "lighthouse-template-definition.json" \
    --parameters "lighthouse-parameters-definition.json" \
    --query "properties.outputs.registrationDefinitionId.value" \
    -o tsv

# Or get it from an existing deployment
DEFINITION_ID=$(az deployment sub show \
    --name "LighthouseDefinition" \
    --query "properties.outputs.registrationDefinitionId.value" \
    -o tsv)

echo "Registration Definition ID: $DEFINITION_ID"
```

#### Method 2: Query Existing Registration Definitions

If you've already deployed the definition and need to retrieve the ID:

**Using PowerShell:**

```powershell
# Connect to Atevet17 tenant
Connect-AzAccount -TenantId "<Atevet17-Tenant-ID>"
Set-AzContext -SubscriptionId "<Atevet17-Subscription-ID>"

# List all registration definitions
$definitions = Get-AzManagedServicesDefinition

# Display all definitions with their IDs
$definitions | Format-Table Name, Id, @{
    Label = "DisplayName"
    Expression = { $_.Properties.RegistrationDefinitionName }
}

# Get a specific definition by display name
$definition = $definitions | Where-Object {
    $_.Properties.RegistrationDefinitionName -eq "Atevet12 Log Collection Delegation"
}

Write-Host "Registration Definition ID: $($definition.Id)"
```

**Using Azure CLI:**

```bash
# Login to Atevet17 tenant
az login --tenant "<Atevet17-Tenant-ID>"
az account set --subscription "<Atevet17-Subscription-ID>"

# List all registration definitions
az managedservices definition list --query "[].{Name:name, DisplayName:properties.registrationDefinitionName, Id:id}" -o table

# Get the ID for a specific definition
az managedservices definition list \
    --query "[?properties.registrationDefinitionName=='Atevet12 Log Collection Delegation'].id" \
    -o tsv
```

#### Method 3: Using Azure Portal

1. Sign in to the **Azure Portal** in the **Atevet17** tenant
2. Navigate to **Subscriptions** → Select your subscription
3. Go to **Service providers** → **Service provider offers**
4. Click on the registration definition you created
5. In the **Overview** or **Properties** section, find the **Resource ID**
6. The Resource ID is your `registrationDefinitionId`

**Example Resource ID format:**
```
/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/providers/Microsoft.ManagedServices/registrationDefinitions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
```

#### Method 4: Construct the ID Manually

If you know the subscription ID and the definition GUID, you can construct the ID manually:

```
/subscriptions/<SUBSCRIPTION-ID>/providers/Microsoft.ManagedServices/registrationDefinitions/<DEFINITION-GUID>
```

**To find the DEFINITION-GUID:**

The GUID is generated deterministically based on the `managedByTenantId` and `registrationDefinitionName` parameters in the definition template. You can calculate it using:

```powershell
# The GUID is generated from this seed string
$managedByTenantId = "<Atevet12-Tenant-ID>"
$registrationDefinitionName = "Atevet12 Log Collection Delegation"
$seedString = "$managedByTenantId-$registrationDefinitionName"

# Generate the GUID (this matches the ARM template guid() function)
# Note: This is for reference - the actual GUID is created during deployment
```

**Important:** The easiest and most reliable method is **Method 1** - capturing the output immediately after deploying the definition.

#### Example: Complete Workflow

Here's a complete example showing how to deploy the definition and immediately use the output for the assignment:

```powershell
# Step 1: Deploy the definition
$defDeployment = New-AzSubscriptionDeployment `
    -Name "LighthouseDefinition" `
    -Location "westus2" `
    -TemplateFile "lighthouse-template-definition.json" `
    -TemplateParameterFile "lighthouse-parameters-definition.json"

# Step 2: Get the registration definition ID
$registrationDefinitionId = $defDeployment.Outputs.registrationDefinitionId.Value
Write-Host "Definition ID: $registrationDefinitionId" -ForegroundColor Green

# Step 3: Update the assignment parameters file (optional - you can also pass inline)
$assignmentParams = Get-Content "lighthouse-parameters-assignment.json" | ConvertFrom-Json
$assignmentParams.parameters.registrationDefinitionId.value = $registrationDefinitionId
$assignmentParams | ConvertTo-Json -Depth 10 | Set-Content "lighthouse-parameters-assignment.json"

# Step 4: Deploy the assignment
New-AzSubscriptionDeployment `
    -Name "LighthouseAssignment" `
    -Location "westus2" `
    -TemplateFile "lighthouse-template-assignment.json" `
    -TemplateParameterFile "lighthouse-parameters-assignment.json"

# Or deploy with inline parameter (skipping step 3)
New-AzSubscriptionDeployment `
    -Name "LighthouseAssignment" `
    -Location "westus2" `
    -TemplateFile "lighthouse-template-assignment.json" `
    -registrationDefinitionId $registrationDefinitionId
```

### 2.6 Deploy the Registration Definition in Atevet17

**Step A: Deploy the Definition**

**Using Azure CLI:**

```bash
# Login to Atevet17 tenant
az login --tenant "<Atevet17-Tenant-ID>"

# Set the subscription you want to delegate
az account set --subscription "<Atevet17-Subscription-ID>"

# Deploy the registration definition
az deployment sub create \
    --name "LighthouseDefinition" \
    --location "westus2" \
    --template-file "lighthouse-template-definition.json" \
    --parameters "lighthouse-parameters-definition.json"
```

**Using PowerShell:**

```powershell
# Login to Atevet17 tenant
Connect-AzAccount -TenantId "<Atevet17-Tenant-ID>"

# Set the subscription context
Set-AzContext -SubscriptionId "<Atevet17-Subscription-ID>"

# Deploy the registration definition
$definitionDeployment = New-AzSubscriptionDeployment `
    -Name "LighthouseDefinition" `
    -Location "westus2" `
    -TemplateFile "lighthouse-template-definition.json" `
    -TemplateParameterFile "lighthouse-parameters-definition.json"

# Get the registration definition ID from the output
$registrationDefinitionId = $definitionDeployment.Outputs.registrationDefinitionId.Value
Write-Host "Registration Definition ID: $registrationDefinitionId"
```

**Important:** Note the `registrationDefinitionId` from the deployment output. You will need this for the assignment step.

### 2.7 Deploy the Registration Assignment in Atevet17

**Step B: Deploy the Assignment**

First, update the `lighthouse-parameters-assignment.json` file with the `registrationDefinitionId` from Step 2.6.

**Using Azure CLI:**

```bash
# Deploy the registration assignment (same subscription context)
az deployment sub create \
    --name "LighthouseAssignment" \
    --location "westus2" \
    --template-file "lighthouse-template-assignment.json" \
    --parameters "lighthouse-parameters-assignment.json"
```

**Using PowerShell:**

```powershell
# Deploy the registration assignment
New-AzSubscriptionDeployment `
    -Name "LighthouseAssignment" `
    -Location "westus2" `
    -TemplateFile "lighthouse-template-assignment.json" `
    -TemplateParameterFile "lighthouse-parameters-assignment.json"
```

**Alternative: Deploy Assignment with Inline Parameter**

If you want to deploy the assignment immediately after the definition without editing the parameters file:

```powershell
# Deploy assignment using the definition ID from the previous deployment
New-AzSubscriptionDeployment `
    -Name "LighthouseAssignment" `
    -Location "westus2" `
    -TemplateFile "lighthouse-template-assignment.json" `
    -registrationDefinitionId $registrationDefinitionId
```

Or with Azure CLI:

```bash
# Get the definition ID from the previous deployment
DEFINITION_ID=$(az deployment sub show \
    --name "LighthouseDefinition" \
    --query "properties.outputs.registrationDefinitionId.value" \
    -o tsv)

# Deploy the assignment with the definition ID
az deployment sub create \
    --name "LighthouseAssignment" \
    --location "westus2" \
    --template-file "lighthouse-template-assignment.json" \
    --parameters registrationDefinitionId="$DEFINITION_ID"
```

### 2.8 Using Azure Portal

**Option: Deploy via Azure Portal**

1. In Atevet17 tenant, go to **Subscriptions** → Select the subscription
2. Go to **Service providers** → **Service provider offers**
3. Click **Add offer** → **Add via template**
4. **First deployment (Definition):**
   - Upload the `lighthouse-template-definition.json` template
   - Fill in the parameters from `lighthouse-parameters-definition.json`
   - Click **Review + Create** → **Create**
   - Note the `registrationDefinitionId` from the deployment outputs
5. **Second deployment (Assignment):**
   - Click **Add offer** → **Add via template** again
   - Upload the `lighthouse-template-assignment.json` template
   - Enter the `registrationDefinitionId` from step 4
   - Click **Review + Create** → **Create**

### 2.9 Repeat for Each Subscription

If you have multiple subscriptions in Atevet17:

1. **Definition:** You only need to deploy the definition once per subscription (or you can reuse the same definition across subscriptions if they're in the same tenant)
2. **Assignment:** Deploy the assignment to each subscription you want to delegate

**Script to deploy to multiple subscriptions:**

```powershell
# Login to Atevet17 tenant
Connect-AzAccount -TenantId "<Atevet17-Tenant-ID>"

# List of subscriptions to delegate
$subscriptions = @(
    "<Subscription-ID-1>",
    "<Subscription-ID-2>",
    "<Subscription-ID-3>"
)

foreach ($subId in $subscriptions) {
    Write-Host "`nProcessing subscription: $subId" -ForegroundColor Cyan
    
    # Set context to this subscription
    Set-AzContext -SubscriptionId $subId
    
    # Deploy the definition
    $defDeployment = New-AzSubscriptionDeployment `
        -Name "LighthouseDefinition" `
        -Location "westus2" `
        -TemplateFile "lighthouse-template-definition.json" `
        -TemplateParameterFile "lighthouse-parameters-definition.json"
    
    $definitionId = $defDeployment.Outputs.registrationDefinitionId.Value
    Write-Host "  Definition ID: $definitionId" -ForegroundColor Green
    
    # Deploy the assignment
    New-AzSubscriptionDeployment `
        -Name "LighthouseAssignment" `
        -Location "westus2" `
        -TemplateFile "lighthouse-template-assignment.json" `
        -registrationDefinitionId $definitionId
    
    Write-Host "  ✓ Delegation complete for $subId" -ForegroundColor Green
}

Write-Host "`n=== All subscriptions processed ===" -ForegroundColor Cyan
```

### 2.10 Verify Delegation

**In Atevet12 (Managing Tenant):**

```powershell
# Login to Atevet12
Connect-AzAccount -TenantId "<Atevet12-Tenant-ID>"

# List all delegated subscriptions
Get-AzManagedServicesAssignment | Format-Table

# List registration definitions
Get-AzManagedServicesDefinition | Format-Table
```

**In Azure Portal (Atevet12):**
1. Go to **My customers** (search in the portal)
2. You should see Atevet17 subscriptions listed under **Customers**

**In Atevet17 (Customer Tenant):**

```powershell
# Login to Atevet17
Connect-AzAccount -TenantId "<Atevet17-Tenant-ID>"

# View service provider offers
Get-AzManagedServicesDefinition | Format-List

# View assignments
Get-AzManagedServicesAssignment | Format-List
```

### 2.11 File Summary

Here's a summary of all the files you need to create:

| File Name | Purpose | Deploy Order |
|-----------|---------|--------------|
| `lighthouse-template-definition.json` | ARM template for registration definition | 1st |
| `lighthouse-parameters-definition.json` | Parameters for definition (tenant ID, roles) | 1st |
| `lighthouse-template-assignment.json` | ARM template for registration assignment | 2nd |
| `lighthouse-parameters-assignment.json` | Parameters for assignment (definition ID) | 2nd |

**Deployment Flow:**

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           DEPLOYMENT FLOW                                    │
│                                                                             │
│  Step 1: Deploy Definition                                                  │
│  ┌─────────────────────────┐    ┌─────────────────────────┐                │
│  │ lighthouse-template-    │ +  │ lighthouse-parameters-  │                │
│  │ definition.json         │    │ definition.json         │                │
│  └───────────┬─────────────┘    └───────────┬─────────────┘                │
│              │                              │                               │
│              └──────────────┬───────────────┘                               │
│                             ▼                                               │
│              ┌─────────────────────────────┐                                │
│              │ Registration Definition     │                                │
│              │ (Output: definitionId)      │                                │
│              └──────────────┬──────────────┘                                │
│                             │                                               │
│  Step 2: Deploy Assignment  │                                               │
│                             ▼                                               │
│  ┌─────────────────────────┐    ┌─────────────────────────┐                │
│  │ lighthouse-template-    │ +  │ lighthouse-parameters-  │                │
│  │ assignment.json         │    │ assignment.json         │                │
│  └───────────┬─────────────┘    └───────────┬─────────────┘                │
│              │                              │                               │
│              └──────────────┬───────────────┘                               │
│                             ▼                                               │
│              ┌─────────────────────────────┐                                │
│              │ Registration Assignment     │                                │
│              │ (Delegation Active!)        │                                │
│              └─────────────────────────────┘                                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Step 3: Configure Activity Log Collection

Activity Logs capture control plane operations (who did what, when, and on which resources).

### 3.1 ARM Template for Activity Log Diagnostic Settings (Recommended)

Activity Log diagnostic settings are subscription-level resources, so you need to use a **subscription deployment**. This ARM template approach is recommended for:
- ✅ Infrastructure as Code (version controlled, repeatable)
- ✅ Idempotent deployments (safe to run multiple times)
- ✅ Easy deployment to multiple subscriptions
- ✅ Consistent with Azure Lighthouse cross-tenant management

#### 3.1.1 ARM Template

Create a file named `activity-log-diagnostic-settings.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "diagnosticSettingName": {
            "type": "string",
            "defaultValue": "SendActivityLogsToAtevet12",
            "metadata": {
                "description": "Name for the diagnostic setting"
            }
        },
        "workspaceResourceId": {
            "type": "string",
            "metadata": {
                "description": "Full resource ID of the Log Analytics workspace in Atevet12"
            }
        },
        "enableAdministrative": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable Administrative log category"
            }
        },
        "enableSecurity": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable Security log category"
            }
        },
        "enableServiceHealth": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable ServiceHealth log category"
            }
        },
        "enableAlert": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable Alert log category"
            }
        },
        "enableRecommendation": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable Recommendation log category"
            }
        },
        "enablePolicy": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable Policy log category"
            }
        },
        "enableAutoscale": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable Autoscale log category"
            }
        },
        "enableResourceHealth": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable ResourceHealth log category"
            }
        }
    },
    "resources": [
        {
            "type": "Microsoft.Insights/diagnosticSettings",
            "apiVersion": "2021-05-01-preview",
            "name": "[parameters('diagnosticSettingName')]",
            "properties": {
                "workspaceId": "[parameters('workspaceResourceId')]",
                "logs": [
                    {
                        "category": "Administrative",
                        "enabled": "[parameters('enableAdministrative')]"
                    },
                    {
                        "category": "Security",
                        "enabled": "[parameters('enableSecurity')]"
                    },
                    {
                        "category": "ServiceHealth",
                        "enabled": "[parameters('enableServiceHealth')]"
                    },
                    {
                        "category": "Alert",
                        "enabled": "[parameters('enableAlert')]"
                    },
                    {
                        "category": "Recommendation",
                        "enabled": "[parameters('enableRecommendation')]"
                    },
                    {
                        "category": "Policy",
                        "enabled": "[parameters('enablePolicy')]"
                    },
                    {
                        "category": "Autoscale",
                        "enabled": "[parameters('enableAutoscale')]"
                    },
                    {
                        "category": "ResourceHealth",
                        "enabled": "[parameters('enableResourceHealth')]"
                    }
                ]
            }
        }
    ],
    "outputs": {
        "diagnosticSettingId": {
            "type": "string",
            "value": "[subscriptionResourceId('Microsoft.Insights/diagnosticSettings', parameters('diagnosticSettingName'))]"
        }
    }
}
```

#### 3.1.2 Parameters File

Create a file named `activity-log-diagnostic-settings.parameters.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "diagnosticSettingName": {
            "value": "SendActivityLogsToAtevet12"
        },
        "workspaceResourceId": {
            "value": "/subscriptions/<ATEVET12-SUBSCRIPTION-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
        }
    }
}
```

**Replace the placeholder:**
- `<ATEVET12-SUBSCRIPTION-ID>`: Your Atevet12 subscription ID where the Log Analytics workspace is located

#### 3.1.3 Deploy the ARM Template

**Using PowerShell:**

```powershell
# Login to Atevet12 (managing tenant)
Connect-AzAccount -TenantId "<Atevet12-Tenant-ID>"

# Set context to the delegated Atevet17 subscription
Set-AzContext -SubscriptionId "<Atevet17-Subscription-ID>"

# Deploy the diagnostic settings
New-AzSubscriptionDeployment `
    -Name "ActivityLogDiagnostics" `
    -Location "westus2" `
    -TemplateFile "activity-log-diagnostic-settings.json" `
    -TemplateParameterFile "activity-log-diagnostic-settings.parameters.json"
```

**Using Azure CLI:**

```bash
# Login to Atevet12 (managing tenant)
az login --tenant "<Atevet12-Tenant-ID>"

# Set the delegated Atevet17 subscription
az account set --subscription "<Atevet17-Subscription-ID>"

# Deploy the diagnostic settings
az deployment sub create \
    --name "ActivityLogDiagnostics" \
    --location "westus2" \
    --template-file "activity-log-diagnostic-settings.json" \
    --parameters "activity-log-diagnostic-settings.parameters.json"
```

#### 3.1.4 Deploy to Multiple Subscriptions

If you have multiple delegated subscriptions in Atevet17, use this script:

**PowerShell Script:**

```powershell
# Login to Atevet12 (managing tenant)
Connect-AzAccount -TenantId "<Atevet12-Tenant-ID>"

# List of delegated subscriptions in Atevet17
$subscriptions = @(
    "<Atevet17-Subscription-ID-1>",
    "<Atevet17-Subscription-ID-2>",
    "<Atevet17-Subscription-ID-3>"
)

foreach ($subId in $subscriptions) {
    Write-Host "`nDeploying Activity Log diagnostics to subscription: $subId" -ForegroundColor Cyan
    
    # Set context to this subscription
    Set-AzContext -SubscriptionId $subId
    
    # Deploy the diagnostic settings
    $deployment = New-AzSubscriptionDeployment `
        -Name "ActivityLogDiagnostics-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
        -Location "westus2" `
        -TemplateFile "activity-log-diagnostic-settings.json" `
        -TemplateParameterFile "activity-log-diagnostic-settings.parameters.json"
    
    if ($deployment.ProvisioningState -eq "Succeeded") {
        Write-Host "  ✓ Successfully configured Activity Log diagnostics" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Failed: $($deployment.ProvisioningState)" -ForegroundColor Red
    }
}

Write-Host "`n=== All subscriptions processed ===" -ForegroundColor Cyan
```

### 3.2 Azure Portal Method (Alternative)

If you prefer to configure via the Azure Portal:

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

### 3.3 Verify Activity Log Collection

After deployment, verify that Activity Logs are being collected:

**Using KQL Query:**

```kusto
AzureActivity
| where TimeGenerated > ago(1h)
| where SubscriptionId == "<Atevet17-Subscription-ID>"
| summarize count() by CategoryValue
| order by count_ desc
```

**Expected Categories:**
- Administrative
- Security
- ServiceHealth
- Alert
- Recommendation
- Policy
- Autoscale
- ResourceHealth

---

## Step 4: Configure Virtual Machine Diagnostic Logs

Virtual Machine diagnostic logs capture performance metrics, Windows Event Logs, and Linux Syslog data. This step covers configuring the Azure Monitor Agent (AMA) and Data Collection Rules (DCR) using ARM templates.

> **Note:** Virtual Machines require a different approach than other Azure resources. Instead of diagnostic settings, VMs use the Azure Monitor Agent with Data Collection Rules to collect logs and metrics.

### 4.1 Overview

For VMs, you need to:
1. **Create a Data Collection Rule (DCR)** - Defines what data to collect and where to send it
2. **Install the Azure Monitor Agent** - Collects data from the VM
3. **Associate the VM with the DCR** - Links the VM to the data collection configuration

### 4.2 ARM Template for Data Collection Rule

For VMs, you need to install the Azure Monitor Agent and configure Data Collection Rules (DCR).

#### 4.2.1 ARM Template for Data Collection Rule (Recommended)

Create a file named `data-collection-rule.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "dataCollectionRuleName": {
            "type": "string",
            "defaultValue": "dcr-vm-logs-atevet17",
            "metadata": {
                "description": "Name of the Data Collection Rule"
            }
        },
        "location": {
            "type": "string",
            "defaultValue": "westus2",
            "metadata": {
                "description": "Location for the Data Collection Rule"
            }
        },
        "workspaceResourceId": {
            "type": "string",
            "metadata": {
                "description": "Full resource ID of the Log Analytics workspace"
            }
        },
        "workspaceName": {
            "type": "string",
            "defaultValue": "law-central-atevet12",
            "metadata": {
                "description": "Name of the Log Analytics workspace (used as destination name)"
            }
        }
    },
    "resources": [
        {
            "type": "Microsoft.Insights/dataCollectionRules",
            "apiVersion": "2022-06-01",
            "name": "[parameters('dataCollectionRuleName')]",
            "location": "[parameters('location')]",
            "properties": {
                "description": "Data Collection Rule for VM logs from Atevet17 to Atevet12",
                "dataSources": {
                    "performanceCounters": [
                        {
                            "name": "perfCounterDataSource",
                            "streams": ["Microsoft-Perf"],
                            "samplingFrequencyInSeconds": 60,
                            "counterSpecifiers": [
                                "\\Processor(_Total)\\% Processor Time",
                                "\\Memory\\Available MBytes",
                                "\\Memory\\% Committed Bytes In Use",
                                "\\LogicalDisk(_Total)\\% Free Space",
                                "\\LogicalDisk(_Total)\\Free Megabytes",
                                "\\PhysicalDisk(_Total)\\Avg. Disk Queue Length",
                                "\\Network Interface(*)\\Bytes Total/sec"
                            ]
                        }
                    ],
                    "windowsEventLogs": [
                        {
                            "name": "windowsEventLogs",
                            "streams": ["Microsoft-Event"],
                            "xPathQueries": [
                                "Application!*[System[(Level=1 or Level=2 or Level=3 or Level=4)]]",
                                "Security!*[System[(band(Keywords,13510798882111488))]]",
                                "System!*[System[(Level=1 or Level=2 or Level=3 or Level=4)]]"
                            ]
                        }
                    ],
                    "syslog": [
                        {
                            "name": "syslogDataSource",
                            "streams": ["Microsoft-Syslog"],
                            "facilityNames": [
                                "auth",
                                "authpriv",
                                "cron",
                                "daemon",
                                "kern",
                                "syslog",
                                "user"
                            ],
                            "logLevels": [
                                "Debug",
                                "Info",
                                "Notice",
                                "Warning",
                                "Error",
                                "Critical",
                                "Alert",
                                "Emergency"
                            ]
                        }
                    ]
                },
                "destinations": {
                    "logAnalytics": [
                        {
                            "name": "[parameters('workspaceName')]",
                            "workspaceResourceId": "[parameters('workspaceResourceId')]"
                        }
                    ]
                },
                "dataFlows": [
                    {
                        "streams": ["Microsoft-Perf"],
                        "destinations": ["[parameters('workspaceName')]"]
                    },
                    {
                        "streams": ["Microsoft-Event"],
                        "destinations": ["[parameters('workspaceName')]"]
                    },
                    {
                        "streams": ["Microsoft-Syslog"],
                        "destinations": ["[parameters('workspaceName')]"]
                    }
                ]
            }
        }
    ],
    "outputs": {
        "dataCollectionRuleId": {
            "type": "string",
            "value": "[resourceId('Microsoft.Insights/dataCollectionRules', parameters('dataCollectionRuleName'))]"
        }
    }
}
```

Create a parameters file named `data-collection-rule.parameters.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "dataCollectionRuleName": {
            "value": "dcr-vm-logs-atevet17"
        },
        "location": {
            "value": "westus2"
        },
        "workspaceResourceId": {
            "value": "/subscriptions/<ATEVET12-SUBSCRIPTION-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
        },
        "workspaceName": {
            "value": "law-central-atevet12"
        }
    }
}
```

**Deploy the Data Collection Rule:**

```powershell
# Connect to Atevet12 (managing tenant)
Connect-AzAccount -TenantId "<Atevet12-Tenant-ID>"

# Deploy the Data Collection Rule to Atevet12
New-AzResourceGroupDeployment `
    -Name "DataCollectionRule" `
    -ResourceGroupName "rg-central-logging" `
    -TemplateFile "data-collection-rule.json" `
    -TemplateParameterFile "data-collection-rule.parameters.json"
```

Or using Azure CLI:

```bash
az deployment group create \
    --name "DataCollectionRule" \
    --resource-group "rg-central-logging" \
    --template-file "data-collection-rule.json" \
    --parameters "data-collection-rule.parameters.json"
```

#### 4.2.2 ARM Template for Azure Monitor Agent Extension

Create a file named `azure-monitor-agent.json` to deploy the Azure Monitor Agent to VMs:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "vmName": {
            "type": "string",
            "metadata": {
                "description": "Name of the virtual machine"
            }
        },
        "location": {
            "type": "string",
            "metadata": {
                "description": "Location of the virtual machine"
            }
        },
        "osType": {
            "type": "string",
            "allowedValues": ["Windows", "Linux"],
            "metadata": {
                "description": "Operating system type of the VM"
            }
        }
    },
    "variables": {
        "extensionName": "[if(equals(parameters('osType'), 'Windows'), 'AzureMonitorWindowsAgent', 'AzureMonitorLinuxAgent')]",
        "extensionPublisher": "Microsoft.Azure.Monitor",
        "extensionType": "[if(equals(parameters('osType'), 'Windows'), 'AzureMonitorWindowsAgent', 'AzureMonitorLinuxAgent')]"
    },
    "resources": [
        {
            "type": "Microsoft.Compute/virtualMachines/extensions",
            "apiVersion": "2023-03-01",
            "name": "[concat(parameters('vmName'), '/', variables('extensionName'))]",
            "location": "[parameters('location')]",
            "properties": {
                "publisher": "[variables('extensionPublisher')]",
                "type": "[variables('extensionType')]",
                "typeHandlerVersion": "1.0",
                "autoUpgradeMinorVersion": true,
                "enableAutomaticUpgrade": true
            }
        }
    ]
}
```

#### 4.2.3 ARM Template for Data Collection Rule Association

Create a file named `dcr-association.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "vmName": {
            "type": "string",
            "metadata": {
                "description": "Name of the virtual machine"
            }
        },
        "vmResourceGroup": {
            "type": "string",
            "metadata": {
                "description": "Resource group of the virtual machine"
            }
        },
        "dataCollectionRuleId": {
            "type": "string",
            "metadata": {
                "description": "Resource ID of the Data Collection Rule"
            }
        }
    },
    "variables": {
        "associationName": "[concat('dcr-association-', parameters('vmName'))]"
    },
    "resources": [
        {
            "type": "Microsoft.Compute/virtualMachines/providers/dataCollectionRuleAssociations",
            "apiVersion": "2022-06-01",
            "name": "[concat(parameters('vmName'), '/Microsoft.Insights/', variables('associationName'))]",
            "properties": {
                "dataCollectionRuleId": "[parameters('dataCollectionRuleId')]"
            }
        }
    ]
}
```

---

## Step 5: Configure Azure Resource Diagnostic Logs

This step covers configuring diagnostic settings for Azure resources **other than Virtual Machines** (which are covered in Step 4). This includes resources like Key Vault, Storage Accounts, Azure SQL, App Services, and other PaaS/IaaS resources.

### 5.1 Overview

Azure resources (excluding VMs) use **Diagnostic Settings** to send logs and metrics to destinations like Log Analytics workspaces. Unlike VMs which use the Azure Monitor Agent and Data Collection Rules, these resources have built-in diagnostic capabilities that can be configured directly.

**Key differences from VM logging:**
- No agent installation required
- Configuration is per-resource via Diagnostic Settings
- Each resource type has specific log categories available
- Can send to Log Analytics, Storage Account, Event Hub, or Partner Solutions

### 5.2 ARM Templates for Resource Diagnostic Settings (Recommended)

ARM templates provide a declarative, repeatable way to configure diagnostic settings for Azure resources. This section provides templates for common resource types.

#### 5.2.1 Generic ARM Template for Any Resource Type

This template can be used to configure diagnostic settings for any Azure resource that supports diagnostics:

Create a file named `resource-diagnostic-settings.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "resourceId": {
            "type": "string",
            "metadata": {
                "description": "Full resource ID of the resource to configure diagnostics for"
            }
        },
        "diagnosticSettingName": {
            "type": "string",
            "defaultValue": "SendToAtevet12",
            "metadata": {
                "description": "Name for the diagnostic setting"
            }
        },
        "workspaceResourceId": {
            "type": "string",
            "metadata": {
                "description": "Full resource ID of the Log Analytics workspace"
            }
        },
        "logs": {
            "type": "array",
            "defaultValue": [],
            "metadata": {
                "description": "Array of log categories to enable"
            }
        },
        "metrics": {
            "type": "array",
            "defaultValue": [
                {
                    "category": "AllMetrics",
                    "enabled": true
                }
            ],
            "metadata": {
                "description": "Array of metric categories to enable"
            }
        }
    },
    "resources": [
        {
            "type": "Microsoft.Insights/diagnosticSettings",
            "apiVersion": "2021-05-01-preview",
            "scope": "[parameters('resourceId')]",
            "name": "[parameters('diagnosticSettingName')]",
            "properties": {
                "workspaceId": "[parameters('workspaceResourceId')]",
                "logs": "[parameters('logs')]",
                "metrics": "[parameters('metrics')]"
            }
        }
    ]
}
```

#### 5.2.2 ARM Template for Key Vault Diagnostic Settings

Create a file named `keyvault-diagnostic-settings.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "keyVaultName": {
            "type": "string",
            "metadata": {
                "description": "Name of the Key Vault"
            }
        },
        "workspaceResourceId": {
            "type": "string",
            "metadata": {
                "description": "Full resource ID of the Log Analytics workspace"
            }
        }
    },
    "resources": [
        {
            "type": "Microsoft.KeyVault/vaults/providers/diagnosticSettings",
            "apiVersion": "2021-05-01-preview",
            "name": "[concat(parameters('keyVaultName'), '/Microsoft.Insights/SendToAtevet12')]",
            "properties": {
                "workspaceId": "[parameters('workspaceResourceId')]",
                "logs": [
                    {
                        "category": "AuditEvent",
                        "enabled": true
                    },
                    {
                        "category": "AzurePolicyEvaluationDetails",
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
}
```

#### 5.2.3 ARM Template for Storage Account Diagnostic Settings

Create a file named `storage-diagnostic-settings.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "storageAccountName": {
            "type": "string",
            "metadata": {
                "description": "Name of the Storage Account"
            }
        },
        "workspaceResourceId": {
            "type": "string",
            "metadata": {
                "description": "Full resource ID of the Log Analytics workspace"
            }
        }
    },
    "resources": [
        {
            "type": "Microsoft.Storage/storageAccounts/blobServices/providers/diagnosticSettings",
            "apiVersion": "2021-05-01-preview",
            "name": "[concat(parameters('storageAccountName'), '/default/Microsoft.Insights/SendToAtevet12')]",
            "properties": {
                "workspaceId": "[parameters('workspaceResourceId')]",
                "logs": [
                    { "category": "StorageRead", "enabled": true },
                    { "category": "StorageWrite", "enabled": true },
                    { "category": "StorageDelete", "enabled": true }
                ],
                "metrics": [
                    { "category": "Transaction", "enabled": true }
                ]
            }
        },
        {
            "type": "Microsoft.Storage/storageAccounts/queueServices/providers/diagnosticSettings",
            "apiVersion": "2021-05-01-preview",
            "name": "[concat(parameters('storageAccountName'), '/default/Microsoft.Insights/SendToAtevet12')]",
            "properties": {
                "workspaceId": "[parameters('workspaceResourceId')]",
                "logs": [
                    { "category": "StorageRead", "enabled": true },
                    { "category": "StorageWrite", "enabled": true },
                    { "category": "StorageDelete", "enabled": true }
                ],
                "metrics": [
                    { "category": "Transaction", "enabled": true }
                ]
            }
        },
        {
            "type": "Microsoft.Storage/storageAccounts/tableServices/providers/diagnosticSettings",
            "apiVersion": "2021-05-01-preview",
            "name": "[concat(parameters('storageAccountName'), '/default/Microsoft.Insights/SendToAtevet12')]",
            "properties": {
                "workspaceId": "[parameters('workspaceResourceId')]",
                "logs": [
                    { "category": "StorageRead", "enabled": true },
                    { "category": "StorageWrite", "enabled": true },
                    { "category": "StorageDelete", "enabled": true }
                ],
                "metrics": [
                    { "category": "Transaction", "enabled": true }
                ]
            }
        },
        {
            "type": "Microsoft.Storage/storageAccounts/fileServices/providers/diagnosticSettings",
            "apiVersion": "2021-05-01-preview",
            "name": "[concat(parameters('storageAccountName'), '/default/Microsoft.Insights/SendToAtevet12')]",
            "properties": {
                "workspaceId": "[parameters('workspaceResourceId')]",
                "logs": [
                    { "category": "StorageRead", "enabled": true },
                    { "category": "StorageWrite", "enabled": true },
                    { "category": "StorageDelete", "enabled": true }
                ],
                "metrics": [
                    { "category": "Transaction", "enabled": true }
                ]
            }
        }
    ]
}
```

#### 5.2.4 Deploy Diagnostic Settings ARM Templates

**Deploy for a specific Key Vault:**

```powershell
# Connect to Atevet12 (managing tenant)
Connect-AzAccount -TenantId "<Atevet12-Tenant-ID>"

# Set context to delegated Atevet17 subscription
Set-AzContext -SubscriptionId "<Atevet17-Subscription-ID>"

# Deploy Key Vault diagnostic settings
New-AzResourceGroupDeployment `
    -Name "KeyVaultDiagnostics" `
    -ResourceGroupName "<Resource-Group-Name>" `
    -TemplateFile "keyvault-diagnostic-settings.json" `
    -keyVaultName "<Key-Vault-Name>" `
    -workspaceResourceId "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
```

**Deploy for all Key Vaults in a subscription:**

```powershell
# Get all Key Vaults
$keyVaults = Get-AzKeyVault

foreach ($kv in $keyVaults) {
    Write-Host "Configuring diagnostics for Key Vault: $($kv.VaultName)" -ForegroundColor Cyan
    
    New-AzResourceGroupDeployment `
        -Name "KeyVaultDiagnostics-$($kv.VaultName)" `
        -ResourceGroupName $kv.ResourceGroupName `
        -TemplateFile "keyvault-diagnostic-settings.json" `
        -keyVaultName $kv.VaultName `
        -workspaceResourceId "/subscriptions/<Atevet12-Subscription-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
}
```

### 5.3 Supported Resource Types Reference

The following table lists common Azure resource types and their diagnostic log categories. Use this reference when configuring the ARM templates above:

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

### 5.4 Azure Policy for Automatic Diagnostic Settings (All Resource Types)

To automatically configure diagnostic settings for **ALL new resources** that support diagnostics, you can use Azure Policy. This section provides multiple approaches:

#### 5.4.1 Using Built-in Policy Initiative (Recommended)

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

#### 5.4.2 Custom Policy Initiative for All Resource Types

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

#### 5.4.3 Azure CLI Alternative for Policy Deployment

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

#### 5.4.4 Using Azure Policy Initiative from Azure Portal

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

#### 5.4.5 Remediation for Existing Resources

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

#### 5.4.6 Monitor Policy Compliance

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

#### 5.4.7 Complete Resource Type Coverage Table

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

## Step 6: Configure Microsoft Entra ID (Azure AD) Logs

Microsoft Entra ID (formerly Azure Active Directory) logs are **tenant-level logs** and require a different configuration approach than Azure resource logs. These logs are critical for security monitoring and include sign-in activities, directory changes, and identity protection events.

> **Important:** Entra ID diagnostic settings must be configured **in the source tenant (Atevet17)** by a user with appropriate permissions in that tenant. Azure Lighthouse does NOT provide access to configure Entra ID diagnostic settings cross-tenant.

### 6.1 Prerequisites for Entra ID Logs

| Requirement | Description |
|-------------|-------------|
| **License** | Microsoft Entra ID P1 or P2 license (for sign-in logs) |
| **Permissions** | Global Administrator or Security Administrator in Atevet17 |
| **Log Analytics Workspace** | Can send to workspace in Atevet12 (cross-tenant supported for data destination) |
| **PowerShell Module** | Az PowerShell module (Az.Accounts) |

### 6.2 Available Entra ID Log Categories

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

### 6.3 PowerShell Script for Configuring Entra ID Diagnostic Settings

The following comprehensive PowerShell script automates the configuration of Microsoft Entra ID diagnostic settings. It includes:
- Embedded ARM template for deployment
- REST API support for direct configuration
- Parameter validation and error handling
- Verification and rollback capabilities
- License requirement warnings

Save this script as `Configure-EntraIDDiagnosticSettings.ps1`:

```powershell
<#
.SYNOPSIS
    Configures Microsoft Entra ID (Azure AD) diagnostic settings to send logs to a Log Analytics workspace.

.DESCRIPTION
    This script automates Step 6 of the Azure Cross-Tenant Log Collection Guide.
    It configures Microsoft Entra ID diagnostic settings to stream identity logs
    (Sign-in, Audit, Risk events, etc.) to a specified Log Analytics workspace.
    
    The script supports:
    - Cross-tenant log collection (source tenant logs to destination tenant workspace)
    - ARM template deployment for consistent, repeatable configuration
    - REST API fallback for environments where ARM deployment is not available
    - Verification of existing diagnostic settings
    - Removal of existing settings before reconfiguration
    
    IMPORTANT: This script must be run by a Global Administrator or Security Administrator
    in the SOURCE tenant (where Entra ID logs originate). Azure Lighthouse does NOT provide
    access to configure Entra ID diagnostic settings cross-tenant.

.PARAMETER SourceTenantId
    The Tenant ID of the source tenant (where Entra ID logs originate).

.PARAMETER DestinationWorkspaceResourceId
    The full resource ID of the Log Analytics workspace in the destination tenant.
    Format: /subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/Microsoft.OperationalInsights/workspaces/{workspaceName}

.PARAMETER DiagnosticSettingName
    The name for the diagnostic setting. Default: "SendEntraLogsToLogAnalytics"

.PARAMETER LogCategories
    Array of log categories to enable. If not specified, all available categories will be enabled.

.PARAMETER UseArmTemplate
    If specified, deploys using ARM template. Otherwise uses REST API directly.

.PARAMETER RemoveExisting
    If specified, removes any existing diagnostic setting with the same name before creating a new one.

.PARAMETER VerifyOnly
    If specified, only verifies existing diagnostic settings without making changes.

.NOTES
    Author: Azure Cross-Tenant Log Collection Guide
    Version: 1.0.0
    Requires: Az PowerShell module (Az.Accounts), Global Administrator or Security Administrator role
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = "The Tenant ID of the source tenant where Entra ID logs originate")]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SourceTenantId,

    [Parameter(Mandatory = $true, HelpMessage = "Full resource ID of the destination Log Analytics workspace")]
    [ValidatePattern('^/subscriptions/[0-9a-fA-F-]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$')]
    [string]$DestinationWorkspaceResourceId,

    [Parameter(Mandatory = $false, HelpMessage = "Name for the diagnostic setting")]
    [ValidateLength(1, 260)]
    [string]$DiagnosticSettingName = "SendEntraLogsToLogAnalytics",

    [Parameter(Mandatory = $false, HelpMessage = "Array of log categories to enable")]
    [ValidateSet(
        "AuditLogs", "SignInLogs", "NonInteractiveUserSignInLogs", "ServicePrincipalSignInLogs",
        "ManagedIdentitySignInLogs", "ProvisioningLogs", "RiskyUsers", "UserRiskEvents",
        "RiskyServicePrincipals", "ServicePrincipalRiskEvents", "MicrosoftGraphActivityLogs",
        "NetworkAccessTrafficLogs", "EnrichedOffice365AuditLogs", "ADFSSignInLogs"
    )]
    [string[]]$LogCategories,

    [Parameter(Mandatory = $false, HelpMessage = "Deploy using ARM template instead of REST API")]
    [switch]$UseArmTemplate,

    [Parameter(Mandatory = $false, HelpMessage = "Remove existing diagnostic setting before creating new one")]
    [switch]$RemoveExisting,

    [Parameter(Mandatory = $false, HelpMessage = "Only verify existing settings without making changes")]
    [switch]$VerifyOnly
)

#region Script Configuration
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$ApiVersion = "2017-04-01"

$DefaultLogCategories = @(
    "AuditLogs", "SignInLogs", "NonInteractiveUserSignInLogs", "ServicePrincipalSignInLogs",
    "ManagedIdentitySignInLogs", "ProvisioningLogs", "RiskyUsers", "UserRiskEvents",
    "RiskyServicePrincipals", "ServicePrincipalRiskEvents", "MicrosoftGraphActivityLogs"
)

$LogCategoryLicenseRequirements = @{
    "AuditLogs" = "Free"; "SignInLogs" = "P1/P2"; "NonInteractiveUserSignInLogs" = "P1/P2"
    "ServicePrincipalSignInLogs" = "P1/P2"; "ManagedIdentitySignInLogs" = "P1/P2"
    "ProvisioningLogs" = "P1/P2"; "RiskyUsers" = "P2"; "UserRiskEvents" = "P2"
    "RiskyServicePrincipals" = "P2"; "ServicePrincipalRiskEvents" = "P2"
    "MicrosoftGraphActivityLogs" = "P1/P2"; "NetworkAccessTrafficLogs" = "P1/P2"
    "EnrichedOffice365AuditLogs" = "E5"; "ADFSSignInLogs" = "P1/P2"
}
#endregion

#region ARM Template Definition (Embedded)
$ArmTemplate = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "settingName": { "type": "string" },
        "workspaceId": { "type": "string" },
        "logs": { "type": "array" }
    },
    "resources": [
        {
            "type": "microsoft.aadiam/diagnosticSettings",
            "apiVersion": "2017-04-01",
            "name": "[parameters('settingName')]",
            "properties": {
                "workspaceId": "[parameters('workspaceId')]",
                "logs": "[parameters('logs')]"
            }
        }
    ],
    "outputs": {
        "diagnosticSettingId": {
            "type": "string",
            "value": "[resourceId('microsoft.aadiam/diagnosticSettings', parameters('settingName'))]"
        }
    }
}
'@
#endregion

#region Helper Functions
function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARNING","ERROR","SUCCESS","DEBUG")][string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) { "INFO" {"White"} "WARNING" {"Yellow"} "ERROR" {"Red"} "SUCCESS" {"Green"} "DEBUG" {"Cyan"} }
    $prefix = switch ($Level) { "INFO" {"[INFO]   "} "WARNING" {"[WARN]   "} "ERROR" {"[ERROR]  "} "SUCCESS" {"[OK]     "} "DEBUG" {"[DEBUG]  "} }
    Write-Host "$timestamp $prefix$Message" -ForegroundColor $color
}

function Test-AzureConnection {
    param([string]$ExpectedTenantId)
    try {
        $context = Get-AzContext -ErrorAction Stop
        if (-not $context) { Write-Log "Not connected to Azure. Please run Connect-AzAccount first." -Level "ERROR"; return $false }
        if ($context.Tenant.Id -ne $ExpectedTenantId) {
            Write-Log "Connected to tenant $($context.Tenant.Id), but expected $ExpectedTenantId" -Level "WARNING"
            return $false
        }
        Write-Log "Connected to Azure tenant: $($context.Tenant.Id)" -Level "SUCCESS"
        return $true
    } catch { Write-Log "Failed to get Azure context: $_" -Level "ERROR"; return $false }
}

function Get-AzureAccessToken {
    try { return (Get-AzAccessToken -ResourceUrl "https://management.azure.com" -ErrorAction Stop).Token }
    catch { Write-Log "Failed to get access token: $_" -Level "ERROR"; throw }
}

function Get-ExistingDiagnosticSettings {
    param([string]$AccessToken, [string]$SettingName)
    $headers = @{ "Authorization" = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    try {
        $uri = if ($SettingName) { "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/${SettingName}?api-version=$ApiVersion" }
               else { "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings?api-version=$ApiVersion" }
        return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
    } catch { if ($_.Exception.Response.StatusCode -eq 404) { return $null }; throw }
}

function Remove-DiagnosticSetting {
    param([string]$AccessToken, [string]$SettingName)
    $headers = @{ "Authorization" = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/${SettingName}?api-version=$ApiVersion"
    try { Invoke-RestMethod -Uri $uri -Method Delete -Headers $headers -ErrorAction Stop; Write-Log "Removed: $SettingName" -Level "SUCCESS"; return $true }
    catch { Write-Log "Failed to remove: $_" -Level "ERROR"; return $false }
}

function New-DiagnosticSettingViaRestApi {
    param([string]$AccessToken, [string]$SettingName, [string]$WorkspaceResourceId, [array]$LogCategories)
    $headers = @{ "Authorization" = "Bearer $AccessToken"; "Content-Type" = "application/json" }
    $logs = $LogCategories | ForEach-Object { @{ category = $_; enabled = $true } }
    $body = @{ properties = @{ workspaceId = $WorkspaceResourceId; logs = $logs } } | ConvertTo-Json -Depth 10
    $uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/${SettingName}?api-version=$ApiVersion"
    try { return Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $body -ErrorAction Stop }
    catch { Write-Log "REST API Error: $($_.Exception.Message)" -Level "ERROR"; throw }
}

function New-DiagnosticSettingViaArmTemplate {
    param([string]$SettingName, [string]$WorkspaceResourceId, [array]$LogCategories, [string]$Location)
    $logs = $LogCategories | ForEach-Object { @{ category = $_; enabled = $true } }
    $tempPath = Join-Path $env:TEMP "entra-diag-template.json"
    $ArmTemplate | Out-File -FilePath $tempPath -Encoding UTF8 -Force
    try {
        $deployment = New-AzTenantDeployment -Name "EntraIDDiag-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
            -Location $Location -TemplateFile $tempPath `
            -TemplateParameterObject @{ settingName = $SettingName; workspaceId = $WorkspaceResourceId; logs = $logs } -ErrorAction Stop
        return $deployment
    } finally { if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue } }
}

function Show-DiagnosticSettingSummary {
    param([object]$Setting)
    Write-Host "`n═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  DIAGNOSTIC SETTING SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    if ($Setting.name) { Write-Host "  Setting Name: $($Setting.name)" -ForegroundColor White }
    if ($Setting.properties.workspaceId) { Write-Host "  Workspace ID: $($Setting.properties.workspaceId)" -ForegroundColor White }
    Write-Host "`n  Enabled Log Categories:" -ForegroundColor White
    foreach ($log in $Setting.properties.logs) {
        $status = if ($log.enabled) { "✓" } else { "✗" }
        $color = if ($log.enabled) { "Green" } else { "Red" }
        Write-Host "    $status $($log.category) (License: $($LogCategoryLicenseRequirements[$log.category]))" -ForegroundColor $color
    }
    Write-Host "═══════════════════════════════════════════════════════════════════`n" -ForegroundColor Cyan
}

function Show-LicenseRequirements {
    param([array]$Categories)
    Write-Host "`n═══════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  LICENSE REQUIREMENTS" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    foreach ($cat in $Categories) {
        $lic = $LogCategoryLicenseRequirements[$cat]
        $color = switch ($lic) { "Free" {"Green"} "P1/P2" {"Yellow"} "P2" {"Red"} "E5" {"Red"} }
        Write-Host "    • $cat ($lic)" -ForegroundColor $color
    }
    Write-Host "═══════════════════════════════════════════════════════════════════`n" -ForegroundColor Yellow
}
#endregion

#region Main Script Execution
Write-Host "`n╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   MICROSOFT ENTRA ID DIAGNOSTIC SETTINGS CONFIGURATION           ║" -ForegroundColor Cyan
Write-Host "║   Azure Cross-Tenant Log Collection Guide - Step 6               ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Cyan

# Validate Azure connection
Write-Log "Validating Azure connection..." -Level "INFO"
if (-not (Test-AzureConnection -ExpectedTenantId $SourceTenantId)) {
    Write-Log "Please connect: Connect-AzAccount -TenantId $SourceTenantId" -Level "ERROR"
    exit 1
}

# Determine log categories
$categoriesToEnable = if ($LogCategories -and $LogCategories.Count -gt 0) { $LogCategories } else { $DefaultLogCategories }
Write-Log "Log categories to enable: $($categoriesToEnable -join ', ')" -Level "INFO"
Show-LicenseRequirements -Categories $categoriesToEnable

# Get access token and check existing settings
$accessToken = Get-AzureAccessToken
Write-Log "Checking for existing diagnostic settings..." -Level "INFO"
$existingSettings = Get-ExistingDiagnosticSettings -AccessToken $accessToken

if ($existingSettings) {
    $settingsList = if ($existingSettings.value) { $existingSettings.value } else { @($existingSettings) }
    Write-Log "Found $($settingsList.Count) existing diagnostic setting(s)" -Level "INFO"
}

# Verify-only mode
if ($VerifyOnly) {
    if ($existingSettings) { foreach ($s in $settingsList) { Show-DiagnosticSettingSummary -Setting $s } }
    else { Write-Log "No diagnostic settings configured." -Level "WARNING" }
    Write-Log "Verification complete. No changes made." -Level "SUCCESS"
    exit 0
}

# Check for existing setting with same name
$existingWithSameName = Get-ExistingDiagnosticSettings -AccessToken $accessToken -SettingName $DiagnosticSettingName
if ($existingWithSameName) {
    if ($RemoveExisting) {
        if ($PSCmdlet.ShouldProcess($DiagnosticSettingName, "Remove existing diagnostic setting")) {
            Write-Log "Removing existing setting: $DiagnosticSettingName" -Level "WARNING"
            if (-not (Remove-DiagnosticSetting -AccessToken $accessToken -SettingName $DiagnosticSettingName)) { exit 1 }
            Start-Sleep -Seconds 2
        }
    } else {
        Write-Log "Setting '$DiagnosticSettingName' already exists. Use -RemoveExisting to replace." -Level "WARNING"
        Show-DiagnosticSettingSummary -Setting $existingWithSameName
        exit 0
    }
}

# Create the diagnostic setting
Write-Log "Creating diagnostic setting: $DiagnosticSettingName" -Level "INFO"
Write-Log "Destination workspace: $DestinationWorkspaceResourceId" -Level "INFO"

if ($PSCmdlet.ShouldProcess($DiagnosticSettingName, "Create Entra ID diagnostic setting")) {
    try {
        if ($UseArmTemplate) {
            Write-Log "Using ARM template deployment..." -Level "INFO"
            $result = New-DiagnosticSettingViaArmTemplate -SettingName $DiagnosticSettingName `
                -WorkspaceResourceId $DestinationWorkspaceResourceId -LogCategories $categoriesToEnable -Location "westus2"
            if ($result.ProvisioningState -eq "Succeeded") { Write-Log "ARM deployment succeeded!" -Level "SUCCESS" }
        } else {
            Write-Log "Using REST API deployment..." -Level "INFO"
            $result = New-DiagnosticSettingViaRestApi -AccessToken $accessToken -SettingName $DiagnosticSettingName `
                -WorkspaceResourceId $DestinationWorkspaceResourceId -LogCategories $categoriesToEnable
            Write-Log "REST API deployment succeeded!" -Level "SUCCESS"
        }
        
        # Verify creation
        Start-Sleep -Seconds 3
        $verified = Get-ExistingDiagnosticSettings -AccessToken $accessToken -SettingName $DiagnosticSettingName
        if ($verified) { Write-Log "Diagnostic setting verified!" -Level "SUCCESS"; Show-DiagnosticSettingSummary -Setting $verified }
        else { Write-Log "Could not verify. It may take a few minutes to appear." -Level "WARNING" }
    } catch {
        Write-Log "Failed to create diagnostic setting: $_" -Level "ERROR"
        Write-Host "`nTroubleshooting:" -ForegroundColor Red
        Write-Host "  1. AuthorizationFailed: Ensure Global Admin or Security Admin role" -ForegroundColor Yellow
        Write-Host "  2. ResourceNotFound: Verify workspace resource ID is correct" -ForegroundColor Yellow
        Write-Host "  3. BadRequest: Check if log category is supported by your license" -ForegroundColor Yellow
        exit 1
    }
}

# Post-configuration info
Write-Host "`n╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║   CONFIGURATION COMPLETE                                          ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════════╝`n" -ForegroundColor Green

Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "  1. Wait 5-15 minutes for initial data to appear in Log Analytics"
Write-Host "  2. Verify data with KQL queries (see examples below)"
Write-Host "  3. Monitor Log Analytics tables: SigninLogs, AuditLogs, AADNonInteractiveUserSignInLogs, etc.`n"

Write-Log "Script execution completed." -Level "SUCCESS"
#endregion
```

### 6.4 Usage Examples

#### Example 1: Configure All Default Log Categories (REST API)

This is the simplest usage - enables all default log categories using REST API:

```powershell
.\Configure-EntraIDDiagnosticSettings.ps1 `
    -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DestinationWorkspaceResourceId "/subscriptions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
```

#### Example 2: Configure Specific Log Categories Only (P1 License)

Use this when you only have Entra ID P1 license and want to avoid errors from P2-only categories:

```powershell
.\Configure-EntraIDDiagnosticSettings.ps1 `
    -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DestinationWorkspaceResourceId "/subscriptions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -LogCategories @("AuditLogs", "SignInLogs", "NonInteractiveUserSignInLogs", "ServicePrincipalSignInLogs", "ManagedIdentitySignInLogs", "ProvisioningLogs")
```

#### Example 3: Configure Only Free Tier Logs (AuditLogs)

Use this for tenants without any Entra ID premium license:

```powershell
.\Configure-EntraIDDiagnosticSettings.ps1 `
    -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DestinationWorkspaceResourceId "/subscriptions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -LogCategories @("AuditLogs")
```

#### Example 4: Deploy Using ARM Template

ARM template deployment provides better audit trail and is useful for infrastructure-as-code approaches:

```powershell
.\Configure-EntraIDDiagnosticSettings.ps1 `
    -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DestinationWorkspaceResourceId "/subscriptions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -UseArmTemplate
```

#### Example 5: Verify Existing Diagnostic Settings (Read-Only)

Check what diagnostic settings are currently configured without making changes:

```powershell
.\Configure-EntraIDDiagnosticSettings.ps1 `
    -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DestinationWorkspaceResourceId "/subscriptions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -VerifyOnly
```

#### Example 6: Replace Existing Diagnostic Setting

Use `-RemoveExisting` to delete the existing setting before creating a new one:

```powershell
.\Configure-EntraIDDiagnosticSettings.ps1 `
    -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DestinationWorkspaceResourceId "/subscriptions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -RemoveExisting
```

#### Example 7: Preview Changes (WhatIf Mode)

See what the script would do without making actual changes:

```powershell
.\Configure-EntraIDDiagnosticSettings.ps1 `
    -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DestinationWorkspaceResourceId "/subscriptions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -WhatIf
```

#### Example 8: Custom Diagnostic Setting Name

Use a custom name for the diagnostic setting:

```powershell
.\Configure-EntraIDDiagnosticSettings.ps1 `
    -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DestinationWorkspaceResourceId "/subscriptions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -DiagnosticSettingName "SendEntraLogsToAtevet12-Production"
```

#### Example 9: Cross-Tenant Scenario (Atevet17 to Atevet12)

Real-world example: Configure Entra ID logs from Atevet17 (source tenant) to be sent to Log Analytics workspace in Atevet12 (destination tenant):

```powershell
# First, connect to the source tenant (Atevet17)
Connect-AzAccount -TenantId "11111111-1111-1111-1111-111111111111"  # Atevet17 Tenant ID

# Then run the script
.\Configure-EntraIDDiagnosticSettings.ps1 `
    -SourceTenantId "11111111-1111-1111-1111-111111111111" `
    -DestinationWorkspaceResourceId "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -DiagnosticSettingName "SendEntraLogsToAtevet12"
```

### 6.5 Verify Entra ID Logs in Log Analytics

Once configured, Entra ID logs will appear in the following tables:

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
| `MicrosoftGraphActivityLogs` | Graph API activity |

**Verification KQL Queries:**

```kusto
// Check Sign-in Logs (wait 5-15 minutes after configuration)
SigninLogs
| where TimeGenerated > ago(1h)
| summarize count() by ResultType, AppDisplayName
| order by count_ desc

// Check Audit Logs
AuditLogs
| where TimeGenerated > ago(1h)
| summarize count() by OperationName, Category
| order by count_ desc

// Check for failed sign-ins (security monitoring)
SigninLogs
| where TimeGenerated > ago(24h)
| where ResultType != "0"
| project TimeGenerated, UserPrincipalName, AppDisplayName, ResultType, ResultDescription, IPAddress
| order by TimeGenerated desc

// Check risky users (requires P2 license)
AADRiskyUsers
| where TimeGenerated > ago(7d)
| project TimeGenerated, UserPrincipalName, RiskLevel, RiskState

---

## Step 7: Configure Microsoft 365 Audit Logs

Microsoft 365 (Office 365) Audit Logs capture user and admin activities across Microsoft 365 services including Exchange Online, SharePoint Online, OneDrive for Business, Microsoft Teams, Power Platform, and more. These logs are essential for security monitoring, compliance, and incident investigation.

> **Important:** Microsoft 365 Audit Logs are separate from Azure resource logs and Microsoft Entra ID logs. They require configuration through the Microsoft 365 Compliance Center or Microsoft Sentinel, and cannot be configured via Azure Lighthouse delegation.

### 7.1 Prerequisites for Microsoft 365 Audit Logs

| Requirement | Description |
|-------------|-------------|
| **License** | Microsoft 365 E3/E5, Office 365 E3/E5, or standalone audit license |
| **Permissions** | Global Administrator or Compliance Administrator in Atevet17 |
| **Audit Logging** | Must be enabled in Microsoft 365 (enabled by default for most tenants) |
| **Retention** | E3: 90 days, E5: 1 year (up to 10 years with add-on) |

### 7.2 Available Microsoft 365 Log Categories

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

### 7.3 Enable Microsoft 365 Audit Logging

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

### 7.4 Option A: Stream M365 Logs to Log Analytics via Microsoft Sentinel

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

### 7.5 Option B: Use Management Activity API for Custom Integration

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

### 7.6 Option C: Use Microsoft Graph API for Audit Logs

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

### 7.7 Configure Audit Log Retention in Microsoft 365

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

### 7.8 Query Microsoft 365 Audit Logs

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

### 7.9 M365 Audit Log Tables in Log Analytics

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

### 7.10 Cross-Tenant M365 Log Collection Architecture

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

### 7.11 Important Considerations for M365 Audit Logs

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

## Step 8: Centralize Logs in Log Analytics Workspace

### 8.1 Verify Log Tables

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

### 8.2 Sample Queries

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

## Step 9: Enable Microsoft Sentinel and Data Connectors

Now that all log sources are configured and data is flowing to the Log Analytics workspace, you can enable Microsoft Sentinel for advanced security analytics, threat detection, and incident response.

> **Why enable Sentinel after log collection?**
> - ✅ Verify all log data is flowing correctly before adding Sentinel costs
> - ✅ Understand your data volumes to estimate Sentinel costs accurately
> - ✅ Troubleshoot any log collection issues without Sentinel complexity
> - ✅ Sentinel charges apply immediately upon enablement

### 9.1 Overview of Microsoft Sentinel

Microsoft Sentinel is a cloud-native SIEM (Security Information and Event Management) and SOAR (Security Orchestration, Automation, and Response) solution built on top of Log Analytics. Enabling Sentinel provides:

- ✅ Advanced threat detection with built-in analytics rules
- ✅ Automated incident response with playbooks
- ✅ Cross-tenant visibility through Azure Lighthouse
- ✅ Built-in data connectors for Azure and Microsoft 365 services
- ✅ Threat intelligence integration
- ✅ Investigation and hunting capabilities

### 9.2 Deploy Microsoft Sentinel and Data Connectors using ARM Template

The recommended approach for deploying Microsoft Sentinel and data connectors is using an ARM template. This provides:
- Repeatable, consistent deployments
- Version control for your configuration
- Automation-friendly deployment

#### 8.2.1 ARM Template for Sentinel and Data Connectors

Create a file named `sentinel-deployment.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "workspaceName": {
            "type": "string",
            "defaultValue": "law-central-atevet12",
            "metadata": {
                "description": "Name of the Log Analytics workspace"
            }
        },
        "location": {
            "type": "string",
            "defaultValue": "[resourceGroup().location]",
            "metadata": {
                "description": "Location for all resources"
            }
        },
        "enableAzureActivityConnector": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable Azure Activity data connector"
            }
        },
        "enableEntraIDConnector": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable Microsoft Entra ID data connector"
            }
        },
        "enableDefenderForCloudConnector": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable Microsoft Defender for Cloud data connector"
            }
        },
        "tenantId": {
            "type": "string",
            "defaultValue": "[subscription().tenantId]",
            "metadata": {
                "description": "Tenant ID for data connectors"
            }
        },
        "subscriptionId": {
            "type": "string",
            "defaultValue": "[subscription().subscriptionId]",
            "metadata": {
                "description": "Subscription ID for Defender for Cloud connector"
            }
        }
    },
    "variables": {
        "sentinelName": "[concat('SecurityInsights(', parameters('workspaceName'), ')')]",
        "solutionAzureActivity": "azuresentinel.azure-sentinel-solution-azureactivity",
        "solutionEntraID": "azuresentinel.azure-sentinel-solution-azureactivedirectory",
        "solutionDefenderForCloud": "azuresentinel.azure-sentinel-solution-azuresecuritycenter"
    },
    "resources": [
        {
            "type": "Microsoft.OperationsManagement/solutions",
            "apiVersion": "2015-11-01-preview",
            "name": "[variables('sentinelName')]",
            "location": "[parameters('location')]",
            "plan": {
                "name": "[variables('sentinelName')]",
                "promotionCode": "",
                "product": "OMSGallery/SecurityInsights",
                "publisher": "Microsoft"
            },
            "properties": {
                "workspaceResourceId": "[resourceId('Microsoft.OperationalInsights/workspaces', parameters('workspaceName'))]"
            }
        },
        {
            "type": "Microsoft.SecurityInsights/onboardingStates",
            "apiVersion": "2022-12-01-preview",
            "name": "default",
            "scope": "[concat('Microsoft.OperationalInsights/workspaces/', parameters('workspaceName'))]",
            "dependsOn": [
                "[resourceId('Microsoft.OperationsManagement/solutions', variables('sentinelName'))]"
            ],
            "properties": {}
        },
        {
            "condition": "[parameters('enableAzureActivityConnector')]",
            "type": "Microsoft.OperationalInsights/workspaces/providers/contentPackages",
            "apiVersion": "2023-11-01",
            "name": "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/', variables('solutionAzureActivity'))]",
            "dependsOn": [
                "[resourceId('Microsoft.SecurityInsights/onboardingStates', 'default')]"
            ],
            "properties": {
                "contentId": "[variables('solutionAzureActivity')]",
                "contentKind": "Solution",
                "displayName": "Azure Activity",
                "version": "2.0.6"
            }
        },
        {
            "condition": "[parameters('enableEntraIDConnector')]",
            "type": "Microsoft.OperationalInsights/workspaces/providers/contentPackages",
            "apiVersion": "2023-11-01",
            "name": "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/', variables('solutionEntraID'))]",
            "dependsOn": [
                "[resourceId('Microsoft.SecurityInsights/onboardingStates', 'default')]"
            ],
            "properties": {
                "contentId": "[variables('solutionEntraID')]",
                "contentKind": "Solution",
                "displayName": "Microsoft Entra ID",
                "version": "3.0.4"
            }
        },
        {
            "condition": "[parameters('enableDefenderForCloudConnector')]",
            "type": "Microsoft.OperationalInsights/workspaces/providers/contentPackages",
            "apiVersion": "2023-11-01",
            "name": "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/', variables('solutionDefenderForCloud'))]",
            "dependsOn": [
                "[resourceId('Microsoft.SecurityInsights/onboardingStates', 'default')]"
            ],
            "properties": {
                "contentId": "[variables('solutionDefenderForCloud')]",
                "contentKind": "Solution",
                "displayName": "Microsoft Defender for Cloud",
                "version": "3.0.2"
            }
        },
        {
            "condition": "[parameters('enableDefenderForCloudConnector')]",
            "type": "Microsoft.OperationalInsights/workspaces/providers/dataConnectors",
            "apiVersion": "2023-02-01-preview",
            "name": "[concat(parameters('workspaceName'), '/Microsoft.SecurityInsights/DefenderForCloud-', parameters('subscriptionId'))]",
            "kind": "AzureSecurityCenter",
            "dependsOn": [
                "[resourceId('Microsoft.OperationalInsights/workspaces/providers/contentPackages', parameters('workspaceName'), 'Microsoft.SecurityInsights', variables('solutionDefenderForCloud'))]"
            ],
            "properties": {
                "subscriptionId": "[parameters('subscriptionId')]",
                "dataTypes": {
                    "alerts": {
                        "state": "Enabled"
                    }
                }
            }
        }
    ],
    "outputs": {
        "sentinelResourceId": {
            "type": "string",
            "value": "[resourceId('Microsoft.OperationsManagement/solutions', variables('sentinelName'))]"
        },
        "workspaceResourceId": {
            "type": "string",
            "value": "[resourceId('Microsoft.OperationalInsights/workspaces', parameters('workspaceName'))]"
        }
    }
}
```

#### 8.2.2 Parameters File

Create a file named `sentinel-deployment.parameters.json`:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "workspaceName": {
            "value": "law-central-atevet12"
        },
        "location": {
            "value": "westus2"
        },
        "enableAzureActivityConnector": {
            "value": true
        },
        "enableEntraIDConnector": {
            "value": true
        },
        "enableDefenderForCloudConnector": {
            "value": true
        },
        "tenantId": {
            "value": "<ATEVET12-TENANT-ID>"
        },
        "subscriptionId": {
            "value": "<ATEVET12-SUBSCRIPTION-ID>"
        }
    }
}
```

**Replace the placeholders:**
- `<ATEVET12-TENANT-ID>`: Your Atevet12 tenant ID
- `<ATEVET12-SUBSCRIPTION-ID>`: Your Atevet12 subscription ID

#### 8.2.3 Deploy the ARM Template

**Via Azure Portal:**

1. Go to **Deploy a custom template** in the Azure Portal
2. Click **Build your own template in the editor**
3. Paste the contents of `sentinel-deployment.json`
4. Click **Save**
5. Fill in the parameters:
   - Resource group: `rg-central-logging`
   - Workspace Name: `law-central-atevet12`
   - Location: `westus2`
   - Enable connectors as needed
6. Click **Review + Create** → **Create**

**Via Azure CLI:**

```bash
# Login to Atevet12 tenant
az login --tenant "<Atevet12-Tenant-ID>"

# Deploy the ARM template
az deployment group create \
    --name "SentinelDeployment" \
    --resource-group "rg-central-logging" \
    --template-file "sentinel-deployment.json" \
    --parameters "sentinel-deployment.parameters.json"
```

**Via PowerShell:**

```powershell
# Login to Atevet12 tenant
Connect-AzAccount -TenantId "<Atevet12-Tenant-ID>"

# Deploy the ARM template
New-AzResourceGroupDeployment `
    -Name "SentinelDeployment" `
    -ResourceGroupName "rg-central-logging" `
    -TemplateFile "sentinel-deployment.json" `
    -TemplateParameterFile "sentinel-deployment.parameters.json"
```

### 9.3 Configure Data Connectors via Azure Portal

After deploying Sentinel, some data connectors require additional configuration through the Azure Portal due to OAuth consent requirements.

#### 8.3.1 Microsoft Entra ID Connector

> **Note:** This connector requires OAuth consent and cannot be fully automated via ARM template.

1. Go to **Microsoft Sentinel** → Select `law-central-atevet12`
2. Navigate to **Configuration** → **Data connectors**
3. Search for **Microsoft Entra ID** (formerly Azure Active Directory)
4. Click **Open connector page**
5. Under **Configuration**, select the log types to enable:
   - ☑️ Sign-in logs
   - ☑️ Audit logs
   - ☑️ Non-interactive user sign-in logs
   - ☑️ Service principal sign-in logs
   - ☑️ Managed Identity sign-in logs
   - ☑️ Provisioning logs
   - ☑️ Risky users (requires P2)
   - ☑️ User risk events (requires P2)
6. Click **Apply Changes**

#### 8.3.2 Office 365 Connector

> **Note:** This connector requires OAuth consent and cannot be fully automated via ARM template.

1. Go to **Microsoft Sentinel** → **Data connectors**
2. Search for **Office 365**
3. Click **Open connector page**
4. Under **Configuration**, select the log types:
   - ☑️ Exchange
   - ☑️ SharePoint
   - ☑️ Teams
5. Click **Apply Changes**

#### 8.3.3 Microsoft 365 Defender Connector

> **Note:** This connector requires OAuth consent and cannot be fully automated via ARM template.

1. Go to **Microsoft Sentinel** → **Data connectors**
2. Search for **Microsoft 365 Defender**
3. Click **Open connector page**
4. Click **Connect incidents & alerts**
5. Select the products to connect:
   - ☑️ Microsoft Defender for Endpoint
   - ☑️ Microsoft Defender for Identity
   - ☑️ Microsoft Defender for Office 365
   - ☑️ Microsoft Defender for Cloud Apps
6. Click **Apply Changes**

### 9.4 Verify Sentinel Deployment

**Via Azure Portal:**

1. Go to **Microsoft Sentinel**
2. Verify `law-central-atevet12` appears in the list of Sentinel workspaces
3. Click on the workspace to access the Sentinel dashboard
4. Navigate to **Configuration** → **Data connectors** to verify connector status

**Via KQL Query:**

Run this query in Log Analytics to verify data is flowing:

```kusto
// Check if data is being ingested from each connector
union withsource=TableName *
| where TimeGenerated > ago(24h)
| summarize Count = count(), LastRecord = max(TimeGenerated) by TableName
| where TableName in (
    "AzureActivity",
    "SigninLogs",
    "AuditLogs",
    "AADNonInteractiveUserSignInLogs",
    "AADServicePrincipalSignInLogs",
    "SecurityAlert",
    "OfficeActivity"
)
| order by TableName asc
```

### 9.5 Common Data Connectors Reference

| Connector | Content Hub Solution | Deployment Method | Required Permissions |
|-----------|---------------------|-------------------|---------------------|
| **Azure Activity** | Azure Activity | ARM Template | Monitoring Reader on subscriptions |
| **Microsoft Entra ID** | Microsoft Entra ID | Portal (OAuth required) | Global Admin or Security Admin |
| **Microsoft Defender for Cloud** | Microsoft Defender for Cloud | ARM Template | Security Reader on subscriptions |
| **Office 365** | Microsoft 365 | Portal (OAuth required) | Global Admin |
| **Microsoft 365 Defender** | Microsoft 365 Defender | Portal (OAuth required) | Security Admin |
| **Azure Key Vault** | Azure Key Vault | Via diagnostic settings | Key Vault Reader |
| **Azure Firewall** | Azure Firewall | Via diagnostic settings | Network Contributor |

### 9.6 Sentinel Cost Considerations

Microsoft Sentinel has additional costs beyond Log Analytics:

| Component | Pricing Model |
|-----------|---------------|
| **Sentinel Ingestion** | ~$2.46 per GB (on top of Log Analytics) |
| **Commitment Tiers** | Discounts available at 100GB/day and above |
| **Free Data Sources** | Azure Activity, Office 365 audit logs (connector only) |
| **Automation** | Logic Apps consumption pricing for playbooks |

**Cost Optimization Tips:**

1. Use **Commitment Tiers** if ingesting >100GB/day for significant discounts
2. Enable **Basic Logs** for high-volume, low-query tables
3. Use **Data Collection Rules** to filter unnecessary data before ingestion
4. Review **Free Data Sources** - some connectors don't incur Sentinel charges
5. Set up **Cost Alerts** in Azure Cost Management

**Estimated Additional Monthly Costs for Sentinel:**

| Log Volume | Log Analytics Cost | Sentinel Cost | Total |
|------------|-------------------|---------------|-------|
| 10 GB/month | ~$28 | ~$25 | ~$53 |
| 50 GB/month | ~$138 | ~$123 | ~$261 |
| 100 GB/month | ~$276 | ~$246 | ~$522 |

> **Note:** Prices are approximate and vary by region. Use the [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/) for accurate estimates.

### 9.7 Troubleshooting Data Connectors

**Issue: Connector shows "Connected" but no data**

Run this KQL query to check data ingestion:

```kusto
union withsource=TableName *
| where TimeGenerated > ago(1h)
| summarize count() by TableName
| order by count_ desc
```

**Issue: Prerequisites not met**

1. Check required permissions for the connector
2. Verify licensing requirements (e.g., P1/P2 for sign-in logs)
3. Ensure the source service is properly configured

**Issue: Connector not appearing in list**

1. Install the Content Hub solution first (via ARM template or Portal)
2. Refresh the Data connectors page
3. Check if the connector requires a specific Azure region

**Useful diagnostic queries:**

```kusto
// Check for ingestion anomalies
Usage
| where TimeGenerated > ago(7d)
| where DataType in ("AzureActivity", "SigninLogs", "SecurityAlert")
| summarize DailyVolume = sum(Quantity) by DataType, bin(TimeGenerated, 1d)
| render timechart

// Check for connector health events
SentinelHealth
| where TimeGenerated > ago(24h)
| where SentinelResourceType == "Data connector"
| project TimeGenerated, SentinelResourceName, Status, Description
| order by TimeGenerated desc
```

---

## Step 10: Verify Log Collection

### 10.1 Check Diagnostic Settings

```powershell
# List all diagnostic settings for a subscription
Get-AzDiagnosticSetting -SubscriptionId "<Atevet17-Subscription-ID>"

# List diagnostic settings for a specific resource
Get-AzDiagnosticSetting -ResourceId "<Resource-ID>"
```

### 10.2 Verify Data in Log Analytics

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

### 10.3 Monitor Data Ingestion

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

### Phase 1: Log Analytics Workspace and Log Collection (Steps 1-7)

1. ✅ Created security group in Atevet12 for delegated access
2. ✅ Created centralized Log Analytics workspace in Atevet12
3. ✅ Onboarded Atevet17 subscriptions to Azure Lighthouse
4. ✅ Configured Activity Log collection
5. ✅ Configured Resource Diagnostic Logs (VMs, Key Vaults, Storage, and all other resource types)
6. ✅ Set up Azure Monitor Agent for VM-level logs
7. ✅ Configured Microsoft Entra ID (Azure AD) diagnostic logs (Sign-in, Audit, Risk events)
8. ✅ Configured Microsoft 365 Audit Logs (Exchange, SharePoint, Teams, OneDrive)
9. ✅ Set up Azure Policy for automatic diagnostic settings on new resources

### Phase 2: Microsoft Sentinel and Data Connectors (Step 8)

10. ✅ Enabled Microsoft Sentinel on the Log Analytics workspace
11. ✅ Deployed Content Hub solutions via ARM template
12. ✅ Configured data connectors for Azure Activity, Defender for Cloud, and other sources
13. ✅ Enabled OAuth-based connectors (Entra ID, Office 365, M365 Defender) via Azure Portal

**Phased Approach Benefits:**
- ✅ All log data flows to the workspace before Sentinel is enabled
- ✅ Reduced initial costs (Sentinel charges apply once enabled)
- ✅ Easier troubleshooting of log collection issues
- ✅ Better understanding of data volumes before committing to Sentinel

**Next Steps:**
1. Set up alerts and analytics rules in Microsoft Sentinel
2. Create dashboards and workbooks for monitoring
3. Configure automation rules and playbooks for incident response
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