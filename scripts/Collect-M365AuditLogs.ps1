<#
.SYNOPSIS
    Collects Microsoft 365 audit logs from source tenants and sends them to Log Analytics.

.DESCRIPTION
    This script automates Step 7.1 of the Azure Cross-Tenant Log Collection Guide.
    It pulls M365 audit logs from configured source tenants using the Office 365 
    Management API and sends them to a central Log Analytics workspace.
    
    The script is designed to run as an Azure Automation Runbook on a schedule
    (recommended: every 15-30 minutes) from the managing tenant.
    
    Prerequisites:
    - Step 7 must be completed (app registration and subscriptions configured)
    - Azure Automation Account with Managed Identity
    - Managed Identity must have Key Vault Secrets User role on the Key Vault
    - Log Analytics workspace must exist

.PARAMETER KeyVaultName
    The name of the Key Vault containing M365 collector credentials.

.PARAMETER WorkspaceId
    The Log Analytics Workspace ID (not the resource ID, but the GUID).

.PARAMETER WorkspaceKey
    The Log Analytics Workspace primary or secondary key.
    If not provided, will attempt to retrieve from Key Vault.

.PARAMETER LogType
    The custom log type name in Log Analytics. Default: "M365AuditLogs"

.PARAMETER HoursToCollect
    Number of hours of logs to collect. Default: 1 (collect last hour).
    Increase if running less frequently.

.PARAMETER ContentTypes
    Array of M365 content types to collect. Default: All subscribed types.

.PARAMETER SpecificTenantId
    If specified, only collect logs from this tenant. Otherwise collects from all.

.EXAMPLE
    # Run as Azure Automation Runbook (uses Managed Identity)
    .\Collect-M365AuditLogs.ps1 -KeyVaultName "kv-central-atevet12" -WorkspaceId "<WORKSPACE-GUID>"

.EXAMPLE
    # Run manually with explicit workspace key
    .\Collect-M365AuditLogs.ps1 `
        -KeyVaultName "kv-central-atevet12" `
        -WorkspaceId "<WORKSPACE-GUID>" `
        -WorkspaceKey "<WORKSPACE-KEY>"

.EXAMPLE
    # Collect only from a specific tenant
    .\Collect-M365AuditLogs.ps1 `
        -KeyVaultName "kv-central-atevet12" `
        -WorkspaceId "<WORKSPACE-GUID>" `
        -SpecificTenantId "<TENANT-ID>"

.NOTES
    Author: Azure Cross-Tenant Log Collection Guide
    Version: 1.0
    Designed for: Azure Automation Runbook
    
    Log Analytics Data Collector API:
    https://docs.microsoft.com/en-us/azure/azure-monitor/logs/data-collector-api
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceKey,

    [Parameter(Mandatory = $false)]
    [string]$LogType = "M365AuditLogs",

    [Parameter(Mandatory = $false)]
    [int]$HoursToCollect = 1,

    [Parameter(Mandatory = $false)]
    [string[]]$ContentTypes = @(
        "Audit.AzureActiveDirectory",
        "Audit.Exchange",
        "Audit.SharePoint",
        "Audit.General",
        "DLP.All"
    ),

    [Parameter(Mandatory = $false)]
    [string]$SpecificTenantId
)

#region Helper Functions

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $prefix = switch ($Level) {
        "Info"    { "[INFO]" }
        "Success" { "[SUCCESS]" }
        "Warning" { "[WARNING]" }
        "Error"   { "[ERROR]" }
    }
    
    # Use Write-Output for Azure Automation compatibility
    Write-Output "$timestamp $prefix $Message"
}

function Build-Signature {
    param(
        [string]$WorkspaceId,
        [string]$WorkspaceKey,
        [string]$Date,
        [int]$ContentLength,
        [string]$Method,
        [string]$ContentType,
        [string]$Resource
    )
    
    $xHeaders = "x-ms-date:" + $Date
    $stringToHash = $Method + "`n" + $ContentLength + "`n" + $ContentType + "`n" + $xHeaders + "`n" + $Resource
    
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
    
    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    
    return "SharedKey ${WorkspaceId}:${encodedHash}"
}

function Send-LogAnalyticsData {
    param(
        [string]$WorkspaceId,
        [string]$WorkspaceKey,
        [string]$LogType,
        [string]$Body,
        [string]$TimeStampField = ""
    )
    
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $Body.Length
    
    $signature = Build-Signature `
        -WorkspaceId $WorkspaceId `
        -WorkspaceKey $WorkspaceKey `
        -Date $rfc1123date `
        -ContentLength $contentLength `
        -Method $method `
        -ContentType $contentType `
        -Resource $resource
    
    $uri = "https://" + $WorkspaceId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
    
    $headers = @{
        "Authorization" = $signature
        "Log-Type" = $LogType
        "x-ms-date" = $rfc1123date
        "time-generated-field" = $TimeStampField
    }
    
    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $Body -UseBasicParsing
    return $response.StatusCode
}

#endregion

#region Main Script

Write-Log "========================================" -Level Info
Write-Log "Step 7.1: Collect Microsoft 365 Audit Logs" -Level Info
Write-Log "========================================" -Level Info

# Check if running in Azure Automation
$isAzureAutomation = $null -ne $PSPrivateMetadata.JobId

if ($isAzureAutomation) {
    Write-Log "Running in Azure Automation - using Managed Identity" -Level Info
    
    try {
        # Connect using Managed Identity
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        Write-Log "Connected to Azure using Managed Identity" -Level Success
    }
    catch {
        Write-Log "Failed to connect using Managed Identity: $($_.Exception.Message)" -Level Error
        throw
    }
}
else {
    Write-Log "Running locally - checking Azure connection" -Level Info
    
    $context = Get-AzContext
    if (-not $context) {
        Write-Log "Not connected to Azure. Please run Connect-AzAccount first." -Level Error
        exit 1
    }
    Write-Log "Connected to Azure as: $($context.Account.Id)" -Level Success
}

# Retrieve credentials from Key Vault
Write-Log "Retrieving credentials from Key Vault '$KeyVaultName'..." -Level Info

try {
    $appId = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-AppId" -AsPlainText -ErrorAction Stop
    $appSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Secret" -AsPlainText -ErrorAction Stop
    $tenantsJson = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Tenants" -AsPlainText -ErrorAction Stop
    
    Write-Log "Retrieved app credentials" -Level Success
}
catch {
    Write-Log "Failed to retrieve credentials from Key Vault: $($_.Exception.Message)" -Level Error
    throw
}

# Get workspace key from Key Vault if not provided
if (-not $WorkspaceKey) {
    try {
        $WorkspaceKey = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "LogAnalytics-WorkspaceKey" -AsPlainText -ErrorAction Stop
        Write-Log "Retrieved workspace key from Key Vault" -Level Success
    }
    catch {
        Write-Log "Workspace key not provided and not found in Key Vault. Please provide -WorkspaceKey parameter or store as 'LogAnalytics-WorkspaceKey' secret." -Level Error
        throw
    }
}

# Parse tenants list
$tenantsConfig = $tenantsJson | ConvertFrom-Json
$tenants = $tenantsConfig.tenants

if ($SpecificTenantId) {
    $tenants = $tenants | Where-Object { $_.tenantId -eq $SpecificTenantId }
    if ($tenants.Count -eq 0) {
        Write-Log "Tenant '$SpecificTenantId' not found in configured tenants list" -Level Error
        exit 1
    }
}

Write-Log "Found $($tenants.Count) tenant(s) to collect logs from" -Level Info

# Calculate time range
$endTime = [DateTime]::UtcNow
$startTime = $endTime.AddHours(-$HoursToCollect)
$startTimeStr = $startTime.ToString("yyyy-MM-ddTHH:mm:ss")
$endTimeStr = $endTime.ToString("yyyy-MM-ddTHH:mm:ss")

Write-Log "Collecting logs from $startTimeStr to $endTimeStr UTC" -Level Info

# Statistics
$totalLogsCollected = 0
$totalLogsSent = 0
$tenantsProcessed = 0
$tenantsWithErrors = 0

# Process each tenant
foreach ($tenant in $tenants) {
    Write-Log "" -Level Info
    Write-Log "Processing tenant: $($tenant.name) ($($tenant.tenantId))" -Level Info
    
    try {
        # Get OAuth token for this tenant
        $tokenBody = @{
            grant_type    = "client_credentials"
            client_id     = $appId
            client_secret = $appSecret
            resource      = "https://manage.office.com"
        }
        
        $tokenResponse = Invoke-RestMethod `
            -Uri "https://login.microsoftonline.com/$($tenant.tenantId)/oauth2/token" `
            -Method POST `
            -Body $tokenBody `
            -ErrorAction Stop
        
        $accessToken = $tokenResponse.access_token
        Write-Log "  Obtained OAuth token" -Level Success
        
        $headers = @{
            "Authorization" = "Bearer $accessToken"
            "Content-Type"  = "application/json"
        }
        
        $tenantLogsCollected = 0
        
        # Process each content type
        foreach ($contentType in $ContentTypes) {
            Write-Log "  Collecting: $contentType" -Level Info
            
            try {
                # List available content blobs
                $contentUri = "https://manage.office.com/api/v1.0/$($tenant.tenantId)/activity/feed/subscriptions/content?contentType=$contentType&startTime=$startTimeStr&endTime=$endTimeStr"
                
                $contentList = Invoke-RestMethod `
                    -Uri $contentUri `
                    -Method GET `
                    -Headers $headers `
                    -ErrorAction Stop
                
                if ($contentList.Count -eq 0) {
                    Write-Log "    No content available for this time range" -Level Info
                    continue
                }
                
                Write-Log "    Found $($contentList.Count) content blob(s)" -Level Info
                
                # Fetch and process each content blob
                foreach ($content in $contentList) {
                    try {
                        # Fetch actual audit records
                        $auditRecords = Invoke-RestMethod `
                            -Uri $content.contentUri `
                            -Method GET `
                            -Headers $headers `
                            -ErrorAction Stop
                        
                        if ($auditRecords.Count -eq 0) {
                            continue
                        }
                        
                        # Add metadata to each record
                        $enrichedRecords = $auditRecords | ForEach-Object {
                            $_ | Add-Member -NotePropertyName "SourceTenantId" -NotePropertyValue $tenant.tenantId -Force
                            $_ | Add-Member -NotePropertyName "SourceTenantName" -NotePropertyValue $tenant.name -Force
                            $_ | Add-Member -NotePropertyName "ContentType" -NotePropertyValue $contentType -Force
                            $_ | Add-Member -NotePropertyName "CollectedTimeUTC" -NotePropertyValue $endTime.ToString("o") -Force
                            $_
                        }
                        
                        $tenantLogsCollected += $enrichedRecords.Count
                        
                        # Send to Log Analytics in batches of 500
                        $batchSize = 500
                        for ($i = 0; $i -lt $enrichedRecords.Count; $i += $batchSize) {
                            $batch = $enrichedRecords[$i..([Math]::Min($i + $batchSize - 1, $enrichedRecords.Count - 1))]
                            $json = $batch | ConvertTo-Json -Depth 20
                            
                            # Handle single record (not array)
                            if ($batch.Count -eq 1) {
                                $json = "[$json]"
                            }
                            
                            $statusCode = Send-LogAnalyticsData `
                                -WorkspaceId $WorkspaceId `
                                -WorkspaceKey $WorkspaceKey `
                                -LogType $LogType `
                                -Body $json `
                                -TimeStampField "CreationTime"
                            
                            if ($statusCode -eq 200) {
                                $totalLogsSent += $batch.Count
                            }
                            else {
                                Write-Log "    Warning: Unexpected status code $statusCode when sending logs" -Level Warning
                            }
                        }
                    }
                    catch {
                        Write-Log "    Error fetching content blob: $($_.Exception.Message)" -Level Warning
                    }
                }
            }
            catch {
                if ($_.Exception.Message -like "*404*" -or $_.Exception.Message -like "*not found*") {
                    Write-Log "    Subscription not active for $contentType (skipping)" -Level Warning
                }
                else {
                    Write-Log "    Error collecting $contentType : $($_.Exception.Message)" -Level Warning
                }
            }
        }
        
        $totalLogsCollected += $tenantLogsCollected
        $tenantsProcessed++
        Write-Log "  Collected $tenantLogsCollected log(s) from $($tenant.name)" -Level Success
    }
    catch {
        Write-Log "  Error processing tenant $($tenant.name): $($_.Exception.Message)" -Level Error
        $tenantsWithErrors++
    }
}

#endregion

#region Summary

Write-Log "" -Level Info
Write-Log "========================================" -Level Info
Write-Log "COLLECTION COMPLETE" -Level Success
Write-Log "========================================" -Level Info

Write-Log "" -Level Info
Write-Log "Summary:" -Level Info
Write-Log "  Time Range: $startTimeStr to $endTimeStr UTC" -Level Info
Write-Log "  Tenants Processed: $tenantsProcessed" -Level Info
Write-Log "  Tenants with Errors: $tenantsWithErrors" -Level Info
Write-Log "  Total Logs Collected: $totalLogsCollected" -Level Info
Write-Log "  Total Logs Sent to Log Analytics: $totalLogsSent" -Level Info
Write-Log "  Log Analytics Table: ${LogType}_CL" -Level Info

if ($tenantsWithErrors -gt 0) {
    Write-Log "" -Level Warning
    Write-Log "Some tenants had errors. Check the logs above for details." -Level Warning
}

#endregion
