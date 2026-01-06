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

> ✅ **RECOMMENDED for Azure Cloud Shell** - No additional setup required!

This PowerShell script checks and registers the `Microsoft.ManagedServices` resource provider across all subscriptions in a tenant. This is required before deploying Azure Lighthouse.

### Script: `Register-ManagedServices.ps1`

```powershell
<#
.SYNOPSIS
    Registers Microsoft.ManagedServices resource provider across Azure subscriptions.

.DESCRIPTION
    This script is used as Step 0 in the Azure Cross-Tenant Log Collection setup.
    It ensures the Microsoft.ManagedServices resource provider is registered in
    all subscriptions before deploying Azure Lighthouse.

.PARAMETER TenantId
    The Azure tenant ID (GUID) to process subscriptions for.

.PARAMETER SubscriptionIds
    Optional. Specific subscription IDs to process. If not provided, all accessible subscriptions are processed.

.PARAMETER CheckOnly
    If specified, only checks registration status without registering.

.EXAMPLE
    .\Register-ManagedServices.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\Register-ManagedServices.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -CheckOnly

.EXAMPLE
    .\Register-ManagedServices.ps1 -SubscriptionIds "sub-id-1", "sub-id-2"

.NOTES
    Author: Cross-Tenant Log Collection Guide
    Requires: Az.Accounts, Az.Resources modules
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [switch]$CheckOnly,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 300
)

# Constants
$ProviderNamespace = "Microsoft.ManagedServices"
$PollIntervalSeconds = 10

# Color functions for output
function Write-Success { param($Message) Write-Host $Message -ForegroundColor Green }
function Write-Error { param($Message) Write-Host $Message -ForegroundColor Red }
function Write-Warning { param($Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Info { param($Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Header { param($Message) Write-Host $Message -ForegroundColor Cyan -BackgroundColor DarkBlue }

function Get-ProviderStatus {
    param(
        [string]$SubscriptionId
    )
    
    try {
        $provider = Get-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction Stop
        # Get-AzResourceProvider returns an array of resource types; extract the first RegistrationState
        return ($provider | Select-Object -First 1).RegistrationState
    }
    catch {
        if ($_.Exception.Message -like "*not found*") {
            return "NotRegistered"
        }
        throw
    }
}

function Register-Provider {
    param(
        [string]$SubscriptionId
    )
    
    try {
        Register-AzResourceProvider -ProviderNamespace $ProviderNamespace -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-Error "    Error registering provider: $($_.Exception.Message)"
        return $false
    }
}

function Wait-ForRegistration {
    param(
        [string]$SubscriptionId,
        [int]$Timeout = $TimeoutSeconds
    )
    
    $startTime = Get-Date
    
    while (((Get-Date) - $startTime).TotalSeconds -lt $Timeout) {
        $status = Get-ProviderStatus -SubscriptionId $SubscriptionId
        
        if ($status -eq "Registered") {
            return $true
        }
        elseif ($status -in @("NotRegistered", "Unregistered")) {
            return $false
        }
        
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    
    return $false
}

function Process-Subscription {
    param(
        [object]$Subscription,
        [bool]$CheckOnly
    )
    
    $subId = $Subscription.Id
    $subName = $Subscription.Name
    
    $result = @{
        SubscriptionId = $subId
        SubscriptionName = $subName
        InitialStatus = $null
        FinalStatus = $null
        ActionTaken = $null
        Success = $false
        Error = $null
    }
    
    try {
        # Set context to this subscription
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
        
        # Check current status
        $status = Get-ProviderStatus -SubscriptionId $subId
        $result.InitialStatus = $status
        
        if ($status -eq "Registered") {
            Write-Success "  [OK] $subName : Already registered"
            $result.FinalStatus = $status
            $result.ActionTaken = "none"
            $result.Success = $true
        }
        elseif ($status -eq "Registering") {
            Write-Info "  [..] $subName : Registration in progress, waiting..."
            if (Wait-ForRegistration -SubscriptionId $subId) {
                Write-Success "    [OK] Registration completed"
                $result.FinalStatus = "Registered"
                $result.ActionTaken = "waited"
                $result.Success = $true
            }
            else {
                Write-Error "    [X] Registration timed out"
                $result.FinalStatus = Get-ProviderStatus -SubscriptionId $subId
                $result.ActionTaken = "waited"
                $result.Success = $false
            }
        }
        elseif ($CheckOnly) {
            Write-Warning "  [--] $subName : Not registered (check-only mode)"
            $result.FinalStatus = $status
            $result.ActionTaken = "check_only"
            $result.Success = $true
        }
        else {
            Write-Info "  [->] $subName : Registering..."
            if (Register-Provider -SubscriptionId $subId) {
                if (Wait-ForRegistration -SubscriptionId $subId) {
                    Write-Success "    [OK] Successfully registered"
                    $result.FinalStatus = "Registered"
                    $result.ActionTaken = "registered"
                    $result.Success = $true
                }
                else {
                    Write-Error "    [X] Registration timed out"
                    $result.FinalStatus = Get-ProviderStatus -SubscriptionId $subId
                    $result.ActionTaken = "registered"
                    $result.Success = $false
                }
            }
            else {
                $result.FinalStatus = $status
                $result.ActionTaken = "failed"
                $result.Success = $false
            }
        }
    }
    catch {
        Write-Error "  [X] $subName : Error - $($_.Exception.Message)"
        $result.Error = $_.Exception.Message
        $result.Success = $false
    }
    
    return $result
}

function Show-Summary {
    param(
        [array]$Results
    )
    
    Write-Host ""
    Write-Header "======================================================================"
    Write-Header "                              SUMMARY                                 "
    Write-Header "======================================================================"
    Write-Host ""
    
    $total = $Results.Count
    $registered = ($Results | Where-Object { $_.FinalStatus -eq 'Registered' }).Count
    $failed = ($Results | Where-Object { -not $_.Success }).Count
    $alreadyRegistered = ($Results | Where-Object { $_.ActionTaken -eq 'none' }).Count
    $newlyRegistered = ($Results | Where-Object { $_.ActionTaken -eq 'registered' -and $_.Success }).Count
    
    Write-Host "Total subscriptions processed: $total"
    Write-Success "  [OK] Registered: $registered"
    Write-Info "    - Already registered: $alreadyRegistered"
    Write-Info "    - Newly registered: $newlyRegistered"
    if ($failed -gt 0) {
        Write-Error "  [X] Failed: $failed"
    }
    
    Write-Host ""
    Write-Host ("-" * 70)
    Write-Host ("{0,-40} {1,-15} {2,-15}" -f "Subscription", "Status", "Action")
    Write-Host ("-" * 70)
    
    foreach ($r in $Results) {
        $name = if ($r.SubscriptionName.Length -gt 38) { $r.SubscriptionName.Substring(0, 38) + ".." } else { $r.SubscriptionName }
        $status = if ($r.FinalStatus) { $r.FinalStatus } else { "Error" }
        $action = if ($r.ActionTaken) { $r.ActionTaken } else { "error" }
        
        if ($r.Success) {
            Write-Host ("{0,-40} {1,-15} {2,-15}" -f $name, $status, $action)
        }
        else {
            Write-Error ("{0,-40} {1,-15} {2,-15}" -f $name, $status, $action)
        }
    }
    
    Write-Host ("-" * 70)
}

# Main script execution
Write-Host ""
Write-Header "======================================================================"
Write-Header "        Azure Resource Provider Registration Script (PowerShell)      "
Write-Header "        Provider: $ProviderNamespace                                  "
Write-Header "======================================================================"
Write-Host ""

# Check if connected to Azure
$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Warning "Not connected to Azure. Please run Connect-AzAccount first."
    Write-Host ""
    Write-Info "Example:"
    Write-Host "  Connect-AzAccount -TenantId '<your-tenant-id>'"
    Write-Host ""
    exit 1
}

Write-Info "Connected as: $($context.Account.Id)"
Write-Info "Current Tenant: $($context.Tenant.Id)"
Write-Host ""

# Get subscriptions
Write-Info "Discovering subscriptions..."

if ($SubscriptionIds) {
    $subscriptions = @()
    foreach ($subId in $SubscriptionIds) {
        try {
            $sub = Get-AzSubscription -SubscriptionId $subId -ErrorAction Stop
            $subscriptions += $sub
        }
        catch {
            Write-Warning "Could not find subscription: $subId"
        }
    }
    Write-Info "Processing $($subscriptions.Count) specified subscription(s)"
}
else {
    if ($TenantId) {
        $subscriptions = Get-AzSubscription -TenantId $TenantId -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' }
    }
    else {
        $subscriptions = Get-AzSubscription -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' }
    }
    
    if (-not $subscriptions -or $subscriptions.Count -eq 0) {
        Write-Warning "No accessible subscriptions found."
        if ($TenantId) {
            Write-Warning "Make sure you have access to subscriptions in tenant: $TenantId"
        }
        exit 1
    }
    
    Write-Success "Found $($subscriptions.Count) subscription(s)"
}

# Process each subscription
Write-Host ""
Write-Info "Processing subscriptions..."
Write-Host ""

$results = @()
foreach ($subscription in $subscriptions) {
    $result = Process-Subscription -Subscription $subscription -CheckOnly $CheckOnly.IsPresent
    $results += $result
}

# Show summary
Show-Summary -Results $results

# Exit with appropriate code
$failedCount = ($results | Where-Object { -not $_.Success }).Count
if ($failedCount -gt 0) {
    exit 1
}
exit 0
```

### Usage Examples

#### In Azure Cloud Shell (PowerShell)

```powershell
# 1. You're already authenticated! Verify your tenant:
(Get-AzContext).Tenant.Id

# 2. If you need to switch tenants:
Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"

# 3. Create the script file (copy-paste the script above)
code Register-ManagedServices.ps1

# 4. Run the script
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

---

## Step 1: Create Security Group and Log Analytics Workspace

> ⚠️ **IMPORTANT**: This script must be run in the **MANAGING TENANT** (Atevet12), not the source tenant. This is where you create the security group and Log Analytics workspace that will receive logs from the source tenant.

This PowerShell script automates the preparation of the managing tenant by:
1. Creating a security group for delegated access
2. Creating a resource group for centralized logging
3. Creating a Log Analytics workspace
4. Outputting all required IDs for the Azure Lighthouse deployment

### Script: `Prepare-ManagingTenant.ps1`

```powershell
<#
.SYNOPSIS
    Prepares the managing tenant for Azure cross-tenant log collection.

.DESCRIPTION
    This script is used as Step 1 in the Azure Cross-Tenant Log Collection setup.
    It creates the necessary resources in the managing tenant (Atevet12):
    - Security group for delegated access
    - Resource group for centralized logging
    - Log Analytics workspace to receive logs
    
    The script outputs all required IDs needed for the Azure Lighthouse deployment.

.PARAMETER TenantId
    The Azure tenant ID (GUID) of the managing tenant.

.PARAMETER SubscriptionId
    The subscription ID where the Log Analytics workspace will be created.

.PARAMETER SecurityGroupName
    Name of the security group to create. Default: "Lighthouse-CrossTenant-Admins"

.PARAMETER SecurityGroupDescription
    Description for the security group. Default: "Users with delegated access to customer tenants"

.PARAMETER ResourceGroupName
    Name of the resource group to create. Default: "rg-central-logging"

.PARAMETER WorkspaceName
    Name of the Log Analytics workspace. Default: "law-central-logging"

.PARAMETER Location
    Azure region for resources. Default: "westus2"

.PARAMETER SkipGroupCreation
    Skip security group creation if it already exists.

.PARAMETER SkipWorkspaceCreation
    Skip workspace creation if it already exists.

.PARAMETER GroupMembers
    Array of user principal names (UPNs) or object IDs to add to the security group.
    Example: @("user1@domain.com", "user2@domain.com")

.EXAMPLE
    .\Prepare-ManagingTenant.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"

.EXAMPLE
    .\Prepare-ManagingTenant.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" -SecurityGroupName "Lighthouse-Atevet17-Admins" -WorkspaceName "law-central-atevet12"

.EXAMPLE
    .\Prepare-ManagingTenant.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" -GroupMembers @("admin@contoso.com", "analyst@contoso.com")

.NOTES
    Author: Cross-Tenant Log Collection Guide
    Requires: Az.Accounts, Az.Resources, Az.OperationalInsights, Microsoft.Graph modules
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$SecurityGroupName = "Lighthouse-CrossTenant-Admins",

    [Parameter(Mandatory = $false)]
    [string]$SecurityGroupDescription = "Users with delegated access to customer tenants",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "rg-central-logging",

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceName = "law-central-logging",

    [Parameter(Mandatory = $false)]
    [string]$Location = "westus2",

    [Parameter(Mandatory = $false)]
    [switch]$SkipGroupCreation,

    [Parameter(Mandatory = $false)]
    [switch]$SkipWorkspaceCreation,

    [Parameter(Mandatory = $false)]
    [string[]]$GroupMembers = @()
)

# Color functions for output
function Write-Success { param($Message) Write-Host $Message -ForegroundColor Green }
function Write-ErrorMsg { param($Message) Write-Host $Message -ForegroundColor Red }
function Write-Warning { param($Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Info { param($Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Header { param($Message) Write-Host $Message -ForegroundColor Cyan -BackgroundColor DarkBlue }

# Results object to store all IDs
$results = @{
    TenantId = $TenantId
    SubscriptionId = $SubscriptionId
    SecurityGroupId = $null
    SecurityGroupName = $SecurityGroupName
    ResourceGroupName = $ResourceGroupName
    WorkspaceName = $WorkspaceName
    WorkspaceId = $null
    WorkspaceResourceId = $null
    WorkspaceCustomerId = $null
    Location = $Location
    GroupMembersAdded = @()
    GroupMembersFailed = @()
    Success = $true
    Errors = @()
}

# Main script execution
Write-Host ""
Write-Header "======================================================================"
Write-Header "        Prepare Managing Tenant for Cross-Tenant Log Collection       "
Write-Header "======================================================================"
Write-Host ""

#region Check Azure Connection
Write-Info "Checking Azure connection..."

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Warning "Not connected to Azure. Attempting to connect..."
    try {
        Connect-AzAccount -TenantId $TenantId -ErrorAction Stop | Out-Null
        $context = Get-AzContext
    }
    catch {
        Write-ErrorMsg "Failed to connect to Azure: $($_.Exception.Message)"
        Write-Host ""
        Write-Info "Please run: Connect-AzAccount -TenantId '$TenantId'"
        exit 1
    }
}

# Verify we're in the correct tenant
if ($context.Tenant.Id -ne $TenantId) {
    Write-Warning "Currently connected to tenant: $($context.Tenant.Id)"
    Write-Warning "Switching to tenant: $TenantId"
    try {
        Connect-AzAccount -TenantId $TenantId -ErrorAction Stop | Out-Null
        $context = Get-AzContext
    }
    catch {
        Write-ErrorMsg "Failed to switch tenant: $($_.Exception.Message)"
        exit 1
    }
}

Write-Success "Connected as: $($context.Account.Id)"
Write-Success "Tenant: $($context.Tenant.Id)"
Write-Host ""
#endregion

#region Set Subscription Context
Write-Info "Setting subscription context..."
try {
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Success "Subscription: $SubscriptionId"
}
catch {
    Write-ErrorMsg "Failed to set subscription context: $($_.Exception.Message)"
    $results.Success = $false
    $results.Errors += "Failed to set subscription: $($_.Exception.Message)"
    exit 1
}
Write-Host ""
#endregion

#region Create Security Group
if (-not $SkipGroupCreation) {
    Write-Info "Creating security group: $SecurityGroupName"
    Write-Info "  (This requires Microsoft Graph permissions)"
    Write-Host ""
    
    # Check if Microsoft.Graph module is available
    $graphModule = Get-Module -ListAvailable Microsoft.Graph.Groups -ErrorAction SilentlyContinue
    
    if ($graphModule) {
        try {
            # Connect to Microsoft Graph
            Write-Info "Connecting to Microsoft Graph..."
            Connect-MgGraph -TenantId $TenantId -Scopes "Group.ReadWrite.All" -NoWelcome -ErrorAction Stop
            
            # Check if group already exists
            $existingGroup = Get-MgGroup -Filter "displayName eq '$SecurityGroupName'" -ErrorAction SilentlyContinue
            
            if ($existingGroup) {
                Write-Warning "Security group '$SecurityGroupName' already exists"
                $results.SecurityGroupId = $existingGroup.Id
                Write-Success "  Group ID: $($existingGroup.Id)"
            }
            else {
                # Create the security group
                $groupParams = @{
                    DisplayName = $SecurityGroupName
                    Description = $SecurityGroupDescription
                    MailEnabled = $false
                    SecurityEnabled = $true
                    MailNickname = ($SecurityGroupName -replace '[^a-zA-Z0-9]', '').ToLower()
                }
                
                $newGroup = New-MgGroup @groupParams -ErrorAction Stop
                $results.SecurityGroupId = $newGroup.Id
                Write-Success "  Created security group successfully"
                Write-Success "  Group ID: $($newGroup.Id)"
            }
        }
        catch {
            Write-ErrorMsg "Failed to create security group: $($_.Exception.Message)"
            Write-Warning "You may need to create the security group manually via Azure Portal:"
            Write-Warning "  1. Go to Azure Active Directory > Groups > New group"
            Write-Warning "  2. Group type: Security"
            Write-Warning "  3. Group name: $SecurityGroupName"
            Write-Warning "  4. Note the Object ID after creation"
            $results.Errors += "Security group creation failed: $($_.Exception.Message)"
        }
    }
    else {
        Write-Warning "Microsoft.Graph module not installed."
        Write-Warning "To install: Install-Module Microsoft.Graph -Scope CurrentUser"
        Write-Host ""
        Write-Warning "Alternative: Create the security group manually via Azure Portal:"
        Write-Warning "  1. Go to Azure Active Directory > Groups > New group"
        Write-Warning "  2. Group type: Security"
        Write-Warning "  3. Group name: $SecurityGroupName"
        Write-Warning "  4. Description: $SecurityGroupDescription"
        Write-Warning "  5. Note the Object ID after creation"
        
        # Try using Az module as fallback
        Write-Host ""
        Write-Info "Attempting to use Az module to create group..."
        try {
            $existingGroup = Get-AzADGroup -DisplayName $SecurityGroupName -ErrorAction SilentlyContinue
            
            if ($existingGroup) {
                Write-Warning "Security group '$SecurityGroupName' already exists"
                $results.SecurityGroupId = $existingGroup.Id
                Write-Success "  Group ID: $($existingGroup.Id)"
            }
            else {
                $newGroup = New-AzADGroup -DisplayName $SecurityGroupName `
                    -Description $SecurityGroupDescription `
                    -MailNickname ($SecurityGroupName -replace '[^a-zA-Z0-9]', '').ToLower() `
                    -SecurityEnabled `
                    -ErrorAction Stop
                
                $results.SecurityGroupId = $newGroup.Id
                Write-Success "  Created security group successfully"
                Write-Success "  Group ID: $($newGroup.Id)"
            }
        }
        catch {
            Write-ErrorMsg "Failed to create security group with Az module: $($_.Exception.Message)"
            $results.Errors += "Security group creation failed: $($_.Exception.Message)"
        }
    }
}
else {
    Write-Info "Skipping security group creation (--SkipGroupCreation specified)"
    Write-Warning "You will need to provide the security group Object ID manually"
}
Write-Host ""
#endregion

#region Add Members to Security Group
if ($GroupMembers.Count -gt 0 -and $results.SecurityGroupId) {
    Write-Info "Adding members to security group..."
    Write-Host ""
    
    foreach ($member in $GroupMembers) {
        try {
            # Try to resolve the user (could be UPN or Object ID)
            $user = $null
            
            # Check if it's a GUID (Object ID)
            if ($member -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                # It's an Object ID
                if ($graphModule) {
                    $user = Get-MgUser -UserId $member -ErrorAction SilentlyContinue
                }
                else {
                    $user = Get-AzADUser -ObjectId $member -ErrorAction SilentlyContinue
                }
            }
            else {
                # It's a UPN
                if ($graphModule) {
                    $user = Get-MgUser -UserId $member -ErrorAction SilentlyContinue
                }
                else {
                    $user = Get-AzADUser -UserPrincipalName $member -ErrorAction SilentlyContinue
                }
            }
            
            if (-not $user) {
                Write-ErrorMsg "  [X] User not found: $member"
                $results.GroupMembersFailed += $member
                continue
            }
            
            $userId = if ($graphModule) { $user.Id } else { $user.Id }
            
            # Check if user is already a member
            $isMember = $false
            if ($graphModule) {
                $existingMembers = Get-MgGroupMember -GroupId $results.SecurityGroupId -ErrorAction SilentlyContinue
                $isMember = $existingMembers.Id -contains $userId
            }
            else {
                $existingMembers = Get-AzADGroupMember -GroupObjectId $results.SecurityGroupId -ErrorAction SilentlyContinue
                $isMember = $existingMembers.Id -contains $userId
            }
            
            if ($isMember) {
                Write-Warning "  [~] Already a member: $member"
                $results.GroupMembersAdded += $member
                continue
            }
            
            # Add user to group
            if ($graphModule) {
                $memberRef = @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId"
                }
                New-MgGroupMemberByRef -GroupId $results.SecurityGroupId -BodyParameter $memberRef -ErrorAction Stop
            }
            else {
                Add-AzADGroupMember -TargetGroupObjectId $results.SecurityGroupId -MemberObjectId $userId -ErrorAction Stop
            }
            
            Write-Success "  [+] Added: $member"
            $results.GroupMembersAdded += $member
        }
        catch {
            Write-ErrorMsg "  [X] Failed to add $member : $($_.Exception.Message)"
            $results.GroupMembersFailed += $member
            $results.Errors += "Failed to add member $member : $($_.Exception.Message)"
        }
    }
    Write-Host ""
}
elseif ($GroupMembers.Count -gt 0 -and -not $results.SecurityGroupId) {
    Write-Warning "Cannot add members: Security group ID not available"
    Write-Warning "Create the group first or provide the group Object ID"
}
#endregion

#region Create Resource Group
if (-not $SkipWorkspaceCreation) {
    Write-Info "Creating resource group: $ResourceGroupName"
    
    try {
        $existingRg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($existingRg) {
            Write-Warning "Resource group '$ResourceGroupName' already exists in $($existingRg.Location)"
            $results.Location = $existingRg.Location
        }
        else {
            $newRg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop
            Write-Success "  Created resource group in $Location"
        }
    }
    catch {
        Write-ErrorMsg "Failed to create resource group: $($_.Exception.Message)"
        $results.Success = $false
        $results.Errors += "Resource group creation failed: $($_.Exception.Message)"
    }
}
Write-Host ""
#endregion

#region Create Log Analytics Workspace
if (-not $SkipWorkspaceCreation) {
    Write-Info "Creating Log Analytics workspace: $WorkspaceName"
    
    try {
        $existingWorkspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction SilentlyContinue
        
        if ($existingWorkspace) {
            Write-Warning "Log Analytics workspace '$WorkspaceName' already exists"
            $workspace = $existingWorkspace
        }
        else {
            $workspace = New-AzOperationalInsightsWorkspace `
                -ResourceGroupName $ResourceGroupName `
                -Name $WorkspaceName `
                -Location $results.Location `
                -Sku "PerGB2018" `
                -ErrorAction Stop
            
            Write-Success "  Created Log Analytics workspace"
        }
        
        $results.WorkspaceId = $workspace.ResourceId
        $results.WorkspaceResourceId = $workspace.ResourceId
        $results.WorkspaceCustomerId = $workspace.CustomerId
        
        Write-Success "  Workspace Resource ID: $($workspace.ResourceId)"
        Write-Success "  Workspace Customer ID: $($workspace.CustomerId)"
    }
    catch {
        Write-ErrorMsg "Failed to create Log Analytics workspace: $($_.Exception.Message)"
        $results.Success = $false
        $results.Errors += "Workspace creation failed: $($_.Exception.Message)"
    }
}
else {
    Write-Info "Skipping workspace creation (--SkipWorkspaceCreation specified)"
    
    # Try to get existing workspace
    try {
        $existingWorkspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction SilentlyContinue
        if ($existingWorkspace) {
            $results.WorkspaceId = $existingWorkspace.ResourceId
            $results.WorkspaceResourceId = $existingWorkspace.ResourceId
            $results.WorkspaceCustomerId = $existingWorkspace.CustomerId
            Write-Success "Found existing workspace: $WorkspaceName"
        }
    }
    catch {
        Write-Warning "Could not find existing workspace"
    }
}
Write-Host ""
#endregion

#region Output Summary
Write-Host ""
Write-Header "======================================================================"
Write-Header "                              SUMMARY                                 "
Write-Header "======================================================================"
Write-Host ""

if ($results.Success -and $results.Errors.Count -eq 0) {
    Write-Success "All resources created successfully!"
}
elseif ($results.Errors.Count -gt 0) {
    Write-Warning "Completed with some issues:"
    foreach ($error in $results.Errors) {
        Write-ErrorMsg "  - $error"
    }
}
Write-Host ""

Write-Info "=== Required IDs for Azure Lighthouse Deployment ==="
Write-Host ""
Write-Host "Managing Tenant ID:        $($results.TenantId)"
Write-Host "Subscription ID:           $($results.SubscriptionId)"
if ($results.SecurityGroupId) {
    Write-Host "Security Group Object ID:  $($results.SecurityGroupId)"
}
else {
    Write-Warning "Security Group Object ID:  <CREATE MANUALLY AND NOTE THE ID>"
}
Write-Host "Resource Group Name:       $($results.ResourceGroupName)"
Write-Host "Workspace Name:            $($results.WorkspaceName)"
if ($results.WorkspaceResourceId) {
    Write-Host "Workspace Resource ID:     $($results.WorkspaceResourceId)"
}
Write-Host "Location:                  $($results.Location)"
Write-Host ""

if ($results.GroupMembersAdded.Count -gt 0) {
    Write-Info "Group Members Added:"
    foreach ($member in $results.GroupMembersAdded) {
        Write-Success "  - $member"
    }
    Write-Host ""
}

if ($results.GroupMembersFailed.Count -gt 0) {
    Write-Warning "Group Members Failed:"
    foreach ($member in $results.GroupMembersFailed) {
        Write-ErrorMsg "  - $member"
    }
    Write-Host ""
}

# Output as JSON for easy copying
Write-Info "=== JSON Output (for automation) ==="
Write-Host ""
$jsonOutput = @{
    managingTenantId = $results.TenantId
    subscriptionId = $results.SubscriptionId
    securityGroupObjectId = $results.SecurityGroupId
    resourceGroupName = $results.ResourceGroupName
    workspaceName = $results.WorkspaceName
    workspaceResourceId = $results.WorkspaceResourceId
    workspaceCustomerId = $results.WorkspaceCustomerId
    location = $results.Location
    groupMembersAdded = $results.GroupMembersAdded
    groupMembersFailed = $results.GroupMembersFailed
} | ConvertTo-Json -Depth 2

Write-Host $jsonOutput
Write-Host ""

# Output the Lighthouse parameters template
Write-Info "=== Lighthouse Parameters Template ==="
Write-Host ""
Write-Host @"
Update your lighthouse-parameters-definition.json with these values:

{
  "managedByTenantId": {
    "value": "$($results.TenantId)"
  },
  "authorizations": {
    "value": [
      {
        "principalId": "$($results.SecurityGroupId)",
        "roleDefinitionId": "acdd72a7-3385-48ef-bd42-f606fba81ae7",
        "principalIdDisplayName": "$SecurityGroupName"
      },
      {
        "principalId": "$($results.SecurityGroupId)",
        "roleDefinitionId": "b24988ac-6180-42a0-ab88-20f7382dd24c",
        "principalIdDisplayName": "$SecurityGroupName"
      },
      {
        "principalId": "$($results.SecurityGroupId)",
        "roleDefinitionId": "43d0d8ad-25c7-4714-9337-8ba259a9fe05",
        "principalIdDisplayName": "$SecurityGroupName"
      },
      {
        "principalId": "$($results.SecurityGroupId)",
        "roleDefinitionId": "73c42c96-874c-492b-b04d-ab87d138a893",
        "principalIdDisplayName": "$SecurityGroupName"
      }
    ]
  }
}
"@
Write-Host ""

Write-Info "=== Next Steps ==="
Write-Host ""
Write-Host "1. Add users to the security group '$SecurityGroupName'"
Write-Host "2. Update the Lighthouse parameters file with the values above"
Write-Host "3. Run the Azure Lighthouse deployment in the SOURCE tenant"
Write-Host "4. Configure diagnostic settings to send logs to the workspace"
Write-Host ""
#endregion

# Return results object
return $results
```

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

---

## Step 2: Deploy Azure Lighthouse

> ⚠️ **IMPORTANT**: This script must be run in the **SOURCE/CUSTOMER TENANT** (Atevet17). Azure Lighthouse delegation is deployed FROM the customer tenant TO grant access to the managing tenant.

This PowerShell script automates the Azure Lighthouse onboarding process by:
1. Creating and deploying the Registration Definition
2. Creating and deploying the Registration Assignment
3. Supporting multi-subscription deployments
4. Verifying the delegation was successful

### Prerequisites

Before running this script, you need:
- **Managing Tenant ID** (Atevet12) - from Step 1
- **Security Group Object ID** (Atevet12) - from Step 1
- **Owner role** on the source subscription(s) in Atevet17
- **Microsoft.ManagedServices** resource provider registered (Step 0)

### Script: `Deploy-AzureLighthouse.ps1`

```powershell
<#
.SYNOPSIS
    Deploys Azure Lighthouse delegation from customer tenant to managing tenant.

.DESCRIPTION
    This script is used as Step 2 in the Azure Cross-Tenant Log Collection setup.
    It deploys Azure Lighthouse registration definitions and assignments to delegate
    access from the source tenant (Atevet17) to the managing tenant (Atevet12).
    
    The script:
    - Creates ARM template files for registration definition and assignment
    - Deploys the registration definition
    - Deploys the registration assignment
    - Supports multi-subscription deployments
    - Verifies the delegation was successful

.PARAMETER ManagingTenantId
    The Azure tenant ID (GUID) of the managing tenant (Atevet12).

.PARAMETER SecurityGroupObjectId
    The Object ID of the security group in the managing tenant that will have delegated access.

.PARAMETER SecurityGroupDisplayName
    Display name for the security group. Default: "Lighthouse-CrossTenant-Admins"

.PARAMETER SubscriptionIds
    Array of subscription IDs in the source tenant to delegate. If not provided, uses current subscription.

.PARAMETER RegistrationDefinitionName
    Name for the Lighthouse registration definition. Default: "Cross-Tenant Log Collection Delegation"

.PARAMETER Location
    Azure region for the deployment. Default: "westus2"

.PARAMETER IncludeContributorRole
    Include Contributor role in the delegation. Default: $true

.PARAMETER IncludeResourcePolicyContributorRole
    Include Resource Policy Contributor role in the delegation. Required for Azure Policy assignments. Default: $true

.PARAMETER IncludeUserAccessAdministratorRole
    Include User Access Administrator role in the delegation. Required for assigning roles to managed identities
    created by Azure Policy. This is added as an eligible authorization requiring PIM activation. Default: $true

.PARAMETER SkipVerification
    Skip the verification step after deployment.

.EXAMPLE
    .\Deploy-AzureLighthouse.ps1 -ManagingTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SecurityGroupObjectId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"

.EXAMPLE
    .\Deploy-AzureLighthouse.ps1 -ManagingTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SecurityGroupObjectId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" -SubscriptionIds @("sub-id-1", "sub-id-2")

.NOTES
    Author: Cross-Tenant Log Collection Guide
    Requires: Az.Accounts, Az.Resources modules
    Must be run in the SOURCE/CUSTOMER tenant (Atevet17)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManagingTenantId,

    [Parameter(Mandatory = $true)]
    [string]$SecurityGroupObjectId,

    [Parameter(Mandatory = $false)]
    [string]$SecurityGroupDisplayName = "Lighthouse-CrossTenant-Admins",

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$RegistrationDefinitionName = "Cross-Tenant Log Collection Delegation",

    [Parameter(Mandatory = $false)]
    [string]$Location = "westus2",

    [Parameter(Mandatory = $false)]
    [bool]$IncludeContributorRole = $true,

    [Parameter(Mandatory = $false)]
    [bool]$IncludeResourcePolicyContributorRole = $true,

    [Parameter(Mandatory = $false)]
    [bool]$IncludeUserAccessAdministratorRole = $true,

    [Parameter(Mandatory = $false)]
    [switch]$SkipVerification
)

# Color functions for output
function Write-Success { param($Message) Write-Host $Message -ForegroundColor Green }
function Write-ErrorMsg { param($Message) Write-Host $Message -ForegroundColor Red }
function Write-Warning { param($Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Info { param($Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Header { param($Message) Write-Host $Message -ForegroundColor Cyan -BackgroundColor DarkBlue }

# Role Definition IDs
$roleDefinitions = @{
    "Reader" = "acdd72a7-3385-48ef-bd42-f606fba81ae7"
    "Contributor" = "b24988ac-6180-42a0-ab88-20f7382dd24c"
    "MonitoringReader" = "43d0d8ad-25c7-4714-9337-8ba259a9fe05"
    "LogAnalyticsReader" = "73c42c96-874c-492b-b04d-ab87d138a893"
    "MonitoringContributor" = "749f88d5-cbae-40b8-bcfc-e573ddc772fa"
    "ResourcePolicyContributor" = "36243c78-bf99-498c-9df9-86d9f8d28608"
    "UserAccessAdministrator" = "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"
}

# Results tracking
$results = @{
    ManagingTenantId = $ManagingTenantId
    SecurityGroupObjectId = $SecurityGroupObjectId
    SubscriptionsProcessed = @()
    SubscriptionsSucceeded = @()
    SubscriptionsFailed = @()
    DefinitionIds = @{}
    Errors = @()
}

# Main script execution
Write-Host ""
Write-Header "======================================================================"
Write-Header "        Deploy Azure Lighthouse - Cross-Tenant Delegation             "
Write-Header "======================================================================"
Write-Host ""

#region Check Azure Connection
Write-Info "Checking Azure connection..."

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-ErrorMsg "Not connected to Azure. Please connect first."
    Write-Host ""
    Write-Info "Run: Connect-AzAccount -TenantId '<SOURCE-TENANT-ID>'"
    exit 1
}

Write-Success "Connected as: $($context.Account.Id)"
Write-Success "Current Tenant: $($context.Tenant.Id)"
Write-Host ""

# Verify we're NOT in the managing tenant
if ($context.Tenant.Id -eq $ManagingTenantId) {
    Write-ErrorMsg "ERROR: You are connected to the MANAGING tenant ($ManagingTenantId)"
    Write-ErrorMsg "This script must be run from the SOURCE/CUSTOMER tenant!"
    Write-Host ""
    Write-Info "Please run: Connect-AzAccount -TenantId '<SOURCE-TENANT-ID>'"
    exit 1
}

Write-Success "Confirmed: Running in source tenant (not managing tenant)"
Write-Host ""
#endregion

#region Get Subscriptions
if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
    # Use current subscription
    $SubscriptionIds = @($context.Subscription.Id)
    Write-Info "No subscriptions specified. Using current subscription: $($context.Subscription.Name)"
}

Write-Info "Subscriptions to delegate: $($SubscriptionIds.Count)"
foreach ($subId in $SubscriptionIds) {
    Write-Host "  - $subId"
}
Write-Host ""
#endregion

#region Build Authorizations Array
Write-Info "Building authorization roles..."

$authorizations = @(
    @{
        principalId = $SecurityGroupObjectId
        roleDefinitionId = $roleDefinitions["Reader"]
        principalIdDisplayName = $SecurityGroupDisplayName
    },
    @{
        principalId = $SecurityGroupObjectId
        roleDefinitionId = $roleDefinitions["MonitoringReader"]
        principalIdDisplayName = $SecurityGroupDisplayName
    },
    @{
        principalId = $SecurityGroupObjectId
        roleDefinitionId = $roleDefinitions["LogAnalyticsReader"]
        principalIdDisplayName = $SecurityGroupDisplayName
    }
)

if ($IncludeContributorRole) {
    $authorizations += @{
        principalId = $SecurityGroupObjectId
        roleDefinitionId = $roleDefinitions["Contributor"]
        principalIdDisplayName = $SecurityGroupDisplayName
    }
    Write-Success "  Including Contributor role (for configuring diagnostic settings)"
}

if ($IncludeResourcePolicyContributorRole) {
    $authorizations += @{
        principalId = $SecurityGroupObjectId
        roleDefinitionId = $roleDefinitions["ResourcePolicyContributor"]
        principalIdDisplayName = $SecurityGroupDisplayName
    }
    Write-Success "  Including Resource Policy Contributor role (for Azure Policy assignments)"
}

if ($IncludeUserAccessAdministratorRole) {
    $authorizations += @{
        principalId = $SecurityGroupObjectId
        roleDefinitionId = $roleDefinitions["UserAccessAdministrator"]
        principalIdDisplayName = $SecurityGroupDisplayName
        # Note: For production, consider using delegatedRoleDefinitionIds to limit which roles can be assigned
        # delegatedRoleDefinitionIds = @($roleDefinitions["Contributor"], $roleDefinitions["MonitoringContributor"])
    }
    Write-Success "  Including User Access Administrator role (for assigning roles to policy managed identities)"
    Write-WarningMsg "  ⚠ User Access Administrator is a privileged role - ensure this is required for your scenario"
}

$rolesList = "Reader, Monitoring Reader, Log Analytics Reader"
if ($IncludeContributorRole) { $rolesList += ", Contributor" }
if ($IncludeResourcePolicyContributorRole) { $rolesList += ", Resource Policy Contributor" }
if ($IncludeUserAccessAdministratorRole) { $rolesList += ", User Access Administrator" }
Write-Success "  Roles configured: $rolesList"
Write-Host ""
#endregion

#region Create ARM Templates
Write-Info "Creating ARM templates..."

# Registration Definition Template
$definitionTemplate = @{
    '$schema' = "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters = @{
        managedByTenantId = @{
            type = "string"
            metadata = @{
                description = "Tenant ID of the managing tenant (Atevet12)"
            }
        }
        registrationDefinitionName = @{
            type = "string"
            metadata = @{
                description = "Display name of the Lighthouse registration definition"
            }
        }
        authorizations = @{
            type = "array"
            metadata = @{
                description = "Array of authorization objects"
            }
        }
    }
    variables = @{
        definitionGuid = "[guid(concat(parameters('managedByTenantId'), '-', parameters('registrationDefinitionName')))]"
    }
    resources = @(
        @{
            type = "Microsoft.ManagedServices/registrationDefinitions"
            apiVersion = "2022-10-01"
            name = "[variables('definitionGuid')]"
            properties = @{
                registrationDefinitionName = "[parameters('registrationDefinitionName')]"
                description = "Delegates access for cross-tenant log collection"
                managedByTenantId = "[parameters('managedByTenantId')]"
                authorizations = "[parameters('authorizations')]"
            }
        }
    )
    outputs = @{
        registrationDefinitionId = @{
            type = "string"
            value = "[resourceId('Microsoft.ManagedServices/registrationDefinitions', variables('definitionGuid'))]"
        }
        definitionGuid = @{
            type = "string"
            value = "[variables('definitionGuid')]"
        }
    }
}

# Registration Assignment Template
$assignmentTemplate = @{
    '$schema' = "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters = @{
        registrationDefinitionId = @{
            type = "string"
            metadata = @{
                description = "Full resource ID of the registration definition"
            }
        }
        registrationAssignmentName = @{
            type = "string"
            defaultValue = "[newGuid()]"
            metadata = @{
                description = "Name (GUID) for the registration assignment"
            }
        }
    }
    resources = @(
        @{
            type = "Microsoft.ManagedServices/registrationAssignments"
            apiVersion = "2022-10-01"
            name = "[parameters('registrationAssignmentName')]"
            properties = @{
                registrationDefinitionId = "[parameters('registrationDefinitionId')]"
            }
        }
    )
    outputs = @{
        registrationAssignmentId = @{
            type = "string"
            value = "[resourceId('Microsoft.ManagedServices/registrationAssignments', parameters('registrationAssignmentName'))]"
        }
    }
}

# Save templates to temp files
$tempDir = [System.IO.Path]::GetTempPath()
$definitionTemplatePath = Join-Path $tempDir "lighthouse-definition-template.json"
$assignmentTemplatePath = Join-Path $tempDir "lighthouse-assignment-template.json"

$definitionTemplate | ConvertTo-Json -Depth 20 | Set-Content -Path $definitionTemplatePath -Encoding UTF8
$assignmentTemplate | ConvertTo-Json -Depth 20 | Set-Content -Path $assignmentTemplatePath -Encoding UTF8

Write-Success "  Templates created in temp directory"
Write-Host ""
#endregion

#region Deploy to Each Subscription
Write-Info "Deploying Azure Lighthouse to subscriptions..."
Write-Host ""

foreach ($subId in $SubscriptionIds) {
    $results.SubscriptionsProcessed += $subId
    
    Write-Info "Processing subscription: $subId"
    
    try {
        # Set context to this subscription
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
        $subName = (Get-AzContext).Subscription.Name
        Write-Host "  Subscription name: $subName"
        
        # Check if Microsoft.ManagedServices is registered
        $provider = Get-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices" -ErrorAction SilentlyContinue
        $providerState = ($provider | Select-Object -First 1).RegistrationState
        
        if ($providerState -ne "Registered") {
            Write-Warning "  Microsoft.ManagedServices not registered. Registering..."
            Register-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices" | Out-Null
            
            # Wait for registration
            $timeout = 120
            $elapsed = 0
            do {
                Start-Sleep -Seconds 5
                $elapsed += 5
                $provider = Get-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"
                $providerState = ($provider | Select-Object -First 1).RegistrationState
            } while ($providerState -eq "Registering" -and $elapsed -lt $timeout)
            
            if ($providerState -ne "Registered") {
                throw "Failed to register Microsoft.ManagedServices provider"
            }
            Write-Success "  Provider registered successfully"
        }
        
        # Deploy Registration Definition
        Write-Host "  Deploying registration definition..."
        $defDeploymentName = "LighthouseDefinition-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        
        $defDeployment = New-AzSubscriptionDeployment `
            -Name $defDeploymentName `
            -Location $Location `
            -TemplateFile $definitionTemplatePath `
            -managedByTenantId $ManagingTenantId `
            -registrationDefinitionName $RegistrationDefinitionName `
            -authorizations $authorizations `
            -ErrorAction Stop
        
        $registrationDefinitionId = $defDeployment.Outputs.registrationDefinitionId.Value
        $results.DefinitionIds[$subId] = $registrationDefinitionId
        
        Write-Success "  Definition deployed: $registrationDefinitionId"
        
        # Deploy Registration Assignment
        Write-Host "  Deploying registration assignment..."
        $assignDeploymentName = "LighthouseAssignment-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        
        $assignDeployment = New-AzSubscriptionDeployment `
            -Name $assignDeploymentName `
            -Location $Location `
            -TemplateFile $assignmentTemplatePath `
            -registrationDefinitionId $registrationDefinitionId `
            -ErrorAction Stop
        
        Write-Success "  Assignment deployed successfully"
        Write-Success "  ✓ Delegation complete for $subName"
        
        $results.SubscriptionsSucceeded += $subId
    }
    catch {
        Write-ErrorMsg "  ✗ Failed: $($_.Exception.Message)"
        $results.SubscriptionsFailed += $subId
        $results.Errors += "Subscription $subId : $($_.Exception.Message)"
    }
    
    Write-Host ""
}
#endregion

#region Verify Delegation
if (-not $SkipVerification -and $results.SubscriptionsSucceeded.Count -gt 0) {
    Write-Info "Verifying delegations..."
    Write-Host ""
    
    foreach ($subId in $results.SubscriptionsSucceeded) {
        try {
            Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
            
            $definitions = Get-AzManagedServicesDefinition -ErrorAction SilentlyContinue
            $assignments = Get-AzManagedServicesAssignment -ErrorAction SilentlyContinue
            
            $matchingDef = $definitions | Where-Object {
                $_.Properties.ManagedByTenantId -eq $ManagingTenantId
            }
            
            if ($matchingDef) {
                Write-Success "  ✓ Verified: $subId"
            }
            else {
                Write-Warning "  ⚠ Definition found but tenant ID mismatch: $subId"
            }
        }
        catch {
            Write-Warning "  ⚠ Could not verify: $subId"
        }
    }
    Write-Host ""
}
#endregion

#region Cleanup Temp Files
Remove-Item -Path $definitionTemplatePath -Force -ErrorAction SilentlyContinue
Remove-Item -Path $assignmentTemplatePath -Force -ErrorAction SilentlyContinue
#endregion

#region Output Summary
Write-Host ""
Write-Header "======================================================================"
Write-Header "                              SUMMARY                                 "
Write-Header "======================================================================"
Write-Host ""

Write-Host "Managing Tenant ID:        $ManagingTenantId"
Write-Host "Security Group Object ID:  $SecurityGroupObjectId"
Write-Host ""

Write-Host "Subscriptions Processed:   $($results.SubscriptionsProcessed.Count)"
Write-Success "  Succeeded: $($results.SubscriptionsSucceeded.Count)"
if ($results.SubscriptionsFailed.Count -gt 0) {
    Write-ErrorMsg "  Failed: $($results.SubscriptionsFailed.Count)"
}
Write-Host ""

if ($results.SubscriptionsSucceeded.Count -gt 0) {
    Write-Info "Successfully Delegated Subscriptions:"
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

Write-Info "=== Next Steps ==="
Write-Host ""
Write-Host "1. In the MANAGING tenant (Atevet12), verify delegation:"
Write-Host "   - Go to Azure Portal > 'My customers'"
Write-Host "   - Or run: Get-AzManagedServicesAssignment"
Write-Host ""
Write-Host "2. Configure diagnostic settings to send logs to Atevet12 workspace"
Write-Host "3. Set up Activity Log collection (Step 3)"
Write-Host "4. Configure resource diagnostic logs (Step 4)"
Write-Host ""

# Output as JSON for automation
Write-Info "=== JSON Output (for automation) ==="
Write-Host ""
$jsonOutput = @{
    managingTenantId = $results.ManagingTenantId
    securityGroupObjectId = $results.SecurityGroupObjectId
    subscriptionsSucceeded = $results.SubscriptionsSucceeded
    subscriptionsFailed = $results.SubscriptionsFailed
    registrationDefinitionIds = $results.DefinitionIds
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

### Troubleshooting

#### Running in Wrong Tenant

**Error:** `ERROR: You are connected to the MANAGING tenant`

**Solution:**
```powershell
# Disconnect and reconnect to the SOURCE tenant
Disconnect-AzAccount
Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"
```

#### Microsoft.ManagedServices Not Registered

**Error:** `The subscription is not registered to use namespace 'Microsoft.ManagedServices'`

**Solution:**
The script automatically registers the provider, but if it fails:
```powershell
# Manually register the provider
Register-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"

# Wait for registration
Get-AzResourceProvider -ProviderNamespace "Microsoft.ManagedServices"
```

#### Permission Denied

**Error:** `The client does not have authorization to perform action`

**Solution:**
- You need **Owner** role on the subscription to deploy Lighthouse
- Contact your subscription administrator to grant Owner access

#### Delegation Already Exists

**Error:** `A registration assignment with the same name already exists`

**Solution:**
```powershell
# Remove existing delegation first
$assignments = Get-AzManagedServicesAssignment
$assignments | Remove-AzManagedServicesAssignment

# Then re-run the deployment
```

### Verify Delegation in Managing Tenant

After deployment, verify the delegation from the **managing tenant** (Atevet12):

```powershell
# Connect to managing tenant
Connect-AzAccount -TenantId "<ATEVET12-TENANT-ID>"

# List delegated subscriptions
Get-AzManagedServicesAssignment

# Or via Azure Portal:
# Go to "My customers" to see delegated subscriptions
```

### Role Definitions Reference

| Role | Role Definition ID | Purpose |
|------|-------------------|---------|
| **Reader** | `acdd72a7-3385-48ef-bd42-f606fba81ae7` | Read access to resources |
| **Contributor** | `b24988ac-6180-42a0-ab88-20f7382dd24c` | Configure diagnostic settings |
| **Monitoring Reader** | `43d0d8ad-25c7-4714-9337-8ba259a9fe05` | Read monitoring data |
| **Log Analytics Reader** | `73c42c96-874c-492b-b04d-ab87d138a893` | Query Log Analytics |
| **Resource Policy Contributor** | `36243c78-bf99-498c-9df9-86d9f8d28608` | Create Azure Policy assignments |
| **User Access Administrator** | `18d7d88d-d35e-4fb5-a5c3-7773c20a72d9` | Assign roles to policy managed identities |

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
| **AMA Windows** | `ca817e41-e85a-4783-bc7f-dc532d36235e` | Deploy Azure Monitor Agent on Windows VMs |
| **AMA Linux** | `a4034bc6-ae50-406d-bf76-50f4ee5a7811` | Deploy Azure Monitor Agent on Linux VMs |
| **DCR Windows** | `eab1f514-22e3-42e3-9a1f-e1dc9199355c` | Associate Windows VMs with DCR |
| **DCR Linux** | `58e891b9-ce13-4ac3-86e4-ac3e1f20cb07` | Associate Linux VMs with DCR |

### Prerequisites

Before running this script, you need:
- **Azure Lighthouse delegation** completed (Step 2)
- **Log Analytics Workspace Resource ID** (from Step 1)
- **Delegated subscription IDs** (from the source tenant)
- **Contributor** role on the delegated subscriptions
- **Resource Policy Contributor** role (if deploying Azure Policy with `-DeployPolicy`)

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
    Resource group where the DCR will be created. Default: Same as workspace resource group.

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
    [string]$ResourceGroupName,

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
    [switch]$AssignRolesAsSourceAdmin
)

# Color functions for output
function Write-Success { param($Message) Write-Host $Message -ForegroundColor Green }
function Write-ErrorMsg { param($Message) Write-Host $Message -ForegroundColor Red }
function Write-WarningMsg { param($Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Info { param($Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Header { param($Message) Write-Host $Message -ForegroundColor Cyan -BackgroundColor DarkBlue }

# Built-in Azure Policy Definition IDs for Azure Monitor Agent
$PolicyDefinitions = @{
    "AMA-Windows" = @{
        Id = "/providers/Microsoft.Authorization/policyDefinitions/ca817e41-e85a-4783-bc7f-dc532d36235e"
        DisplayName = "Configure Windows virtual machines to run Azure Monitor Agent"
    }
    "AMA-Linux" = @{
        Id = "/providers/Microsoft.Authorization/policyDefinitions/a4034bc6-ae50-406d-bf76-50f4ee5a7811"
        DisplayName = "Configure Linux virtual machines to run Azure Monitor Agent"
    }
    "DCR-Windows" = @{
        Id = "/providers/Microsoft.Authorization/policyDefinitions/eab1f514-22e3-42e3-9a1f-e1dc9199355c"
        DisplayName = "Configure Windows VMs to be associated with a Data Collection Rule"
    }
    "DCR-Linux" = @{
        Id = "/providers/Microsoft.Authorization/policyDefinitions/58e891b9-ce13-4ac3-86e4-ac3e1f20cb07"
        DisplayName = "Configure Linux VMs to be associated with a Data Collection Rule"
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
            
            # Discover policy assignments with managed identities
            Write-Host "  Discovering policy assignments with managed identities..."
            
            $policyAssignments = Get-AzPolicyAssignment -Scope $scope -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$PolicyAssignmentPrefix*" -and $_.Identity -and $_.Identity.PrincipalId }
            
            if (-not $policyAssignments -or $policyAssignments.Count -eq 0) {
                Write-WarningMsg "  No policy assignments found with prefix '$PolicyAssignmentPrefix'"
                Write-Host "  Looking for all policy assignments with managed identities..."
                
                $policyAssignments = Get-AzPolicyAssignment -Scope $scope -ErrorAction SilentlyContinue |
                    Where-Object { $_.Identity -and $_.Identity.PrincipalId }
            }
            
            if (-not $policyAssignments -or $policyAssignments.Count -eq 0) {
                Write-WarningMsg "  No policy assignments with managed identities found in this subscription."
                continue
            }
            
            Write-Success "  Found $($policyAssignments.Count) policy assignment(s) with managed identities"
            Write-Host ""
            
            foreach ($assignment in $policyAssignments) {
                $principalId = $assignment.Identity.PrincipalId
                $displayName = $assignment.Properties.DisplayName
                $assignmentId = $assignment.PolicyAssignmentId
                if (-not $assignmentId) {
                    $assignmentId = $assignment.ResourceId
                }
                if (-not $assignmentId) {
                    $assignmentId = "/subscriptions/$subId/providers/Microsoft.Authorization/policyAssignments/$($assignment.Name)"
                }
                
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
                if ($assignment.Name -like "*DCR*" -and $DataCollectionRuleName) {
                    # Try to find the DCR
                    $dcr = Get-AzDataCollectionRule -Name $DataCollectionRuleName -ErrorAction SilentlyContinue | Select-Object -First 1
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
                    $remediationName = "remediate-$($found.Name)-$(Get-Date -Format 'yyyyMMddHHmmss')"
                    
                    Write-Host "  Creating remediation: $remediationName"
                    
                    try {
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
                        Write-WarningMsg "    ⚠ Could not create remediation: $($_.Exception.Message)"
                        $adminResults.Errors += "Remediation for $($found.Name): $($_.Exception.Message)"
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

# Use workspace resource group if not specified
if (-not $ResourceGroupName) {
    $ResourceGroupName = $workspaceResourceGroup
}

Write-Success "  Workspace Name: $workspaceName"
Write-Success "  Resource Group: $workspaceResourceGroup"
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
    
    # Switch to workspace subscription to create DCR
    Set-AzContext -SubscriptionId $workspaceSubscriptionId -ErrorAction Stop | Out-Null
    
    # Check if DCR already exists
    $existingDCR = Get-AzDataCollectionRule -Name $DataCollectionRuleName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    
    if ($existingDCR) {
        Write-WarningMsg "  Data Collection Rule '$DataCollectionRuleName' already exists"
        $results.DataCollectionRuleId = $existingDCR.Id
    }
    else {
        Write-Host "  Creating new Data Collection Rule..."
        
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
                -ResourceGroupName $ResourceGroupName `
                -TemplateFile $dcrTemplatePath `
                -ErrorAction Stop
            
            $results.DataCollectionRuleId = $dcrDeployment.Outputs.dataCollectionRuleId.Value
            Write-Success "  ✓ Data Collection Rule created successfully"
        }
        catch {
            Write-ErrorMsg "  ✗ Failed to create DCR: $($_.Exception.Message)"
            $results.Errors += "DCR creation failed: $($_.Exception.Message)"
        }
        finally {
            Remove-Item -Path $dcrTemplatePath -Force -ErrorAction SilentlyContinue
        }
    }
}
else {
    Write-Info "Skipping DCR creation (--SkipDCRCreation specified)"
    
    # Try to get existing DCR
    Set-AzContext -SubscriptionId $workspaceSubscriptionId -ErrorAction Stop | Out-Null
    $existingDCR = Get-AzDataCollectionRule -Name $DataCollectionRuleName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($existingDCR) {
        $results.DataCollectionRuleId = $existingDCR.Id
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
                    $results.VMsSkipped += @{
                        Id = $vm.Id
                        Name = $vm.Name
                        PowerState = $powerState
                        Reason = "VM not running"
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
            
            foreach ($policyKey in $PolicyDefinitions.Keys) {
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
                Write-WarningMsg "    ⚠ Could not create remediation: $($_.Exception.Message)"
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
        Write-Info "Note: Azure Policy has been deployed to automatically install the agent"
        Write-Info "      when these VMs come back online."
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
$jsonOutput = @{
    dataCollectionRuleName = $results.DataCollectionRuleName
    dataCollectionRuleId = $results.DataCollectionRuleId
    subscriptionsProcessed = $results.SubscriptionsProcessed
    vmsConfiguredCount = $results.VMsConfigured.Count
    vmsSkippedCount = $results.VMsSkipped.Count
    vmsFailedCount = $results.VMsFailed.Count
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

```powershell
<#
.SYNOPSIS
    Configures diagnostic settings for Azure resources to send logs to a centralized Log Analytics workspace.

.DESCRIPTION
    This script is used as Step 5 in the Azure Cross-Tenant Log Collection setup.
    It configures diagnostic settings on Azure PaaS resources in delegated subscriptions to send
    all logs to a centralized Log Analytics workspace using the 'allLogs' category group.
    
    The script:
    - Discovers resources that support diagnostic settings
    - Creates diagnostic settings using 'allLogs' category group for comprehensive coverage
    - Supports filtering by resource type
    - Handles Storage Account sub-services (blob, queue, table, file)
    - Optionally deploys Azure Policy for automatic coverage of new resources
    - Verifies the configuration after deployment

.PARAMETER WorkspaceResourceId
    The full resource ID of the Log Analytics workspace to send logs to.
    Example: /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>

.PARAMETER SubscriptionIds
    Array of subscription IDs to configure. If not provided, uses current subscription.

.PARAMETER DiagnosticSettingName
    Name for the diagnostic setting. Default: "SendToLogAnalytics"

.PARAMETER ResourceTypes
    Array of resource types to configure. If not provided, configures all supported types.
    Example: @("Microsoft.KeyVault/vaults", "Microsoft.Storage/storageAccounts")

.PARAMETER DeployPolicy
    Deploy Azure Policy for automatic diagnostic settings on new resources. Default: $false

.PARAMETER SkipVerification
    Skip the verification step after deployment.

.EXAMPLE
    .\Configure-ResourceDiagnosticLogs.ps1 -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

.EXAMPLE
    .\Configure-ResourceDiagnosticLogs.ps1 -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" -ResourceTypes @("Microsoft.KeyVault/vaults", "Microsoft.Storage/storageAccounts")

.EXAMPLE
    .\Configure-ResourceDiagnosticLogs.ps1 -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" -DeployPolicy $true

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
    [string]$DiagnosticSettingName = "SendToLogAnalytics",

    [Parameter(Mandatory = $false)]
    [string[]]$ResourceTypes,

    [Parameter(Mandatory = $false)]
    [bool]$DeployPolicy = $false,

    [Parameter(Mandatory = $false)]
    [switch]$SkipVerification
)

#region Helper Functions
function Write-Success { param($Message) Write-Host $Message -ForegroundColor Green }
function Write-ErrorMsg { param($Message) Write-Host $Message -ForegroundColor Red }
function Write-WarningMsg { param($Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Info { param($Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Header { param($Message) Write-Host $Message -ForegroundColor Cyan -BackgroundColor DarkBlue }
#endregion

#region Supported Resource Types
# Resource types that support diagnostic settings with allLogs category group
$SupportedResourceTypes = @(
    "Microsoft.KeyVault/vaults",
    "Microsoft.Storage/storageAccounts",
    "Microsoft.Web/sites",
    "Microsoft.Sql/servers/databases",
    "Microsoft.Network/networkSecurityGroups",
    "Microsoft.ContainerService/managedClusters",
    "Microsoft.DocumentDB/databaseAccounts",
    "Microsoft.EventHub/namespaces",
    "Microsoft.ServiceBus/namespaces",
    "Microsoft.Network/applicationGateways",
    "Microsoft.Network/azureFirewalls",
    "Microsoft.ApiManagement/service",
    "Microsoft.Logic/workflows",
    "Microsoft.ContainerRegistry/registries",
    "Microsoft.Cache/redis",
    "Microsoft.DataFactory/factories",
    "Microsoft.CognitiveServices/accounts"
)
#endregion

#region Results Tracking
$results = @{
    WorkspaceResourceId = $WorkspaceResourceId
    DiagnosticSettingName = $DiagnosticSettingName
    SubscriptionsProcessed = @()
    ResourcesConfigured = @()
    ResourcesFailed = @()
    PolicyAssignmentsCreated = @()
    Errors = @()
}
#endregion

#region ARM Template for Diagnostic Settings
# This ARM template is used for resources that require ARM deployment
# It uses categoryGroup: "allLogs" for comprehensive log collection
$DiagnosticSettingsTemplate = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "resourceId": {
            "type": "string",
            "metadata": {
                "description": "Resource ID of the resource to configure"
            }
        },
        "settingName": {
            "type": "string",
            "metadata": {
                "description": "Name for the diagnostic setting"
            }
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
            "type": "Microsoft.Insights/diagnosticSettings",
            "apiVersion": "2021-05-01-preview",
            "scope": "[parameters('resourceId')]",
            "name": "[parameters('settingName')]",
            "properties": {
                "workspaceId": "[parameters('workspaceId')]",
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
}
'@
#endregion

#region Main Script Execution
Write-Host ""
Write-Header "======================================================================"
Write-Header "        Configure Azure Resource Diagnostic Logs - Step 5             "
Write-Header "======================================================================"
Write-Host ""

# Check Azure Connection
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

# Validate Workspace Resource ID
Write-Info "Validating workspace resource ID..."
if ($WorkspaceResourceId -notmatch "^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$") {
    Write-ErrorMsg "Invalid workspace resource ID format."
    Write-ErrorMsg "Expected: /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>"
    exit 1
}

$workspaceIdParts = $WorkspaceResourceId -split "/"
$workspaceSubscriptionId = $workspaceIdParts[2]
$workspaceResourceGroup = $workspaceIdParts[4]
$workspaceName = $workspaceIdParts[8]

Write-Success "  Workspace: $workspaceName"
Write-Success "  Resource Group: $workspaceResourceGroup"
Write-Host ""

# Get Subscriptions
if (-not $SubscriptionIds -or $SubscriptionIds.Count -eq 0) {
    $SubscriptionIds = @($context.Subscription.Id)
    Write-Info "Using current subscription: $($context.Subscription.Name)"
}
Write-Info "Subscriptions to configure: $($SubscriptionIds.Count)"
foreach ($subId in $SubscriptionIds) {
    Write-Host "  - $subId"
}
Write-Host ""

# Filter Resource Types
$targetResourceTypes = $SupportedResourceTypes
if ($ResourceTypes -and $ResourceTypes.Count -gt 0) {
    Write-Info "Filtering to specified resource types:"
    $targetResourceTypes = @()
    foreach ($rt in $ResourceTypes) {
        if ($SupportedResourceTypes -contains $rt) {
            $targetResourceTypes += $rt
            Write-Host "  ✓ $rt"
        }
        else {
            Write-WarningMsg "  ✗ $rt (not supported)"
        }
    }
}
else {
    Write-Info "Configuring all supported resource types ($($SupportedResourceTypes.Count) types)"
}
Write-Host ""
#endregion

#region Function: Configure Diagnostic Setting using REST API
function Set-DiagnosticSettingWithAllLogs {
    param(
        [string]$ResourceId,
        [string]$SettingName,
        [string]$WorkspaceId
    )
    
    try {
        # Build the diagnostic setting properties
        $diagnosticSetting = @{
            properties = @{
                workspaceId = $WorkspaceId
                logs = @(
                    @{
                        categoryGroup = "allLogs"
                        enabled = $true
                    }
                )
                metrics = @(
                    @{
                        category = "AllMetrics"
                        enabled = $true
                    }
                )
            }
        }
        
        # Use REST API to create the diagnostic setting
        $apiVersion = "2021-05-01-preview"
        $uri = "$ResourceId/providers/Microsoft.Insights/diagnosticSettings/${SettingName}?api-version=$apiVersion"
        
        $response = Invoke-AzRestMethod -Path $uri -Method PUT -Payload ($diagnosticSetting | ConvertTo-Json -Depth 10)
        
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            return @{ Success = $true; Message = "Configured successfully" }
        }
        else {
            $errorContent = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            $errorMessage = if ($errorContent.error.message) { $errorContent.error.message } else { "HTTP $($response.StatusCode)" }
            
            # If allLogs is not supported, try with audit category group
            if ($errorMessage -like "*categoryGroup*" -or $errorMessage -like "*allLogs*") {
                return Set-DiagnosticSettingWithAudit -ResourceId $ResourceId -SettingName $SettingName -WorkspaceId $WorkspaceId
            }
            
            return @{ Success = $false; Message = $errorMessage }
        }
    }
    catch {
        return @{ Success = $false; Message = $_.Exception.Message }
    }
}
#endregion

#region Function: Fallback to audit category group
function Set-DiagnosticSettingWithAudit {
    param(
        [string]$ResourceId,
        [string]$SettingName,
        [string]$WorkspaceId
    )
    
    try {
        $diagnosticSetting = @{
            properties = @{
                workspaceId = $WorkspaceId
                logs = @(
                    @{
                        categoryGroup = "audit"
                        enabled = $true
                    }
                )
                metrics = @(
                    @{
                        category = "AllMetrics"
                        enabled = $true
                    }
                )
            }
        }
        
        $apiVersion = "2021-05-01-preview"
        $uri = "$ResourceId/providers/Microsoft.Insights/diagnosticSettings/${SettingName}?api-version=$apiVersion"
        
        $response = Invoke-AzRestMethod -Path $uri -Method PUT -Payload ($diagnosticSetting | ConvertTo-Json -Depth 10)
        
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            return @{ Success = $true; Message = "Configured with audit category" }
        }
        else {
            $errorContent = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            $errorMessage = if ($errorContent.error.message) { $errorContent.error.message } else { "HTTP $($response.StatusCode)" }
            return @{ Success = $false; Message = $errorMessage }
        }
    }
    catch {
        return @{ Success = $false; Message = $_.Exception.Message }
    }
}
#endregion

#region Function: Configure Storage Account Services
function Set-StorageAccountDiagnostics {
    param(
        [object]$StorageAccount,
        [string]$SettingName,
        [string]$WorkspaceId
    )
    
    $storageResults = @()
    $services = @("blobServices", "queueServices", "tableServices", "fileServices")
    
    foreach ($service in $services) {
        $serviceResourceId = "$($StorageAccount.Id)/$service/default"
        
        Write-Host "      Configuring $service..."
        $result = Set-DiagnosticSettingWithAllLogs -ResourceId $serviceResourceId -SettingName $SettingName -WorkspaceId $WorkspaceId
        
        $storageResults += @{
            Service = $service
            ResourceId = $serviceResourceId
            Success = $result.Success
            Message = $result.Message
        }
    }
    
    return $storageResults
}
#endregion

#region Process Each Subscription
Write-Info "Processing subscriptions and configuring diagnostic settings..."
Write-Host ""

foreach ($subId in $SubscriptionIds) {
    $results.SubscriptionsProcessed += $subId
    
    Write-Info "Processing subscription: $subId"
    
    try {
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
        $subName = (Get-AzContext).Subscription.Name
        Write-Host "  Subscription name: $subName"
        Write-Host ""
        
        foreach ($resourceType in $targetResourceTypes) {
            Write-Host "  Discovering $resourceType..."
            
            $resources = @()
            
            # Get resources based on type
            switch ($resourceType) {
                "Microsoft.KeyVault/vaults" {
                    $resources = Get-AzKeyVault -ErrorAction SilentlyContinue | ForEach-Object {
                        Get-AzKeyVault -VaultName $_.VaultName -ErrorAction SilentlyContinue
                    }
                }
                "Microsoft.Storage/storageAccounts" {
                    $resources = Get-AzStorageAccount -ErrorAction SilentlyContinue
                }
                "Microsoft.Web/sites" {
                    $resources = Get-AzWebApp -ErrorAction SilentlyContinue
                }
                "Microsoft.Sql/servers/databases" {
                    $sqlServers = Get-AzSqlServer -ErrorAction SilentlyContinue
                    foreach ($server in $sqlServers) {
                        $dbs = Get-AzSqlDatabase -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName -ErrorAction SilentlyContinue
                        $resources += $dbs | Where-Object { $_.DatabaseName -ne "master" }
                    }
                }
                "Microsoft.Network/networkSecurityGroups" {
                    $resources = Get-AzNetworkSecurityGroup -ErrorAction SilentlyContinue
                }
                "Microsoft.ContainerService/managedClusters" {
                    $resources = Get-AzAksCluster -ErrorAction SilentlyContinue
                }
                default {
                    $resources = Get-AzResource -ResourceType $resourceType -ErrorAction SilentlyContinue
                }
            }
            
            if (-not $resources -or $resources.Count -eq 0) {
                Write-Host "    No resources found"
                Write-Host ""
                continue
            }
            
            Write-Host "    Found $($resources.Count) resource(s)"
            
            foreach ($resource in $resources) {
                $resourceId = $resource.ResourceId
                if (-not $resourceId) { $resourceId = $resource.Id }
                
                $resourceName = $resource.Name
                if (-not $resourceName) { $resourceName = $resource.VaultName }
                
                Write-Host "    Configuring: $resourceName"
                
                # Special handling for Storage Accounts (configure sub-services)
                if ($resourceType -eq "Microsoft.Storage/storageAccounts") {
                    $storageResults = Set-StorageAccountDiagnostics -StorageAccount $resource -SettingName $DiagnosticSettingName -WorkspaceId $WorkspaceResourceId
                    
                    foreach ($sr in $storageResults) {
                        if ($sr.Success) {
                            Write-Success "      ✓ $($sr.Service)"
                            $results.ResourcesConfigured += $sr.ResourceId
                        }
                        else {
                            Write-ErrorMsg "      ✗ $($sr.Service): $($sr.Message)"
                            $results.ResourcesFailed += $sr.ResourceId
                            $results.Errors += "$($sr.ResourceId): $($sr.Message)"
                        }
                    }
                }
                else {
                    # Configure diagnostic setting for the resource
                    $result = Set-DiagnosticSettingWithAllLogs -ResourceId $resourceId -SettingName $DiagnosticSettingName -WorkspaceId $WorkspaceResourceId
                    
                    if ($result.Success) {
                        Write-Success "      ✓ $($result.Message)"
                        $results.ResourcesConfigured += $resourceId
                    }
                    else {
                        Write-ErrorMsg "      ✗ $($result.Message)"
                        $results.ResourcesFailed += $resourceId
                        $results.Errors += "$resourceId : $($result.Message)"
                    }
                }
            }
            
            Write-Host ""
        }
    }
    catch {
        Write-ErrorMsg "  ✗ Failed to process subscription: $($_.Exception.Message)"
        $results.Errors += "Subscription $subId : $($_.Exception.Message)"
    }
    
    Write-Host ""
}
#endregion

#region Deploy Azure Policy (Optional)
if ($DeployPolicy) {
    Write-Host ""
    Write-Info "Deploying Azure Policy for automatic diagnostic settings..."
    Write-Host ""
    Write-Info "This ensures new resources automatically get diagnostic settings configured."
    Write-Host ""
    
    # Built-in policy definition for diagnostic settings
    $policyDefinitionId = "/providers/Microsoft.Authorization/policyDefinitions/752154a7-1e0f-45c6-a880-ac75a7e4f648"
    
    foreach ($subId in $SubscriptionIds) {
        Write-Host "  Deploying policy to subscription: $subId"
        
        try {
            Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
            
            $assignmentName = "diag-settings-to-law"
            $scope = "/subscriptions/$subId"
            
            # Check if assignment already exists
            $existingAssignment = Get-AzPolicyAssignment -Name $assignmentName -Scope $scope -ErrorAction SilentlyContinue
            
            if ($existingAssignment) {
                Write-WarningMsg "    Policy assignment already exists"
                $results.PolicyAssignmentsCreated += @{
                    SubscriptionId = $subId
                    AssignmentName = $assignmentName
                    Existing = $true
                }
            }
            else {
                # Create policy assignment
                $policyParams = @{
                    logAnalytics = $WorkspaceResourceId
                }
                
                New-AzPolicyAssignment `
                    -Name $assignmentName `
                    -DisplayName "Configure diagnostic settings to Log Analytics workspace" `
                    -PolicyDefinition (Get-AzPolicyDefinition -Id $policyDefinitionId) `
                    -Scope $scope `
                    -PolicyParameterObject $policyParams `
                    -Location "westus2" `
                    -IdentityType "SystemAssigned" `
                    -ErrorAction Stop | Out-Null
                
                Write-Success "    ✓ Policy assigned"
                $results.PolicyAssignmentsCreated += @{
                    SubscriptionId = $subId
                    AssignmentName = $assignmentName
                    Existing = $false
                }
            }
        }
        catch {
            Write-ErrorMsg "    ✗ Failed: $($_.Exception.Message)"
            $results.Errors += "Policy assignment in $subId : $($_.Exception.Message)"
        }
    }
    Write-Host ""
}
#endregion

#region Verification
if (-not $SkipVerification -and $results.ResourcesConfigured.Count -gt 0) {
    Write-Info "Verifying diagnostic settings configuration..."
    Write-Host ""
    
    $verifiedCount = 0
    $sampleResources = $results.ResourcesConfigured | Select-Object -First 5
    
    foreach ($resourceId in $sampleResources) {
        try {
            $apiVersion = "2021-05-01-preview"
            $uri = "$resourceId/providers/Microsoft.Insights/diagnosticSettings?api-version=$apiVersion"
            $response = Invoke-AzRestMethod -Path $uri -Method GET
            
            if ($response.StatusCode -eq 200) {
                $settings = ($response.Content | ConvertFrom-Json).value
                $ourSetting = $settings | Where-Object { $_.name -eq $DiagnosticSettingName }
                
                if ($ourSetting) {
                    $verifiedCount++
                    $resourceName = ($resourceId -split "/")[-1]
                    Write-Success "  ✓ Verified: $resourceName"
                }
            }
        }
        catch {
            Write-WarningMsg "  ⚠ Could not verify: $resourceId"
        }
    }
    
    Write-Host ""
    Write-Success "  Verified $verifiedCount of $($sampleResources.Count) sampled resources"
    Write-Host ""
}
#endregion

#region Output Summary
Write-Host ""
Write-Header "======================================================================"
Write-Header "                              SUMMARY                                 "
Write-Header "======================================================================"
Write-Host ""

Write-Host "Workspace:                 $workspaceName"
Write-Host "Diagnostic Setting Name:   $DiagnosticSettingName"
Write-Host ""

Write-Host "Subscriptions Processed:   $($results.SubscriptionsProcessed.Count)"
Write-Success "Resources Configured:      $($results.ResourcesConfigured.Count)"
if ($results.ResourcesFailed.Count -gt 0) {
    Write-ErrorMsg "Resources Failed:          $($results.ResourcesFailed.Count)"
}
if ($DeployPolicy) {
    Write-Host "Policy Assignments:        $($results.PolicyAssignmentsCreated.Count)"
}
Write-Host ""

if ($results.ResourcesConfigured.Count -gt 0) {
    Write-Success "Successfully configured resources:"
    $resourceSummary = $results.ResourcesConfigured | Group-Object { ($_ -split "/providers/")[1] -split "/" | Select-Object -First 2 | Join-String -Separator "/" }
    foreach ($group in $resourceSummary | Select-Object -First 10) {
        Write-Success "  $($group.Name): $($group.Count)"
    }
    Write-Host ""
}

if ($results.ResourcesFailed.Count -gt 0) {
    Write-WarningMsg "Failed resources (first 5):"
    foreach ($resource in $results.ResourcesFailed | Select-Object -First 5) {
        $resourceName = ($resource -split "/")[-1]
        Write-ErrorMsg "  ✗ $resourceName"
    }
    Write-Host ""
}

if ($results.Errors.Count -gt 0) {
    Write-WarningMsg "Errors encountered (first 5):"
    foreach ($err in $results.Errors | Select-Object -First 5) {
        Write-ErrorMsg "  - $err"
    }
    Write-Host ""
}

# JSON Output for automation
Write-Info "=== JSON Output (for automation) ==="
Write-Host ""
$jsonOutput = @{
    workspaceResourceId = $results.WorkspaceResourceId
    diagnosticSettingName = $results.DiagnosticSettingName
    subscriptionsProcessed = $results.SubscriptionsProcessed
    resourcesConfiguredCount = $results.ResourcesConfigured.Count
    resourcesFailedCount = $results.ResourcesFailed.Count
    policyAssignmentsCount = $results.PolicyAssignmentsCreated.Count
    errorsCount = $results.Errors.Count
} | ConvertTo-Json -Depth 2

Write-Host $jsonOutput
Write-Host ""

# Verification Queries
Write-Info "=== Verification Queries (Run in Log Analytics) ==="
Write-Host ""
Write-Host @"
// Key Vault audit events
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where TimeGenerated > ago(1h)
| summarize count() by OperationName
| order by count_ desc

// Storage account operations
StorageBlobLogs
| where TimeGenerated > ago(1h)
| summarize count() by OperationName
| order by count_ desc

// All resource diagnostic logs
AzureDiagnostics
| where TimeGenerated > ago(1h)
| summarize count() by ResourceProvider, Category
| order by count_ desc
"@
Write-Host ""

Write-Info "=== Next Steps ==="
Write-Host ""
Write-Host "1. Wait 5-15 minutes for logs to start flowing"
Write-Host "2. Run the verification queries in Log Analytics"
Write-Host "3. Configure Microsoft Sentinel analytics rules"
Write-Host "4. Set up workbooks for cross-tenant visibility"
Write-Host ""
#endregion

# Return results object
return $results
```

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

#### With Azure Policy for New Resources

```powershell
# Configure existing resources AND deploy policy for new resources
.\Configure-ResourceDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -DeployPolicy $true
```

#### Custom Diagnostic Setting Name

```powershell
# Use a custom name for the diagnostic setting
.\Configure-ResourceDiagnosticLogs.ps1 `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -DiagnosticSettingName "CrossTenantLogs"
```

### ARM Template: Diagnostic Settings (Alternative Deployment)

For organizations that prefer ARM template deployments, here is a reusable template that can be deployed via Azure Portal, CLI, or PowerShell:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "resourceId": {
            "type": "string",
            "metadata": {
                "description": "Full resource ID of the resource to configure diagnostic settings for"
            }
        },
        "diagnosticSettingName": {
            "type": "string",
            "defaultValue": "SendToLogAnalytics",
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
        "enableAllLogs": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable all log categories using categoryGroup"
            }
        },
        "enableMetrics": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Enable all metrics"
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
                "logs": [
                    {
                        "categoryGroup": "allLogs",
                        "enabled": "[parameters('enableAllLogs')]"
                    }
                ],
                "metrics": [
                    {
                        "category": "AllMetrics",
                        "enabled": "[parameters('enableMetrics')]"
                    }
                ]
            }
        }
    ],
    "outputs": {
        "diagnosticSettingId": {
            "type": "string",
            "value": "[extensionResourceId(parameters('resourceId'), 'Microsoft.Insights/diagnosticSettings', parameters('diagnosticSettingName'))]"
        }
    }
}
```

#### Deploy ARM Template via Azure CLI

```bash
# Deploy diagnostic settings for a Key Vault
az deployment group create \
    --resource-group "rg-source-resources" \
    --template-file "diagnostic-settings-template.json" \
    --parameters \
        resourceId="/subscriptions/<SUB-ID>/resourceGroups/rg-source-resources/providers/Microsoft.KeyVault/vaults/kv-source" \
        diagnosticSettingName="SendToLogAnalytics" \
        workspaceResourceId="/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
```

#### Deploy ARM Template via PowerShell

```powershell
# Deploy diagnostic settings for a Key Vault
New-AzResourceGroupDeployment `
    -ResourceGroupName "rg-source-resources" `
    -TemplateFile "diagnostic-settings-template.json" `
    -resourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-source-resources/providers/Microsoft.KeyVault/vaults/kv-source" `
    -diagnosticSettingName "SendToLogAnalytics" `
    -workspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"
```

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

### Next Steps

After completing Step 5:
- **Step 6**: Configure Microsoft Sentinel analytics rules for cross-tenant detection
- **Step 7**: Set up workbooks and dashboards for unified visibility
- **Step 8**: Implement alerting and incident response workflows

## Additional Resources

- [Main Guide: Azure Cross-Tenant Log Collection](azure-cross-tenant-log-collection-guide.md)
- [Azure PowerShell Documentation](https://docs.microsoft.com/en-us/powershell/azure/)
- [Az.Resources Module](https://docs.microsoft.com/en-us/powershell/module/az.resources/)
- [Azure Cloud Shell](https://docs.microsoft.com/en-us/azure/cloud-shell/overview)

---