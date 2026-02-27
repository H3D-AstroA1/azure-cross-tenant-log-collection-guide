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