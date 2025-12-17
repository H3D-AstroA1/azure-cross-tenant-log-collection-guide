# Azure Cross-Tenant Log Collection - Execution Scripts

This document contains PowerShell scripts for automating the Azure cross-tenant log collection setup process. These scripts complement the main guide ([azure-cross-tenant-log-collection-guide.md](azure-cross-tenant-log-collection-guide.md)).

---

## Table of Contents

1. [Important: Where to Run These Scripts](#important-where-to-run-these-scripts)
2. [Prerequisites](#prerequisites)
3. [Step 0: Register Resource Providers](#step-0-register-resource-providers)
4. [Step 1: Create Security Group and Log Analytics Workspace](#step-1-create-security-group-and-log-analytics-workspace)
5. [Step 2: Deploy Azure Lighthouse](#step-2-deploy-azure-lighthouse)

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

.EXAMPLE
    .\Prepare-ManagingTenant.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"

.EXAMPLE
    .\Prepare-ManagingTenant.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" -SecurityGroupName "Lighthouse-Atevet17-Admins" -WorkspaceName "law-central-atevet12"

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
    [switch]$SkipWorkspaceCreation
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

=== JSON Output (for automation) ===

{
  "managingTenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "subscriptionId": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy",
  "securityGroupObjectId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
  ...
}

=== Lighthouse Parameters Template ===

Update your lighthouse-parameters-definition.json with these values:
...

=== Next Steps ===

1. Add users to the security group 'Lighthouse-CrossTenant-Admins'
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

*Coming soon: PowerShell scripts for deploying Azure Lighthouse registration definitions and assignments.*

---

## Additional Resources

- [Main Guide: Azure Cross-Tenant Log Collection](azure-cross-tenant-log-collection-guide.md)
- [Azure PowerShell Documentation](https://docs.microsoft.com/en-us/powershell/azure/)
- [Az.Resources Module](https://docs.microsoft.com/en-us/powershell/module/az.resources/)
- [Azure Cloud Shell](https://docs.microsoft.com/en-us/azure/cloud-shell/overview)