<#
.SYNOPSIS
    Verifies Microsoft 365 audit log collection configuration and subscription status.

.DESCRIPTION
    This script verifies the M365 audit log collection setup by:
    - Retrieving credentials from Key Vault
    - Checking active subscriptions for each configured source tenant
    - Optionally testing log retrieval from the Office 365 Management API

.PARAMETER KeyVaultName
    The name of the Key Vault containing M365 collector credentials.

.PARAMETER SourceTenantId
    Optional. Specific source tenant ID to verify. If not provided, verifies all configured tenants.

.PARAMETER TestLogRetrieval
    If specified, attempts to retrieve recent audit logs to verify the full pipeline.

.PARAMETER HoursToCheck
    Number of hours to look back when testing log retrieval. Default: 1

.EXAMPLE
    .\Verify-M365AuditLogCollection.ps1 -KeyVaultName "kv-central-atevet12"

.EXAMPLE
    .\Verify-M365AuditLogCollection.ps1 -KeyVaultName "kv-central-atevet12" -SourceTenantId "<TENANT-ID>"

.EXAMPLE
    .\Verify-M365AuditLogCollection.ps1 -KeyVaultName "kv-central-atevet12" -TestLogRetrieval -HoursToCheck 24

.NOTES
    Author: Cross-Tenant Log Collection Guide
    Requires: Az.Accounts, Az.KeyVault modules
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$KeyVaultName,

    [Parameter()]
    [string]$SourceTenantId,

    [Parameter()]
    [switch]$TestLogRetrieval,

    [Parameter()]
    [int]$HoursToCheck = 1
)

#region Helper Functions
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    $colors = @{
        Info    = "Cyan"
        Success = "Green"
        Warning = "Yellow"
        Error   = "Red"
    }
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message" -ForegroundColor $colors[$Level]
}

function Get-M365Token {
    param(
        [string]$TenantId,
        [string]$AppId,
        [string]$AppSecret
    )
    
    try {
        $tokenResponse = Invoke-RestMethod `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/token" `
            -Method POST `
            -Body @{
                grant_type    = "client_credentials"
                client_id     = $AppId
                client_secret = $AppSecret
                resource      = "https://manage.office.com"
            } `
            -ErrorAction Stop
        
        return $tokenResponse.access_token
    }
    catch {
        Write-Log "Failed to get token for tenant $TenantId : $($_.Exception.Message)" -Level Error
        return $null
    }
}
#endregion

#region Main Script
Write-Log "========================================" -Level Info
Write-Log "Verify M365 Audit Log Collection" -Level Info
Write-Log "========================================" -Level Info
Write-Log ""

# Check Azure connection
$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Log "Not connected to Azure. Connecting..." -Level Warning
    Connect-AzAccount -ErrorAction Stop | Out-Null
    $context = Get-AzContext
}
Write-Log "Connected as: $($context.Account.Id)" -Level Success
Write-Log ""

# Retrieve credentials from Key Vault
Write-Log "Retrieving credentials from Key Vault: $KeyVaultName" -Level Info

try {
    $appId = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-AppId" -AsPlainText -ErrorAction Stop
    Write-Log "  App ID: $appId" -Level Success
}
catch {
    Write-Log "Failed to retrieve App ID from Key Vault: $($_.Exception.Message)" -Level Error
    exit 1
}

try {
    $appSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Secret" -AsPlainText -ErrorAction Stop
    Write-Log "  App Secret: ********" -Level Success
}
catch {
    Write-Log "Failed to retrieve App Secret from Key Vault: $($_.Exception.Message)" -Level Error
    exit 1
}

try {
    $tenantsJson = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Tenants" -AsPlainText -ErrorAction Stop
    $tenantsConfig = $tenantsJson | ConvertFrom-Json
    Write-Log "  Configured tenants: $($tenantsConfig.tenants.Count)" -Level Success
}
catch {
    Write-Log "Failed to retrieve tenants list from Key Vault: $($_.Exception.Message)" -Level Error
    exit 1
}

Write-Log ""

# Filter tenants if specific tenant ID provided
$tenantsToVerify = $tenantsConfig.tenants
if ($SourceTenantId) {
    $tenantsToVerify = $tenantsConfig.tenants | Where-Object { $_.tenantId -eq $SourceTenantId }
    if (-not $tenantsToVerify) {
        Write-Log "Tenant $SourceTenantId not found in configured tenants" -Level Error
        exit 1
    }
}

# Content types to check
$contentTypes = @(
    "Audit.AzureActiveDirectory",
    "Audit.Exchange",
    "Audit.SharePoint",
    "Audit.General",
    "DLP.All"
)

# Results tracking
$results = @{
    TenantsChecked     = 0
    TenantsSuccessful  = 0
    TenantsFailed      = 0
    SubscriptionsActive = 0
    LogsRetrieved      = 0
}

# Verify each tenant
foreach ($tenant in $tenantsToVerify) {
    Write-Log "========================================" -Level Info
    Write-Log "Verifying tenant: $($tenant.name) ($($tenant.tenantId))" -Level Info
    Write-Log "  Added: $($tenant.addedDate)" -Level Info
    Write-Log ""
    
    $results.TenantsChecked++
    
    # Get OAuth token
    $token = Get-M365Token -TenantId $tenant.tenantId -AppId $appId -AppSecret $appSecret
    if (-not $token) {
        $results.TenantsFailed++
        continue
    }
    Write-Log "  OAuth token acquired" -Level Success
    
    $headers = @{ "Authorization" = "Bearer $token" }
    
    # List active subscriptions
    Write-Log ""
    Write-Log "  Checking subscriptions:" -Level Info
    
    try {
        $subscriptions = Invoke-RestMethod `
            -Uri "https://manage.office.com/api/v1.0/$($tenant.tenantId)/activity/feed/subscriptions/list" `
            -Headers $headers `
            -ErrorAction Stop
        
        if ($subscriptions) {
            foreach ($sub in $subscriptions) {
                $statusColor = if ($sub.status -eq "enabled") { "Success" } else { "Warning" }
                Write-Log "    $($sub.contentType): $($sub.status)" -Level $statusColor
                if ($sub.status -eq "enabled") {
                    $results.SubscriptionsActive++
                }
            }
        }
        else {
            Write-Log "    No subscriptions found" -Level Warning
        }
    }
    catch {
        Write-Log "    Failed to list subscriptions: $($_.Exception.Message)" -Level Error
    }
    
    # Test log retrieval if requested
    if ($TestLogRetrieval) {
        Write-Log ""
        Write-Log "  Testing log retrieval (last $HoursToCheck hour(s)):" -Level Info
        
        $endTime = [DateTime]::UtcNow
        $startTime = $endTime.AddHours(-$HoursToCheck)
        $startTimeStr = $startTime.ToString("yyyy-MM-ddTHH:mm:ss")
        $endTimeStr = $endTime.ToString("yyyy-MM-ddTHH:mm:ss")
        
        foreach ($contentType in $contentTypes) {
            try {
                $contentUri = "https://manage.office.com/api/v1.0/$($tenant.tenantId)/activity/feed/subscriptions/content?contentType=$contentType&startTime=$startTimeStr&endTime=$endTimeStr"
                $contentList = Invoke-RestMethod -Uri $contentUri -Headers $headers -ErrorAction Stop
                
                $logCount = 0
                if ($contentList) {
                    foreach ($content in $contentList) {
                        try {
                            $logs = Invoke-RestMethod -Uri $content.contentUri -Headers $headers -ErrorAction Stop
                            if ($logs) {
                                $logCount += $logs.Count
                            }
                        }
                        catch {
                            # Content blob may have expired
                        }
                    }
                }
                
                $results.LogsRetrieved += $logCount
                if ($logCount -gt 0) {
                    Write-Log "    $contentType : $logCount log(s)" -Level Success
                }
                else {
                    Write-Log "    $contentType : No logs" -Level Info
                }
            }
            catch {
                if ($_.Exception.Message -like "*subscription*not*found*" -or $_.Exception.Message -like "*not enabled*") {
                    Write-Log "    $contentType : Not subscribed" -Level Warning
                }
                else {
                    Write-Log "    $contentType : Error - $($_.Exception.Message)" -Level Warning
                }
            }
        }
    }
    
    $results.TenantsSuccessful++
    Write-Log ""
}

# Summary
Write-Log "========================================" -Level Info
Write-Log "VERIFICATION SUMMARY" -Level Info
Write-Log "========================================" -Level Info
Write-Log ""
Write-Log "Tenants Checked:      $($results.TenantsChecked)" -Level Info
Write-Log "Tenants Successful:   $($results.TenantsSuccessful)" -Level $(if ($results.TenantsSuccessful -eq $results.TenantsChecked) { "Success" } else { "Warning" })
Write-Log "Tenants Failed:       $($results.TenantsFailed)" -Level $(if ($results.TenantsFailed -eq 0) { "Success" } else { "Error" })
Write-Log "Active Subscriptions: $($results.SubscriptionsActive)" -Level Info

if ($TestLogRetrieval) {
    Write-Log "Logs Retrieved:       $($results.LogsRetrieved)" -Level $(if ($results.LogsRetrieved -gt 0) { "Success" } else { "Warning" })
}

Write-Log ""

if ($results.TenantsFailed -gt 0) {
    Write-Log "Some tenants failed verification. Check the errors above." -Level Warning
}
elseif ($results.SubscriptionsActive -eq 0) {
    Write-Log "No active subscriptions found. Run Configure-M365AuditLogCollection.ps1 to set up subscriptions." -Level Warning
}
else {
    Write-Log "All configured tenants verified successfully!" -Level Success
}

Write-Log ""
Write-Log "To check logs in Log Analytics, run this KQL query:" -Level Info
Write-Log ""
Write-Log "M365AuditLogs_CL" -Level Info
Write-Log "| where TimeGenerated > ago(1h)" -Level Info
Write-Log "| summarize count() by SourceTenantName_s, ContentType_s" -Level Info
Write-Log "| order by count_ desc" -Level Info
Write-Log ""
#endregion
