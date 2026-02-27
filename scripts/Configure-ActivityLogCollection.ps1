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
    [string]$DiagnosticSettingName = "SendLogsToadaptgbmgthdfeb26",

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