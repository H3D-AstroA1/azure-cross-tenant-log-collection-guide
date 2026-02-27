# Azure Cross-Tenant Log Collection - Execution Scripts

This document contains PowerShell scripts for automating the Azure cross-tenant log collection setup process. These scripts complement the main guide ([azure-cross-tenant-log-collection-guide.md](azure-cross-tenant-log-collection-guide.md)).

---

## Table of Contents

1. [Important: Where to Run These Scripts](#important-where-to-run-these-scripts)
2. [Prerequisites](#prerequisites)
3. [Step 0: Register Resource Providers](#step-0-register-resource-providers)
4. [Step 1: Create Security Group and Log Analytics Workspace](#step-1-create-security-group-and-log-analytics-workspace)
5. [Step 2: Deploy Azure Lighthouse](#step-2-deploy-azure-lighthouse)
6. [Step 3: Configure Activity Log Collection](#step-3-configure-activity-log-collection)
7. [Step 4: Configure Virtual Machine Diagnostic Logs](#step-4-configure-virtual-machine-diagnostic-logs)
8. [Step 5: Configure Azure Resource Diagnostic Logs](#step-5-configure-azure-resource-diagnostic-logs)
9. [Step 6: Configure Microsoft Entra ID (Azure AD) Logs via Event Hub](#step-6-configure-microsoft-entra-id-azure-ad-logs-via-event-hub)
10. [Step 7: Configure Microsoft 365 Audit Logs](#step-7-configure-microsoft-365-audit-logs)

---

## Important: Where to Run These Scripts

> ⚠️ **CRITICAL**: These scripts must be run from the **SOURCE/CUSTOMER TENANT** (the tenant where the resources exist that you want to collect logs from).

### Cross-Tenant Architecture Overview

In a cross-tenant log collection scenario, there are two tenants:

| Tenant | Role | Example | What Runs Here |
|--------|------|---------|----------------|
| **Source Tenant** | Customer/Resource Owner | Atevet17 | ✅ **Run these scripts here** |
| **Managing Tenant** | MSP/Security Team | Atevet12 | Log Analytics Workspace, Sentinel |

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SOURCE TENANT (Atevet17)                         │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  📜 Run these scripts here:                                      │   │
│  │     • Register-ManagedServices.ps1                               │   │
│  │     • Azure Lighthouse ARM template deployment                   │   │
│  │     • Diagnostic settings configuration                          │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                  │
│  │ Subscription │  │ Subscription │  │ Subscription │                  │
│  │      A       │  │      B       │  │      C       │                  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘                  │
│         │                 │                 │                           │
│         └─────────────────┼─────────────────┘                           │
│                           │                                             │
│                           │ Logs flow via                               │
│                           │ Azure Lighthouse                            │
│                           ▼                                             │
└─────────────────────────────────────────────────────────────────────────┘
                            │
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      MANAGING TENANT (Atevet12)                         │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Log Analytics Workspace  ──────►  Microsoft Sentinel            │  │
│  │  (Receives logs)                   (Security monitoring)         │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Why Run from the Source Tenant?

The `Register-ManagedServices.ps1` script registers the `Microsoft.ManagedServices` resource provider on subscriptions. This is a **prerequisite for Azure Lighthouse** and must be done on the **source tenant's subscriptions** (where the resources exist).

### Authentication Requirements

When running from the source tenant, you need:

| Requirement | Details |
|-------------|---------|
| **Role** | Owner or Contributor on the source subscriptions |
| **Permission** | `Microsoft.ManagedServices/register/action` |
| **Authentication** | Azure PowerShell (`Connect-AzAccount`) |

### Step-by-Step Execution

1. **Authenticate to the SOURCE tenant** (e.g., Atevet17):
   ```powershell
   Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"
   ```

2. **Verify you're in the correct tenant**:
   ```powershell
   (Get-AzContext).Tenant.Id
   ```

3. **Run the script**:
   ```powershell
   .\Register-ManagedServices.ps1 -TenantId "<SOURCE-TENANT-ID>"
   ```

---

## Prerequisites

### Azure Cloud Shell (Recommended)

The Az PowerShell module is **pre-installed** in Azure Cloud Shell. No additional setup required!

1. Go to [Azure Portal](https://portal.azure.com)
2. Click the Cloud Shell icon (>_) in the top navigation bar
3. Select **PowerShell** as your shell type
4. You're ready to run the scripts!

### Local PowerShell Setup

For running scripts locally:

```powershell
# Check if Az module is installed
Get-Module -ListAvailable Az.Accounts

# Install if needed (run as Administrator)
Install-Module -Name Az -Repository PSGallery -Force

# Connect to Azure
Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"
```

---

## Step 0: Register Resource Providers

> ⚠️ **IMPORTANT**: This script must be run in the **SOURCE/CUSTOMER TENANT** (the tenant where the resources exist that you want to collect logs from).

> ✅ **RECOMMENDED for Azure Cloud Shell** - The Az PowerShell module is pre-installed, no additional setup required!

This PowerShell script checks and registers the `Microsoft.ManagedServices` resource provider across all subscriptions in a tenant. This registration is a **prerequisite for Azure Lighthouse** - without it, the Lighthouse delegation deployment will fail.

### Prerequisites

Before running this script, you need:
- **Azure account** with access to the source tenant
- **Owner** or **Contributor** role on the subscriptions you want to register
- **PowerShell** with the Az module installed (or use Azure Cloud Shell)

### What This Script Does

The `Microsoft.ManagedServices` resource provider enables Azure Lighthouse functionality on a subscription. This script:
1. Discovers all accessible subscriptions in the specified tenant
2. Checks the current registration status of the `Microsoft.ManagedServices` provider
3. Registers the provider on subscriptions where it's not already registered
4. Waits for registration to complete (can take 1-2 minutes per subscription)
5. Provides a summary showing which subscriptions were processed

### Script: `Register-ManagedServices.ps1`

The complete PowerShell script is located at: [`scripts/Register-ManagedServices.ps1`](scripts/Register-ManagedServices.ps1)

### Usage Examples

#### Basic Usage (Azure Cloud Shell)

```powershell
# 1. Open Azure Cloud Shell (PowerShell) from the Azure Portal
# 2. You're already authenticated! Verify your tenant:
(Get-AzContext).Tenant.Id

# 3. If you need to switch tenants:
Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"

# 4. Download the script from the repository or upload it to Cloud Shell
# 5. Run the script:
.\Register-ManagedServices.ps1 -TenantId "<SOURCE-TENANT-ID>"
```

#### Basic Usage (Local PowerShell)

```powershell
# 1. Install Az module if not already installed
Install-Module -Name Az -Repository PSGallery -Force

# 2. Connect to Azure
Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"

# 3. Run the script
.\Register-ManagedServices.ps1 -TenantId "<SOURCE-TENANT-ID>"
```

#### Check Status Only (No Registration)

```powershell
.\Register-ManagedServices.ps1 -TenantId "<SOURCE-TENANT-ID>" -CheckOnly
```

#### Process Specific Subscriptions

```powershell
.\Register-ManagedServices.ps1 -SubscriptionIds "sub-id-1", "sub-id-2", "sub-id-3"
```

### Expected Output

```
======================================================================
        Azure Resource Provider Registration Script (PowerShell)      
        Provider: Microsoft.ManagedServices                           
======================================================================

Connected as: user@domain.com
Current Tenant: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

Discovering subscriptions...
Found 3 subscription(s)

Processing subscriptions...

  [OK] Production-Subscription : Already registered
  [->] Development-Subscription : Registering...
    [OK] Successfully registered
  [->] Test-Subscription : Registering...
    [OK] Successfully registered

======================================================================
                              SUMMARY                                 
======================================================================

Total subscriptions processed: 3
  [OK] Registered: 3
    - Already registered: 1
    - Newly registered: 2

----------------------------------------------------------------------
Subscription                             Status          Action         
----------------------------------------------------------------------
Production-Subscription                  Registered      none           
Development-Subscription                 Registered      registered     
Test-Subscription                        Registered      registered     
----------------------------------------------------------------------
```

### Troubleshooting

#### Not Connected to Azure

**Error:** `Not connected to Azure. Please run Connect-AzAccount first.`

**Solution:**
```powershell
Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"
```

#### Permission Errors

**Error:** `The client does not have authorization to perform action 'Microsoft.Resources/subscriptions/providers/register/action'`

**Solution:**
- You need **Owner** or **Contributor** role on the subscription
- Or a custom role with `Microsoft.Resources/subscriptions/providers/register/action` permission

#### No Subscriptions Found

**Error:** `No accessible subscriptions found.`

**Solution:**
1. Verify you're authenticated to the correct tenant:
   ```powershell
   (Get-AzContext).Tenant.Id
   ```
2. Check that your account has access to subscriptions in that tenant
3. Ensure subscriptions are in 'Enabled' state

#### Wrong Tenant

**Error:** Script runs but shows subscriptions from wrong tenant

**Solution:**
```powershell
# Disconnect and reconnect to correct tenant
Disconnect-AzAccount
Connect-AzAccount -TenantId "<CORRECT-TENANT-ID>"
```

### Verification

After running the script, verify that the resource provider is registered:

```powershell
# Check registration status for all subscriptions
Get-AzSubscription | ForEach-Object {
    Set-AzContext -SubscriptionId $_.Id | Out-Null
    $provider = Get-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"
    [PSCustomObject]@{
        Subscription = $_.Name
        Status = $provider.RegistrationState
    }
} | Format-Table -AutoSize
```

**Expected result:** All subscriptions should show `Registered` status.

### Next Steps

Once all subscriptions show `Registered` status, proceed to:
- **Step 1**: Create Security Group and Log Analytics Workspace (in the managing tenant)

---

## Step 1: Create Security Group and Log Analytics Workspace

> ⚠️ **IMPORTANT**: This script must be run in the **MANAGING TENANT** (Atevet12), not the source tenant. This is where you create the security group and Log Analytics workspace that will receive logs from the source tenant.

> **Note:** This step creates the foundational resources in your managing tenant that will be used throughout the rest of the setup process.

This PowerShell script automates the preparation of the managing tenant, creating all the resources needed to receive and store logs from source tenants via Azure Lighthouse.

### Prerequisites

Before running this script, you need:
- **Azure account** with access to the managing tenant (Atevet12)
- **Global Administrator** or **Groups Administrator** role in Microsoft Entra ID (to create security groups)
- **Owner** or **Contributor** role on the subscription where resources will be created
- **PowerShell** with the following modules installed:
  - `Az.Accounts`, `Az.Resources`, `Az.OperationalInsights`, `Az.KeyVault`
  - `Microsoft.Graph.Groups` (for security group creation)

### What This Script Creates

| Resource | Purpose |
|----------|---------|
| **Security Group** | Contains users who will have delegated access to source tenant resources via Lighthouse |
| **Resource Group** | Container for the Log Analytics workspace and Key Vault |
| **Log Analytics Workspace** | Central repository for all collected logs from source tenants |
| **Key Vault** | Stores configuration secrets (e.g., Event Hub connection strings for Entra ID logs) |

### Script: `Prepare-ManagingTenant.ps1`

The complete PowerShell script is located at: [`scripts/Prepare-ManagingTenant.ps1`](scripts/Prepare-ManagingTenant.ps1)

### Usage Examples

#### Basic Usage

```powershell
# Connect to the managing tenant first
Connect-AzAccount -TenantId "<MANAGING-TENANT-ID>"

# Run the script
.\Prepare-ManagingTenant.ps1 `
    -TenantId "<MANAGING-TENANT-ID>" `
    -SubscriptionId "<MANAGING-SUBSCRIPTION-ID>"
```

#### Custom Names

```powershell
.\Prepare-ManagingTenant.ps1 `
    -TenantId "<MANAGING-TENANT-ID>" `
    -SubscriptionId "<MANAGING-SUBSCRIPTION-ID>" `
    -SecurityGroupName "Lighthouse-Atevet17-Admins" `
    -ResourceGroupName "rg-central-logging" `
    -WorkspaceName "law-central-atevet12" `
    -Location "eastus"
```

#### Add Users to Security Group

```powershell
# Add specific users to the security group during creation
.\Prepare-ManagingTenant.ps1 `
    -TenantId "<MANAGING-TENANT-ID>" `
    -SubscriptionId "<MANAGING-SUBSCRIPTION-ID>" `
    -GroupMembers @("admin@contoso.com", "analyst@contoso.com", "secops@contoso.com")

# You can also use Object IDs
.\Prepare-ManagingTenant.ps1 `
    -TenantId "<MANAGING-TENANT-ID>" `
    -SubscriptionId "<MANAGING-SUBSCRIPTION-ID>" `
    -GroupMembers @("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
```

#### Skip Existing Resources

```powershell
# If security group already exists
.\Prepare-ManagingTenant.ps1 `
    -TenantId "<MANAGING-TENANT-ID>" `
    -SubscriptionId "<MANAGING-SUBSCRIPTION-ID>" `
    -SkipGroupCreation

# If workspace already exists
.\Prepare-ManagingTenant.ps1 `
    -TenantId "<MANAGING-TENANT-ID>" `
    -SubscriptionId "<MANAGING-SUBSCRIPTION-ID>" `
    -SkipWorkspaceCreation
```

### Expected Output

```
======================================================================
        Prepare Managing Tenant for Cross-Tenant Log Collection
======================================================================

Checking Azure connection...
Connected as: admin@atevet12.onmicrosoft.com
Tenant: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

Setting subscription context...
Subscription: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy

Creating security group: Lighthouse-CrossTenant-Admins
  (This requires Microsoft Graph permissions)

Connecting to Microsoft Graph...
  Created security group successfully
  Group ID: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa

Adding members to security group...

  [+] Added: admin@contoso.com
  [+] Added: analyst@contoso.com
  [~] Already a member: secops@contoso.com

Creating resource group: rg-central-logging
  Created resource group in westus2

Creating Log Analytics workspace: law-central-logging
  Created Log Analytics workspace
  Workspace Resource ID: /subscriptions/.../workspaces/law-central-logging
  Workspace Customer ID: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

Creating Key Vault: kv-central-logging
  Created Key Vault with RBAC authorization
  Key Vault Resource ID: /subscriptions/.../vaults/kv-central-logging
  Key Vault URI: https://kv-central-logging.vault.azure.net/
  Assigning Key Vault Secrets Officer role to security group...
  ✓ Key Vault Secrets Officer role assigned to security group 'Lighthouse-CrossTenant-Admins'
    (All group members can now write secrets in Step 6 and Step 7)

======================================================================
                              SUMMARY
======================================================================

All resources created successfully!

=== Required IDs for Azure Lighthouse Deployment ===

Managing Tenant ID:        xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Subscription ID:           yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
Security Group Object ID:  aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
Resource Group Name:       rg-central-logging
Workspace Name:            law-central-logging
Workspace Resource ID:     /subscriptions/.../workspaces/law-central-logging
Location:                  westus2

Group Members Added:
  - admin@contoso.com
  - analyst@contoso.com
  - secops@contoso.com

=== JSON Output (for automation) ===

{
  "managingTenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "subscriptionId": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy",
  "securityGroupObjectId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  "groupMembersAdded": ["admin@contoso.com", "analyst@contoso.com", "secops@contoso.com"],
  ...
}

=== Lighthouse Parameters Template ===

Update your lighthouse-parameters-definition.json with these values:
...

=== Next Steps ===

1. Verify users in the security group 'Lighthouse-CrossTenant-Admins'
2. Update the Lighthouse parameters file with the values above
3. Run the Azure Lighthouse deployment in the SOURCE tenant
4. Configure diagnostic settings to send logs to the workspace
```

### Troubleshooting

#### Microsoft Graph Module Not Installed

**Error:** `Microsoft.Graph module not installed.`

**Solution:**
```powershell
# Install Microsoft Graph module
Install-Module Microsoft.Graph -Scope CurrentUser

# Or install just the Groups module
Install-Module Microsoft.Graph.Groups -Scope CurrentUser
```

#### Permission Denied Creating Security Group

**Error:** `Insufficient privileges to complete the operation.`

**Solution:**
- You need **Global Administrator** or **Groups Administrator** role in Azure AD
- Or create the security group manually via Azure Portal:
  1. Go to **Azure Active Directory** → **Groups** → **New group**
  2. Group type: **Security**
  3. Enter the group name and description
  4. Note the **Object ID** after creation

#### Subscription Not Found

**Error:** `The subscription 'xxx' could not be found.`

**Solution:**
1. Verify the subscription ID is correct
2. Ensure you have access to the subscription
3. Check you're connected to the correct tenant

#### User Not Found When Adding Group Members

**Error:** `[X] User not found: user@otherdomain.com` or `[X] User not found: <object-id>`

**Cause:** This typically occurs when trying to add **guest users (B2B users)** to the security group. Guest users have a different UPN format in the host tenant than their home tenant.

For example, a user `username@subdomain.domain.com` invited as a guest to ATEVET12 will have a UPN like:
`username_subdomain.domain.com#EXT#@ATEVET12.domain.com`

**Solutions:**

1. **Use the guest user's Object ID from the current tenant** (Recommended):
   ```powershell
   # Find the guest user's Object ID in the current tenant
   Get-MgUser -Filter "mail eq 'username@subdomain.domain.com'" | Select-Object Id, DisplayName, UserPrincipalName
   
   # Or search by the guest UPN pattern
   Get-MgUser -Filter "startswith(userPrincipalName, 'username_subdomain.domain.com#EXT#')" | Select-Object Id, DisplayName, UserPrincipalName
   
   # Then use the Object ID from the current tenant
   .\Prepare-ManagingTenant.ps1 -TenantId "..." -SubscriptionId "..." -GroupMembers @("<object-id-from-current-tenant>")
   ```

2. **Skip the `-GroupMembers` parameter if users are already in the group**:
   ```powershell
   # If the users are already members of the security group, simply omit the parameter
   .\Prepare-ManagingTenant.ps1 -TenantId "..." -SubscriptionId "..." -SecurityGroupName "Lighthouse-CrossTenant-Atevet17-Admins-TD"
   ```

3. **Add members manually via Azure Portal**:
   - Go to **Microsoft Entra ID** → **Groups** → Select your security group
   - Click **Members** → **Add members**
   - Search for the guest user by their display name or email

**Note:** The script has been updated to automatically search for guest users by their mail property and guest UPN pattern. If you're still seeing this error, ensure the user has been invited to the tenant first.

#### Key Vault Creation Failed - EnableRbacAuthorization Parameter

**Error:** `Failed to create Key Vault: A parameter cannot be found that matches parameter name 'EnableRbacAuthorization'.`

**Cause:** Your installed `Az.KeyVault` module is an older version that doesn't support the `-EnableRbacAuthorization` parameter. This parameter was added in newer versions of the module.

**Solution:**
```powershell
# Check your current Az.KeyVault version
Get-Module -ListAvailable Az.KeyVault | Select-Object Name, Version

# Update the Az.KeyVault module
Update-Module -Name Az.KeyVault -Force

# Or install the latest version (if Update-Module doesn't work)
Install-Module -Name Az.KeyVault -Force -AllowClobber

# Verify the new version is installed
Get-Module -ListAvailable Az.KeyVault | Select-Object Name, Version

# Re-run the script after updating
.\Prepare-ManagingTenant.ps1 -TenantId "..." -SubscriptionId "..."
```

**Alternative:** If you cannot update the module, create the Key Vault manually via Azure Portal:
1. Go to **Azure Portal** → **Create a resource** → **Key Vault**
2. Select your subscription and resource group
3. Enter the Key Vault name (e.g., `kv-central-logging-for-atevet17-TD`)
4. Select the region (e.g., `westus2`)
5. Under **Access configuration**, select **Azure role-based access control (recommended)**
6. Click **Review + create** → **Create**

#### Key Vault Name Already In Use (Global Uniqueness)

**Error:** `Key Vault name 'xxx' is globally reserved` or `VaultAlreadyExists`

**Cause:** Azure Key Vault names are **globally unique across ALL of Azure** - not just within your tenant or subscription. This error occurs when:
1. The Key Vault was soft-deleted in your current tenant (can be recovered or purged)
2. The Key Vault name is used in a **different tenant** (cannot be detected by the script)
3. The Key Vault name is reserved by another Azure customer

**Solutions:**

1. **Check for soft-deleted vault in your current tenant:**
   ```powershell
   # Check if the vault is soft-deleted in your current subscription
   Get-AzKeyVault -VaultName 'your-keyvault-name' -Location 'westus2' -InRemovedState
   ```

2. **Purge the soft-deleted vault (if found above):**
   ```powershell
   # Permanently delete the soft-deleted vault
   Remove-AzKeyVault -VaultName 'your-keyvault-name' -Location 'westus2' -InRemovedState -Force
   ```

3. **Use a different Key Vault name (RECOMMENDED if vault is in another tenant):**
   ```powershell
   # Use a unique name with a random suffix
   .\Prepare-ManagingTenant.ps1 `
       -TenantId "..." `
       -SubscriptionId "..." `
       -KeyVaultName "kv-logs-$(Get-Random -Maximum 9999)"
   
   # Or use a more descriptive unique name
   .\Prepare-ManagingTenant.ps1 `
       -TenantId "..." `
       -SubscriptionId "..." `
       -KeyVaultName "kv-central-atevet12-prod"
   ```

4. **If you created the vault in another tenant, delete it there first:**
   ```powershell
   # Connect to the OTHER tenant where the Key Vault exists
   Connect-AzAccount -TenantId "<OTHER-TENANT-ID>"
   
   # Delete the Key Vault
   Remove-AzKeyVault -VaultName 'your-keyvault-name' -ResourceGroupName '<RG-NAME>'
   
   # Purge the soft-deleted vault (required to release the name)
   Remove-AzKeyVault -VaultName 'your-keyvault-name' -Location '<LOCATION>' -InRemovedState -Force
   
   # Wait a few minutes for the name to be released, then re-run the script
   ```

**Note:** The script cannot detect Key Vaults in other tenants because Azure only allows querying resources within your current tenant context. If you're unsure whether the name is used elsewhere, the safest option is to choose a different, more unique name.

### Verification

After running the script, verify that all resources were created successfully:

#### 1. Verify Security Group

```powershell
# Check the security group exists and has the correct members
Connect-MgGraph -Scopes "Group.Read.All"
$group = Get-MgGroup -Filter "displayName eq 'Lighthouse-CrossTenant-Admins'"
$group | Select-Object DisplayName, Id, Description

# List group members
Get-MgGroupMember -GroupId $group.Id | ForEach-Object {
    Get-MgUser -UserId $_.Id | Select-Object DisplayName, UserPrincipalName
}
```

#### 2. Verify Log Analytics Workspace

```powershell
# Check the workspace exists
Get-AzOperationalInsightsWorkspace -ResourceGroupName "rg-central-logging" -Name "law-central-logging"
```

#### 3. Verify Key Vault

```powershell
# Check the Key Vault exists
Get-AzKeyVault -VaultName "kv-central-logging" -ResourceGroupName "rg-central-logging"
```

### Important Values to Save

After running the script, **save these values** - you'll need them for subsequent steps:

| Value | Used In | Example |
|-------|---------|---------|
| **Managing Tenant ID** | Step 2 (Lighthouse deployment) | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| **Security Group Object ID** | Step 2 (Lighthouse deployment) | `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa` |
| **Workspace Resource ID** | Steps 3, 4, 5, 6, 7 (all log collection) | `/subscriptions/.../workspaces/law-central-logging` |
| **Key Vault URI** | Step 6 (Entra ID logs) | `https://kv-central-logging.vault.azure.net/` |

### Next Steps

Once all resources are created successfully, proceed to:
- **Step 2**: Deploy Azure Lighthouse (in the source tenant)

---

## Step 2: Deploy Azure Lighthouse

> ⚠️ **IMPORTANT**: This script must be run in the **SOURCE/CUSTOMER TENANT** (Atevet17). Azure Lighthouse delegation is deployed FROM the customer tenant TO grant access to the managing tenant.

Azure Lighthouse enables cross-tenant management by creating a delegation from the source tenant (where resources exist) to the managing tenant (where your security team operates). This is the foundation for all subsequent log collection steps.

### What is Azure Lighthouse?

Azure Lighthouse is a service that enables cross-tenant management with enhanced security and governance. In the context of log collection:

| Concept | Description |
|---------|-------------|
| **Registration Definition** | Defines WHAT permissions are granted and to WHOM (the security group in your managing tenant) |
| **Registration Assignment** | Applies the definition to a specific subscription, creating the actual delegation |
| **Delegated Access** | Users in the security group can now access resources in the source tenant without switching accounts |

### Prerequisites

Before running this script, you need:

| Requirement | Where to Get It | Example |
|-------------|-----------------|---------|
| **Managing Tenant ID** | From Step 1 output | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| **Security Group Object ID** | From Step 1 output | `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa` |
| **Owner role** | On source subscription(s) in Atevet17 | Required to deploy Lighthouse |
| **Microsoft.ManagedServices registered** | Run Step 0 first | Provider must be registered |

### Script: `Deploy-AzureLighthouse.ps1`

The complete PowerShell script is located at: [`scripts/Deploy-AzureLighthouse.ps1`](scripts/Deploy-AzureLighthouse.ps1)

This script automates the Azure Lighthouse onboarding process:
1. Validates you're connected to the correct (source) tenant
2. Creates ARM templates for the Registration Definition and Assignment
3. Deploys the Lighthouse delegation to one or more subscriptions
4. Verifies the delegation was successful
5. Provides next steps for verification in the managing tenant

### Usage Examples

#### Basic Usage (Single Subscription)

```powershell
# Connect to the SOURCE tenant (Atevet17) first
Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"

# Deploy Lighthouse delegation
.\Deploy-AzureLighthouse.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SecurityGroupObjectId "<SECURITY-GROUP-OBJECT-ID>"
```

#### Multiple Subscriptions

```powershell
# Deploy to multiple subscriptions
.\Deploy-AzureLighthouse.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SecurityGroupObjectId "<SECURITY-GROUP-OBJECT-ID>" `
    -SubscriptionIds @("sub-id-1", "sub-id-2", "sub-id-3")
```

#### Custom Configuration

```powershell
# Custom definition name and without Contributor role
.\Deploy-AzureLighthouse.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SecurityGroupObjectId "<SECURITY-GROUP-OBJECT-ID>" `
    -SecurityGroupDisplayName "Lighthouse-Atevet17-Admins" `
    -RegistrationDefinitionName "Atevet12 Log Collection Delegation" `
    -IncludeContributorRole $false
```

#### Using Output from Step 1

```powershell
# If you saved the output from Step 1
$step1Output = .\Prepare-ManagingTenant.ps1 `
    -TenantId "<ATEVET12-TENANT-ID>" `
    -SubscriptionId "<ATEVET12-SUBSCRIPTION-ID>"

# Switch to source tenant
Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"

# Use the values from Step 1
.\Deploy-AzureLighthouse.ps1 `
    -ManagingTenantId $step1Output.TenantId `
    -SecurityGroupObjectId $step1Output.SecurityGroupId
```

### Expected Output

```
======================================================================
        Deploy Azure Lighthouse - Cross-Tenant Delegation
======================================================================

Checking Azure connection...
Connected as: admin@atevet17.onmicrosoft.com
Current Tenant: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

Confirmed: Running in source tenant (not managing tenant)

Subscriptions to delegate: 2
  - aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  - bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

Building authorization roles...
  Including Contributor role (for configuring diagnostic settings)
  Roles configured: Reader, Monitoring Reader, Log Analytics Reader, Contributor

Creating ARM templates...
  Templates created in temp directory

Deploying Azure Lighthouse to subscriptions...

Processing subscription: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  Subscription name: Production-Subscription
  Deploying registration definition...
  Definition deployed: /subscriptions/.../registrationDefinitions/...
  Deploying registration assignment...
  Assignment deployed successfully
  ✓ Delegation complete for Production-Subscription

Processing subscription: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
  Subscription name: Development-Subscription
  Deploying registration definition...
  Definition deployed: /subscriptions/.../registrationDefinitions/...
  Deploying registration assignment...
  Assignment deployed successfully
  ✓ Delegation complete for Development-Subscription

Verifying delegations...

  ✓ Verified: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  ✓ Verified: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

======================================================================
                              SUMMARY
======================================================================

Managing Tenant ID:        yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
Security Group Object ID:  zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz

Subscriptions Processed:   2
  Succeeded: 2

Successfully Delegated Subscriptions:
  ✓ aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  ✓ bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

=== Next Steps ===

1. In the MANAGING tenant (Atevet12), verify delegation:
   - Go to Azure Portal > 'My customers'
   - Or run: Get-AzManagedServicesAssignment

2. Configure diagnostic settings to send logs to Atevet12 workspace
3. Set up Activity Log collection (Step 3)
4. Configure resource diagnostic logs (Step 4)
```

### Verification

After running the script, verify that the Lighthouse delegation was successful:

#### 1. Verify in Source Tenant (Atevet17)

Check that the registration assignment was created:

```powershell
# While still connected to the source tenant
Get-AzManagedServicesDefinition | Format-Table Name, ManagedByTenantId

# List all assignments
Get-AzManagedServicesAssignment | Format-Table Name, RegistrationDefinitionId
```

#### 2. Verify in Managing Tenant (Atevet12)

Switch to the managing tenant and verify you can see the delegated subscriptions:

```powershell
# Connect to managing tenant
Connect-AzAccount -TenantId "<ATEVET12-TENANT-ID>"

# List delegated subscriptions (these are from the source tenant)
Get-AzSubscription | Where-Object { $_.TenantId -ne (Get-AzContext).Tenant.Id } | Format-Table Name, Id, TenantId
```

#### 3. Verify via Azure Portal

1. In the **managing tenant** (Atevet12), go to [Azure Portal](https://portal.azure.com)
2. Search for **"My customers"** in the search bar
3. You should see the delegated subscriptions from the source tenant listed
4. Click on a subscription to verify you have the expected access

#### 4. Test Access to Delegated Resources

```powershell
# While connected to the managing tenant, access resources in the delegated subscription
Set-AzContext -SubscriptionId "<DELEGATED-SUBSCRIPTION-ID>"

# List resources (should work if delegation is successful)
Get-AzResource | Select-Object Name, ResourceType, ResourceGroupName | Format-Table
```

### Troubleshooting

| Issue | Possible Cause | Solution |
|-------|---------------|----------|
| "ERROR: You are connected to the MANAGING tenant" | Running script from wrong tenant | Run `Disconnect-AzAccount` then `Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"` |
| "The subscription is not registered to use namespace 'Microsoft.ManagedServices'" | Resource provider not registered | Run Step 0 first, or manually: `Register-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"` |
| "The client does not have authorization to perform action" | Missing Owner role | You need **Owner** role on the subscription. Contact your subscription administrator. |
| "A registration assignment with the same name already exists" | Previous delegation exists | Remove existing: `Get-AzManagedServicesAssignment \| Remove-AzManagedServicesAssignment` |
| Delegated subscriptions not visible in "My customers" | Delegation not complete or wrong tenant | Verify you're in the managing tenant; wait 5 minutes for propagation |
| "Cannot access resources in delegated subscription" | Security group membership issue | Verify your account is a member of the security group created in Step 1 |

#### Detailed Troubleshooting Steps

**If delegation appears successful but you can't access resources:**

1. **Verify security group membership:**
   ```powershell
   # Connect to managing tenant
   Connect-MgGraph -Scopes "Group.Read.All"
   $group = Get-MgGroup -Filter "displayName eq 'Lighthouse-CrossTenant-Admins'"
   Get-MgGroupMember -GroupId $group.Id | ForEach-Object { Get-MgUser -UserId $_.Id } | Select-Object DisplayName, UserPrincipalName
   ```

2. **Check the roles assigned in the delegation:**
   ```powershell
   # In the source tenant
   Get-AzManagedServicesDefinition | Select-Object -ExpandProperty Authorization
   ```

3. **Verify the delegation is active:**
   ```powershell
   # In the source tenant
   Get-AzManagedServicesAssignment | Select-Object Name, ProvisioningState
   # ProvisioningState should be "Succeeded"
   ```

### Role Definitions Reference

The script assigns these roles to the security group for cross-tenant access:

| Role | Role Definition ID | Purpose | When Needed |
|------|-------------------|---------|-------------|
| **Reader** | `acdd72a7-3385-48ef-bd42-f606fba81ae7` | Read access to all resources | Always (baseline access) |
| **Contributor** | `b24988ac-6180-42a0-ab88-20f7382dd24c` | Create/modify resources, configure diagnostic settings | Steps 3-7 (log configuration) |
| **Monitoring Reader** | `43d0d8ad-25c7-4714-9337-8ba259a9fe05` | Read monitoring data and metrics | Viewing collected logs |
| **Log Analytics Reader** | `73c42c96-874c-492b-b04d-ab87d138a893` | Query Log Analytics workspaces | Querying collected logs |
| **Resource Policy Contributor** | `36243c78-bf99-498c-9df9-86d9f8d28608` | Create and manage Azure Policy assignments | Steps 4-5 (policy deployment) |
| **User Access Administrator** | `18d7d88d-d35e-4fb5-a5c3-7773c20a72d9` | Assign roles to managed identities | Policy remediation tasks |

### Best Practices

1. **Use descriptive names**: Name your registration definition clearly (e.g., "Atevet12 Security Team - Log Collection Access")
2. **Principle of least privilege**: Only include roles that are necessary for log collection
3. **Document the delegation**: Keep a record of which subscriptions are delegated and to whom
4. **Regular audits**: Periodically review delegations using `Get-AzManagedServicesAssignment`
5. **Security group management**: Use a dedicated security group for Lighthouse access; don't reuse existing groups
6. **Test before production**: Deploy to a test subscription first to verify the delegation works as expected

---

## Step 3: Configure Activity Log Collection

> ⚠️ **IMPORTANT**: This script should be run from the **MANAGING TENANT** (Atevet12) after Azure Lighthouse delegation is complete. The script configures diagnostic settings on the delegated subscriptions in the source tenant to send Activity Logs to the Log Analytics workspace in the managing tenant.

Activity Logs capture control plane operations (who did what, when, and on which resources). This script automates the configuration of Activity Log diagnostic settings across one or more delegated subscriptions.

### Prerequisites

Before running this script, you need:
- **Azure Lighthouse delegation** completed (Step 2)
- **Log Analytics Workspace Resource ID** (from Step 1)
- **Delegated subscription IDs** (from the source tenant)
- **Contributor** or **Monitoring Contributor** role on the delegated subscriptions

### Script: `Configure-ActivityLogCollection.ps1`

```powershell
<#
.SYNOPSIS
    Configures Activity Log diagnostic settings to send logs to a centralized Log Analytics workspace.

.DESCRIPTION
    This script is used as Step 3 in the Azure Cross-Tenant Log Collection setup.
    It configures Activity Log diagnostic settings on delegated subscriptions to send
    all Activity Log categories to a centralized Log Analytics workspace.
    
    The script:
    - Creates an ARM template for Activity Log diagnostic settings
    - Deploys the diagnostic settings to one or more subscriptions
    - Supports all Activity Log categories (Administrative, Security, ServiceHealth, etc.)
    - Verifies the configuration after deployment

.PARAMETER WorkspaceResourceId
    The full resource ID of the Log Analytics workspace to send logs to.
    Example: /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>

.PARAMETER SubscriptionIds
    Array of subscription IDs to configure. If not provided, uses current subscription.

.PARAMETER DiagnosticSettingName
    Name for the diagnostic setting. Default: "SendActivityLogsToLogAnalytics"

.PARAMETER Location
    Azure region for the deployment. Default: "westus2"

.PARAMETER EnableAdministrative
    Enable Administrative log category. Default: $true

.PARAMETER EnableSecurity
    Enable Security log category. Default: $true

.PARAMETER EnableServiceHealth
    Enable ServiceHealth log category. Default: $true

.PARAMETER EnableAlert
    Enable Alert log category. Default: $true

.PARAMETER EnableRecommendation
    Enable Recommendation log category. Default: $true

.PARAMETER EnablePolicy
    Enable Policy log category. Default: $true

.PARAMETER EnableAutoscale
    Enable Autoscale log category. Default: $true

.PARAMETER EnableResourceHealth
    Enable ResourceHealth log category. Default: $true

.PARAMETER SkipVerification
    Skip the verification step after deployment.

.EXAMPLE
    .\Configure-ActivityLogCollection.ps1 -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

.EXAMPLE
    .\Configure-ActivityLogCollection.ps1 -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" -SubscriptionIds @("sub-id-1", "sub-id-2")

.EXAMPLE
    .\Configure-ActivityLogCollection.ps1 -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" -DiagnosticSettingName "SendToAtevet12"

.NOTES
    Author: Cross-Tenant Log Collection Guide
    Requires: Az.Accounts, Az.Resources, Az.Monitor modules
    Should be run from the MANAGING tenant after Lighthouse delegation is complete
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceResourceId,

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$DiagnosticSettingName = "SendActivityLogsToLogAnalytics",

    [Parameter(Mandatory = $false)]
    [string]$Location = "westus2",

    [Parameter(Mandatory = $false)]
    [bool]$EnableAdministrative = $true,

    [Parameter(Mandatory = $false)]
    [bool]$EnableSecurity = $true,

    [Parameter(Mandatory = $false)]
    [bool]$EnableServiceHealth = $true,

    [Parameter(Mandatory = $false)]
    [bool]$EnableAlert = $true,

    [Parameter(Mandatory = $false)]
    [bool]$EnableRecommendation = $true,

    [Parameter(Mandatory = $false)]
    [bool]$EnablePolicy = $true,

    [Parameter(Mandatory = $false)]
    [bool]$EnableAutoscale = $true,

    [Parameter(Mandatory = $false)]
    [bool]$EnableResourceHealth = $true,

    [Parameter(Mandatory = $false)]
    [switch]$SkipVerification
)

# Color functions for output
function Write-Success { param($Message) Write-Host $Message -ForegroundColor Green }
function Write-ErrorMsg { param($Message) Write-Host $Message -ForegroundColor Red }
function Write-Warning { param($Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Info { param($Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Header { param($Message) Write-Host $Message -ForegroundColor Cyan -BackgroundColor DarkBlue }

# Results tracking
$results = @{
    WorkspaceResourceId = $WorkspaceResourceId
    DiagnosticSettingName = $DiagnosticSettingName
    SubscriptionsProcessed = @()
    SubscriptionsSucceeded = @()
    SubscriptionsFailed = @()
    CategoriesEnabled = @()
    Errors = @()
}

# Main script execution
Write-Host ""
Write-Header "======================================================================"
Write-Header "        Configure Activity Log Collection - Diagnostic Settings       "
Write-Header "======================================================================"
Write-Host ""

#region Check Azure Connection
Write-Info "Checking Azure connection..."

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-ErrorMsg "Not connected to Azure. Please connect first."
    Write-Host ""
    Write-Info "Run: Connect-AzAccount -TenantId '<MANAGING-TENANT-ID>'"
    exit 1
}

Write-Success "Connected as: $($context.Account.Id)"
Write-Success "Current Tenant: $($context.Tenant.Id)"
Write-Host ""
#endregion

#region Validate Workspace Resource ID
Write-Info "Validating workspace resource ID..."

if ($WorkspaceResourceId -notmatch "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$") {
    Write-ErrorMsg "Invalid workspace resource ID format."
    Write-ErrorMsg "Expected format: /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>"
    exit 1
}

# Extract workspace details from resource ID
$workspaceIdParts = $WorkspaceResourceId -split "/"
$workspaceSubscriptionId = $workspaceIdParts[2]
$workspaceResourceGroup = $workspaceIdParts[4]
$workspaceName = $workspaceIdParts[8]

Write-Success "  Workspace Name: $workspaceName"
Write-Success "  Resource Group: $workspaceResourceGroup"
Write-Success "  Subscription: $workspaceSubscriptionId"
Write-Host ""
#endregion

#region Get Subscriptions
if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
    # Use current subscription
    $SubscriptionIds = @($context.Subscription.Id)
    Write-Info "No subscriptions specified. Using current subscription: $($context.Subscription.Name)"
}

Write-Info "Subscriptions to configure: $($SubscriptionIds.Count)"
foreach ($subId in $SubscriptionIds) {
    Write-Host "  - $subId"
}
Write-Host ""
#endregion

#region Build Log Categories
Write-Info "Building log categories configuration..."

$logCategories = @()

if ($EnableAdministrative) {
    $logCategories += @{ category = "Administrative"; enabled = $true }
    $results.CategoriesEnabled += "Administrative"
}
if ($EnableSecurity) {
    $logCategories += @{ category = "Security"; enabled = $true }
    $results.CategoriesEnabled += "Security"
}
if ($EnableServiceHealth) {
    $logCategories += @{ category = "ServiceHealth"; enabled = $true }
    $results.CategoriesEnabled += "ServiceHealth"
}
if ($EnableAlert) {
    $logCategories += @{ category = "Alert"; enabled = $true }
    $results.CategoriesEnabled += "Alert"
}
if ($EnableRecommendation) {
    $logCategories += @{ category = "Recommendation"; enabled = $true }
    $results.CategoriesEnabled += "Recommendation"
}
if ($EnablePolicy) {
    $logCategories += @{ category = "Policy"; enabled = $true }
    $results.CategoriesEnabled += "Policy"
}
if ($EnableAutoscale) {
    $logCategories += @{ category = "Autoscale"; enabled = $true }
    $results.CategoriesEnabled += "Autoscale"
}
if ($EnableResourceHealth) {
    $logCategories += @{ category = "ResourceHealth"; enabled = $true }
    $results.CategoriesEnabled += "ResourceHealth"
}

Write-Success "  Categories enabled: $($results.CategoriesEnabled -join ', ')"
Write-Host ""
#endregion

#region Create ARM Template
Write-Info "Creating ARM template for Activity Log diagnostic settings..."

$armTemplate = @{
    '$schema' = "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters = @{
        diagnosticSettingName = @{
            type = "string"
            defaultValue = $DiagnosticSettingName
            metadata = @{
                description = "Name for the diagnostic setting"
            }
        }
        workspaceResourceId = @{
            type = "string"
            metadata = @{
                description = "Full resource ID of the Log Analytics workspace"
            }
        }
        enableAdministrative = @{
            type = "bool"
            defaultValue = $EnableAdministrative
        }
        enableSecurity = @{
            type = "bool"
            defaultValue = $EnableSecurity
        }
        enableServiceHealth = @{
            type = "bool"
            defaultValue = $EnableServiceHealth
        }
        enableAlert = @{
            type = "bool"
            defaultValue = $EnableAlert
        }
        enableRecommendation = @{
            type = "bool"
            defaultValue = $EnableRecommendation
        }
        enablePolicy = @{
            type = "bool"
            defaultValue = $EnablePolicy
        }
        enableAutoscale = @{
            type = "bool"
            defaultValue = $EnableAutoscale
        }
        enableResourceHealth = @{
            type = "bool"
            defaultValue = $EnableResourceHealth
        }
    }
    resources = @(
        @{
            type = "Microsoft.Insights/diagnosticSettings"
            apiVersion = "2021-05-01-preview"
            name = "[parameters('diagnosticSettingName')]"
            properties = @{
                workspaceId = "[parameters('workspaceResourceId')]"
                logs = @(
                    @{
                        category = "Administrative"
                        enabled = "[parameters('enableAdministrative')]"
                    }
                    @{
                        category = "Security"
                        enabled = "[parameters('enableSecurity')]"
                    }
                    @{
                        category = "ServiceHealth"
                        enabled = "[parameters('enableServiceHealth')]"
                    }
                    @{
                        category = "Alert"
                        enabled = "[parameters('enableAlert')]"
                    }
                    @{
                        category = "Recommendation"
                        enabled = "[parameters('enableRecommendation')]"
                    }
                    @{
                        category = "Policy"
                        enabled = "[parameters('enablePolicy')]"
                    }
                    @{
                        category = "Autoscale"
                        enabled = "[parameters('enableAutoscale')]"
                    }
                    @{
                        category = "ResourceHealth"
                        enabled = "[parameters('enableResourceHealth')]"
                    }
                )
            }
        }
    )
    outputs = @{
        diagnosticSettingId = @{
            type = "string"
            value = "[subscriptionResourceId('Microsoft.Insights/diagnosticSettings', parameters('diagnosticSettingName'))]"
        }
    }
}

# Save template to temp file
$tempDir = [System.IO.Path]::GetTempPath()
$templatePath = Join-Path $tempDir "activity-log-diagnostic-settings.json"
$armTemplate | ConvertTo-Json -Depth 20 | Set-Content -Path $templatePath -Encoding UTF8

Write-Success "  Template created: $templatePath"
Write-Host ""
#endregion

#region Deploy to Each Subscription
Write-Info "Deploying Activity Log diagnostic settings to subscriptions..."
Write-Host ""

foreach ($subId in $SubscriptionIds) {
    $results.SubscriptionsProcessed += $subId
    
    Write-Info "Processing subscription: $subId"
    
    try {
        # Set context to this subscription
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
        $subName = (Get-AzContext).Subscription.Name
        Write-Host "  Subscription name: $subName"
        
        # Check if diagnostic setting already exists
        $existingSetting = $null
        try {
            $existingSetting = Get-AzDiagnosticSetting -ResourceId "/subscriptions/$subId" -Name $DiagnosticSettingName -ErrorAction SilentlyContinue
        }
        catch {
            # Setting doesn't exist, which is fine
        }
        
        if ($existingSetting) {
            Write-Warning "  Diagnostic setting '$DiagnosticSettingName' already exists. Updating..."
        }
        
        # Deploy the ARM template
        Write-Host "  Deploying diagnostic settings..."
        $deploymentName = "ActivityLogDiagnostics-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        
        $deployment = New-AzSubscriptionDeployment `
            -Name $deploymentName `
            -Location $Location `
            -TemplateFile $templatePath `
            -diagnosticSettingName $DiagnosticSettingName `
            -workspaceResourceId $WorkspaceResourceId `
            -enableAdministrative $EnableAdministrative `
            -enableSecurity $EnableSecurity `
            -enableServiceHealth $EnableServiceHealth `
            -enableAlert $EnableAlert `
            -enableRecommendation $EnableRecommendation `
            -enablePolicy $EnablePolicy `
            -enableAutoscale $EnableAutoscale `
            -enableResourceHealth $EnableResourceHealth `
            -ErrorAction Stop
        
        if ($deployment.ProvisioningState -eq "Succeeded") {
            Write-Success "  ✓ Diagnostic settings configured successfully"
            $results.SubscriptionsSucceeded += $subId
        }
        else {
            Write-ErrorMsg "  ✗ Deployment state: $($deployment.ProvisioningState)"
            $results.SubscriptionsFailed += $subId
            $results.Errors += "Subscription $subId : Deployment state $($deployment.ProvisioningState)"
        }
    }
    catch {
        Write-ErrorMsg "  ✗ Failed: $($_.Exception.Message)"
        $results.SubscriptionsFailed += $subId
        $results.Errors += "Subscription $subId : $($_.Exception.Message)"
    }
    
    Write-Host ""
}
#endregion

#region Verify Configuration
if (-not $SkipVerification -and $results.SubscriptionsSucceeded.Count -gt 0) {
    Write-Info "Verifying diagnostic settings configuration..."
    Write-Host ""
    
    foreach ($subId in $results.SubscriptionsSucceeded) {
        try {
            Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
            
            # Get the diagnostic setting
            $setting = Get-AzDiagnosticSetting -ResourceId "/subscriptions/$subId" -Name $DiagnosticSettingName -ErrorAction Stop
            
            if ($setting) {
                $enabledCategories = ($setting.Log | Where-Object { $_.Enabled -eq $true }).Category
                Write-Success "  ✓ Verified: $subId"
                Write-Host "    Enabled categories: $($enabledCategories -join ', ')"
                Write-Host "    Workspace: $($setting.WorkspaceId)"
            }
            else {
                Write-Warning "  ⚠ Setting not found: $subId"
            }
        }
        catch {
            Write-Warning "  ⚠ Could not verify: $subId - $($_.Exception.Message)"
        }
    }
    Write-Host ""
}
#endregion

#region Cleanup Temp Files
Remove-Item -Path $templatePath -Force -ErrorAction SilentlyContinue
#endregion

#region Output Summary
Write-Host ""
Write-Header "======================================================================"
Write-Header "                              SUMMARY                                 "
Write-Header "======================================================================"
Write-Host ""

Write-Host "Workspace Resource ID:     $WorkspaceResourceId"
Write-Host "Diagnostic Setting Name:   $DiagnosticSettingName"
Write-Host "Categories Enabled:        $($results.CategoriesEnabled -join ', ')"
Write-Host ""

Write-Host "Subscriptions Processed:   $($results.SubscriptionsProcessed.Count)"
Write-Success "  Succeeded: $($results.SubscriptionsSucceeded.Count)"
if ($results.SubscriptionsFailed.Count -gt 0) {
    Write-ErrorMsg "  Failed: $($results.SubscriptionsFailed.Count)"
}
Write-Host ""

if ($results.SubscriptionsSucceeded.Count -gt 0) {
    Write-Info "Successfully Configured Subscriptions:"
    foreach ($subId in $results.SubscriptionsSucceeded) {
        Write-Success "  ✓ $subId"
    }
    Write-Host ""
}

if ($results.SubscriptionsFailed.Count -gt 0) {
    Write-Warning "Failed Subscriptions:"
    foreach ($subId in $results.SubscriptionsFailed) {
        Write-ErrorMsg "  ✗ $subId"
    }
    Write-Host ""
    
    Write-Warning "Errors:"
    foreach ($error in $results.Errors) {
        Write-ErrorMsg "  - $error"
    }
    Write-Host ""
}

# Output verification query
Write-Info "=== Verification Query (Run in Log Analytics) ==="
Write-Host ""
Write-Host @"
// Run this KQL query in your Log Analytics workspace to verify Activity Logs are being collected:

AzureActivity
| where TimeGenerated > ago(1h)
| where SubscriptionId in ($($results.SubscriptionsSucceeded | ForEach-Object { "'$_'" } | Join-String -Separator ", "))
| summarize count() by CategoryValue
| order by count_ desc

// Expected categories:
// - Administrative
// - Security
// - ServiceHealth
// - Alert
// - Recommendation
// - Policy
// - Autoscale
// - ResourceHealth
"@
Write-Host ""

Write-Info "=== Next Steps ==="
Write-Host ""
Write-Host "1. Wait 5-15 minutes for initial data ingestion"
Write-Host "2. Run the verification query above in Log Analytics"
Write-Host "3. Proceed to Step 4: Configure Resource Diagnostic Logs"
Write-Host "4. Configure Microsoft Entra ID logs (Step 5)"
Write-Host ""

# Output as JSON for automation
Write-Info "=== JSON Output (for automation) ==="
Write-Host ""
$jsonOutput = @{
    workspaceResourceId = $results.WorkspaceResourceId
    diagnosticSettingName = $results.DiagnosticSettingName
    categoriesEnabled = $results.CategoriesEnabled
    subscriptionsSucceeded = $results.SubscriptionsSucceeded
    subscriptionsFailed = $results.SubscriptionsFailed
} | ConvertTo-Json -Depth 3

Write-Host $jsonOutput
Write-Host ""
#endregion

# Return results
return $results
```

### Usage Examples

#### Basic Usage (Single Subscription)

```powershell
# Connect to the managing tenant (Atevet12) first
Connect-AzAccount -TenantId "<MANAGING-TENANT-ID>"

# Set context to a delegated subscription
Set-AzContext -SubscriptionId "<DELEGATED-SUBSCRIPTION-ID>"

# Configure Activity Log collection
.\Configure-ActivityLogCollection.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
```

#### Multiple Subscriptions

```powershell
# Configure multiple delegated subscriptions
.\Configure-ActivityLogCollection.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SubscriptionIds @("sub-id-1", "sub-id-2", "sub-id-3")
```

#### Custom Diagnostic Setting Name

```powershell
# Use a custom name for the diagnostic setting
.\Configure-ActivityLogCollection.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -DiagnosticSettingName "SendActivityLogsToAtevet12"
```

#### Selective Log Categories

```powershell
# Enable only specific log categories
.\Configure-ActivityLogCollection.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -EnableAdministrative $true `
    -EnableSecurity $true `
    -EnableServiceHealth $false `
    -EnableAlert $false `
    -EnableRecommendation $false `
    -EnablePolicy $true `
    -EnableAutoscale $false `
    -EnableResourceHealth $false
```

#### Using Output from Previous Steps

```powershell
# If you saved the output from Step 1
$step1Output = .\Prepare-ManagingTenant.ps1 `
    -TenantId "<ATEVET12-TENANT-ID>" `
    -SubscriptionId "<ATEVET12-SUBSCRIPTION-ID>"

# Use the workspace resource ID from Step 1
.\Configure-ActivityLogCollection.ps1 `
    -WorkspaceResourceId $step1Output.WorkspaceResourceId `
    -SubscriptionIds @("<DELEGATED-SUB-1>", "<DELEGATED-SUB-2>")
```

### Expected Output

```
======================================================================
        Configure Activity Log Collection - Diagnostic Settings
======================================================================

Checking Azure connection...
Connected as: admin@atevet12.onmicrosoft.com
Current Tenant: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

Validating workspace resource ID...
  Workspace Name: law-central-atevet12
  Resource Group: rg-central-logging
  Subscription: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy

Subscriptions to configure: 2
  - aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  - bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

Building log categories configuration...
  Categories enabled: Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth

Creating ARM template for Activity Log diagnostic settings...
  Template created: C:\Users\...\activity-log-diagnostic-settings.json

Deploying Activity Log diagnostic settings to subscriptions...

Processing subscription: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  Subscription name: Production-Subscription
  Deploying diagnostic settings...
  ✓ Diagnostic settings configured successfully

Processing subscription: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
  Subscription name: Development-Subscription
  Deploying diagnostic settings...
  ✓ Diagnostic settings configured successfully

Verifying diagnostic settings configuration...

  ✓ Verified: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
    Enabled categories: Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth
    Workspace: /subscriptions/.../workspaces/law-central-atevet12
  ✓ Verified: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
    Enabled categories: Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth
    Workspace: /subscriptions/.../workspaces/law-central-atevet12

======================================================================
                              SUMMARY
======================================================================

Workspace Resource ID:     /subscriptions/.../workspaces/law-central-atevet12
Diagnostic Setting Name:   SendActivityLogsToLogAnalytics
Categories Enabled:        Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth

Subscriptions Processed:   2
  Succeeded: 2

Successfully Configured Subscriptions:
  ✓ aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  ✓ bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

=== Verification Query (Run in Log Analytics) ===

// Run this KQL query in your Log Analytics workspace to verify Activity Logs are being collected:

AzureActivity
| where TimeGenerated > ago(1h)
| where SubscriptionId in ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')
| summarize count() by CategoryValue
| order by count_ desc

=== Next Steps ===

1. Wait 5-15 minutes for initial data ingestion
2. Run the verification query above in Log Analytics
3. Proceed to Step 4: Configure Resource Diagnostic Logs
4. Configure Microsoft Entra ID logs (Step 5)
```

### Troubleshooting

#### Invalid Workspace Resource ID

**Error:** `Invalid workspace resource ID format.`

**Solution:**
Ensure the workspace resource ID follows this format:
```
/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>
```

You can get the workspace resource ID from Step 1 output or by running:
```powershell
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName "rg-central-logging" -Name "law-central-atevet12"
$workspace.ResourceId
```

#### Permission Denied

**Error:** `The client does not have authorization to perform action 'Microsoft.Insights/diagnosticSettings/write'`

**Solution:**
- You need **Contributor** or **Monitoring Contributor** role on the subscription
- Verify Azure Lighthouse delegation includes the Contributor role
- Check that you're a member of the delegated security group

#### Diagnostic Setting Already Exists

**Warning:** `Diagnostic setting 'SendActivityLogsToLogAnalytics' already exists. Updating...`

This is not an error. The script will update the existing diagnostic setting with the new configuration.

#### No Data in Log Analytics

**Issue:** Activity Logs not appearing in Log Analytics after deployment

**Solution:**
1. Wait 5-15 minutes for initial data ingestion
2. Verify the diagnostic setting was created:
   ```powershell
   Get-AzDiagnosticSetting -ResourceId "/subscriptions/<sub-id>" -Name "SendActivityLogsToLogAnalytics"
   ```
3. Check that the workspace is accessible from the subscription
4. Verify there is activity in the subscription (create/modify a resource to generate logs)

### Activity Log Categories Reference

| Category | Description | Common Events |
|----------|-------------|---------------|
| **Administrative** | All create, update, delete, and action operations | Resource deployments, role assignments, policy assignments |
| **Security** | Security-related events | Security alerts, Azure Defender events |
| **ServiceHealth** | Azure service health events | Service incidents, planned maintenance |
| **Alert** | Azure Monitor alert activations | Metric alerts, log alerts |
| **Recommendation** | Azure Advisor recommendations | Cost, performance, security recommendations |
| **Policy** | Azure Policy operations | Policy evaluations, compliance changes |
| **Autoscale** | Autoscale engine events | Scale up/down operations |
| **ResourceHealth** | Resource health status changes | Resource availability changes |

---

## Step 4: Configure Virtual Machine Diagnostic Logs

> ⚠️ **IMPORTANT**: This script should be run from the **MANAGING TENANT** (Atevet12) after Azure Lighthouse delegation is complete. The script configures Data Collection Rules (DCR), installs the Azure Monitor Agent, creates DCR associations for VMs, and optionally deploys Azure Policy for automatic coverage of stopped and new VMs.

Virtual Machine diagnostic logs capture performance metrics, Windows Event Logs, and Linux Syslog data. This step covers configuring the Azure Monitor Agent (AMA) and Data Collection Rules (DCR) for VMs.

> **Note:** Virtual Machines require a different approach than other Azure resources. Instead of diagnostic settings, VMs use the Azure Monitor Agent with Data Collection Rules to collect logs and metrics.

### Critical: System Assigned Managed Identity Requirement

> ⚠️ **IMPORTANT**: The Azure Policy for AMA installation (`ca817e41-e85a-4783-bc7f-dc532d36235e`) requires VMs to have a **System Assigned Managed Identity** enabled.

**Why?** The policy definition includes a condition that checks for `identity.type` containing `SystemAssigned`. Without this identity, the policy will completely ignore the VM - it won't even appear in policy state evaluations.

**The Solution**: The script automatically enables System Assigned Managed Identity on running VMs before policy deployment. This ensures:
- The AMA policy can evaluate and remediate all VMs
- New VMs created with managed identity will be automatically covered
- Stopped VMs will need identity enabled when they start (the script documents this)

```
Policy Condition (from ca817e41-e85a-4783-bc7f-dc532d36235e):
{
  "field": "identity.type",
  "contains": "SystemAssigned"
}
```

### Critical: DCR Location for Cross-Tenant Scenarios

> ⚠️ **IMPORTANT ARCHITECTURE NOTE**: The Data Collection Rule (DCR) must be created in the **SOURCE TENANT** (where the VMs are located), NOT in the managing tenant.

**Why?** Azure Policy creates managed identities in the source tenant to perform remediation actions. These managed identities can only access resources within their own tenant. If the DCR is in the managing tenant, the policy will fail with:

```
The client has permission to perform action 'Microsoft.Insights/dataCollectionRules/read' on scope '...',
however the current tenant '<source-tenant-id>' is not authorized to access linked subscription '<managing-tenant-subscription>'.
```

**The Solution**:
- The DCR is created in the **source tenant subscription** (where the VMs are)
- The DCR sends data to the Log Analytics workspace in the **managing tenant** (cross-tenant data flow is supported)
- The policy's managed identity can read the DCR because it's in the same tenant

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SOURCE TENANT (Atevet17)                         │
│                                                                         │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────────┐    │
│  │     VMs      │────►│     DCR      │────►│  Azure Monitor Agent │    │
│  │              │     │ (Created     │     │  (Installed by       │    │
│  │              │     │  HERE)       │     │   Policy)            │    │
│  └──────────────┘     └──────┬───────┘     └──────────────────────┘    │
│                              │                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Azure Policy (with Managed Identity in SOURCE tenant)           │  │
│  │  - Can read DCR (same tenant) ✓                                  │  │
│  │  - Can install AMA on VMs ✓                                      │  │
│  │  - Can create DCR associations ✓                                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                              │                                          │
└──────────────────────────────┼──────────────────────────────────────────┘
                               │ Data flows cross-tenant
                               │ (This is supported!)
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      MANAGING TENANT (Atevet12)                         │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Log Analytics Workspace  ──────►  Microsoft Sentinel            │  │
│  │  (Receives logs from DCR)         (Security monitoring)          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Why Azure Policy is Important

When running this script, you may encounter VMs that are stopped/deallocated. Azure VM extensions cannot be installed on stopped VMs, resulting in errors like:

```
Installing Azure Monitor Agent...
    ✗ Failed to install agent: Cannot modify extensions in the VM when the VM is not running.
ErrorCode: OperationNotAllowed
```

The script handles this gracefully by:
1. **Creating DCR associations** for stopped VMs (these will be active when VMs start)
2. **Deploying Azure Policy** (when `-DeployPolicy` is enabled) to automatically:
   - Install the Azure Monitor Agent when stopped VMs come back online
   - Install the Azure Monitor Agent on newly created VMs
   - Create DCR associations for new VMs

### Important: Managed Identity Role Assignment

Azure Policy uses managed identities to perform remediation actions. These managed identities are created in the **source tenant** and need **Contributor** role to install VM extensions.

**Cross-Tenant Limitation**: Azure Lighthouse typically cannot assign roles to managed identities created in the source tenant because User Access Administrator is a privileged role with restrictions.

**Solution Options**:

1. **Option A: Source Tenant Admin Assigns Roles** (Recommended)
   - The script outputs the managed identity principal IDs
   - A source tenant admin assigns Contributor role to these identities
   - This is a one-time setup per subscription

2. **Option B: Add User Access Administrator to Lighthouse** (Complex)
   - Requires adding User Access Administrator as an eligible authorization
   - Must use `delegatedRoleDefinitionIds` to limit assignable roles
   - May require Azure AD Premium P2 for PIM activation

The script supports both approaches and will guide you through the process.

### Built-in Policy Definitions Reference

| Policy | Definition ID | Purpose |
|--------|--------------|---------|
| **Identity VMs** | `3cf2ab00-13f1-4d0c-8971-2ac904541a7e` | Add System Assigned Managed Identity to VMs without identities (REQUIRED - works for both Windows and Linux) |
| **AMA Windows** | `ca817e41-e85a-4783-bc7f-dc532d36235e` | Deploy Azure Monitor Agent on Windows VMs |
| **AMA Linux** | `a4034bc6-ae50-406d-bf76-50f4ee5a7811` | Deploy Azure Monitor Agent on Linux VMs |
| **DCR Windows** | `eab1f514-22e3-42e3-9a1f-e1dc9199355c` | Associate Windows VMs with DCR |
| **DCR Linux** | `58e891b9-ce13-4ac3-86e4-ac3e1f20cb07` | Associate Linux VMs with DCR |

> **Important Policy Deployment Order:**
> 1. **Identity policy** must be deployed first - it enables System Assigned Managed Identity on VMs (single policy for both Windows and Linux)
> 2. **AMA policies** depend on managed identity being present - they install the Azure Monitor Agent
> 3. **DCR policies** associate VMs with the Data Collection Rule
>
> The script deploys policies in this order to ensure proper dependency chain.

### Prerequisites

Before running this script, you need:
- **Azure Lighthouse delegation** completed (Step 2)
- **Log Analytics Workspace Resource ID** (from Step 1)
- **Delegated subscription IDs** (from the source tenant)
- **Contributor** role on the delegated subscriptions
- **Resource Policy Contributor** role (if deploying Azure Policy with `-DeployPolicy`)

### Opt-Out Parameters Reference

The script provides several opt-out switches to customize what gets deployed:

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-DeployPolicy` | bool | `$true` | **Set to `$false` to skip Azure Policy deployment**. When disabled, stopped VMs will NOT automatically get the agent when they start, and new VMs will NOT be automatically configured. |
| `-SkipDCRCreation` | switch | `$false` | **Skip Data Collection Rule creation**. Use this if you already have a DCR and want to reuse it. Specify the existing DCR name with `-DataCollectionRuleName`. |
| `-SkipAgentInstallation` | switch | `$false` | Skip Azure Monitor Agent installation on VMs. Use if agents are already installed. |
| `-SkipRemediation` | switch | `$false` | Skip creating remediation tasks for existing non-compliant VMs. |
| `-SkipVerification` | switch | `$false` | Skip the verification step after deployment. |

**Quick Reference - Common Opt-Out Scenarios:**

```powershell
# Scenario 1: Skip policy deployment only (manual VM management)
.\Configure-VMDiagnosticLogs.ps1 -WorkspaceResourceId "..." -DeployPolicy $false

# Scenario 2: Skip DCR creation (use existing DCR)
.\Configure-VMDiagnosticLogs.ps1 -WorkspaceResourceId "..." -SkipDCRCreation -DataCollectionRuleName "existing-dcr"

# Scenario 3: Skip both policy AND DCR (minimal deployment)
.\Configure-VMDiagnosticLogs.ps1 -WorkspaceResourceId "..." -DeployPolicy $false -SkipDCRCreation

# Scenario 4: Skip everything except DCR associations (agents already installed)
.\Configure-VMDiagnosticLogs.ps1 -WorkspaceResourceId "..." -DeployPolicy $false -SkipAgentInstallation
```

### Script: `Configure-VMDiagnosticLogs.ps1`

```powershell
<#
.SYNOPSIS
    Configures Virtual Machine diagnostic logs using Azure Monitor Agent, Data Collection Rules, and Azure Policy.

.DESCRIPTION
    This script is used as Step 4 in the Azure Cross-Tenant Log Collection setup.
    It configures VM log collection by:
    - Creating a Data Collection Rule (DCR) for VM logs
    - Installing the Azure Monitor Agent on running VMs
    - Creating DCR associations to link VMs to the DCR
    - Deploying Azure Policy for automatic agent installation on stopped/new VMs
    
    The script supports both Windows and Linux VMs and collects:
    - Performance counters (CPU, Memory, Disk, Network)
    - Windows Event Logs (Application, Security, System)
    - Linux Syslog
    
    Azure Policy ensures that:
    - Stopped VMs get the agent when they come back online
    - New VMs automatically get the agent and DCR association
    
    SOURCE TENANT ADMIN MODE:
    When run with -AssignRolesAsSourceAdmin, the script can be used by a source tenant
    administrator to assign roles to policy managed identities. This is required when
    Azure Lighthouse cannot assign roles due to cross-tenant restrictions.

.PARAMETER WorkspaceResourceId
    The full resource ID of the Log Analytics workspace to send logs to.
    Not required when using -AssignRolesAsSourceAdmin.

.PARAMETER SubscriptionIds
    Array of subscription IDs to configure. If not provided, uses current subscription.

.PARAMETER DataCollectionRuleName
    Name for the Data Collection Rule. Default: "dcr-vm-logs"

.PARAMETER ResourceGroupName
    Resource group where the DCR will be created in the SOURCE TENANT.
    Default: "rg-monitoring-dcr" (created in the first source subscription).
    Note: The DCR must be in the source tenant for Azure Policy to work correctly.

.PARAMETER Location
    Azure region for DCR deployment. Default: "westus2"

.PARAMETER DeployPolicy
    Deploy Azure Policy for automatic agent installation on stopped/new VMs. Default: $true

.PARAMETER PolicyAssignmentPrefix
    Prefix for policy assignment names. Default: "vm-monitoring"

.PARAMETER SkipAgentInstallation
    Skip Azure Monitor Agent installation (useful if agents are already installed).

.PARAMETER SkipDCRCreation
    Skip DCR creation (useful if DCR already exists).

.PARAMETER MasterDCRResourceGroup
    Resource group in the MANAGING TENANT where the Master DCR template will be stored.
    Default: "rg-master-dcr-templates"
    The Master DCR serves as a backup/template that can be used to restore source tenant DCRs.

.PARAMETER SkipMasterDCR
    Skip creating/updating the Master DCR in the managing tenant.
    By default, the script creates a Master DCR as a backup template.

.PARAMETER SyncDCRFromMaster
    Sync/restore DCRs in source tenants from the Master DCR in the managing tenant.
    Use this to restore a deleted/modified DCR or to ensure consistency across tenants.
    Requires -WorkspaceResourceId to identify the managing tenant subscription.

.PARAMETER SkipRemediation
    Skip creating remediation tasks for existing non-compliant VMs.

.PARAMETER SkipVerification
    Skip the verification step after deployment.

.PARAMETER AssignRolesAsSourceAdmin
    Run in SOURCE TENANT ADMIN mode to assign roles to policy managed identities.
    This mode discovers existing policy assignments and assigns Contributor role to their
    managed identities. Use this when the managing tenant cannot assign roles via Lighthouse.

.EXAMPLE
    .\Configure-VMDiagnosticLogs.ps1 -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

.EXAMPLE
    .\Configure-VMDiagnosticLogs.ps1 -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" -SubscriptionIds @("sub-id-1", "sub-id-2")

.EXAMPLE
    .\Configure-VMDiagnosticLogs.ps1 -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" -DeployPolicy $false

.EXAMPLE
    # SOURCE TENANT ADMIN: Assign roles to policy managed identities
    .\Configure-VMDiagnosticLogs.ps1 -AssignRolesAsSourceAdmin -SubscriptionIds @("sub-id-1")

.NOTES
    Author: Cross-Tenant Log Collection Guide
    Requires: Az.Accounts, Az.Resources, Az.Compute, Az.Monitor, Az.PolicyInsights modules
    Should be run from the MANAGING tenant after Lighthouse delegation is complete
    OR from the SOURCE tenant with -AssignRolesAsSourceAdmin for role assignment
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$WorkspaceResourceId,

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$DataCollectionRuleName = "dcr-vm-logs",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "rg-monitoring-dcr",

    [Parameter(Mandatory = $false)]
    [string]$Location = "westus2",

    [Parameter(Mandatory = $false)]
    [bool]$DeployPolicy = $true,

    [Parameter(Mandatory = $false)]
    [string]$PolicyAssignmentPrefix = "vm-monitoring",

    [Parameter(Mandatory = $false)]
    [switch]$SkipAgentInstallation,

    [Parameter(Mandatory = $false)]
    [switch]$SkipDCRCreation,

    [Parameter(Mandatory = $false)]
    [switch]$SkipRemediation,

    [Parameter(Mandatory = $false)]
    [switch]$SkipVerification,

    [Parameter(Mandatory = $false)]
    [switch]$AssignRolesAsSourceAdmin,

    [Parameter(Mandatory = $false)]
    [string]$MasterDCRResourceGroup = "rg-master-dcr-templates",

    [Parameter(Mandatory = $false)]
    [switch]$SkipMasterDCR,

    [Parameter(Mandatory = $false)]
    [switch]$SyncDCRFromMaster
)

# Color functions for output
function Write-Success { param($Message) Write-Host $Message -ForegroundColor Green }
function Write-ErrorMsg { param($Message) Write-Host $Message -ForegroundColor Red }
function Write-WarningMsg { param($Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Info { param($Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Header { param($Message) Write-Host $Message -ForegroundColor Cyan -BackgroundColor DarkBlue }

# Built-in Azure Policy Definition IDs for Azure Monitor Agent
$PolicyDefinitions = @{
    # System Assigned Managed Identity policy (REQUIRED for AMA policies to work)
    # This SINGLE policy handles BOTH Windows and Linux VMs - it's NOT OS-specific!
    # Must be deployed FIRST to ensure VMs have managed identity before AMA installation
    "Identity-VMs" = @{
        Id = "/providers/Microsoft.Authorization/policyDefinitions/3cf2ab00-13f1-4d0c-8971-2ac904541a7e"
        DisplayName = "Add system-assigned managed identity to enable Guest Configuration assignments on virtual machines"
        Description = "Adds System Assigned Managed Identity to VMs without any identities - REQUIRED for AMA policy. Works for both Windows and Linux."
        Priority = 1  # Deploy first
    }
    # Azure Monitor Agent policies (require managed identity to be present)
    "AMA-Windows" = @{
        Id = "/providers/Microsoft.Authorization/policyDefinitions/ca817e41-e85a-4783-bc7f-dc532d36235e"
        DisplayName = "Configure Windows virtual machines to run Azure Monitor Agent"
        Description = "Installs Azure Monitor Agent on Windows VMs with managed identity"
        Priority = 2  # Deploy after identity policies
    }
    "AMA-Linux" = @{
        Id = "/providers/Microsoft.Authorization/policyDefinitions/a4034bc6-ae50-406d-bf76-50f4ee5a7811"
        DisplayName = "Configure Linux virtual machines to run Azure Monitor Agent"
        Description = "Installs Azure Monitor Agent on Linux VMs with managed identity"
        Priority = 2  # Deploy after identity policies
    }
    # DCR Association policies
    "DCR-Windows" = @{
        Id = "/providers/Microsoft.Authorization/policyDefinitions/eab1f514-22e3-42e3-9a1f-e1dc9199355c"
        DisplayName = "Configure Windows VMs to be associated with a Data Collection Rule"
        Description = "Associates Windows VMs with the Data Collection Rule"
        Priority = 3  # Deploy after AMA policies
    }
    "DCR-Linux" = @{
        Id = "/providers/Microsoft.Authorization/policyDefinitions/58e891b9-ce13-4ac3-86e4-ac3e1f20cb07"
        DisplayName = "Configure Linux VMs to be associated with a Data Collection Rule"
        Description = "Associates Linux VMs with the Data Collection Rule"
        Priority = 3  # Deploy after AMA policies
    }
}

# Results tracking
$results = @{
    WorkspaceResourceId = $WorkspaceResourceId
    DataCollectionRuleName = $DataCollectionRuleName
    DataCollectionRuleId = $null
    SubscriptionsProcessed = @()
    VMsConfigured = @()
    VMsFailed = @()
    VMsSkipped = @()
    AgentsInstalled = @()
    DCRAssociationsCreated = @()
    PolicyAssignmentsCreated = @()
    PolicyAssignmentsFailed = @()
    RemediationTasksCreated = @()
    Errors = @()
}

# Main script execution
Write-Host ""
Write-Header "======================================================================"
Write-Header "        Configure Virtual Machine Diagnostic Logs - Step 4            "
Write-Header "======================================================================"
Write-Host ""

#region Check Azure Connection
Write-Info "Checking Azure connection..."

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-ErrorMsg "Not connected to Azure. Please connect first."
    Write-Host ""
    Write-Info "Run: Connect-AzAccount -TenantId '<MANAGING-TENANT-ID>'"
    exit 1
}

Write-Success "Connected as: $($context.Account.Id)"
Write-Success "Current Tenant: $($context.Tenant.Id)"
Write-Host ""
#endregion

#region Source Tenant Admin Mode - Assign Roles to Policy Managed Identities
if ($AssignRolesAsSourceAdmin) {
    Write-Host ""
    Write-Header "======================================================================"
    Write-Header "    SOURCE TENANT ADMIN MODE - Assign Roles to Policy Identities     "
    Write-Header "======================================================================"
    Write-Host ""
    
    Write-Info "This mode assigns Contributor role to policy managed identities."
    Write-Info "Run this after the managing tenant has deployed Azure Policy assignments."
    Write-Host ""
    
    # Get subscriptions
    if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
        $SubscriptionIds = @($context.Subscription.Id)
        Write-Info "No subscriptions specified. Using current subscription: $($context.Subscription.Name)"
    }
    
    $adminResults = @{
        SubscriptionsProcessed = @()
        PolicyAssignmentsFound = @()
        RoleAssignmentsCreated = @()
        RoleAssignmentsFailed = @()
        RemediationTasksCreated = @()
        Errors = @()
    }
    
    foreach ($subId in $SubscriptionIds) {
        Write-Info "Processing subscription: $subId"
        $adminResults.SubscriptionsProcessed += $subId
        
        try {
            Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
            $subName = (Get-AzContext).Subscription.Name
            Write-Host "  Subscription name: $subName"
            
            $scope = "/subscriptions/$subId"
            
            # Discover policy assignments with managed identities using REST API
            # Note: Get-AzPolicyAssignment cmdlet doesn't reliably return Identity information
            # so we use the REST API directly for accurate results
            Write-Host "  Discovering policy assignments with managed identities (using REST API)..."
            
            $apiVersion = "2022-06-01"
            $uri = "/subscriptions/$subId/providers/Microsoft.Authorization/policyAssignments?api-version=$apiVersion"
            
            $response = Invoke-AzRestMethod -Path $uri -Method GET -ErrorAction SilentlyContinue
            
            $policyAssignments = @()
            if ($response.StatusCode -eq 200) {
                $allAssignments = ($response.Content | ConvertFrom-Json).value
                
                # Filter for assignments with our prefix and managed identities
                $policyAssignments = $allAssignments | Where-Object {
                    $_.name -like "$PolicyAssignmentPrefix*" -and
                    $_.identity -and
                    $_.identity.principalId
                }
                
                if (-not $policyAssignments -or $policyAssignments.Count -eq 0) {
                    Write-WarningMsg "  No policy assignments found with prefix '$PolicyAssignmentPrefix'"
                    Write-Host "  Looking for all policy assignments with managed identities..."
                    
                    $policyAssignments = $allAssignments | Where-Object {
                        $_.identity -and
                        $_.identity.principalId
                    }
                }
            }
            else {
                Write-ErrorMsg "  Failed to query policy assignments: HTTP $($response.StatusCode)"
                $adminResults.Errors += "Failed to query policy assignments in $subId"
                continue
            }
            
            if (-not $policyAssignments -or $policyAssignments.Count -eq 0) {
                Write-WarningMsg "  No policy assignments with managed identities found in this subscription."
                continue
            }
            
            Write-Success "  Found $($policyAssignments.Count) policy assignment(s) with managed identities"
            Write-Host ""
            
            foreach ($assignment in $policyAssignments) {
                $principalId = $assignment.identity.principalId
                $displayName = $assignment.properties.displayName
                $assignmentId = $assignment.id
                
                Write-Host "  Policy: $displayName"
                Write-Host "    Principal ID: $principalId"
                
                $adminResults.PolicyAssignmentsFound += @{
                    Name = $assignment.Name
                    DisplayName = $displayName
                    PrincipalId = $principalId
                    AssignmentId = $assignmentId
                    SubscriptionId = $subId
                }
                
                # Check if Contributor role is already assigned
                $existingRole = Get-AzRoleAssignment -ObjectId $principalId -Scope $scope -RoleDefinitionName "Contributor" -ErrorAction SilentlyContinue
                
                if ($existingRole) {
                    Write-Success "    ✓ Contributor role already assigned"
                    $adminResults.RoleAssignmentsCreated += @{
                        PrincipalId = $principalId
                        Role = "Contributor"
                        Scope = $scope
                        AlreadyExisted = $true
                    }
                }
                else {
                    Write-Host "    Assigning Contributor role..."
                    try {
                        New-AzRoleAssignment `
                            -ObjectId $principalId `
                            -RoleDefinitionName "Contributor" `
                            -Scope $scope `
                            -ErrorAction Stop | Out-Null
                        
                        Write-Success "    ✓ Contributor role assigned"
                        $adminResults.RoleAssignmentsCreated += @{
                            PrincipalId = $principalId
                            Role = "Contributor"
                            Scope = $scope
                            AlreadyExisted = $false
                        }
                    }
                    catch {
                        Write-ErrorMsg "    ✗ Failed to assign role: $($_.Exception.Message)"
                        $adminResults.RoleAssignmentsFailed += @{
                            PrincipalId = $principalId
                            Role = "Contributor"
                            Scope = $scope
                            Error = $_.Exception.Message
                        }
                        $adminResults.Errors += "Role assignment for $principalId : $($_.Exception.Message)"
                    }
                }
                
                # For DCR-related policies, also assign Monitoring Contributor on the DCR if we have the DCR ID
                if ($assignment.name -like "*DCR*" -and $DataCollectionRuleName) {
                    # Try to find the DCR by searching all resource groups in the subscription
                    # Note: Get-AzDataCollectionRule requires -ResourceGroupName when using -Name
                    # So we search all DCRs and filter by name
                    $dcr = $null
                    try {
                        $allDcrs = Get-AzDataCollectionRule -ErrorAction SilentlyContinue
                        $dcr = $allDcrs | Where-Object { $_.Name -eq $DataCollectionRuleName } | Select-Object -First 1
                    }
                    catch {
                        Write-WarningMsg "    ⚠ Could not search for DCR: $($_.Exception.Message)"
                    }
                    
                    if ($dcr) {
                        Write-Host "    Assigning Monitoring Contributor on DCR..."
                        $existingDcrRole = Get-AzRoleAssignment -ObjectId $principalId -Scope $dcr.Id -RoleDefinitionName "Monitoring Contributor" -ErrorAction SilentlyContinue
                        
                        if ($existingDcrRole) {
                            Write-Success "    ✓ Monitoring Contributor role already assigned on DCR"
                        }
                        else {
                            try {
                                New-AzRoleAssignment `
                                    -ObjectId $principalId `
                                    -RoleDefinitionName "Monitoring Contributor" `
                                    -Scope $dcr.Id `
                                    -ErrorAction Stop | Out-Null
                                
                                Write-Success "    ✓ Monitoring Contributor role assigned on DCR"
                                $adminResults.RoleAssignmentsCreated += @{
                                    PrincipalId = $principalId
                                    Role = "Monitoring Contributor"
                                    Scope = $dcr.Id
                                    AlreadyExisted = $false
                                }
                            }
                            catch {
                                Write-WarningMsg "    ⚠ Could not assign Monitoring Contributor on DCR: $($_.Exception.Message)"
                            }
                        }
                    }
                }
                
                Write-Host ""
            }
            
            # Create remediation tasks if roles were assigned
            if (-not $SkipRemediation -and $adminResults.RoleAssignmentsCreated.Count -gt 0) {
                Write-Host ""
                Write-Info "Creating remediation tasks for existing non-compliant VMs..."
                Write-Host ""
                
                Write-Host "  Waiting 15 seconds for role assignments to propagate..."
                Start-Sleep -Seconds 15
                
                foreach ($found in ($adminResults.PolicyAssignmentsFound | Where-Object { $_.SubscriptionId -eq $subId })) {
                    $remediationName = "remediate-$($found.Name)"
                    
                    Write-Host "  Creating remediation: $remediationName"
                    
                    try {
                        # Check for existing running remediations for this policy assignment
                        $existingRemediations = Get-AzPolicyRemediation -Scope $scope -ErrorAction SilentlyContinue |
                            Where-Object {
                                $_.PolicyAssignmentId -eq $found.AssignmentId -and
                                $_.ProvisioningState -in @("Accepted", "Running", "Evaluating")
                            }
                        
                        if ($existingRemediations) {
                            Write-Success "    ✓ Remediation already in progress: $($existingRemediations[0].Name)"
                            Write-Host "      Status: $($existingRemediations[0].ProvisioningState)"
                            $adminResults.RemediationTasksCreated += @{
                                Name = $existingRemediations[0].Name
                                PolicyAssignment = $found.Name
                                Status = $existingRemediations[0].ProvisioningState
                                Existing = $true
                            }
                            continue
                        }
                        
                        $remediation = Start-AzPolicyRemediation `
                            -Name $remediationName `
                            -PolicyAssignmentId $found.AssignmentId `
                            -Scope $scope `
                            -ErrorAction Stop
                        
                        Write-Success "    ✓ Remediation task created"
                        $adminResults.RemediationTasksCreated += @{
                            Name = $remediationName
                            PolicyAssignment = $found.Name
                            Status = $remediation.ProvisioningState
                        }
                    }
                    catch {
                        # Check if error is due to existing remediation
                        if ($_.Exception.Message -like "*already running*" -or $_.Exception.Message -like "*InvalidCreateRemediationRequest*") {
                            Write-Success "    ✓ Remediation already in progress for this policy"
                            $adminResults.RemediationTasksCreated += @{
                                Name = $remediationName
                                PolicyAssignment = $found.Name
                                Status = "AlreadyRunning"
                                Existing = $true
                            }
                        }
                        else {
                            Write-WarningMsg "    ⚠ Could not create remediation: $($_.Exception.Message)"
                            $adminResults.Errors += "Remediation for $($found.Name): $($_.Exception.Message)"
                        }
                    }
                }
            }
        }
        catch {
            Write-ErrorMsg "  ✗ Failed to process subscription: $($_.Exception.Message)"
            $adminResults.Errors += "Subscription $subId : $($_.Exception.Message)"
        }
        
        Write-Host ""
    }
    
    # Output summary for source tenant admin mode
    Write-Host ""
    Write-Header "======================================================================"
    Write-Header "                              SUMMARY                                 "
    Write-Header "======================================================================"
    Write-Host ""
    
    Write-Host "Subscriptions Processed:   $($adminResults.SubscriptionsProcessed.Count)"
    Write-Host "Policy Assignments Found:  $($adminResults.PolicyAssignmentsFound.Count)"
    Write-Host "Role Assignments Created:  $($adminResults.RoleAssignmentsCreated.Count)"
    Write-Host "Role Assignments Failed:   $($adminResults.RoleAssignmentsFailed.Count)"
    Write-Host "Remediation Tasks Created: $($adminResults.RemediationTasksCreated.Count)"
    Write-Host ""
    
    if ($adminResults.RoleAssignmentsCreated.Count -gt 0) {
        Write-Success "Successfully assigned roles:"
        foreach ($role in $adminResults.RoleAssignmentsCreated) {
            $status = if ($role.AlreadyExisted) { "(already existed)" } else { "(newly assigned)" }
            Write-Success "  ✓ $($role.Role) to $($role.PrincipalId) $status"
        }
        Write-Host ""
    }
    
    if ($adminResults.RoleAssignmentsFailed.Count -gt 0) {
        Write-ErrorMsg "Failed role assignments:"
        foreach ($failed in $adminResults.RoleAssignmentsFailed) {
            Write-ErrorMsg "  ✗ $($failed.Role) to $($failed.PrincipalId)"
            Write-ErrorMsg "    Error: $($failed.Error)"
        }
        Write-Host ""
    }
    
    if ($adminResults.RemediationTasksCreated.Count -gt 0) {
        Write-Success "Remediation tasks created:"
        foreach ($task in $adminResults.RemediationTasksCreated) {
            Write-Success "  ✓ $($task.Name) - $($task.Status)"
        }
        Write-Host ""
    }
    
    if ($adminResults.Errors.Count -gt 0) {
        Write-WarningMsg "Errors encountered:"
        foreach ($err in $adminResults.Errors) {
            Write-ErrorMsg "  - $err"
        }
        Write-Host ""
    }
    
    Write-Info "=== Next Steps ==="
    Write-Host ""
    Write-Host "1. Wait for remediation tasks to complete (check status in Azure Portal)"
    Write-Host "2. Verify VMs are getting the Azure Monitor Agent installed"
    Write-Host "3. Check Log Analytics workspace for incoming VM data"
    Write-Host ""
    
    # Return results and exit (don't continue with normal mode)
    return $adminResults
}
#endregion

#region SyncDCRFromMaster Mode - Restore/Sync DCRs from Master DCR in Managing Tenant
if ($SyncDCRFromMaster) {
    Write-Host ""
    Write-Header "======================================================================"
    Write-Header "    SYNC DCR FROM MASTER - Restore/Sync DCRs from Managing Tenant    "
    Write-Header "======================================================================"
    Write-Host ""
    
    Write-Info "This mode syncs/restores DCRs in source tenants from the Master DCR in the managing tenant."
    Write-Info "Use this to restore a deleted/modified DCR or ensure consistency across tenants."
    Write-Host ""
    
    # WorkspaceResourceId is required to identify the managing tenant subscription
    if (-not $WorkspaceResourceId) {
        Write-ErrorMsg "WorkspaceResourceId is required for -SyncDCRFromMaster mode."
        Write-ErrorMsg "The workspace subscription is used to locate the Master DCR in the managing tenant."
        exit 1
    }
    
    # Extract managing tenant subscription from workspace resource ID
    $workspaceIdParts = $WorkspaceResourceId -split "/"
    $managingSubscriptionId = $workspaceIdParts[2]
    
    Write-Info "Managing Tenant Subscription: $managingSubscriptionId"
    Write-Info "Master DCR Resource Group: $MasterDCRResourceGroup"
    Write-Info "Master DCR Name: $DataCollectionRuleName"
    Write-Host ""
    
    # Get subscriptions to sync
    if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
        $SubscriptionIds = @($context.Subscription.Id)
        Write-Info "No subscriptions specified. Using current subscription: $($context.Subscription.Name)"
    }
    
    $syncResults = @{
        MasterDCRFound = $false
        MasterDCRConfig = $null
        SubscriptionsProcessed = @()
        DCRsSynced = @()
        DCRsFailed = @()
        Errors = @()
    }
    
    # Step 1: Read the Master DCR from the managing tenant
    Write-Info "Step 1: Reading Master DCR from managing tenant..."
    Write-Host ""
    
    try {
        Set-AzContext -SubscriptionId $managingSubscriptionId -ErrorAction Stop | Out-Null
        
        $masterDCR = Get-AzDataCollectionRule -Name $DataCollectionRuleName -ResourceGroupName $MasterDCRResourceGroup -ErrorAction SilentlyContinue
        
        if (-not $masterDCR) {
            Write-ErrorMsg "Master DCR '$DataCollectionRuleName' not found in resource group '$MasterDCRResourceGroup'"
            Write-ErrorMsg "in managing tenant subscription '$managingSubscriptionId'."
            Write-Host ""
            Write-Info "To create a Master DCR, run the script without -SyncDCRFromMaster first."
            Write-Info "The script will automatically create a Master DCR in the managing tenant."
            exit 1
        }
        
        Write-Success "  ✓ Found Master DCR: $($masterDCR.Name)"
        Write-Host "    Location: $($masterDCR.Location)"
        Write-Host "    ID: $($masterDCR.Id)"
        
        $syncResults.MasterDCRFound = $true
        $syncResults.MasterDCRConfig = $masterDCR
    }
    catch {
        Write-ErrorMsg "Failed to read Master DCR: $($_.Exception.Message)"
        $syncResults.Errors += "Master DCR read failed: $($_.Exception.Message)"
        exit 1
    }
    Write-Host ""
    
    # Step 2: Sync DCR to each source tenant subscription
    Write-Info "Step 2: Syncing DCR to source tenant subscriptions..."
    Write-Host ""
    
    foreach ($subId in $SubscriptionIds) {
        Write-Info "Processing subscription: $subId"
        $syncResults.SubscriptionsProcessed += $subId
        
        try {
            Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
            $subName = (Get-AzContext).Subscription.Name
            Write-Host "  Subscription name: $subName"
            
            # Check if resource group exists, create if not
            $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
            if (-not $rg) {
                Write-Host "  Creating resource group '$ResourceGroupName'..."
                New-AzResourceGroup -Name $ResourceGroupName -Location $masterDCR.Location -ErrorAction Stop | Out-Null
                Write-Success "  ✓ Resource group created"
            }
            
            # Check if DCR already exists
            $existingDCR = Get-AzDataCollectionRule -Name $DataCollectionRuleName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
            
            if ($existingDCR) {
                Write-WarningMsg "  DCR '$DataCollectionRuleName' already exists. Updating from Master..."
            }
            else {
                Write-Host "  Creating DCR from Master template..."
            }
            
            # Create/Update DCR using ARM template based on Master DCR configuration
            # We need to recreate the DCR with the same configuration but in the source tenant
            $dcrTemplate = @{
                '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
                contentVersion = "1.0.0.0"
                resources = @(
                    @{
                        type = "Microsoft.Insights/dataCollectionRules"
                        apiVersion = "2022-06-01"
                        name = $DataCollectionRuleName
                        location = $masterDCR.Location
                        properties = @{
                            description = $masterDCR.Description
                            dataSources = $masterDCR.DataSource
                            destinations = $masterDCR.Destination
                            dataFlows = $masterDCR.DataFlow
                        }
                    }
                )
            }
            
            # Save template to temp file
            $tempDir = [System.IO.Path]::GetTempPath()
            $dcrTemplatePath = Join-Path $tempDir "dcr-sync-template-$subId.json"
            $dcrTemplate | ConvertTo-Json -Depth 20 | Set-Content -Path $dcrTemplatePath -Encoding UTF8
            
            try {
                $deployment = New-AzResourceGroupDeployment `
                    -Name "DCR-Sync-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
                    -ResourceGroupName $ResourceGroupName `
                    -TemplateFile $dcrTemplatePath `
                    -ErrorAction Stop
                
                Write-Success "  ✓ DCR synced successfully"
                $syncResults.DCRsSynced += @{
                    SubscriptionId = $subId
                    SubscriptionName = $subName
                    DCRName = $DataCollectionRuleName
                    ResourceGroup = $ResourceGroupName
                }
            }
            catch {
                Write-ErrorMsg "  ✗ Failed to sync DCR: $($_.Exception.Message)"
                $syncResults.DCRsFailed += @{
                    SubscriptionId = $subId
                    Error = $_.Exception.Message
                }
                $syncResults.Errors += "DCR sync in $subId : $($_.Exception.Message)"
            }
            finally {
                Remove-Item -Path $dcrTemplatePath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-ErrorMsg "  ✗ Failed to process subscription: $($_.Exception.Message)"
            $syncResults.Errors += "Subscription $subId : $($_.Exception.Message)"
        }
        
        Write-Host ""
    }
    
    # Output summary
    Write-Host ""
    Write-Header "======================================================================"
    Write-Header "                              SUMMARY                                 "
    Write-Header "======================================================================"
    Write-Host ""
    
    Write-Host "Master DCR Found:          $($syncResults.MasterDCRFound)"
    Write-Host "Subscriptions Processed:   $($syncResults.SubscriptionsProcessed.Count)"
    Write-Success "DCRs Synced:               $($syncResults.DCRsSynced.Count)"
    if ($syncResults.DCRsFailed.Count -gt 0) {
        Write-ErrorMsg "DCRs Failed:               $($syncResults.DCRsFailed.Count)"
    }
    Write-Host ""
    
    if ($syncResults.DCRsSynced.Count -gt 0) {
        Write-Success "Successfully synced DCRs:"
        foreach ($synced in $syncResults.DCRsSynced) {
            Write-Success "  ✓ $($synced.SubscriptionName) ($($synced.SubscriptionId))"
        }
        Write-Host ""
    }
    
    if ($syncResults.DCRsFailed.Count -gt 0) {
        Write-ErrorMsg "Failed DCR syncs:"
        foreach ($failed in $syncResults.DCRsFailed) {
            Write-ErrorMsg "  ✗ $($failed.SubscriptionId): $($failed.Error)"
        }
        Write-Host ""
    }
    
    Write-Info "=== Next Steps ==="
    Write-Host ""
    Write-Host "1. Verify DCR associations are still valid for existing VMs"
    Write-Host "2. Run remediation tasks if needed to re-associate VMs with the restored DCR"
    Write-Host "3. Check Log Analytics workspace for incoming VM data"
    Write-Host ""
    
    # Return results and exit
    return $syncResults
}
#endregion

#region Validate Workspace Resource ID
# WorkspaceResourceId is required when not in AssignRolesAsSourceAdmin mode
if (-not $WorkspaceResourceId) {
    Write-ErrorMsg "WorkspaceResourceId is required."
    Write-ErrorMsg "Use -WorkspaceResourceId parameter or -AssignRolesAsSourceAdmin for source tenant admin mode."
    exit 1
}

Write-Info "Validating workspace resource ID..."

if ($WorkspaceResourceId -notmatch "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$") {
    Write-ErrorMsg "Invalid workspace resource ID format."
    exit 1
}

# Extract workspace details from resource ID
$workspaceIdParts = $WorkspaceResourceId -split "/"
$workspaceSubscriptionId = $workspaceIdParts[2]
$workspaceResourceGroup = $workspaceIdParts[4]
$workspaceName = $workspaceIdParts[8]

Write-Success "  Workspace Name: $workspaceName"
Write-Success "  Workspace Resource Group: $workspaceResourceGroup"
Write-Success "  Workspace Subscription (Managing Tenant): $workspaceSubscriptionId"
Write-Host ""
#endregion

#region Get Subscriptions
if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
    $SubscriptionIds = @($context.Subscription.Id)
    Write-Info "No subscriptions specified. Using current subscription: $($context.Subscription.Name)"
}

Write-Info "Subscriptions to configure: $($SubscriptionIds.Count)"
foreach ($subId in $SubscriptionIds) {
    Write-Host "  - $subId"
}
Write-Host ""
#endregion

#region Create Data Collection Rule
if (-not $SkipDCRCreation) {
    Write-Info "Creating Data Collection Rule: $DataCollectionRuleName"
    Write-Host ""
    
    # IMPORTANT: Create DCR in the SOURCE TENANT subscription, NOT the workspace subscription
    # This is critical for cross-tenant scenarios because:
    # 1. Azure Policy creates managed identities in the source tenant
    # 2. These managed identities can only access resources in their own tenant
    # 3. If DCR is in managing tenant, policy will fail with "not authorized to access linked subscription"
    # 4. The DCR can still send data to the Log Analytics workspace in the managing tenant (cross-tenant data flow is supported)
    
    # Use the first source subscription for DCR creation
    $dcrSubscriptionId = $SubscriptionIds[0]
    $dcrResourceGroupName = $ResourceGroupName
    
    Write-Info "  DCR will be created in SOURCE TENANT (required for Azure Policy to work)"
    Write-Host "    Source Subscription: $dcrSubscriptionId"
    Write-Host "    Resource Group: $dcrResourceGroupName"
    Write-Host "    Target Workspace: $workspaceName (in managing tenant)"
    Write-Host ""
    
    Set-AzContext -SubscriptionId $dcrSubscriptionId -ErrorAction Stop | Out-Null
    
    # Check if resource group exists in source tenant, create if not
    $dcrRg = Get-AzResourceGroup -Name $dcrResourceGroupName -ErrorAction SilentlyContinue
    if (-not $dcrRg) {
        Write-Info "  Creating resource group '$dcrResourceGroupName' in source tenant..."
        try {
            New-AzResourceGroup -Name $dcrResourceGroupName -Location $Location -ErrorAction Stop | Out-Null
            Write-Success "  ✓ Resource group created"
        }
        catch {
            Write-ErrorMsg "  ✗ Failed to create resource group: $($_.Exception.Message)"
            $results.Errors += "Resource group creation failed: $($_.Exception.Message)"
        }
    }
    
    # Check if DCR already exists
    $existingDCR = Get-AzDataCollectionRule -Name $DataCollectionRuleName -ResourceGroupName $dcrResourceGroupName -ErrorAction SilentlyContinue
    
    # Variable to track if we need to create Master DCR
    $sourceDCRCreatedOrExists = $false
    
    if ($existingDCR) {
        Write-WarningMsg "  Data Collection Rule '$DataCollectionRuleName' already exists in source tenant"
        $results.DataCollectionRuleId = $existingDCR.Id
        $sourceDCRCreatedOrExists = $true
    }
    else {
        Write-Host "  Creating new Data Collection Rule in source tenant..."
        Write-Host "  DCR Location: $Location"
        Write-Host "  DCR Resource Group: $dcrResourceGroupName"
        Write-Host "  Target Workspace: $WorkspaceResourceId (in managing tenant)"
        
        # Create DCR using ARM template
        $dcrTemplate = @{
            '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
            contentVersion = "1.0.0.0"
            resources = @(
                @{
                    type = "Microsoft.Insights/dataCollectionRules"
                    apiVersion = "2022-06-01"
                    name = $DataCollectionRuleName
                    location = $Location
                    properties = @{
                        description = "Data Collection Rule for VM logs - Cross-tenant collection"
                        dataSources = @{
                            performanceCounters = @(
                                @{
                                    name = "perfCounterDataSource"
                                    streams = @("Microsoft-Perf")
                                    samplingFrequencyInSeconds = 60
                                    counterSpecifiers = @(
                                        "\\Processor(_Total)\\% Processor Time",
                                        "\\Memory\\Available MBytes",
                                        "\\Memory\\% Committed Bytes In Use",
                                        "\\LogicalDisk(_Total)\\% Free Space",
                                        "\\LogicalDisk(_Total)\\Free Megabytes",
                                        "\\PhysicalDisk(_Total)\\Avg. Disk Queue Length",
                                        "\\Network Interface(*)\\Bytes Total/sec"
                                    )
                                }
                            )
                            windowsEventLogs = @(
                                @{
                                    name = "windowsEventLogs"
                                    streams = @("Microsoft-Event")
                                    xPathQueries = @(
                                        "Application!*[System[(Level=1 or Level=2 or Level=3 or Level=4)]]",
                                        "Security!*[System[(band(Keywords,13510798882111488))]]",
                                        "System!*[System[(Level=1 or Level=2 or Level=3 or Level=4)]]"
                                    )
                                }
                            )
                            syslog = @(
                                @{
                                    name = "syslogDataSource"
                                    streams = @("Microsoft-Syslog")
                                    facilityNames = @("auth", "authpriv", "cron", "daemon", "kern", "syslog", "user")
                                    logLevels = @("Debug", "Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency")
                                }
                            )
                        }
                        destinations = @{
                            logAnalytics = @(
                                @{
                                    name = $workspaceName
                                    workspaceResourceId = $WorkspaceResourceId
                                }
                            )
                        }
                        dataFlows = @(
                            @{ streams = @("Microsoft-Perf"); destinations = @($workspaceName) },
                            @{ streams = @("Microsoft-Event"); destinations = @($workspaceName) },
                            @{ streams = @("Microsoft-Syslog"); destinations = @($workspaceName) }
                        )
                    }
                }
            )
            outputs = @{
                dataCollectionRuleId = @{
                    type = "string"
                    value = "[resourceId('Microsoft.Insights/dataCollectionRules', '$DataCollectionRuleName')]"
                }
            }
        }
        
        # Save template to temp file
        $tempDir = [System.IO.Path]::GetTempPath()
        $dcrTemplatePath = Join-Path $tempDir "dcr-template.json"
        $dcrTemplate | ConvertTo-Json -Depth 20 | Set-Content -Path $dcrTemplatePath -Encoding UTF8
        
        try {
            $dcrDeployment = New-AzResourceGroupDeployment `
                -Name "DCR-Deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
                -ResourceGroupName $dcrResourceGroupName `
                -TemplateFile $dcrTemplatePath `
                -ErrorAction Stop
            
            $results.DataCollectionRuleId = $dcrDeployment.Outputs.dataCollectionRuleId.Value
            Write-Success "  ✓ Data Collection Rule created successfully in source tenant"
            Write-Success "  DCR ID: $($results.DataCollectionRuleId)"
            $sourceDCRCreatedOrExists = $true
        }
        catch {
            Write-ErrorMsg "  ✗ Failed to create DCR: $($_.Exception.Message)"
            $results.Errors += "DCR creation failed: $($_.Exception.Message)"
        }
        finally {
            Remove-Item -Path $dcrTemplatePath -Force -ErrorAction SilentlyContinue
        }
    }
    
    # Store the DCR resource group name for later use
    $results.DCRResourceGroupName = $dcrResourceGroupName
    $results.DCRSubscriptionId = $dcrSubscriptionId
    
    #region Create Master DCR in Managing Tenant (Backup/Template)
    # This runs regardless of whether source DCR was newly created or already existed
    if ($sourceDCRCreatedOrExists -and -not $SkipMasterDCR) {
        Write-Host ""
        Write-Info "Creating/updating Master DCR in managing tenant (backup/template)..."
        Write-Host "  Master DCR Resource Group: $MasterDCRResourceGroup"
        Write-Host "  Master DCR Subscription: $workspaceSubscriptionId"
        
        try {
            # Switch to managing tenant subscription
            Set-AzContext -SubscriptionId $workspaceSubscriptionId -ErrorAction Stop | Out-Null
            
            # Check if Master DCR resource group exists, create if not
            $masterRg = Get-AzResourceGroup -Name $MasterDCRResourceGroup -ErrorAction SilentlyContinue
            if (-not $masterRg) {
                Write-Host "  Creating Master DCR resource group..."
                New-AzResourceGroup -Name $MasterDCRResourceGroup -Location $Location -ErrorAction Stop | Out-Null
                Write-Success "  ✓ Master DCR resource group created"
            }
            
            # Build the DCR template for Master DCR
            $masterDcrTemplate = @{
                '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
                contentVersion = "1.0.0.0"
                resources = @(
                    @{
                        type = "Microsoft.Insights/dataCollectionRules"
                        apiVersion = "2022-06-01"
                        name = $DataCollectionRuleName
                        location = $Location
                        properties = @{
                            description = "Master DCR template for VM logs - Cross-tenant collection (backup/governance)"
                            dataSources = @{
                                performanceCounters = @(
                                    @{
                                        name = "perfCounterDataSource"
                                        streams = @("Microsoft-Perf")
                                        samplingFrequencyInSeconds = 60
                                        counterSpecifiers = @(
                                            "\\Processor(_Total)\\% Processor Time",
                                            "\\Memory\\Available MBytes",
                                            "\\Memory\\% Committed Bytes In Use",
                                            "\\LogicalDisk(_Total)\\% Free Space",
                                            "\\LogicalDisk(_Total)\\Free Megabytes",
                                            "\\PhysicalDisk(_Total)\\Avg. Disk Queue Length",
                                            "\\Network Interface(*)\\Bytes Total/sec"
                                        )
                                    }
                                )
                                windowsEventLogs = @(
                                    @{
                                        name = "windowsEventLogs"
                                        streams = @("Microsoft-Event")
                                        xPathQueries = @(
                                            "Application!*[System[(Level=1 or Level=2 or Level=3 or Level=4)]]",
                                            "Security!*[System[(band(Keywords,13510798882111488))]]",
                                            "System!*[System[(Level=1 or Level=2 or Level=3 or Level=4)]]"
                                        )
                                    }
                                )
                                syslog = @(
                                    @{
                                        name = "syslogDataSource"
                                        streams = @("Microsoft-Syslog")
                                        facilityNames = @("auth", "authpriv", "cron", "daemon", "kern", "syslog", "user")
                                        logLevels = @("Debug", "Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency")
                                    }
                                )
                            }
                            destinations = @{
                                logAnalytics = @(
                                    @{
                                        name = $workspaceName
                                        workspaceResourceId = $WorkspaceResourceId
                                    }
                                )
                            }
                            dataFlows = @(
                                @{ streams = @("Microsoft-Perf"); destinations = @($workspaceName) },
                                @{ streams = @("Microsoft-Event"); destinations = @($workspaceName) },
                                @{ streams = @("Microsoft-Syslog"); destinations = @($workspaceName) }
                            )
                        }
                    }
                )
                outputs = @{
                    dataCollectionRuleId = @{
                        type = "string"
                        value = "[resourceId('Microsoft.Insights/dataCollectionRules', '$DataCollectionRuleName')]"
                    }
                }
            }
            
            # Save template to temp file
            $tempDir = [System.IO.Path]::GetTempPath()
            $masterDcrTemplatePath = Join-Path $tempDir "master-dcr-template.json"
            $masterDcrTemplate | ConvertTo-Json -Depth 20 | Set-Content -Path $masterDcrTemplatePath -Encoding UTF8
            
            $masterDcrDeployment = New-AzResourceGroupDeployment `
                -Name "Master-DCR-Deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
                -ResourceGroupName $MasterDCRResourceGroup `
                -TemplateFile $masterDcrTemplatePath `
                -ErrorAction Stop
            
            $results.MasterDCRId = $masterDcrDeployment.Outputs.dataCollectionRuleId.Value
            Write-Success "  ✓ Master DCR created/updated in managing tenant"
            Write-Success "  Master DCR ID: $($results.MasterDCRId)"
            
            Remove-Item -Path $masterDcrTemplatePath -Force -ErrorAction SilentlyContinue
            
            # Switch back to source tenant subscription
            Set-AzContext -SubscriptionId $dcrSubscriptionId -ErrorAction Stop | Out-Null
        }
        catch {
            Write-WarningMsg "  ⚠ Could not create/update Master DCR: $($_.Exception.Message)"
            Write-WarningMsg "  The source tenant DCR is available for use."
            Write-WarningMsg "  You can manually create a Master DCR later for backup purposes."
            $results.Errors += "Master DCR creation failed: $($_.Exception.Message)"
            
            # Make sure we're back in source tenant context
            Set-AzContext -SubscriptionId $dcrSubscriptionId -ErrorAction SilentlyContinue | Out-Null
        }
    }
    elseif (-not $sourceDCRCreatedOrExists) {
        Write-WarningMsg "  Skipping Master DCR creation (source DCR not available)"
    }
    elseif ($SkipMasterDCR) {
        Write-Info "  Skipping Master DCR creation (-SkipMasterDCR specified)"
    }
    #endregion
}
else {
    Write-Info "Skipping DCR creation (--SkipDCRCreation specified)"
    
    # Try to get existing DCR from source tenant (first subscription)
    $dcrSubscriptionId = $SubscriptionIds[0]
    $dcrResourceGroupName = $ResourceGroupName
    
    Set-AzContext -SubscriptionId $dcrSubscriptionId -ErrorAction Stop | Out-Null
    
    $existingDCR = Get-AzDataCollectionRule -Name $DataCollectionRuleName -ResourceGroupName $dcrResourceGroupName -ErrorAction SilentlyContinue
    if ($existingDCR) {
        $results.DataCollectionRuleId = $existingDCR.Id
        $results.DCRResourceGroupName = $dcrResourceGroupName
        $results.DCRSubscriptionId = $dcrSubscriptionId
        Write-Success "  Found existing DCR: $($existingDCR.Id)"
    }
    else {
        Write-WarningMsg "  Could not find existing DCR '$DataCollectionRuleName' in resource group '$dcrResourceGroupName'"
        Write-WarningMsg "  Make sure the DCR exists in the source tenant subscription: $dcrSubscriptionId"
    }
}
Write-Host ""
#endregion

#region Process VMs in Each Subscription
Write-Info "Processing Virtual Machines in delegated subscriptions..."
Write-Host ""

foreach ($subId in $SubscriptionIds) {
    $results.SubscriptionsProcessed += $subId
    
    Write-Info "Processing subscription: $subId"
    
    try {
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
        $subName = (Get-AzContext).Subscription.Name
        Write-Host "  Subscription name: $subName"
        
        # Get all VMs in the subscription
        $vms = Get-AzVM -ErrorAction SilentlyContinue
        
        if (-not $vms -or $vms.Count -eq 0) {
            Write-WarningMsg "  No VMs found in subscription $subId"
            continue
        }
        
        Write-Host "  Found $($vms.Count) VM(s)"
        Write-Host ""
        
        foreach ($vm in $vms) {
            Write-Host "  Processing VM: $($vm.Name)"
            
            try {
                # Check VM power state before attempting configuration
                $vmStatus = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status -ErrorAction SilentlyContinue
                $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
                
                if ($powerState -ne "VM running") {
                    Write-WarningMsg "    ⚠ VM is not running (Status: $powerState) - Skipping agent installation"
                    Write-Host "    Note: DCR association will still be created for when VM starts"
                    Write-Info "    ℹ When VM starts, Azure Policy will automatically:"
                    Write-Info "      1. Enable System Assigned Managed Identity (Identity policy)"
                    Write-Info "      2. Install Azure Monitor Agent (AMA policy)"
                    Write-Info "      3. Associate VM with DCR (DCR policy)"
                    Write-WarningMsg "    ⚠ Note: Policy evaluation may take up to 24 hours. To expedite:"
                    Write-WarningMsg "      - Trigger a compliance scan: Start-AzPolicyComplianceScan -ResourceGroupName '<RG>'"
                    Write-WarningMsg "      - Or manually enable managed identity and run remediation tasks"
                    $results.VMsSkipped += @{
                        Id = $vm.Id
                        Name = $vm.Name
                        PowerState = $powerState
                        Reason = "VM not running"
                        NeedsManagedIdentity = $true
                    }
                    
                    # Still create DCR association even for stopped VMs
                    # The association will be active when the VM starts
                    $osType = $vm.StorageProfile.OsDisk.OsType
                    Write-Host "    OS Type: $osType"
                    
                    #region Create DCR Association for stopped VM
                    Write-Host "    Creating DCR association (will be active when VM starts)..."
                    
                    $associationName = "dcr-association-$($vm.Name)"
                    
                    # Check if association already exists
                    $existingAssociation = Get-AzDataCollectionRuleAssociation -TargetResourceId $vm.Id -AssociationName $associationName -ErrorAction SilentlyContinue
                    
                    if ($existingAssociation) {
                        Write-Success "    ✓ DCR association already exists"
                    }
                    else {
                        try {
                            New-AzDataCollectionRuleAssociation `
                                -TargetResourceId $vm.Id `
                                -AssociationName $associationName `
                                -RuleId $results.DataCollectionRuleId `
                                -ErrorAction Stop | Out-Null
                            
                            Write-Success "    ✓ DCR association created"
                            $results.DCRAssociationsCreated += $vm.Id
                        }
                        catch {
                            Write-ErrorMsg "    ✗ Failed to create DCR association: $($_.Exception.Message)"
                            $results.Errors += "DCR association failed for $($vm.Name): $($_.Exception.Message)"
                        }
                    }
                    #endregion
                    
                    Write-WarningMsg "    ⚠ VM skipped (not running) - Start VM and re-run to install agent"
                    continue
                }
                
                $osType = $vm.StorageProfile.OsDisk.OsType
                Write-Host "    OS Type: $osType"
                Write-Host "    Power State: $powerState"
                
                #region Enable System Assigned Managed Identity (Required for Azure Policy)
                # The AMA policy (ca817e41-e85a-4783-bc7f-dc532d36235e) requires VMs to have
                # System Assigned Managed Identity. Without it, the policy ignores the VM.
                Write-Host "    Checking System Assigned Managed Identity..."
                
                $hasSystemIdentity = $false
                if ($vm.Identity -and $vm.Identity.Type) {
                    $hasSystemIdentity = $vm.Identity.Type -like "*SystemAssigned*"
                }
                
                if ($hasSystemIdentity) {
                    Write-Success "    ✓ System Assigned Managed Identity already enabled"
                }
                else {
                    Write-Host "    Enabling System Assigned Managed Identity..."
                    Write-Host "      (Required for Azure Policy to install AMA automatically)"
                    
                    try {
                        # Get the current VM configuration
                        $vmConfig = Get-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -ErrorAction Stop
                        
                        # Determine the new identity type and handle existing user-assigned identities
                        $currentIdentityType = $vmConfig.Identity.Type
                        
                        if ($currentIdentityType -like "*UserAssigned*") {
                            # VM has user-assigned identity (could be "UserAssigned" or "SystemAssigned, UserAssigned")
                            # We need to preserve the existing user-assigned identity IDs
                            $existingIdentityIds = @($vmConfig.Identity.UserAssignedIdentities.Keys)
                            
                            if ($existingIdentityIds.Count -gt 0) {
                                Write-Host "      Preserving $($existingIdentityIds.Count) existing user-assigned identity(ies)"
                                
                                # Update with SystemAssignedUserAssigned, preserving existing user-assigned identities
                                Update-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $vmConfig `
                                    -IdentityType "SystemAssignedUserAssigned" `
                                    -IdentityId $existingIdentityIds `
                                    -ErrorAction Stop | Out-Null
                            }
                            else {
                                # Edge case: UserAssigned type but no identity IDs (shouldn't happen, but handle gracefully)
                                Update-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $vmConfig `
                                    -IdentityType "SystemAssigned" `
                                    -ErrorAction Stop | Out-Null
                            }
                        }
                        else {
                            # VM has no identity or only SystemAssigned - just set SystemAssigned
                            Update-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $vmConfig `
                                -IdentityType "SystemAssigned" `
                                -ErrorAction Stop | Out-Null
                        }
                        
                        Write-Success "    ✓ System Assigned Managed Identity enabled"
                        
                        # Track that we enabled identity
                        if (-not $results.IdentitiesEnabled) {
                            $results.IdentitiesEnabled = @()
                        }
                        $results.IdentitiesEnabled += @{
                            VMName = $vm.Name
                            VMId = $vm.Id
                            IdentityType = $newIdentityType
                        }
                    }
                    catch {
                        Write-ErrorMsg "    ✗ Failed to enable managed identity: $($_.Exception.Message)"
                        Write-WarningMsg "      Azure Policy may not be able to install AMA on this VM automatically."
                        Write-WarningMsg "      Manually enable System Assigned Managed Identity for policy coverage."
                        $results.Errors += "Managed identity for $($vm.Name): $($_.Exception.Message)"
                    }
                }
                #endregion
                
                #region Install Azure Monitor Agent
                if (-not $SkipAgentInstallation) {
                    $extensionName = if ($osType -eq "Windows") { "AzureMonitorWindowsAgent" } else { "AzureMonitorLinuxAgent" }
                    
                    # Check if agent is already installed
                    $existingExtension = Get-AzVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -Name $extensionName -ErrorAction SilentlyContinue
                    
                    if ($existingExtension) {
                        Write-Success "    ✓ Azure Monitor Agent already installed"
                    }
                    else {
                        Write-Host "    Installing Azure Monitor Agent..."
                        
                        try {
                            Set-AzVMExtension `
                                -ResourceGroupName $vm.ResourceGroupName `
                                -VMName $vm.Name `
                                -Name $extensionName `
                                -Publisher "Microsoft.Azure.Monitor" `
                                -ExtensionType $extensionName `
                                -TypeHandlerVersion "1.0" `
                                -EnableAutomaticUpgrade $true `
                                -ErrorAction Stop | Out-Null
                            
                            Write-Success "    ✓ Azure Monitor Agent installed"
                            $results.AgentsInstalled += $vm.Id
                        }
                        catch {
                            Write-ErrorMsg "    ✗ Failed to install agent: $($_.Exception.Message)"
                            $results.Errors += "Agent installation failed for $($vm.Name): $($_.Exception.Message)"
                            $results.VMsFailed += $vm.Id
                            continue
                        }
                    }
                }
                #endregion
                
                #region Create DCR Association
                Write-Host "    Creating DCR association..."
                
                $associationName = "dcr-association-$($vm.Name)"
                
                # Check if association already exists
                $existingAssociation = Get-AzDataCollectionRuleAssociation -TargetResourceId $vm.Id -AssociationName $associationName -ErrorAction SilentlyContinue
                
                if ($existingAssociation) {
                    Write-Success "    ✓ DCR association already exists"
                }
                else {
                    try {
                        New-AzDataCollectionRuleAssociation `
                            -TargetResourceId $vm.Id `
                            -AssociationName $associationName `
                            -RuleId $results.DataCollectionRuleId `
                            -ErrorAction Stop | Out-Null
                        
                        Write-Success "    ✓ DCR association created"
                        $results.DCRAssociationsCreated += $vm.Id
                    }
                    catch {
                        Write-ErrorMsg "    ✗ Failed to create DCR association: $($_.Exception.Message)"
                        $results.Errors += "DCR association failed for $($vm.Name): $($_.Exception.Message)"
                        $results.VMsFailed += $vm.Id
                        continue
                    }
                }
                #endregion
                
                $results.VMsConfigured += $vm.Id
                Write-Success "    ✓ VM configured successfully"
            }
            catch {
                Write-ErrorMsg "    ✗ Failed to configure VM: $($_.Exception.Message)"
                $results.Errors += "VM $($vm.Name): $($_.Exception.Message)"
                $results.VMsFailed += $vm.Id
            }
            
            Write-Host ""
        }
    }
    catch {
        Write-ErrorMsg "  ✗ Failed to process subscription: $($_.Exception.Message)"
        $results.Errors += "Subscription $subId : $($_.Exception.Message)"
    }
}
#endregion

#region Deploy Azure Policy for Automatic Agent Installation
if ($DeployPolicy -and $results.DataCollectionRuleId) {
    Write-Host ""
    Write-Info "Deploying Azure Policy for automatic agent installation..."
    Write-Host ""
    Write-Info "This ensures that:"
    Write-Host "  - Stopped VMs get the agent when they come back online"
    Write-Host "  - New VMs automatically get the agent and DCR association"
    Write-Host ""
    
    # Function to create policy assignment using REST API (works reliably in cross-tenant scenarios)
    function New-PolicyAssignmentWithIdentity {
        param(
            [string]$SubscriptionId,
            [string]$AssignmentName,
            [string]$DisplayName,
            [string]$PolicyDefinitionId,
            [string]$Scope,
            [string]$Location,
            [hashtable]$Parameters = @{}
        )
        
        $assignmentId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyAssignments/$AssignmentName"
        
        # Build the request body
        $body = @{
            location = $Location
            identity = @{
                type = "SystemAssigned"
            }
            properties = @{
                displayName = $DisplayName
                policyDefinitionId = $PolicyDefinitionId
                scope = $Scope
                enforcementMode = "Default"
            }
        }
        
        # Add parameters if provided
        if ($Parameters.Count -gt 0) {
            $parameterValues = @{}
            foreach ($key in $Parameters.Keys) {
                $parameterValues[$key] = @{ value = $Parameters[$key] }
            }
            $body.properties.parameters = $parameterValues
        }
        
        $jsonBody = $body | ConvertTo-Json -Depth 10
        
        # Use REST API to create the assignment
        $response = Invoke-AzRestMethod `
            -Path "$assignmentId`?api-version=2022-06-01" `
            -Method PUT `
            -Payload $jsonBody
        
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            $result = $response.Content | ConvertFrom-Json
            return @{
                Success = $true
                AssignmentId = $assignmentId
                PrincipalId = $result.identity.principalId
                TenantId = $result.identity.tenantId
                Response = $result
            }
        }
        else {
            $errorContent = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            $errorMessage = if ($errorContent.error.message) { $errorContent.error.message } else { $response.Content }
            return @{
                Success = $false
                AssignmentId = $assignmentId
                Error = $errorMessage
                StatusCode = $response.StatusCode
            }
        }
    }
    
    foreach ($subId in $SubscriptionIds) {
        Write-Info "Deploying policies to subscription: $subId"
        
        try {
            Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
            $scope = "/subscriptions/$subId"
            
            # Sort policies by priority to ensure proper deployment order:
            # 1. Identity policies (enable managed identity on VMs)
            # 2. AMA policies (install Azure Monitor Agent - requires managed identity)
            # 3. DCR policies (associate VMs with Data Collection Rule)
            $sortedPolicyKeys = $PolicyDefinitions.Keys | Sort-Object { $PolicyDefinitions[$_].Priority }
            
            foreach ($policyKey in $sortedPolicyKeys) {
                $policyDef = $PolicyDefinitions[$policyKey]
                $assignmentName = "$PolicyAssignmentPrefix-$policyKey-$($subId.Substring(0,8))"
                
                Write-Host "  Assigning policy: $($policyDef.DisplayName)"
                
                try {
                    # Check if assignment already exists
                    $existingAssignment = Get-AzPolicyAssignment -Name $assignmentName -Scope $scope -ErrorAction SilentlyContinue
                    
                    if ($existingAssignment) {
                        Write-WarningMsg "    Policy assignment already exists. Adding to remediation list..."
                        # Add existing assignment to the list for remediation
                        # Construct the assignment ID manually as a fallback
                        $assignmentId = $existingAssignment.ResourceId
                        if (-not $assignmentId) {
                            $assignmentId = $existingAssignment.PolicyAssignmentId
                        }
                        if (-not $assignmentId) {
                            # Construct manually if properties are not available
                            $assignmentId = "/subscriptions/$subId/providers/Microsoft.Authorization/policyAssignments/$assignmentName"
                        }
                        
                        $results.PolicyAssignmentsCreated += @{
                            Name = $assignmentName
                            PolicyKey = $policyKey
                            SubscriptionId = $subId
                            AssignmentId = $assignmentId
                            PrincipalId = $existingAssignment.Identity.PrincipalId
                            Existing = $true
                        }
                        Write-Host "      Assignment ID: $assignmentId"
                        
                        # Check if existing assignment has a managed identity
                        if (-not $existingAssignment.Identity.PrincipalId) {
                            Write-WarningMsg "    ⚠ Existing assignment has no managed identity!"
                            Write-WarningMsg "      The policy cannot perform remediation without an identity."
                            Write-WarningMsg "      Delete the assignment and re-run the script to fix this."
                        }
                        continue
                    }
                    
                    # Prepare parameters based on policy type
                    $policyParams = @{}
                    if ($policyKey -like "DCR-*") {
                        $policyParams = @{ "dcrResourceId" = $results.DataCollectionRuleId }
                    }
                    
                    # Create the policy assignment using REST API (more reliable for cross-tenant)
                    Write-Host "    Creating policy assignment with managed identity (using REST API)..."
                    
                    $assignmentResult = New-PolicyAssignmentWithIdentity `
                        -SubscriptionId $subId `
                        -AssignmentName $assignmentName `
                        -DisplayName "$($policyDef.DisplayName) - Cross-Tenant Monitoring" `
                        -PolicyDefinitionId $policyDef.Id `
                        -Scope $scope `
                        -Location $Location `
                        -Parameters $policyParams
                    
                    if ($assignmentResult.Success) {
                        Write-Success "    ✓ Policy assigned with managed identity"
                        Write-Host "      Assignment ID: $($assignmentResult.AssignmentId)"
                        Write-Host "      Identity Principal ID: $($assignmentResult.PrincipalId)"
                        Write-Host "      Identity Tenant ID: $($assignmentResult.TenantId)"
                        
                        $results.PolicyAssignmentsCreated += @{
                            Name = $assignmentName
                            PolicyKey = $policyKey
                            SubscriptionId = $subId
                            AssignmentId = $assignmentResult.AssignmentId
                            PrincipalId = $assignmentResult.PrincipalId
                            TenantId = $assignmentResult.TenantId
                            RoleAssigned = $false
                        }
                        
                        # Attempt to grant the managed identity the required permissions
                        # This may fail in cross-tenant scenarios without User Access Administrator
                        if ($assignmentResult.PrincipalId) {
                            Write-Host "    Attempting to grant permissions to managed identity..."
                            Write-Host "    Waiting 20 seconds for identity to propagate in Azure AD..."
                            Start-Sleep -Seconds 20
                            
                            # Retry logic for role assignment (identity propagation can take time)
                            $maxRetries = 3
                            $retryCount = 0
                            $roleAssigned = $false
                            $roleAssignmentFailed = $false
                            $roleAssignmentError = ""
                            
                            while (-not $roleAssigned -and -not $roleAssignmentFailed -and $retryCount -lt $maxRetries) {
                                try {
                                    New-AzRoleAssignment `
                                        -ObjectId $assignmentResult.PrincipalId `
                                        -RoleDefinitionName "Contributor" `
                                        -Scope $scope `
                                        -ErrorAction Stop | Out-Null
                                    Write-Success "    ✓ Contributor role assigned"
                                    $roleAssigned = $true
                                    # Update the results
                                    $results.PolicyAssignmentsCreated[-1].RoleAssigned = $true
                                }
                                catch {
                                    if ($_.Exception.Message -like "*already exists*" -or $_.Exception.Message -like "*Conflict*") {
                                        Write-Success "    ✓ Contributor role already assigned"
                                        $roleAssigned = $true
                                        $results.PolicyAssignmentsCreated[-1].RoleAssigned = $true
                                    }
                                    elseif ($_.Exception.Message -like "*does not exist*" -or $_.Exception.Message -like "*PrincipalNotFound*") {
                                        $retryCount++
                                        if ($retryCount -lt $maxRetries) {
                                            Write-WarningMsg "    ⚠ Identity not yet available, retrying in 10 seconds... (attempt $retryCount of $maxRetries)"
                                            Start-Sleep -Seconds 10
                                        }
                                        else {
                                            $roleAssignmentFailed = $true
                                            $roleAssignmentError = "Identity not found after $maxRetries attempts"
                                        }
                                    }
                                    elseif ($_.Exception.Message -like "*AuthorizationFailed*" -or $_.Exception.Message -like "*does not have authorization*") {
                                        # This is expected in cross-tenant scenarios without User Access Administrator
                                        $roleAssignmentFailed = $true
                                        $roleAssignmentError = "No permission to assign roles (User Access Administrator required)"
                                    }
                                    else {
                                        $roleAssignmentFailed = $true
                                        $roleAssignmentError = $_.Exception.Message
                                    }
                                }
                            }
                            
                            if ($roleAssignmentFailed) {
                                Write-WarningMsg "    ⚠ Could not assign Contributor role: $roleAssignmentError"
                                Write-WarningMsg "    → Manual role assignment required (see instructions at end of script)"
                                
                                # Track identities that need manual role assignment
                                if (-not $results.IdentitiesNeedingRoles) {
                                    $results.IdentitiesNeedingRoles = @()
                                }
                                $results.IdentitiesNeedingRoles += @{
                                    PrincipalId = $assignmentResult.PrincipalId
                                    PolicyKey = $policyKey
                                    SubscriptionId = $subId
                                    Scope = $scope
                                    RoleNeeded = "Contributor"
                                }
                            }
                            
                            # For DCR policies, also need Monitoring Contributor on the DCR
                            if ($policyKey -like "DCR-*" -and $roleAssigned) {
                                try {
                                    New-AzRoleAssignment `
                                        -ObjectId $assignmentResult.PrincipalId `
                                        -RoleDefinitionName "Monitoring Contributor" `
                                        -Scope $results.DataCollectionRuleId `
                                        -ErrorAction Stop | Out-Null
                                    Write-Success "    ✓ Monitoring Contributor role assigned on DCR"
                                }
                                catch {
                                    if ($_.Exception.Message -like "*already exists*" -or $_.Exception.Message -like "*Conflict*") {
                                        Write-Success "    ✓ Monitoring Contributor role already assigned on DCR"
                                    }
                                    else {
                                        Write-WarningMsg "    ⚠ Could not assign Monitoring Contributor role on DCR"
                                        if (-not $results.IdentitiesNeedingRoles) {
                                            $results.IdentitiesNeedingRoles = @()
                                        }
                                        $results.IdentitiesNeedingRoles += @{
                                            PrincipalId = $assignmentResult.PrincipalId
                                            PolicyKey = $policyKey
                                            SubscriptionId = $subId
                                            Scope = $results.DataCollectionRuleId
                                            RoleNeeded = "Monitoring Contributor"
                                        }
                                    }
                                }
                            }
                        }
                    }
                    else {
                        Write-ErrorMsg "    ✗ Failed to create policy assignment: $($assignmentResult.Error)"
                        $results.PolicyAssignmentsFailed += @{
                            PolicyKey = $policyKey
                            SubscriptionId = $subId
                            Error = $assignmentResult.Error
                        }
                        $results.Errors += "Policy $policyKey in $subId : $($assignmentResult.Error)"
                    }
                }
                catch {
                    Write-ErrorMsg "    ✗ Failed to assign policy: $($_.Exception.Message)"
                    $results.PolicyAssignmentsFailed += @{
                        PolicyKey = $policyKey
                        SubscriptionId = $subId
                        Error = $_.Exception.Message
                    }
                    $results.Errors += "Policy $policyKey in $subId : $($_.Exception.Message)"
                }
            }
        }
        catch {
            Write-ErrorMsg "  ✗ Failed to process subscription for policy: $($_.Exception.Message)"
            $results.Errors += "Policy deployment in $subId : $($_.Exception.Message)"
        }
        
        Write-Host ""
    }
    
    #region Create Remediation Tasks
    if (-not $SkipRemediation -and $results.PolicyAssignmentsCreated.Count -gt 0) {
        Write-Host ""
        Write-Info "Creating remediation tasks for existing non-compliant VMs..."
        Write-Host ""
        Write-Info "Note: Remediation tasks will apply policies to existing running VMs."
        Write-Info "      Stopped VMs will be remediated automatically when they start."
        Write-Host ""
        
        Write-Host "  Waiting 30 seconds for policy assignments to propagate..."
        Start-Sleep -Seconds 30
        
        foreach ($assignment in $results.PolicyAssignmentsCreated) {
            $remediationName = "remediate-$($assignment.Name)"
            
            Write-Host "  Creating remediation: $remediationName"
            
            try {
                Set-AzContext -SubscriptionId $assignment.SubscriptionId -ErrorAction Stop | Out-Null
                
                # Check for existing running remediations for this policy assignment
                $existingRemediations = Get-AzPolicyRemediation -Scope "/subscriptions/$($assignment.SubscriptionId)" -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.PolicyAssignmentId -eq $assignment.AssignmentId -and
                        $_.ProvisioningState -in @("Accepted", "Running", "Evaluating")
                    }
                
                if ($existingRemediations) {
                    Write-Success "    ✓ Remediation already in progress: $($existingRemediations[0].Name)"
                    Write-Host "      Status: $($existingRemediations[0].ProvisioningState)"
                    $results.RemediationTasksCreated += @{
                        Name = $existingRemediations[0].Name
                        PolicyKey = $assignment.PolicyKey
                        SubscriptionId = $assignment.SubscriptionId
                        Existing = $true
                    }
                    continue
                }
                
                $remediation = Start-AzPolicyRemediation `
                    -Name $remediationName `
                    -PolicyAssignmentId $assignment.AssignmentId `
                    -Scope "/subscriptions/$($assignment.SubscriptionId)" `
                    -ErrorAction Stop
                
                Write-Success "    ✓ Remediation task created"
                $results.RemediationTasksCreated += @{
                    Name = $remediationName
                    PolicyKey = $assignment.PolicyKey
                    SubscriptionId = $assignment.SubscriptionId
                }
            }
            catch {
                # Check if error is due to existing remediation (in case the check above missed it)
                if ($_.Exception.Message -like "*already running*" -or $_.Exception.Message -like "*InvalidCreateRemediationRequest*") {
                    Write-Success "    ✓ Remediation already in progress for this policy"
                    $results.RemediationTasksCreated += @{
                        Name = $remediationName
                        PolicyKey = $assignment.PolicyKey
                        SubscriptionId = $assignment.SubscriptionId
                        Existing = $true
                    }
                }
                else {
                    Write-WarningMsg "    ⚠ Could not create remediation: $($_.Exception.Message)"
                }
            }
        }
    }
    elseif ($SkipRemediation) {
        Write-Host ""
        Write-Info "Skipping remediation tasks (--SkipRemediation specified)"
    }
    #endregion
}
elseif (-not $DeployPolicy) {
    Write-Host ""
    Write-Info "Skipping Azure Policy deployment (-DeployPolicy is false)"
    Write-Host ""
    Write-WarningMsg "Note: Without Azure Policy, stopped VMs will NOT automatically get the agent"
    Write-WarningMsg "      when they come back online. You will need to manually re-run this script."
}
#endregion

#region Output Summary
Write-Host ""
Write-Header "======================================================================"
Write-Header "                              SUMMARY                                 "
Write-Header "======================================================================"
Write-Host ""

Write-Host "Data Collection Rule:      $DataCollectionRuleName"
Write-Host "DCR Resource ID:           $($results.DataCollectionRuleId)"
Write-Host ""

Write-Host "Subscriptions Processed:   $($results.SubscriptionsProcessed.Count)"
Write-Host "VMs Configured:            $($results.VMsConfigured.Count)"
Write-Host "VMs Skipped (not running): $($results.VMsSkipped.Count)"
Write-Host "VMs Failed:                $($results.VMsFailed.Count)"
if ($results.IdentitiesEnabled) {
    Write-Host "Managed Identities Enabled: $($results.IdentitiesEnabled.Count)"
}
Write-Host "Agents Installed:          $($results.AgentsInstalled.Count)"
Write-Host "DCR Associations Created:  $($results.DCRAssociationsCreated.Count)"
Write-Host ""

if ($DeployPolicy) {
    Write-Host "Policy Assignments:        $($results.PolicyAssignmentsCreated.Count)"
    Write-Host "Remediation Tasks:         $($results.RemediationTasksCreated.Count)"
    Write-Host ""
}

if ($results.VMsConfigured.Count -gt 0) {
    Write-Success "Successfully configured VMs:"
    foreach ($vmId in $results.VMsConfigured | Select-Object -First 10) {
        $vmName = ($vmId -split "/")[-1]
        Write-Success "  ✓ $vmName"
    }
    if ($results.VMsConfigured.Count -gt 10) {
        Write-Success "  ... and $($results.VMsConfigured.Count - 10) more"
    }
    Write-Host ""
}

if ($results.IdentitiesEnabled -and $results.IdentitiesEnabled.Count -gt 0) {
    Write-Success "System Assigned Managed Identities enabled:"
    foreach ($identity in $results.IdentitiesEnabled | Select-Object -First 10) {
        Write-Success "  ✓ $($identity.VMName)"
    }
    if ($results.IdentitiesEnabled.Count -gt 10) {
        Write-Success "  ... and $($results.IdentitiesEnabled.Count - 10) more"
    }
    Write-Host ""
    Write-Info "Note: Managed identity is required for Azure Policy to install AMA automatically."
    Write-Host ""
}

if ($results.VMsSkipped.Count -gt 0) {
    Write-WarningMsg "Skipped VMs (not running):"
    foreach ($skipped in $results.VMsSkipped | Select-Object -First 10) {
        Write-WarningMsg "  ⚠ $($skipped.Name) - $($skipped.PowerState)"
    }
    if ($results.VMsSkipped.Count -gt 10) {
        Write-WarningMsg "  ... and $($results.VMsSkipped.Count - 10) more"
    }
    Write-Host ""
    if ($DeployPolicy) {
        Write-Info "Note: Azure Policy has been deployed to automatically configure these VMs"
        Write-Info "      when they come back online. The policies will:"
        Write-Info "      1. Enable System Assigned Managed Identity (Identity policy)"
        Write-Info "      2. Install Azure Monitor Agent (AMA policy)"
        Write-Info "      3. Associate VM with DCR (DCR policy)"
        Write-Host ""
        Write-WarningMsg "⚠ Policy evaluation timing:"
        Write-WarningMsg "  - Automatic evaluation occurs every 24 hours"
        Write-WarningMsg "  - To expedite, trigger a compliance scan after VM starts:"
        Write-WarningMsg "    Start-AzPolicyComplianceScan -ResourceGroupName '<RGName>'"
        Write-WarningMsg "  - Or run remediation tasks manually for immediate effect"
    }
    else {
        Write-Info "Note: DCR associations were created for skipped VMs."
        Write-Info "Start the VMs and re-run the script to install the Azure Monitor Agent."
    }
    Write-Host ""
}

if ($results.PolicyAssignmentsCreated.Count -gt 0) {
    Write-Success "Azure Policy Assignments Created:"
    foreach ($assignment in $results.PolicyAssignmentsCreated) {
        Write-Success "  ✓ $($assignment.PolicyKey)"
    }
    Write-Host ""
    Write-Info "Azure Policy ensures that:"
    Write-Host "  - Stopped VMs get the agent when they come back online"
    Write-Host "  - New VMs automatically get the agent and DCR association"
    Write-Host ""
}

if ($results.Errors.Count -gt 0) {
    Write-WarningMsg "Errors encountered:"
    foreach ($err in $results.Errors | Select-Object -First 5) {
        Write-ErrorMsg "  - $err"
    }
    Write-Host ""
}

# Output as JSON for automation
Write-Info "=== JSON Output (for automation) ==="
Write-Host ""
$identitiesEnabledCount = if ($results.IdentitiesEnabled) { $results.IdentitiesEnabled.Count } else { 0 }
$jsonOutput = @{
    dataCollectionRuleName = $results.DataCollectionRuleName
    dataCollectionRuleId = $results.DataCollectionRuleId
    subscriptionsProcessed = $results.SubscriptionsProcessed
    vmsConfiguredCount = $results.VMsConfigured.Count
    vmsSkippedCount = $results.VMsSkipped.Count
    vmsFailedCount = $results.VMsFailed.Count
    managedIdentitiesEnabledCount = $identitiesEnabledCount
    agentsInstalledCount = $results.AgentsInstalled.Count
    dcrAssociationsCreatedCount = $results.DCRAssociationsCreated.Count
    policyAssignmentsCreatedCount = $results.PolicyAssignmentsCreated.Count
    remediationTasksCreatedCount = $results.RemediationTasksCreated.Count
    errorsCount = $results.Errors.Count
} | ConvertTo-Json -Depth 2

Write-Host $jsonOutput
Write-Host ""

Write-Info "=== Verification Queries ==="
Write-Host ""
Write-Host "Run these queries in Log Analytics to verify VM data is flowing:"
Write-Host ""
Write-Host "// VM Performance data"
Write-Host "Perf"
Write-Host "| where TimeGenerated > ago(1h)"
Write-Host "| summarize count() by Computer, ObjectName"
Write-Host ""
Write-Host "// Windows Event Logs"
Write-Host "Event"
Write-Host "| where TimeGenerated > ago(1h)"
Write-Host "| summarize count() by Computer, EventLog"
Write-Host ""
Write-Host "// Linux Syslog"
Write-Host "Syslog"
Write-Host "| where TimeGenerated > ago(1h)"
Write-Host "| summarize count() by Computer, Facility"
Write-Host ""

Write-Info "=== Next Steps ==="
Write-Host ""
Write-Host "1. Wait 5-15 minutes for VM logs to start flowing"
Write-Host "2. Run the verification queries in Log Analytics"
Write-Host "3. Proceed to Step 5: Configure Azure Resource Diagnostic Logs"
Write-Host "4. Configure Microsoft Sentinel analytics rules for VM security events"
Write-Host ""

if ($results.VMsSkipped.Count -gt 0 -and -not $DeployPolicy) {
    Write-WarningMsg "=== ACTION REQUIRED: Stopped VMs Detected ==="
    Write-Host ""
    Write-Host "The following VMs were skipped because they are not running:"
    foreach ($skipped in $results.VMsSkipped) {
        Write-Host "  - $($skipped.Name) ($($skipped.PowerState))"
    }
    Write-Host ""
    Write-Host "To ensure these VMs get the Azure Monitor Agent when they start:"
    Write-Host "  1. Re-run this script with -DeployPolicy `$true (RECOMMENDED)"
    Write-Host "     This deploys Azure Policy for automatic agent installation"
    Write-Host ""
    Write-Host "  2. OR manually start the VMs and re-run this script"
    Write-Host ""
}
elseif ($results.VMsSkipped.Count -gt 0 -and $DeployPolicy) {
    Write-Success "=== AUTOMATIC COVERAGE ENABLED ==="
    Write-Host ""
    Write-Host "Azure Policy has been deployed. The following stopped VMs will"
    Write-Host "automatically get the Azure Monitor Agent when they start:"
    foreach ($skipped in $results.VMsSkipped) {
        Write-Host "  - $($skipped.Name) ($($skipped.PowerState))"
    }
    Write-Host ""
}

#region Manual Role Assignment Instructions
if ($results.IdentitiesNeedingRoles -and $results.IdentitiesNeedingRoles.Count -gt 0) {
    Write-Host ""
    Write-ErrorMsg "╔══════════════════════════════════════════════════════════════════════╗"
    Write-ErrorMsg "║  ACTION REQUIRED: Manual Role Assignment Needed                       ║"
    Write-ErrorMsg "╚══════════════════════════════════════════════════════════════════════╝"
    Write-Host ""
    Write-Host "The script could not assign roles to the policy managed identities."
    Write-Host "This is expected in cross-tenant scenarios without User Access Administrator."
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════╗"
    Write-Host "║  RECOMMENDED: Use the built-in -AssignRolesAsSourceAdmin parameter   ║"
    Write-Host "╚══════════════════════════════════════════════════════════════════════╝"
    Write-Host ""
    Write-Info "A SOURCE TENANT ADMIN should run this same script with -AssignRolesAsSourceAdmin:"
    Write-Host ""
    Write-Success "# ============================================================"
    Write-Success "# COMMAND FOR SOURCE TENANT ADMIN TO RUN:"
    Write-Success "# ============================================================"
    Write-Host ""
    Write-Host "# Step 1: Connect to the SOURCE tenant (where the VMs are located)"
    Write-Host "Connect-AzAccount -TenantId '<SOURCE-TENANT-ID>'"
    Write-Host ""
    Write-Host "# Step 2: Run this script with -AssignRolesAsSourceAdmin parameter"
    
    # Build the subscription list for the command
    $subList = ($results.IdentitiesNeedingRoles | Select-Object -ExpandProperty SubscriptionId -Unique) -join "', '"
    Write-Host ".\Configure-VMDiagnosticLogs.ps1 -AssignRolesAsSourceAdmin -SubscriptionIds @('$subList')"
    Write-Host ""
    Write-Success "# ============================================================"
    Write-Host ""
    Write-Host "This will automatically:"
    Write-Host "  1. Discover all policy assignments with managed identities"
    Write-Host "  2. Assign Contributor role to each managed identity"
    Write-Host "  3. Create remediation tasks to apply policies to existing VMs"
    Write-Host ""
    
    Write-Host "─────────────────────────────────────────────────────────────────────────"
    Write-Host ""
    Write-Info "ALTERNATIVE: Manual role assignment commands (if you prefer not to use the script):"
    Write-Host ""
    
    # Group by subscription for cleaner output
    $groupedBySubscription = $results.IdentitiesNeedingRoles | Group-Object -Property SubscriptionId
    
    foreach ($subGroup in $groupedBySubscription) {
        Write-Host "# For subscription: $($subGroup.Name)"
        Write-Host "Set-AzContext -SubscriptionId '$($subGroup.Name)'"
        Write-Host ""
        
        foreach ($identity in $subGroup.Group) {
            Write-Host "# Assign $($identity.RoleNeeded) for $($identity.PolicyKey) policy"
            Write-Host "New-AzRoleAssignment ``"
            Write-Host "    -ObjectId '$($identity.PrincipalId)' ``"
            Write-Host "    -RoleDefinitionName '$($identity.RoleNeeded)' ``"
            Write-Host "    -Scope '$($identity.Scope)'"
            Write-Host ""
        }
    }
    
    Write-Host "After assigning the roles, run remediation tasks to apply policies to existing VMs:"
    Write-Host ""
    foreach ($assignment in $results.PolicyAssignmentsCreated | Where-Object { -not $_.RoleAssigned }) {
        Write-Host "Start-AzPolicyRemediation -Name 'remediate-$($assignment.Name)' -PolicyAssignmentId '$($assignment.AssignmentId)' -Scope '/subscriptions/$($assignment.SubscriptionId)'"
    }
    Write-Host ""
}
#endregion
#endregion

# Return results object
return $results
```

### Usage Examples

#### Basic Usage (All VMs in Current Subscription)

```powershell
# Connect to the managing tenant first
Connect-AzAccount -TenantId "<MANAGING-TENANT-ID>"

# Set context to a delegated subscription
Set-AzContext -SubscriptionId "<DELEGATED-SUBSCRIPTION-ID>"

# Configure VM diagnostic logs
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
```

#### Multiple Subscriptions

```powershell
# Configure VMs across multiple delegated subscriptions
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SubscriptionIds @("sub-id-1", "sub-id-2", "sub-id-3")
```

#### Skip Policy Deployment (Opt-Out of Azure Policy)

```powershell
# Skip Azure Policy deployment - only configure running VMs manually
# Use this if you don't want automatic agent installation on stopped/new VMs
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -DeployPolicy $false
```

#### Skip DCR Creation (Use Existing DCR)

```powershell
# Skip DCR creation if you already have a Data Collection Rule
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SkipDCRCreation `
    -DataCollectionRuleName "existing-dcr-name"
```

#### Skip Both Policy and DCR (Manual VM Configuration Only)

```powershell
# Skip both policy deployment AND DCR creation
# Only install agents and create DCR associations for running VMs
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -DeployPolicy $false `
    -SkipDCRCreation
```

#### Custom DCR Name

```powershell
# Use a custom name for the Data Collection Rule
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -DataCollectionRuleName "dcr-cross-tenant-vm-logs-atevet17"
```

#### Skip Agent Installation (Agents Already Installed)

```powershell
# Skip agent installation if Azure Monitor Agent is already deployed
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SkipAgentInstallation
```

#### Source Tenant Admin Mode (Assign Roles to Policy Managed Identities)

When Azure Policy is deployed, it creates managed identities in the **source tenant** that need **Contributor** role to install VM extensions. Due to cross-tenant restrictions, Azure Lighthouse typically cannot assign these roles.

The `-AssignRolesAsSourceAdmin` parameter allows a source tenant administrator to:
1. Discover existing policy assignments with managed identities
2. Assign Contributor role to those identities
3. Create remediation tasks to apply policies to existing VMs

```powershell
# SOURCE TENANT ADMIN: Connect to the source tenant
Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"

# Assign roles to policy managed identities and create remediation tasks
.\Configure-VMDiagnosticLogs.ps1 `
    -AssignRolesAsSourceAdmin `
    -SubscriptionIds @("<SOURCE-SUBSCRIPTION-ID>")

# With custom policy assignment prefix (if you used a different prefix)
.\Configure-VMDiagnosticLogs.ps1 `
    -AssignRolesAsSourceAdmin `
    -SubscriptionIds @("<SOURCE-SUBSCRIPTION-ID>") `
    -PolicyAssignmentPrefix "custom-prefix"
```

**When to use this mode:**
- After the managing tenant has deployed Azure Policy assignments
- When the script outputs "ACTION REQUIRED: Manual Role Assignment Needed"
- When remediation tasks fail due to missing permissions

**Expected output:**
```
======================================================================
    SOURCE TENANT ADMIN MODE - Assign Roles to Policy Identities
======================================================================

This mode assigns Contributor role to policy managed identities.
Run this after the managing tenant has deployed Azure Policy assignments.

Processing subscription: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  Subscription name: Production-Subscription
  Discovering policy assignments with managed identities...
  Found 4 policy assignment(s) with managed identities

  Policy: Configure Windows virtual machines to run Azure Monitor Agent
    Principal ID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    ✓ Contributor role assigned

  Policy: Configure Linux virtual machines to run Azure Monitor Agent
    Principal ID: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
    ✓ Contributor role assigned

Creating remediation tasks for existing non-compliant VMs...

  Creating remediation: remediate-vm-monitoring-AMA-Windows-aaaaaaaa
    ✓ Remediation task created

======================================================================
                              SUMMARY
======================================================================

Subscriptions Processed:   1
Policy Assignments Found:  4
Role Assignments Created:  4
Remediation Tasks Created: 4
```

#### Master DCR Pattern (Backup and Restore)

The script implements a **Master DCR pattern** for centralized governance and disaster recovery:

- **Master DCR**: A backup copy of the DCR stored in the managing tenant
- **Source DCR**: The operational DCR in each source tenant (used by Azure Policy)

**Why use the Master DCR pattern?**
1. **Backup**: If someone accidentally deletes or modifies the source tenant DCR, you can restore it from the Master
2. **Consistency**: Ensure all source tenants have identical DCR configurations
3. **Governance**: Centralized template management in the managing tenant

**Default behavior (Master DCR created automatically):**
```powershell
# By default, the script creates both:
# 1. Source DCR in source tenant (for Azure Policy)
# 2. Master DCR in managing tenant (backup/template)
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
```

**Skip Master DCR creation:**
```powershell
# Skip creating the Master DCR (only create source tenant DCR)
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SkipMasterDCR
```

**Custom Master DCR resource group:**
```powershell
# Specify a custom resource group for the Master DCR
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -MasterDCRResourceGroup "rg-dcr-templates"
```

**Sync/Restore DCRs from Master (disaster recovery):**
```powershell
# If a source tenant DCR was deleted or modified, restore it from the Master DCR
.\Configure-VMDiagnosticLogs.ps1 `
    -SyncDCRFromMaster `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SubscriptionIds @("source-sub-1", "source-sub-2")
```

**Expected output for -SyncDCRFromMaster:**
```
======================================================================
    SYNC DCR FROM MASTER - Restore/Sync DCRs from Managing Tenant
======================================================================

This mode syncs/restores DCRs in source tenants from the Master DCR in the managing tenant.
Use this to restore a deleted/modified DCR or ensure consistency across tenants.

Managing Tenant Subscription: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
Master DCR Resource Group: rg-master-dcr-templates
Master DCR Name: dcr-vm-logs

Step 1: Reading Master DCR from managing tenant...

  ✓ Found Master DCR: dcr-vm-logs
    Location: westus2
    ID: /subscriptions/.../dataCollectionRules/dcr-vm-logs

Step 2: Syncing DCR to source tenant subscriptions...

Processing subscription: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  Subscription name: Production-Subscription
  DCR 'dcr-vm-logs' already exists. Updating from Master...
  ✓ DCR synced successfully

======================================================================
                              SUMMARY
======================================================================

Master DCR Found:          True
Subscriptions Processed:   1
DCRs Synced:               1

Successfully synced DCRs:
  ✓ Production-Subscription (aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa)

=== Next Steps ===

1. Verify DCR associations are still valid for existing VMs
2. Run remediation tasks if needed to re-associate VMs with the restored DCR
3. Check Log Analytics workspace for incoming VM data
```

### Expected Output

```
======================================================================
        Configure Virtual Machine Diagnostic Logs - Step 4
======================================================================

Checking Azure connection...
Connected as: admin@atevet12.onmicrosoft.com
Current Tenant: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

Validating workspace resource ID...
  Workspace Name: law-central-atevet12
  Resource Group: rg-central-logging

Subscriptions to configure: 2
  - aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  - bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb

Creating Data Collection Rule: dcr-vm-logs
  Creating new Data Collection Rule...
  ✓ Data Collection Rule created successfully

Processing Virtual Machines in delegated subscriptions...

Processing subscription: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  Subscription name: Production-Subscription
  Found 3 VM(s)

  Processing VM: vm-web-01
    OS Type: Windows
    Installing Azure Monitor Agent...
    ✓ Azure Monitor Agent installed
    Creating DCR association...
    ✓ DCR association created
    ✓ VM configured successfully

  Processing VM: vm-db-01
    OS Type: Windows
    ✓ Azure Monitor Agent already installed
    Creating DCR association...
    ✓ DCR association created
    ✓ VM configured successfully

  Processing VM: vm-linux-01
    OS Type: Linux
    Installing Azure Monitor Agent...
    ✓ Azure Monitor Agent installed
    Creating DCR association...
    ✓ DCR association created
    ✓ VM configured successfully

======================================================================
                              SUMMARY
======================================================================

Data Collection Rule:      dcr-vm-logs
DCR Resource ID:           /subscriptions/.../dataCollectionRules/dcr-vm-logs

Subscriptions Processed:   2
VMs Configured:            3
VMs Failed:                0
Agents Installed:          2
DCR Associations Created:  3

Successfully configured VMs:
  ✓ vm-web-01
  ✓ vm-db-01
  ✓ vm-linux-01

=== Verification Queries ===

Run these queries in Log Analytics to verify VM data is flowing:

// VM Performance data
Perf
| where TimeGenerated > ago(1h)
| summarize count() by Computer, ObjectName

// Windows Event Logs
Event
| where TimeGenerated > ago(1h)
| summarize count() by Computer, EventLog

// Linux Syslog
Syslog
| where TimeGenerated > ago(1h)
| summarize count() by Computer, Facility

=== Next Steps ===

1. Wait 5-15 minutes for VM logs to start flowing
2. Run the verification queries in Log Analytics
3. Proceed to Step 5: Configure Azure Resource Diagnostic Logs
4. Configure Microsoft Sentinel analytics rules for VM security events
```

### Troubleshooting

#### Permission Denied

**Error:** `The client does not have authorization to perform action`

**Solution:**
- Ensure you have **Contributor** role on the delegated subscription
- Verify Azure Lighthouse delegation includes the Contributor role
- Check that you're a member of the delegated security group

#### VM Extension Installation Failed

**Error:** `VM extension installation failed`

**Solution:**
1. Verify the VM is running
2. Check that the VM has outbound internet connectivity
3. Ensure no conflicting extensions are installed
4. Try installing the agent manually via Azure Portal

#### DCR Association Failed

**Error:** `Failed to create DCR association`

**Solution:**
1. Verify the DCR was created successfully
2. Check that the Azure Monitor Agent is installed on the VM
3. Ensure the DCR resource ID is correct
4. Verify you have permissions on both the VM and DCR

---


## Step 5: Configure Azure Resource Diagnostic Logs

> ⚠️ **IMPORTANT**: This script should be run from the **MANAGING TENANT** (Atevet12) after Azure Lighthouse delegation is complete. The script configures diagnostic settings on Azure resources in the delegated subscriptions to send logs to the Log Analytics workspace in the managing tenant.

> **Note:** Virtual Machine diagnostic logs are covered in **Step 4**. This step focuses on Azure PaaS resources like Key Vault, Storage Accounts, SQL Databases, etc.

Resource diagnostic logs capture data plane operations for Azure resources (e.g., Key Vault access, Storage operations, SQL queries). This script automates the configuration of diagnostic settings across multiple resource types using the `allLogs` category group for comprehensive coverage.

### Prerequisites

Before running this script, you need:
- **Azure Lighthouse delegation** completed (Step 2)
- **Log Analytics Workspace Resource ID** (from Step 1)
- **Delegated subscription IDs** (from the source tenant)
- **Contributor** or **Monitoring Contributor** role on the delegated subscriptions

### Supported Resource Types

| Resource Type | Description |
|--------------|-------------|
| Microsoft.KeyVault/vaults | Key Vault audit and access logs |
| Microsoft.Storage/storageAccounts | Blob, Queue, Table, File service logs |
| Microsoft.Web/sites | App Service HTTP, console, and audit logs |
| Microsoft.Sql/servers/databases | SQL insights, errors, and deadlocks |
| Microsoft.Network/networkSecurityGroups | NSG flow and rule logs |
| Microsoft.ContainerService/managedClusters | AKS control plane logs |
| Microsoft.DocumentDB/databaseAccounts | Cosmos DB request and query logs |
| Microsoft.EventHub/namespaces | Event Hub operational logs |
| Microsoft.ServiceBus/namespaces | Service Bus operational logs |
| Microsoft.Network/applicationGateways | Application Gateway access and firewall logs |
| Microsoft.Network/azureFirewalls | Azure Firewall rule logs |
| Microsoft.ApiManagement/service | API Management gateway logs |
| Microsoft.Logic/workflows | Logic Apps workflow runtime logs |
| Microsoft.ContainerRegistry/registries | Container Registry repository and login events |
| Microsoft.Cache/redis | Redis Cache connection logs |
| Microsoft.DataFactory/factories | Data Factory pipeline and activity logs |
| Microsoft.CognitiveServices/accounts | Cognitive Services audit and request logs |

### Script: `Configure-ResourceDiagnosticLogs.ps1`

The complete PowerShell script is located at: [`scripts/Configure-ResourceDiagnosticLogs.ps1`](scripts/Configure-ResourceDiagnosticLogs.ps1)

This script automates the configuration of diagnostic settings for Azure PaaS resources:
1. Discovers all supported resources in delegated subscriptions
2. Configures diagnostic settings using the `allLogs` category group
3. Optionally deploys Azure Policy for automatic coverage of new resources
4. Supports source tenant admin mode for role assignment in cross-tenant scenarios

### Usage Examples

#### Basic Usage (All Resource Types)

```powershell
# Connect to the managing tenant first
Connect-AzAccount -TenantId "<MANAGING-TENANT-ID>"

# Configure diagnostic settings for all supported resource types
.\Configure-ResourceDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
```

#### Specific Resource Types Only

```powershell
# Configure only Key Vault and Storage accounts
.\Configure-ResourceDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -ResourceTypes @("Microsoft.KeyVault/vaults", "Microsoft.Storage/storageAccounts")
```

#### Multiple Subscriptions

```powershell
# Configure across multiple delegated subscriptions
.\Configure-ResourceDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SubscriptionIds @("sub-id-1", "sub-id-2", "sub-id-3")
```

#### Skip Azure Policy Deployment

```powershell
# Configure existing resources only (skip Azure Policy deployment)
.\Configure-ResourceDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SkipPolicy
```

#### Custom Diagnostic Setting Name

```powershell
# Use a custom name for the diagnostic setting
.\Configure-ResourceDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -DiagnosticSettingName "CrossTenantLogs"
```

#### Source Tenant Admin Mode (Assign Roles to Policy Managed Identities)

When Azure Policy is deployed, the managed identity needs Contributor role to configure diagnostic settings on resources. In cross-tenant scenarios, the managing tenant may not be able to assign this role due to Lighthouse restrictions.

A **source tenant administrator** should run this command to assign the required roles:

```powershell
# Step 1: Connect to the SOURCE tenant as an admin
Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"

# Step 2: Run the script with -AssignRolesAsSourceAdmin
.\Configure-ResourceDiagnosticLogs.ps1 `
    -AssignRolesAsSourceAdmin `
    -SubscriptionIds @("<SOURCE-SUBSCRIPTION-ID>")
```

This mode will:
1. Discover existing policy assignments with managed identities
2. Assign Contributor role to each managed identity
3. Create remediation tasks to configure existing non-compliant resources

### Verification

After running the script, verify that logs are flowing to the Log Analytics workspace:

#### 1. Check Diagnostic Settings via Azure Portal

1. Navigate to any configured resource (e.g., Key Vault)
2. Go to **Monitoring** > **Diagnostic settings**
3. Verify the "SendToLogAnalytics" setting exists and shows the correct workspace

#### 2. Query Log Analytics

Wait 5-15 minutes for logs to start flowing, then run these queries:

```kusto
// Check for Key Vault audit events
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where TimeGenerated > ago(1h)
| summarize count() by OperationName, ResultType
| order by count_ desc

// Check for Storage account operations
StorageBlobLogs
| where TimeGenerated > ago(1h)
| summarize count() by OperationName, StatusCode
| order by count_ desc

// Summary of all diagnostic logs by resource type
AzureDiagnostics
| where TimeGenerated > ago(1h)
| summarize LogCount = count() by ResourceProvider, Category
| order by LogCount desc

// Check for any errors in log ingestion
_LogOperation
| where TimeGenerated > ago(1h)
| where Level == "Error"
| project TimeGenerated, Operation, Detail
```

#### 3. Verify via PowerShell

```powershell
# List all diagnostic settings for a resource
$resourceId = "/subscriptions/<SUB-ID>/resourceGroups/<RG>/providers/Microsoft.KeyVault/vaults/<KV-NAME>"
Get-AzDiagnosticSetting -ResourceId $resourceId

# Check if logs are being received in the workspace
$workspaceId = "<WORKSPACE-ID>"
$query = "AzureDiagnostics | where TimeGenerated > ago(1h) | summarize count() by ResourceProvider"
Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $query
```

### Troubleshooting

| Issue | Possible Cause | Solution |
|-------|---------------|----------|
| "Resource does not support diagnostic settings" | Resource type not supported | Check the supported resource types list |
| "categoryGroup 'allLogs' is not valid" | Older API version or resource doesn't support categoryGroup | Script automatically falls back to 'audit' category |
| "Authorization failed" | Missing permissions | Ensure Contributor or Monitoring Contributor role on delegated subscription |
| "Workspace not found" | Incorrect workspace resource ID | Verify the workspace resource ID format |
| Logs not appearing | Latency in log ingestion | Wait 15-30 minutes; check _LogOperation for errors |
| Partial logs only | Some categories not enabled | Use the script which enables allLogs category group |

### Best Practices

1. **Use consistent naming**: Use the same diagnostic setting name across all resources for easier management
2. **Enable Azure Policy**: Deploy the policy assignment to automatically configure new resources
3. **Monitor log ingestion**: Set up alerts on _LogOperation errors to catch ingestion issues
4. **Review costs**: Monitor Log Analytics ingestion costs, especially for high-volume resources
5. **Retention settings**: Configure appropriate retention periods in the Log Analytics workspace
6. **Cross-tenant visibility**: Use Azure Lighthouse to manage diagnostic settings across tenants from a single location

---



## Step 6: Configure Microsoft Entra ID (Azure AD) Logs via Event Hub

> 🚨 **IMPORTANT: EVENT HUB METHOD FOR CROSS-TENANT ENTRA ID LOGS**
>
> Due to limitations with the Lighthouse method for Entra ID log ingestion to the managing tenant, this step uses **Azure Event Hub** as the transport mechanism. The Event Hub method provides:
> - ✅ **Full automation support** - No manual Portal configuration required
> - ✅ **Real-time streaming** - Sub-second latency for security monitoring
> - ✅ **Cross-tenant native support** - Works with connection string authentication
> - ✅ **No Lighthouse delegation required** - Bypasses the `LinkedAuthorizationFailed` limitation
> - ✅ **Scalable architecture** - Handles high-volume Entra ID logs

Microsoft Entra ID (formerly Azure Active Directory) logs are **tenant-level logs** that include sign-in activities, directory changes, and identity protection events. These logs are critical for security monitoring and compliance.

### Why Event Hub Instead of Direct Log Analytics?

The standard approach of configuring Entra ID diagnostic settings to send logs directly to a cross-tenant Log Analytics workspace fails due to Azure API limitations:

| Method | Result | Error |
|--------|--------|-------|
| Direct REST API | ❌ FAILS | `LinkedAuthorizationFailed` |
| ARM Templates | ❌ FAILS | `LinkedAuthorizationFailed` |
| Lighthouse Delegation | ❌ FAILS | Lighthouse doesn't cover Entra ID |
| Auxiliary Tokens | ❌ FAILS | `401 Unauthorized` |
| Portal (Manual) | ✅ Works | Requires manual configuration |
| **Event Hub** | ✅ **Works** | **Fully automated** |

The Event Hub method works because:
1. Entra ID diagnostic settings **can** send logs to an Event Hub using a connection string
2. The connection string authentication bypasses cross-tenant authorization issues
3. An Azure Function in the managing tenant processes and forwards logs to Log Analytics

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              SOURCE TENANT (Atevet17)                                │
│                                                                                      │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                         Microsoft Entra ID                                      │ │
│  │                                                                                  │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │ │
│  │  │  AuditLogs   │  │ SignInLogs   │  │ RiskyUsers   │  │ Provisioning │        │ │
│  │  │              │  │              │  │              │  │    Logs      │        │ │
│  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘        │ │
│  │         │                 │                 │                 │                 │ │
│  │         └─────────────────┴────────┬────────┴─────────────────┘                 │ │
│  │                                    │                                             │ │
│  │                         Diagnostic Settings                                      │ │
│  │                    (Stream to Event Hub via SAS)                                │ │
│  └────────────────────────────────────┼─────────────────────────────────────────────┘ │
│                                       │                                              │
└───────────────────────────────────────┼──────────────────────────────────────────────┘
                                        │ Event Hub Connection String
                                        │ (SAS Token Authentication)
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              MANAGING TENANT (Atevet12)                              │
│                                                                                      │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                        Event Hub Namespace                                      │ │
│  │                    (eh-namespace-central-atevet12)                              │ │
│  │                                                                                  │ │
│  │  ┌──────────────────────────────────────────────────────────────────────────┐  │ │
│  │  │                         eh-entra-id-logs                                  │  │ │
│  │  │  (Receives all Entra ID log categories from source tenant)               │  │ │
│  │  └──────────────────────────────────┬────────────────────────────────────────┘  │ │
│  └─────────────────────────────────────┼────────────────────────────────────────────┘ │
│                                        │                                              │
│                                        ▼                                              │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                         Azure Function App                                      │ │
│  │                    (Event Hub Trigger → Log Analytics)                          │ │
│  │                                                                                  │ │
│  │  • Parses incoming Entra ID events                                              │ │
│  │  • Transforms to Log Analytics schema                                           │ │
│  │  • Sends to Data Collection Endpoint                                            │ │
│  │  • Preserves original table structure (SigninLogs, AuditLogs, etc.)            │ │
│  └────────────────────────────────────────────────────────────────────────────────┘ │
│                                        │                                              │
│                                        ▼                                              │
│  ┌────────────────────────────────────────────────────────────────────────────────┐ │
│  │                      Log Analytics Workspace                                    │ │
│  │                    (law-central-atevet12)                                       │ │
│  │                                                                                  │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        │ │
│  │  │EntraIDSignIn │  │EntraIDAudit  │  │EntraIDRisky  │  │EntraIDProvi- │        │ │
│  │  │   Logs_CL    │  │  Logs_CL     │  │  Users_CL    │  │ sioning_CL   │        │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘        │ │
│  └────────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Where to Run This Script

| Tenant | Role | What Happens |
|--------|------|--------------|
| **Managing Tenant (Atevet12)** | ✅ **Run script here** | Creates Event Hub, Function App, stores secrets in Key Vault |
| **Source Tenant (Atevet17)** | ✅ **Authenticate here** | Script prompts for source tenant auth to configure Entra ID diagnostic settings |

### Prerequisites

Before running this script, you need:
- **Global Administrator** role in the **source tenant** (required to configure Entra ID diagnostic settings)
- **Contributor** role in the **managing tenant** subscription (to create Event Hub, Function App)
- **Microsoft Entra ID P1 or P2 license** in the **source tenant** (required for sign-in logs; AuditLogs are free)
- **Log Analytics Workspace** in the **managing tenant** (from Step 1)
- **Key Vault** in the **managing tenant** (from Step 1)
- **Az PowerShell module** installed locally (Az.Accounts, Az.EventHub, Az.Functions, Az.KeyVault)
- **Completed Steps 1-2** (Lighthouse delegation and workspace setup)

### Available Entra ID Log Categories

| Log Category | Description | License Required |
|--------------|-------------|------------------|
| **AuditLogs** | Directory changes (user/group/app management) | Free |
| **SignInLogs** | Interactive user sign-ins | P1/P2 |
| **NonInteractiveUserSignInLogs** | Sign-ins by clients on behalf of users | P1/P2 |
| **ServicePrincipalSignInLogs** | Sign-ins by apps and service principals | P1/P2 |
| **ManagedIdentitySignInLogs** | Sign-ins by managed identities | P1/P2 |
| **MicrosoftServicePrincipalSignInLogs** | Microsoft first-party app sign-ins | P1/P2 |
| **ProvisioningLogs** | User provisioning activities | P1/P2 |
| **ADFSSignInLogs** | AD FS sign-in logs | P1/P2 |
| **RiskyUsers** | Users flagged for risk | P2 |
| **UserRiskEvents** | Risk detection events | P2 |
| **RiskyServicePrincipals** | Service principals flagged for risk | P2 |
| **ServicePrincipalRiskEvents** | Service principal risk events | P2 |
| **MicrosoftGraphActivityLogs** | Microsoft Graph API activity | P1/P2 |
| **AzureADGraphActivityLogs** | Azure AD Graph API activity (deprecated) | P1/P2 |
| **GraphNotificationsActivityLogs** | Graph notification activity | P1/P2 |
| **NetworkAccessTrafficLogs** | Global Secure Access traffic logs | GSA |
| **NetworkAccessAlerts** | Network access alerts | GSA |
| **RemoteNetworkHealthLogs** | Remote network health logs | GSA |
| **NetworkAccessConnectionEvents** | Network connection events | GSA |
| **NetworkAccessGenerativeAIInsights** | AI-generated insights | GSA |
| **EnrichedOffice365AuditLogs** | Enriched Office 365 audit logs | M365 E5 |

> **Note:** Categories marked with "GSA" require Global Secure Access license. Categories will be silently skipped if your tenant doesn't have the required license.

---

### 🎯 Which Path Should You Follow?

> **For most users, you only need to complete Step 6.1 (Automated) and then skip to Step 6.4 (Verify).**

| Your Situation | Steps to Follow |
|----------------|-----------------|
| **First time setup (RECOMMENDED)** | ✅ Step 6.1 → Step 6.4 |
| **Want manual control over each component** | Step 6.2 → Step 6.3 → Step 6.4 |
| **Automated script failed** | Step 6.2 → Step 6.3 → Step 6.4 |
| **Event Hub already exists, need diagnostic settings only** | Step 6.3 → Step 6.4 |

**The automated script (Step 6.1) does EVERYTHING for you:**
- ✅ Creates Event Hub infrastructure in managing tenant
- ✅ Deploys Azure Function for log processing
- ✅ Configures diagnostic settings in source tenant
- ✅ Stores secrets in Key Vault

---

### Step 6.1: Deploy Event Hub and Function App (Automated) ⭐ RECOMMENDED

> 💡 **This is the recommended approach.** Running this script completes the entire Step 6 configuration automatically. After running this script successfully, skip directly to **Step 6.4** to verify your logs are flowing.

The primary method for deploying the Event Hub infrastructure and Azure Function is using the automated PowerShell script.

#### Script Location

The main deployment script is located at:
- **[`scripts/Configure-EntraIDLogsViaEventHub.ps1`](scripts/Configure-EntraIDLogsViaEventHub.ps1)**

The Azure Function code files are located at:
- **[`scripts/EntraIDLogsProcessor/__init__.py`](scripts/EntraIDLogsProcessor/__init__.py)** - Main function code
- **[`scripts/EntraIDLogsProcessor/function.json`](scripts/EntraIDLogsProcessor/function.json)** - Function binding configuration
- **[`scripts/EntraIDLogsProcessor/requirements.txt`](scripts/EntraIDLogsProcessor/requirements.txt)** - Python dependencies
- **[`scripts/EntraIDLogsProcessor/host.json`](scripts/EntraIDLogsProcessor/host.json)** - Function host configuration

#### Running the Automated Script

You have **two options** to run the script:

##### Option 1: Edit the Script Configuration (Recommended for First-Time Users)

1. Open the script file [`scripts/Configure-EntraIDLogsViaEventHub.ps1`](scripts/Configure-EntraIDLogsViaEventHub.ps1)
2. Find the **CONFIGURATION SECTION** (around line 165)
3. Fill in your values:

```powershell
# REQUIRED: Managing Tenant Configuration
$Config_ManagingTenantId       = "your-managing-tenant-id"
$Config_ManagingSubscriptionId = "your-subscription-id"

# REQUIRED: Source Tenant Configuration
$Config_SourceTenantId         = "your-source-tenant-id"
$Config_SourceTenantName       = "Atevet17"

# REQUIRED: Resource Names
$Config_EventHubNamespaceName  = "eh-ns-entra-logs-atevet17"
$Config_FunctionAppName        = "func-entra-logs-atevet17"
$Config_KeyVaultName           = "kv-central-atevet12"

# REQUIRED: Log Analytics Workspace
$Config_WorkspaceResourceId    = "/subscriptions/.../workspaces/law-central-atevet12"
```

4. Save the file and run:

```powershell
cd "C:\path\to\azure-cross-tenant-log-collection-guide\scripts"
.\Configure-EntraIDLogsViaEventHub.ps1
```

##### Option 2: Pass Parameters on Command Line

```powershell
# Navigate to the scripts directory
cd "C:\path\to\azure-cross-tenant-log-collection-guide\scripts"

# Run the deployment script with parameters
.\Configure-EntraIDLogsViaEventHub.ps1 `
    -ManagingTenantId "<MANAGING-TENANT-ID>" `
    -ManagingSubscriptionId "<MANAGING-SUBSCRIPTION-ID>" `
    -SourceTenantId "<SOURCE-TENANT-ID>" `
    -SourceTenantName "Atevet17" `
    -EventHubNamespaceName "eh-ns-entra-logs-atevet17" `
    -KeyVaultName "kv-central-atevet12" `
    -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -Location "westus2" `
    -Verbose
```

#### Script Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `ManagingTenantId` | Yes | Tenant ID of the managing tenant (Atevet12) |
| `ManagingSubscriptionId` | Yes | Subscription ID in the managing tenant |
| `SourceTenantId` | Yes | Tenant ID of the source tenant (Atevet17) |
| `SourceTenantName` | Yes | Friendly name for the source tenant (used in table names) |
| `EventHubNamespaceName` | Yes | Name for the Event Hub namespace |
| `KeyVaultName` | Yes | Name of the Key Vault to store secrets |
| `WorkspaceResourceId` | Yes | Full resource ID of the Log Analytics workspace |
| `Location` | No | Azure region (default: westus2) |
| `ResourceGroupName` | No | Resource group name (default: rg-entra-logs-eventhub) |
| `EventHubName` | No | Event Hub name (default: eh-entra-id-logs) |
| `FunctionAppName` | No | Function App name (default: func-entra-logs-processor) |
| `LogCategories` | No | Array of log categories to enable |
| `SkipFunctionDeployment` | No | Skip deploying the Azure Function code |
| `SkipDiagnosticSettings` | No | Skip configuring diagnostic settings in source tenant |
| `CleanUp` | No | Remove all resources created by this script (see note below) |

> ⚠️ **CleanUp Note:** The `-CleanUp` parameter removes all resources (Event Hub Namespace, Function App, Storage Account, Application Insights, App Service Plan) but preserves the resource group. After running with `-CleanUp`, you must run the script again **without** `-CleanUp` to recreate the resources:
> ```powershell
> # Step 1: Remove existing resources
> .\Configure-EntraIDLogsViaEventHub.ps1 -CleanUp
>
> # Step 2: Recreate resources
> .\Configure-EntraIDLogsViaEventHub.ps1
> ```

#### What the Script Does

1. **Creates Event Hub Infrastructure** (Managing Tenant)
   - Creates resource group for Event Hub resources
   - Creates Event Hub Namespace with Standard SKU
   - Creates Event Hub with 4 partitions and 7-day retention
   - Creates consumer group for Log Analytics processing
   - Creates Send-only authorization rule for source tenant

2. **Deploys Azure Function App** (Managing Tenant)
   - Creates Storage Account for Function App
   - Creates Consumption Plan Function App (Python 3.11)
   - Enables System-Assigned Managed Identity
   - Configures app settings with Event Hub and Log Analytics connections
   - Deploys the EntraIDLogsProcessor function code with remote build (installs Python dependencies)

3. **Stores Secrets in Key Vault** (Managing Tenant)
   - Stores Event Hub connection string
   - Stores Log Analytics workspace key

4. **Configures Diagnostic Settings** (Source Tenant)
   - Prompts for Global Administrator authentication
   - Creates diagnostic setting to stream logs to Event Hub
   - Enables all available log categories based on license

---

### Step 6.2: Manual Deployment (Alternative)

> ⚠️ **SKIP THIS SECTION if you successfully ran Step 6.1.** This section is only for users who want to deploy components manually or if the automated script failed.

If you prefer to deploy components manually or need to customize the deployment, follow these steps.

#### Create Event Hub Namespace (Azure CLI)

```bash
# Login to managing tenant (Atevet12)
az login --tenant "<MANAGING-TENANT-ID>"
az account set --subscription "<MANAGING-SUBSCRIPTION-ID>"

# Create resource group for Event Hub
az group create \
    --name "rg-entra-logs-eventhub" \
    --location "westus2"

# Create Event Hub Namespace
az eventhubs namespace create \
    --name "eh-ns-entra-logs-<unique-suffix>" \
    --resource-group "rg-entra-logs-eventhub" \
    --location "westus2" \
    --sku "Standard" \
    --capacity 1 \
    --enable-auto-inflate true \
    --maximum-throughput-units 10

# Create Event Hub for Entra ID logs
az eventhubs eventhub create \
    --name "eh-entra-id-logs" \
    --namespace-name "eh-ns-entra-logs-<unique-suffix>" \
    --resource-group "rg-entra-logs-eventhub" \
    --partition-count 4 \
    --message-retention 7

# Create consumer group for Log Analytics processing
az eventhubs eventhub consumer-group create \
    --name "cg-loganalytics" \
    --eventhub-name "eh-entra-id-logs" \
    --namespace-name "eh-ns-entra-logs-<unique-suffix>" \
    --resource-group "rg-entra-logs-eventhub"

# Create Shared Access Policy for source tenant (Send only)
az eventhubs namespace authorization-rule create \
    --name "source-tenant-send-policy" \
    --namespace-name "eh-ns-entra-logs-<unique-suffix>" \
    --resource-group "rg-entra-logs-eventhub" \
    --rights Send

# Get the connection string (save this for diagnostic settings)
az eventhubs namespace authorization-rule keys list \
    --name "source-tenant-send-policy" \
    --namespace-name "eh-ns-entra-logs-<unique-suffix>" \
    --resource-group "rg-entra-logs-eventhub" \
    --query "primaryConnectionString" \
    --output tsv
```

#### Create Event Hub Namespace (PowerShell)

```powershell
# Login to managing tenant (Atevet12)
Connect-AzAccount -TenantId "<MANAGING-TENANT-ID>"
Set-AzContext -SubscriptionId "<MANAGING-SUBSCRIPTION-ID>"

# Variables
$resourceGroupName = "rg-entra-logs-eventhub"
$location = "westus2"
$eventHubNamespaceName = "eh-ns-entra-logs-<unique-suffix>"
$eventHubName = "eh-entra-id-logs"

# Create resource group
New-AzResourceGroup -Name $resourceGroupName -Location $location

# Create Event Hub Namespace
New-AzEventHubNamespace `
    -ResourceGroupName $resourceGroupName `
    -Name $eventHubNamespaceName `
    -Location $location `
    -SkuName "Standard" `
    -SkuCapacity 1 `
    -EnableAutoInflate $true `
    -MaximumThroughputUnits 10

# Create Event Hub
New-AzEventHub `
    -ResourceGroupName $resourceGroupName `
    -NamespaceName $eventHubNamespaceName `
    -Name $eventHubName `
    -PartitionCount 4 `
    -MessageRetentionInDays 7

# Create consumer group
New-AzEventHubConsumerGroup `
    -ResourceGroupName $resourceGroupName `
    -NamespaceName $eventHubNamespaceName `
    -EventHubName $eventHubName `
    -Name "cg-loganalytics"

# Create Shared Access Policy for source tenant (Send only)
New-AzEventHubAuthorizationRule `
    -ResourceGroupName $resourceGroupName `
    -NamespaceName $eventHubNamespaceName `
    -Name "source-tenant-send-policy" `
    -Rights @("Send")

# Get the connection string
$keys = Get-AzEventHubKey `
    -ResourceGroupName $resourceGroupName `
    -NamespaceName $eventHubNamespaceName `
    -Name "source-tenant-send-policy"

Write-Host "Event Hub Connection String:"
Write-Host $keys.PrimaryConnectionString
```

#### Deploy Azure Function App

```bash
# Create Storage Account for Function App
az storage account create \
    --name "stfuncentralogsprocessor" \
    --resource-group "rg-entra-logs-eventhub" \
    --location "westus2" \
    --sku "Standard_LRS"

# Create Function App (Consumption Plan)
az functionapp create \
    --name "func-entra-logs-processor" \
    --resource-group "rg-entra-logs-eventhub" \
    --storage-account "stfuncentralogsprocessor" \
    --consumption-plan-location "westus2" \
    --runtime "python" \
    --runtime-version "3.9" \
    --functions-version "4" \
    --os-type "Linux"

# Enable System-Assigned Managed Identity
az functionapp identity assign \
    --name "func-entra-logs-processor" \
    --resource-group "rg-entra-logs-eventhub"
```

#### Configure Function App Settings

```bash
# Get Event Hub connection string (Listen)
EH_CONNECTION=$(az eventhubs namespace authorization-rule keys list \
    --name "RootManageSharedAccessKey" \
    --namespace-name "eh-ns-entra-logs-<unique-suffix>" \
    --resource-group "rg-entra-logs-eventhub" \
    --query "primaryConnectionString" --output tsv)

# Get Log Analytics Workspace details
WORKSPACE_ID=$(az monitor log-analytics workspace show \
    --resource-group "rg-central-logging" \
    --workspace-name "law-central-atevet12" \
    --query "customerId" --output tsv)

WORKSPACE_KEY=$(az monitor log-analytics workspace get-shared-keys \
    --resource-group "rg-central-logging" \
    --workspace-name "law-central-atevet12" \
    --query "primarySharedKey" --output tsv)

# Configure app settings
az functionapp config appsettings set \
    --name "func-entra-logs-processor" \
    --resource-group "rg-entra-logs-eventhub" \
    --settings \
        "EventHubConnectionString=$EH_CONNECTION" \
        "WORKSPACE_ID=$WORKSPACE_ID" \
        "WORKSPACE_KEY=$WORKSPACE_KEY" \
        "SOURCE_TENANT_NAME=Atevet17"
```

#### Deploy Function Code

The Azure Function code is located in the [`scripts/EntraIDLogsProcessor/`](scripts/EntraIDLogsProcessor/) directory. Deploy it using Azure Functions Core Tools:

```bash
# Navigate to the EntraIDLogsProcessor directory
cd scripts/EntraIDLogsProcessor

# Deploy using Azure Functions Core Tools
func azure functionapp publish func-entra-logs-processor --python

# Or using Azure CLI with zip deployment
cd ..
zip -r EntraIDLogsProcessor.zip EntraIDLogsProcessor/
az functionapp deployment source config-zip \
    --name "func-entra-logs-processor" \
    --resource-group "rg-entra-logs-eventhub" \
    --src "EntraIDLogsProcessor.zip"
```

---

### Step 6.3: Configure Entra ID Diagnostic Settings in Source Tenant

> ⚠️ **SKIP THIS SECTION if you successfully ran Step 6.1.** The automated script already configures diagnostic settings. This section is only needed if you used Step 6.2 for manual deployment.

Now configure the source tenant's Entra ID to send logs to the Event Hub.

#### Get Event Hub Authorization Rule ID

First, get the authorization rule resource ID from the managing tenant:

```bash
# In managing tenant (Atevet12)
az eventhubs namespace authorization-rule show \
    --name "source-tenant-send-policy" \
    --namespace-name "eh-ns-entra-logs-<unique-suffix>" \
    --resource-group "rg-entra-logs-eventhub" \
    --query "id" \
    --output tsv
```

**Save this ID - you'll need it for diagnostic settings:**
```
/subscriptions/<Managing-Sub-ID>/resourceGroups/rg-entra-logs-eventhub/providers/Microsoft.EventHub/namespaces/eh-ns-entra-logs-<unique-suffix>/authorizationRules/source-tenant-send-policy
```

#### Configure Diagnostic Settings via Azure CLI

```bash
# Login to source tenant (Atevet17) as Global Administrator
az login --tenant "<SOURCE-TENANT-ID>"

# Set the Event Hub authorization rule ID from managing tenant
EVENT_HUB_AUTH_RULE="/subscriptions/<MANAGING-SUB-ID>/resourceGroups/rg-entra-logs-eventhub/providers/Microsoft.EventHub/namespaces/eh-ns-entra-logs-<unique-suffix>/authorizationRules/source-tenant-send-policy"

# Create diagnostic setting for Entra ID
az monitor diagnostic-settings create \
    --name "SendToEventHub" \
    --resource "/providers/microsoft.aadiam" \
    --event-hub "eh-entra-id-logs" \
    --event-hub-rule "$EVENT_HUB_AUTH_RULE" \
    --logs '[
        {"category": "AuditLogs", "enabled": true},
        {"category": "SignInLogs", "enabled": true},
        {"category": "NonInteractiveUserSignInLogs", "enabled": true},
        {"category": "ServicePrincipalSignInLogs", "enabled": true},
        {"category": "ManagedIdentitySignInLogs", "enabled": true},
        {"category": "ProvisioningLogs", "enabled": true},
        {"category": "RiskyUsers", "enabled": true},
        {"category": "UserRiskEvents", "enabled": true},
        {"category": "MicrosoftGraphActivityLogs", "enabled": true}
    ]'
```

#### Configure Diagnostic Settings via PowerShell

```powershell
# Login to source tenant (Atevet17) as Global Administrator
Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"

# Variables
$eventHubAuthRuleId = "/subscriptions/<MANAGING-SUB-ID>/resourceGroups/rg-entra-logs-eventhub/providers/Microsoft.EventHub/namespaces/eh-ns-entra-logs-<unique-suffix>/authorizationRules/source-tenant-send-policy"
$eventHubName = "eh-entra-id-logs"
$diagnosticSettingName = "SendToEventHub"

# Define log categories to enable (adjust based on your license)
$logCategories = @(
    "AuditLogs",
    "SignInLogs",
    "NonInteractiveUserSignInLogs",
    "ServicePrincipalSignInLogs",
    "ManagedIdentitySignInLogs",
    "ProvisioningLogs",
    "RiskyUsers",
    "UserRiskEvents",
    "MicrosoftGraphActivityLogs"
)

# Build the logs array for the API call
$logsArray = $logCategories | ForEach-Object {
    @{
        category = $_
        enabled = $true
    }
}

# Create the diagnostic setting using REST API
$body = @{
    properties = @{
        eventHubAuthorizationRuleId = $eventHubAuthRuleId
        eventHubName = $eventHubName
        logs = $logsArray
    }
} | ConvertTo-Json -Depth 10

$uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/${diagnosticSettingName}?api-version=2017-04-01"

$token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

$response = Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -Body $body
Write-Host "Diagnostic setting created successfully"
```

#### Configure via Azure Portal (Alternative)

If you prefer the Portal method:

1. **Sign in to Azure Portal** as Global Administrator of the **source tenant**
2. Navigate to **Microsoft Entra ID** → **Monitoring** → **Diagnostic settings**
3. Click **+ Add diagnostic setting**
4. Enter name: `SendToEventHub`
5. Select log categories based on your license
6. Check **Stream to an event hub**
7. Enter the Event Hub details:
   - Subscription: Select the **managing tenant** subscription
   - Event hub namespace: `eh-ns-entra-logs-<unique-suffix>`
   - Event hub name: `eh-entra-id-logs`
   - Event hub policy name: `source-tenant-send-policy`
8. Click **Save**

---

### Step 6.4: Verify Log Collection

#### Check Event Hub Metrics

```bash
# In managing tenant
az monitor metrics list \
    --resource "/subscriptions/<MANAGING-SUB-ID>/resourceGroups/rg-entra-logs-eventhub/providers/Microsoft.EventHub/namespaces/eh-ns-entra-logs-<unique-suffix>" \
    --metric "IncomingMessages" \
    --interval PT1M \
    --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ)
```

#### Check Function App Logs

```bash
# View Function App logs
az functionapp log tail \
    --name "func-entra-logs-processor" \
    --resource-group "rg-entra-logs-eventhub"
```

#### Query Logs in Log Analytics

Wait 5-15 minutes after configuration, then run these KQL queries in your Log Analytics workspace:

```kusto
// Check for Entra ID logs from Event Hub
union EntraIDAuditLogs_*_CL, EntraIDSignInLogs_*_CL, EntraIDNonInteractiveSignInLogs_*_CL
| where TimeGenerated > ago(1h)
| summarize Count=count() by Type
| order by Count desc

// Check Sign-in Logs
EntraIDSignInLogs_*_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, SourceTenantName, UserPrincipalName_s, AppDisplayName_s, ResultType_s
| order by TimeGenerated desc
| take 100

// Check Audit Logs
EntraIDAuditLogs_*_CL
| where TimeGenerated > ago(1h)
| project TimeGenerated, SourceTenantName, OperationName_s, Category_s, Result_s
| order by TimeGenerated desc
| take 100

// Check for failed sign-ins (security monitoring)
EntraIDSignInLogs_*_CL
| where TimeGenerated > ago(24h)
| where ResultType_s != "0"
| project TimeGenerated, UserPrincipalName_s, AppDisplayName_s, ResultType_s, ResultDescription_s, IPAddress_s
| order by TimeGenerated desc

// Check risky users (requires P2 license)
EntraIDRiskyUsers_*_CL
| where TimeGenerated > ago(7d)
| project TimeGenerated, UserPrincipalName_s, RiskLevel_s, RiskState_s
```

---

### Troubleshooting

| Issue | Symptoms | Solution |
|-------|----------|----------|
| **Events not arriving in Event Hub** | No incoming messages in Event Hub metrics | Verify diagnostic settings in source tenant; check Event Hub authorization rule ID is correct |
| **Function not processing events** | Events in Event Hub but not in Log Analytics | Check Function App logs; verify connection strings in app settings |
| **Permission denied on diagnostic settings** | Error creating diagnostic setting | Ensure you have Global Administrator role in source tenant |
| **LinkedAuthorizationFailed** | Error when using direct Log Analytics | This is expected - use Event Hub method instead |
| **Missing log categories** | Some categories not appearing | Verify you have the required license (P1/P2) for those categories |
| **High latency** | Events delayed | Increase Event Hub throughput units; check Function App scaling |

#### Diagnostic Commands

```bash
# Check Event Hub health
az eventhubs namespace show \
    --name "eh-ns-entra-logs-<unique-suffix>" \
    --resource-group "rg-entra-logs-eventhub" \
    --query "{Status:status, ProvisioningState:provisioningState}"

# List diagnostic settings in source tenant
az monitor diagnostic-settings list \
    --resource "/providers/microsoft.aadiam" \
    --query "[].{Name:name, EventHub:eventHubName}"

# Check Function App status
az functionapp show \
    --name "func-entra-logs-processor" \
    --resource-group "rg-entra-logs-eventhub" \
    --query "{State:state, DefaultHostName:defaultHostName}"

# View recent Function invocations
az monitor app-insights query \
    --app "func-entra-logs-processor" \
    --analytics-query "requests | where timestamp > ago(1h) | summarize count() by resultCode"
```

---

### Cost Estimation

| Component | Unit | Estimated Monthly Cost |
|-----------|------|------------------------|
| **Event Hub Namespace (Standard)** | Base | ~$22/month |
| **Event Hub Throughput Units** | Per TU | ~$22/TU/month |
| **Azure Function (Consumption)** | Per million executions | ~$0.20 |
| **Azure Function Execution Time** | Per GB-s | ~$0.000016 |
| **Log Analytics Ingestion** | Per GB | ~$2.76/GB |

**Estimated Total (50GB Entra ID logs/month):** ~$180-220/month

---

### Security Considerations

1. **Principle of Least Privilege**
   - Use **Send-only** SAS policies for source tenant
   - Use **Listen-only** SAS policies for Function App consumer
   - Rotate SAS keys every 90 days

2. **Network Security**
   - Consider enabling Private Endpoints for Event Hub in production
   - Configure NSG rules to restrict access
   - Use Service Endpoints as minimum security

3. **Key Rotation Schedule**

| Component | Rotation Frequency | Method |
|-----------|-------------------|--------|
| Event Hub SAS Keys | Every 90 days | Regenerate secondary, update configs, regenerate primary |
| Log Analytics Key | Every 90 days | Regenerate and update Function App settings |

4. **Store Secrets in Key Vault**
   - All connection strings should be stored in Key Vault
   - Use Managed Identity for Function App to access Key Vault
   - Enable soft delete and purge protection on Key Vault

---

### Script Files Reference

| File | Description |
|------|-------------|
| [`scripts/Configure-EntraIDLogsViaEventHub.ps1`](scripts/Configure-EntraIDLogsViaEventHub.ps1) | Main PowerShell script for automated deployment |
| [`scripts/EntraIDLogsProcessor/__init__.py`](scripts/EntraIDLogsProcessor/__init__.py) | Azure Function Python code for log processing |
| [`scripts/EntraIDLogsProcessor/function.json`](scripts/EntraIDLogsProcessor/function.json) | Function binding configuration |
| [`scripts/EntraIDLogsProcessor/requirements.txt`](scripts/EntraIDLogsProcessor/requirements.txt) | Python dependencies |
| [`scripts/EntraIDLogsProcessor/host.json`](scripts/EntraIDLogsProcessor/host.json) | Function host configuration |

---

### Summary

You have now configured cross-tenant Entra ID log collection using Azure Event Hub. This method bypasses the limitations of direct Log Analytics workspace configuration and provides:

| Feature | Status |
|---------|--------|
| **Automated deployment** | ✅ Fully scriptable |
| **Real-time streaming** | ✅ Sub-second latency |
| **Cross-tenant support** | ✅ Works via connection string |
| **All log categories** | ✅ Based on license |
| **Scalable architecture** | ✅ Auto-inflate enabled |
| **Secure transport** | ✅ SAS token authentication |

### Next Steps

1. **Monitor Event Hub metrics** for incoming messages
2. **Verify logs in Log Analytics** using the KQL queries above
3. **Set up alerts** for critical Entra ID events
4. **Proceed to Step 7** to configure Microsoft 365 Audit Logs

---

## Step 7: Configure Microsoft 365 Audit Logs

> ⚠️ **IMPORTANT**: This step requires **Global Administrator** access to BOTH the source tenant AND the managing tenant. Unlike Azure resource logs (Steps 3-5), Microsoft 365 audit logs are NOT accessible via Azure Lighthouse. This script uses a **multi-tenant app registration** with the Office 365 Management API to collect M365 audit logs from source tenants.

Microsoft 365 audit logs capture activities across Exchange Online, SharePoint Online, OneDrive, Teams, and other M365 services. These logs are essential for security monitoring, compliance, and incident investigation.

### Where to Run This Script

| Tenant | Role | What Happens |
|--------|------|--------------|
| **Managing Tenant (Atevet12)** | ✅ **Run script here** | Creates multi-tenant app, stores credentials in Key Vault |
| **Source Tenant (Atevet17)** | ✅ **Admin consent required** | Script authenticates and grants permissions automatically |

### Prerequisites

Before running this script, you need:
- **Global Administrator** role in the **managing tenant** (to create app registration)
- **Global Administrator** role in the **source tenant** (to grant admin consent)
- **Microsoft Graph PowerShell SDK** installed (`Install-Module Microsoft.Graph`)
- **Az PowerShell module** installed (`Install-Module Az`)
- **Key Vault** in the managing tenant (created in Step 1)
- **Log Analytics Workspace** in the managing tenant (created in Step 1)

### Authentication Flow

The script uses an improved authentication flow that:
1. **Automatically opens a full browser window** for authentication (not a small popup)
2. **Disables Windows Account Manager (WAM)** to avoid authentication issues
3. **Clearly identifies which tenant** you need to authenticate to at each step
4. **Falls back to device code authentication** if browser authentication fails

You will see clear prompts like:
```
*** AUTHENTICATE TO MANAGING TENANT: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx ***
*** AUTHENTICATE TO SOURCE TENANT: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy ***
```

> **Tip**: If you encounter authentication issues, use the `-UseDeviceCode` parameter to force device code authentication, which opens a browser to https://microsoft.com/devicelogin where you enter a code.

### Script: `Configure-M365AuditLogCollection.ps1`

The complete PowerShell script is located at: [`scripts/Configure-M365AuditLogCollection.ps1`](scripts/Configure-M365AuditLogCollection.ps1)

This script automates the entire setup process:
1. Creates a multi-tenant app registration in the managing tenant
2. Configures Office 365 Management API permissions
3. Grants admin consent in the source tenant (automated)
4. Stores credentials securely in Key Vault
5. Creates audit log subscriptions

### Usage Examples

#### Full Setup (First Source Tenant)

```powershell
# Run from MANAGING TENANT (Atevet12) as Global Administrator
# This creates the app and configures the first source tenant
# The script will prompt for authentication to both tenants with clear instructions

.\Configure-M365AuditLogCollection.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SourceTenantId "<ATEVET17-TENANT-ID>" `
    -SourceTenantName "Atevet17" `
    -KeyVaultName "kv-central-atevet12" `
    -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
```

#### Using Device Code Authentication

```powershell
# Use device code authentication if browser authentication fails
# This opens https://microsoft.com/devicelogin where you enter a code
.\Configure-M365AuditLogCollection.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SourceTenantId "<ATEVET17-TENANT-ID>" `
    -SourceTenantName "Atevet17" `
    -KeyVaultName "kv-central-atevet12" `
    -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -UseDeviceCode
```

#### Add Another Source Tenant (App Already Exists)

```powershell
# Skip app creation when adding additional source tenants
.\Configure-M365AuditLogCollection.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SourceTenantId "<ATEVET18-TENANT-ID>" `
    -SourceTenantName "Atevet18" `
    -KeyVaultName "kv-central-atevet12" `
    -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SkipAppCreation
```

#### Specific Content Types Only

```powershell
# Configure only Exchange and SharePoint audit logs
.\Configure-M365AuditLogCollection.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SourceTenantId "<ATEVET17-TENANT-ID>" `
    -SourceTenantName "Atevet17" `
    -KeyVaultName "kv-central-atevet12" `
    -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -ContentTypes @("Audit.Exchange", "Audit.SharePoint")
```

#### Verify Existing Configuration

```powershell
# Check current configuration without making changes
.\Configure-M365AuditLogCollection.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SourceTenantId "<ATEVET17-TENANT-ID>" `
    -SourceTenantName "Atevet17" `
    -KeyVaultName "kv-central-atevet12" `
    -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -VerifyOnly
```

#### Custom Configuration Options

```powershell
# Customize automation account name, location, and schedule interval
.\Configure-M365AuditLogCollection.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SourceTenantId "<ATEVET17-TENANT-ID>" `
    -SourceTenantName "Atevet17" `
    -KeyVaultName "kv-central-atevet12" `
    -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -AutomationAccountName "aa-m365-collector-custom" `
    -Location "westus2" `
    -ScheduleIntervalMinutes 60
```

### Expected Output (Configuration Script)

When running `Configure-M365AuditLogCollection.ps1`, you will see output with clear status indicators:

```
========================================
Configure M365 Audit Log Collection
========================================

*** AUTHENTICATE TO MANAGING TENANT: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx ***
Opening browser for authentication...
✓ Connected to Microsoft Graph (Managing Tenant)

Step 1: Creating multi-tenant app registration...
  ✓ App registration created: M365-AuditLog-Collector
  ✓ Client secret created (expires: 2027-02-26)

Step 2: Configuring Office 365 Management API permissions...
  ✓ O365 Management API service principal found
  ✓ Permission granted: ActivityFeed.Read
  ✓ Permission granted: ActivityFeed.ReadDlp
  ✓ Permission granted: ServiceHealth.Read

*** AUTHENTICATE TO SOURCE TENANT: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy ***
Opening browser for authentication...
✓ Connected to Microsoft Graph (Source Tenant)

Step 3: Granting admin consent in source tenant...
  ✓ Service principal created in source tenant
  ✓ Admin consent granted for all permissions

Step 4: Storing credentials in Key Vault...
  ✓ App ID stored in Key Vault
  ✓ Client secret stored in Key Vault
  ✓ Tenant configuration updated

Step 5: Creating audit log subscriptions...
  Waiting 10 seconds for permission propagation...
  ✓ Subscribed: Audit.AzureActiveDirectory
  ✓ Subscribed: Audit.Exchange
  ✓ Subscribed: Audit.SharePoint
  ✓ Subscribed: Audit.General
  ✓ Already subscribed: DLP.All

========================================
CONFIGURATION COMPLETE
========================================

✓ App Registration: M365-AuditLog-Collector
✓ Permissions: ActivityFeed.Read, ActivityFeed.ReadDlp, ServiceHealth.Read
✓ Subscriptions: 5/5 enabled
✓ Credentials stored in Key Vault: kv-central-atevet12

Next steps:
1. Wait 5-10 minutes for the first scheduled runbook execution (or run manually)
2. Check Log Analytics for M365 audit logs using the KQL queries below
```

### Key Vault Secrets Created

| Secret Name | Description |
|-------------|-------------|
| `M365Collector-AppId` | Application (client) ID of the multi-tenant app |
| `M365Collector-Secret` | Client secret for authentication |
| `M365Collector-Tenants` | JSON list of configured source tenants |
| `LogAnalytics-WorkspaceKey` | Log Analytics workspace primary key |

### Verify Logs in Log Analytics

After the runbook runs, verify logs appear in Log Analytics. The `M365AuditLogs_CL` table will be created automatically when the first logs are ingested.

#### M365 Audit Log Content Types

| Content Type | What It Logs |
|--------------|--------------|
| **Audit.AzureActiveDirectory** | Entra ID - user/group changes, app registrations, directory changes |
| **Audit.Exchange** | Exchange Online - mailbox access, mail flow, admin actions, email events |
| **Audit.SharePoint** | SharePoint & OneDrive - file access, sharing, site changes, downloads |
| **Audit.General** | Teams, Power Platform, Dynamics 365, Yammer, Forms |
| **DLP.All** | Data Loss Prevention - policy matches and actions |

#### Office Application Activities

Office activities are captured when files are stored in SharePoint/OneDrive:

| App | Activities Logged |
|-----|-------------------|
| **Word, Excel, PowerPoint, OneNote** | File open, edit, download, share, delete |
| **Outlook** | Email send/receive, calendar, mailbox access |
| **Teams** | Messages, meetings, file sharing |
| **OneDrive** | Sync, upload, download, share |

#### Common File Operations (SharePoint/OneDrive)

| Operation | Description |
|-----------|-------------|
| `FileAccessed` | User opened a file |
| `FileModified` | User edited a file |
| `FileDownloaded` | User downloaded a file |
| `FileUploaded` | User uploaded a file |
| `FileShared` | User shared a file |
| `FileSyncDownloadedFull` | User synced files via OneDrive |

#### Email Operations (Exchange)

| Operation | Description |
|-----------|-------------|
| `MailItemsAccessed` | User accessed/read email |
| `Send` | User sent an email |
| `SendAs` | Sent email as another user |
| `SendOnBehalf` | Sent on behalf of another user |
| `Create` | Email/calendar item created |
| `SoftDelete` | Email moved to Deleted Items |
| `HardDelete` | Email permanently deleted |
| `MailboxLogin` | User logged into mailbox |
| `SearchQueryInitiated` | User searched mailbox |

#### Teams Operations (General)

| Operation | Description |
|-----------|-------------|
| `MessageSent` | User sent a Teams message |
| `MessageUpdated` | User edited a Teams message |
| `MessageDeleted` | User deleted a Teams message |
| `MeetingStarted` | User started a meeting |
| `MeetingJoined` | User joined a meeting |

#### KQL Queries

```kusto
// Check M365 audit logs by content type
M365AuditLogs_CL
| where TimeGenerated > ago(1h)
| summarize count() by SourceTenantName_s, ContentType_s
| order by count_ desc

// View all Exchange audit events (email, calendar)
M365AuditLogs_CL
| where ContentType_s == "Audit.Exchange"
| where TimeGenerated > ago(24h)
| project TimeGenerated, SourceTenantName_s, Operation_s, UserId_s, ClientIP_s
| order by TimeGenerated desc

// View email send activities
M365AuditLogs_CL
| where ContentType_s == "Audit.Exchange"
| where Operation_s in ("Send", "SendAs", "SendOnBehalf")
| where TimeGenerated > ago(24h)
| project TimeGenerated, UserId_s, Operation_s, SourceTenantName_s
| order by TimeGenerated desc

// View mailbox access activities
M365AuditLogs_CL
| where ContentType_s == "Audit.Exchange"
| where Operation_s == "MailItemsAccessed"
| where TimeGenerated > ago(24h)
| project TimeGenerated, UserId_s, ClientIP_s, SourceTenantName_s
| order by TimeGenerated desc

// View Office file activities (Word, Excel, PowerPoint, etc.)
M365AuditLogs_CL
| where ContentType_s == "Audit.SharePoint"
| where Operation_s in ("FileAccessed", "FileModified", "FileDownloaded", "FileUploaded", "FileShared")
| where TimeGenerated > ago(1h)
| project TimeGenerated, UserId_s, Operation_s, ObjectId_s, SourceTenantName_s
| order by TimeGenerated desc

// View SharePoint/OneDrive file access events
M365AuditLogs_CL
| where ContentType_s == "Audit.SharePoint"
| where TimeGenerated > ago(1h)
| project TimeGenerated, SourceTenantName_s, Operation_s, UserId_s, ObjectId_s
| order by TimeGenerated desc

// View Teams events (messages, meetings)
M365AuditLogs_CL
| where ContentType_s == "Audit.General"
| where Workload_s == "MicrosoftTeams"
| where TimeGenerated > ago(1h)
| project TimeGenerated, SourceTenantName_s, Operation_s, UserId_s
| order by TimeGenerated desc

// View Entra ID (Azure AD) events
M365AuditLogs_CL
| where ContentType_s == "Audit.AzureActiveDirectory"
| where TimeGenerated > ago(1h)
| project TimeGenerated, SourceTenantName_s, Operation_s, UserId_s
| order by TimeGenerated desc

// View DLP policy events
M365AuditLogs_CL
| where ContentType_s == "DLP.All"
| where TimeGenerated > ago(24h)
| project TimeGenerated, SourceTenantName_s, Operation_s, UserId_s
| order by TimeGenerated desc
```

### Troubleshooting

| Issue | Solution |
|-------|----------|
| **Authentication Issues** | |
| Browser authentication fails or shows small popup | The script automatically disables WAM and opens a full browser window. If issues persist, use `-UseDeviceCode` parameter |
| "InteractiveBrowserCredential authentication failed" | Use `-UseDeviceCode` parameter to force device code authentication flow |
| Confused about which tenant to authenticate to | The script shows clear prompts: `*** AUTHENTICATE TO MANAGING TENANT ***` or `*** AUTHENTICATE TO SOURCE TENANT ***` |
| Device code authentication not working | Ensure you're entering the code at https://microsoft.com/devicelogin and signing in with the correct account |
| **Permission Issues** | |
| "Permission being assigned was not found" | The script dynamically discovers app roles from the O365 Management API service principal. If this fails, the O365 Management API may not be available in your tenant |
| Admin consent error in source tenant | Ensure you have Global Administrator role in the source tenant |
| 401 Unauthorized when creating subscriptions | The script includes a 10-second delay and retry mechanism (3 attempts) for permission propagation. Wait and retry if needed |
| **Subscription Issues** | |
| Subscription start fails with "already enabled" | This is informational (shown as ✓) - the subscription is already active |
| DLP.All returns 400 Bad Request | This is treated as "already subscribed" if the subscription is actually enabled. Run the KQL query above to verify logs are being collected |
| No logs collected | Wait 5-10 minutes after runbook execution, then run the KQL queries above to check if logs appear in Log Analytics |
| **Key Vault & Automation Issues** | |
| Runbook fails with "Key Vault access denied" | Verify Managed Identity has Key Vault access policy with `get` and `list` permissions for secrets (the script configures this via ARM template) |
| OAuth token error | Verify app credentials in Key Vault are correct (`M365Collector-AppId` and `M365Collector-Secret`) |
| Logs not appearing in Log Analytics | Check `LogAnalytics-WorkspaceKey` secret is correct; verify Workspace ID in runbook parameters |
| Module import fails | Wait for previous module import to complete; check Automation Account > Modules for status |
| **DLP-Specific Issues** | |
| DLP.All subscription enabled but no DLP events | Verify DLP policies exist in the source tenant: `Get-DlpCompliancePolicy` in Exchange Online PowerShell |
| Need to check DLP license status | Connect to Exchange Online: `Connect-ExchangeOnline -UserPrincipalName admin@tenant.onmicrosoft.com` then run `Get-DlpCompliancePolicy` |

---

### Next Steps

After completing Step 7:
- **Step 8**: Configure Microsoft Sentinel analytics rules for cross-tenant detection
- **Step 9**: Set up workbooks and dashboards for unified visibility
- **Step 10**: Implement alerting and incident response workflows

## Additional Resources

- [Main Guide: Azure Cross-Tenant Log Collection](azure-cross-tenant-log-collection-guide.md)
- [Azure PowerShell Documentation](https://docs.microsoft.com/en-us/powershell/azure/)
- [Az.Resources Module](https://docs.microsoft.com/en-us/powershell/module/az.resources/)
- [Azure Cloud Shell](https://docs.microsoft.com/en-us/azure/cloud-shell/overview)

---
