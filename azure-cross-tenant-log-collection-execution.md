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

### What This Script Does

The script automates the configuration of Activity Log diagnostic settings:
1. Validates the Log Analytics workspace resource ID
2. Discovers all delegated subscriptions (or uses specified subscription IDs)
3. Creates diagnostic settings on each subscription to send Activity Logs to the workspace
4. Enables all Activity Log categories by default (can be customized)
5. Verifies the diagnostic settings were created successfully

### Script: `Configure-ActivityLogCollection.ps1`

The complete PowerShell script is located at: [`scripts/Configure-ActivityLogCollection.ps1`](scripts/Configure-ActivityLogCollection.ps1)

This script automates the configuration of Activity Log diagnostic settings for Azure subscriptions:
1. Connects to delegated subscriptions via Azure Lighthouse
2. Creates diagnostic settings using ARM template deployment
3. Configures all Activity Log categories (Administrative, Security, ServiceHealth, etc.)
4. Supports both single and multiple subscription configurations

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

### Verification

After running the script, verify that Activity Logs are flowing to the Log Analytics workspace:

#### 1. Check Diagnostic Settings via Azure Portal

1. Navigate to the Azure Portal
2. Go to **Monitor** > **Activity log** > **Diagnostic settings**
3. Select the subscription you configured
4. Verify the diagnostic setting exists and shows the correct workspace

#### 2. Check Diagnostic Settings via PowerShell

```powershell
# List diagnostic settings for a subscription
$subscriptionId = "<DELEGATED-SUBSCRIPTION-ID>"
Get-AzDiagnosticSetting -ResourceId "/subscriptions/$subscriptionId" | Format-List Name, WorkspaceId, Log
```

#### 3. Query Log Analytics

Wait 5-15 minutes for logs to start flowing, then run these queries:

```kusto
// Check for Activity Logs from delegated subscriptions
AzureActivity
| where TimeGenerated > ago(1h)
| summarize count() by SubscriptionId, CategoryValue
| order by count_ desc

// Check for specific administrative operations
AzureActivity
| where TimeGenerated > ago(1h)
| where CategoryValue == "Administrative"
| project TimeGenerated, OperationNameValue, Caller, ResourceGroup, _ResourceId
| order by TimeGenerated desc
| take 20

// Summary of Activity Log categories
AzureActivity
| where TimeGenerated > ago(24h)
| summarize
    TotalEvents = count(),
    UniqueOperations = dcount(OperationNameValue),
    UniqueCallers = dcount(Caller)
    by CategoryValue
| order by TotalEvents desc
```

### Best Practices

1. **Enable all categories**: By default, enable all Activity Log categories for comprehensive visibility. You can filter in queries later.
2. **Use consistent naming**: Use the same diagnostic setting name across all subscriptions for easier management.
3. **Monitor log ingestion**: Set up alerts on `_LogOperation` errors to catch ingestion issues early.
4. **Review costs**: Activity Logs are typically low-volume, but monitor Log Analytics ingestion costs.
5. **Retention settings**: Configure appropriate retention periods in the Log Analytics workspace (default is 30 days).
6. **Cross-tenant visibility**: Use Azure Lighthouse to manage diagnostic settings across tenants from a single location.
7. **Automate for new subscriptions**: Consider using Azure Policy to automatically configure Activity Log collection for new subscriptions.

---

## Step 4: Configure Virtual Machine Diagnostic Logs

> ⚠️ **IMPORTANT**: This script should be run from the **MANAGING TENANT** (Atevet12) after Azure Lighthouse delegation is complete.

Virtual Machine diagnostic logs capture performance metrics, Windows Event Logs, and Linux Syslog data. This step configures the Azure Monitor Agent (AMA) and Data Collection Rules (DCR) for VMs.

---

### Quick Start

For most users, follow these simple steps:

**Step 1: Connect to the managing tenant**
```powershell
Connect-AzAccount -TenantId "<MANAGING-TENANT-ID>"
```

**Step 2: Run the script with your workspace resource ID**
```powershell
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SourceTenantId "<SOURCE-TENANT-ID>"
```

**Step 3: Wait for completion**

The script will automatically:
1. ✅ Create a Data Collection Rule (DCR) in the source tenant
2. ✅ Install Azure Monitor Agent on running VMs
3. ✅ Deploy Azure Policy for stopped/new VMs
4. ✅ Assign roles to policy managed identities
5. ✅ Create remediation tasks

That's it! The script handles everything automatically.

---

### What This Step Does

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SOURCE TENANT (Atevet17)                         │
│                                                                         │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────────────┐    │
│  │     VMs      │────►│     DCR      │────►│  Azure Monitor Agent │    │
│  │              │     │ (Created     │     │  (Installed by       │    │
│  │              │     │  HERE)       │     │   Script/Policy)     │    │
│  └──────────────┘     └──────┬───────┘     └──────────────────────┘    │
│                              │                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Azure Policy (automatically deployed)                           │  │
│  │  - Handles stopped VMs when they start                           │  │
│  │  - Handles new VMs automatically                                 │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                              │                                          │
└──────────────────────────────┼──────────────────────────────────────────┘
                               │ Data flows cross-tenant
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      MANAGING TENANT (Atevet12)                         │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Log Analytics Workspace  ──────►  Microsoft Sentinel            │  │
│  │  (Receives VM logs)               (Security monitoring)          │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**The script collects:**
- Performance counters (CPU, Memory, Disk, Network)
- Windows Event Logs (Application, Security, System)
- Linux Syslog

---

### Prerequisites

Before running this script, ensure you have:

| Requirement | Where to Get It |
|-------------|-----------------|
| **Azure Lighthouse delegation** | Completed in Step 2 |
| **Log Analytics Workspace Resource ID** | From Step 1 output |
| **Source Tenant ID** | The tenant where VMs are located |
| **Contributor role** | On the delegated subscriptions |
| **Resource Policy Contributor role** | On the delegated subscriptions (for policy deployment) |

---

### Scripts

This step uses two PowerShell scripts that work together:

| Script | Purpose | Run Manually? |
|--------|---------|---------------|
| [`Configure-VMDiagnosticLogs.ps1`](scripts/Configure-VMDiagnosticLogs.ps1) | Main script - configures DCR, AMA, and Azure Policy | ✅ Yes - run this one |
| [`Run-AssignRolesAsSourceAdmin.ps1`](scripts/Run-AssignRolesAsSourceAdmin.ps1) | Helper script - assigns roles to policy identities | ❌ No - called automatically |

> **Note:** The main script automatically calls the helper script after deploying Azure Policy. You don't need to run them separately.

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

---

### Advanced Configuration

The following sections cover advanced scenarios. Most users can skip these unless they have specific requirements.

#### How Automatic Role Assignment Works

When Azure Policy is deployed, it creates managed identities in the **source tenant** that need **Contributor** role to install VM extensions. The main script **automatically handles this** by calling the helper script after policy deployment.

**How it works:**
1. The main script deploys Azure Policy assignments with managed identities
2. After policy deployment, it automatically invokes `Run-AssignRolesAsSourceAdmin.ps1`
3. The helper script connects to the source tenant and assigns Contributor role to the policy identities
4. Remediation tasks are created to apply policies to existing VMs

**Providing the Source Tenant ID:**

```powershell
# Option 1: Provide the source tenant ID upfront (no prompts)
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SourceTenantId "<SOURCE-TENANT-ID>"

# Option 2: Let the script prompt for the source tenant ID (if not provided)
# The script will detect tenant IDs from policy assignments or prompt you
.\Configure-VMDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
```

#### Manual Role Assignment (If Automatic Assignment Fails)

In some cases, you may need to run the role assignment manually:
- If the automatic role assignment failed
- If you need to re-run role assignment after the initial setup
- If you're troubleshooting policy remediation issues

**Option 1: Use the Helper Script Directly**

```powershell
# Run the helper script - it will connect to the source tenant and assign roles
.\Run-AssignRolesAsSourceAdmin.ps1 `
    -TenantId "<SOURCE-TENANT-ID>" `
    -SubscriptionIds @("<SOURCE-SUBSCRIPTION-ID>")

# With custom policy assignment prefix and DCR name
.\Run-AssignRolesAsSourceAdmin.ps1 `
    -TenantId "<SOURCE-TENANT-ID>" `
    -SubscriptionIds @("<SOURCE-SUBSCRIPTION-ID>") `
    -PolicyAssignmentPrefix "vm-monitoring-atevet17" `
    -DataCollectionRuleName "dcr-vmlogs-for-atevet17"

# Skip remediation task creation
.\Run-AssignRolesAsSourceAdmin.ps1 `
    -TenantId "<SOURCE-TENANT-ID>" `
    -SubscriptionIds @("<SOURCE-SUBSCRIPTION-ID>") `
    -SkipRemediation
```

**Option 2: Use the Main Script with -AssignRolesAsSourceAdmin**

The `-AssignRolesAsSourceAdmin` parameter runs the script in a special mode that only performs role assignment:

```powershell
# SOURCE TENANT ADMIN: Connect to the source tenant first
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

---

### Technical Reference

This section contains detailed technical information for advanced users and troubleshooting.

#### Built-in Policy Definitions

The script deploys these Azure Policy definitions in the correct order:

| Policy | Definition ID | Purpose |
|--------|--------------|---------|
| **Identity VMs** | `3cf2ab00-13f1-4d0c-8971-2ac904541a7e` | Add System Assigned Managed Identity to VMs (REQUIRED - works for both Windows and Linux) |
| **AMA Windows** | `ca817e41-e85a-4783-bc7f-dc532d36235e` | Deploy Azure Monitor Agent on Windows VMs |
| **AMA Linux** | `a4034bc6-ae50-406d-bf76-50f4ee5a7811` | Deploy Azure Monitor Agent on Linux VMs |
| **DCR Windows** | `eab1f514-22e3-42e3-9a1f-e1dc9199355c` | Associate Windows VMs with DCR |
| **DCR Linux** | `58e891b9-ce13-4ac3-86e4-ac3e1f20cb07` | Associate Linux VMs with DCR |

> **Policy Deployment Order:** Identity → AMA → DCR (the script handles this automatically)

#### Why DCR Must Be in Source Tenant

The Data Collection Rule (DCR) must be created in the **source tenant** (where VMs are located), not the managing tenant. This is because:

1. Azure Policy creates managed identities in the source tenant
2. These identities can only access resources in their own tenant
3. If DCR is in managing tenant, policy fails with: `not authorized to access linked subscription`

The script handles this automatically - it creates the DCR in the source tenant while sending data to the managing tenant's Log Analytics workspace.

#### System Assigned Managed Identity Requirement

The AMA policy requires VMs to have System Assigned Managed Identity enabled. The script automatically enables this on running VMs. For stopped VMs, the Identity policy will enable it when they start.

#### Opt-Out Parameters Reference

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-DeployPolicy` | bool | `$true` | Skip Azure Policy deployment |
| `-SkipDCRCreation` | switch | `$false` | Skip DCR creation (use existing) |
| `-SkipAgentInstallation` | switch | `$false` | Skip AMA installation |
| `-SkipRemediation` | switch | `$false` | Skip remediation tasks |
| `-SkipVerification` | switch | `$false` | Skip verification step |
| `-SkipMasterDCR` | switch | `$false` | Skip Master DCR backup creation |

---

### Troubleshooting

#### Permission Denied

**Error:** `The client does not have authorization to perform action`

**Solution:**
- Ensure you have **Contributor** role on the delegated subscription
- Verify Azure Lighthouse delegation includes the Contributor role
- Check that you're a member of the delegated security group

#### VM Extension Installation Failed

**Error:** `VM extension installation failed` or `Cannot modify extensions in the VM when the VM is not running`

**Solution:**
1. Verify the VM is running (stopped VMs will be handled by Azure Policy when they start)
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

#### Role Assignment Failed

**Error:** `Could not assign Contributor role` or `AuthorizationFailed`

**Solution:**
This is expected in cross-tenant scenarios. The script automatically calls the helper script to handle this. If it still fails:
1. Run the helper script manually: `.\Run-AssignRolesAsSourceAdmin.ps1 -TenantId "<SOURCE-TENANT-ID>" -SubscriptionIds @("<SUB-ID>")`
2. Or have a source tenant admin run the role assignment

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
