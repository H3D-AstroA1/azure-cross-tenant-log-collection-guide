# Step 5: Configure Azure Resource Diagnostic Logs (Global Admin Optimized)

> 🚀 **OPTIMIZED VERSION**: This version assumes you have **Global Administrator** access on both the managing tenant AND the source tenant, enabling a streamlined single-phase deployment.

## Overview

This optimized approach eliminates the two-phase process (managing tenant → source tenant admin) by leveraging Global Admin access to handle everything in a single session with automatic tenant switching.

### Key Improvements Over Standard Approach

| Aspect | Standard Mode | Global Admin Mode (This Version) |
|--------|--------------|----------------------------------|
| **Process** | Two-phase (requires coordination) | Single-phase (self-service) |
| **Role Assignment** | Often fails cross-tenant, requires separate step | Direct assignment in same session |
| **Remediation** | Separate task creation | Immediate remediation |
| **Total Time** | ~30+ minutes | ~10-15 minutes |
| **Complexity** | High (multiple scripts, multiple logins) | Low (single command) |

## Architecture: Global Admin Mode Workflow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     GLOBAL ADMIN MODE WORKFLOW                          │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  1. Start in MANAGING TENANT (Atevet12)                          │   │
│  │     - Validate workspace exists                                  │   │
│  │     - Store workspace resource ID for cross-tenant reference     │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│                              ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  2. Auto-switch to SOURCE TENANT (Atevet17)                      │   │
│  │     - Configure diagnostic settings on ALL existing resources    │   │
│  │     - Deploy Azure Policy with managed identity                  │   │
│  │     - IMMEDIATELY assign Contributor role (same tenant = works!) │   │
│  │     - Create and execute remediation tasks                       │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                              │                                          │
│                              ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  3. Verify & Report                                              │   │
│  │     - Check diagnostic settings applied                          │   │
│  │     - Verify policy compliance state                             │   │
│  │     - Output verification queries for Log Analytics              │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **Global Administrator** role in the **managing tenant** (Atevet12)
- **Global Administrator** role in the **source tenant** (Atevet17)
- **Azure Lighthouse delegation** completed (Step 2) - still needed for ongoing cross-tenant visibility
- **Log Analytics Workspace Resource ID** (from Step 1)
- **Az PowerShell module** installed

## Quick Start

```powershell
# Single command - handles everything automatically
.\Configure-ResourceDiagnosticLogs-GlobalAdmin.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SourceTenantId "<ATEVET17-TENANT-ID>" `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SubscriptionIds @("<SOURCE-SUB-ID-1>", "<SOURCE-SUB-ID-2>")
```

## Script: `Configure-ResourceDiagnosticLogs-GlobalAdmin.ps1`

```powershell
<#
.SYNOPSIS
    Configures diagnostic settings for Azure resources using Global Admin access on both tenants.

.DESCRIPTION
    OPTIMIZED VERSION for users with Global Administrator access on both managing and source tenants.
    
    This script streamlines the cross-tenant diagnostic settings configuration by:
    - Automatically switching between tenants in a single session
    - Configuring diagnostic settings on existing resources
    - Deploying Azure Policy with managed identity
    - IMMEDIATELY assigning roles (no cross-tenant restriction when in source tenant context)
    - Creating and executing remediation tasks
    - Verifying the configuration
    
    This eliminates the need for a separate "-AssignRolesAsSourceAdmin" step.

.PARAMETER ManagingTenantId
    The Azure tenant ID (GUID) of the managing tenant (where Log Analytics workspace resides).

.PARAMETER SourceTenantId
    The Azure tenant ID (GUID) of the source tenant (where resources to be monitored reside).

.PARAMETER WorkspaceResourceId
    The full resource ID of the Log Analytics workspace to send logs to.
    Example: /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>

.PARAMETER SubscriptionIds
    Array of subscription IDs in the SOURCE tenant to configure.

.PARAMETER DiagnosticSettingName
    Name for the diagnostic setting. Default: "SendToLogAnalytics"

.PARAMETER ResourceTypes
    Array of resource types to configure. If not provided, configures all supported types.

.PARAMETER SkipPolicy
    Skip Azure Policy deployment (only configure existing resources).

.PARAMETER SkipRemediation
    Skip creating remediation tasks after policy deployment.

.PARAMETER SkipVerification
    Skip the verification step after deployment.

.EXAMPLE
    .\Configure-ResourceDiagnosticLogs-GlobalAdmin.ps1 `
        -ManagingTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -SourceTenantId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
        -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central" `
        -SubscriptionIds @("sub-id-1", "sub-id-2")

.NOTES
    Author: Cross-Tenant Log Collection Guide (Global Admin Optimized)
    Requires: Az.Accounts, Az.Resources, Az.Monitor modules
    Requires: Global Administrator on BOTH managing and source tenants
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManagingTenantId,

    [Parameter(Mandatory = $true)]
    [string]$SourceTenantId,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceResourceId,

    [Parameter(Mandatory = $true)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$DiagnosticSettingName = "SendToLogAnalytics",

    [Parameter(Mandatory = $false)]
    [string[]]$ResourceTypes,

    [Parameter(Mandatory = $false)]
    [switch]$SkipPolicy,

    [Parameter(Mandatory = $false)]
    [switch]$SkipRemediation,

    [Parameter(Mandatory = $false)]
    [switch]$SkipVerification,

    [Parameter(Mandatory = $false)]
    [string]$PolicyAssignmentPrefix = "diag-settings"
)

#region Helper Functions
function Write-Success { param($Message) Write-Host $Message -ForegroundColor Green }
function Write-ErrorMsg { param($Message) Write-Host $Message -ForegroundColor Red }
function Write-WarningMsg { param($Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Info { param($Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Header { param($Message) Write-Host $Message -ForegroundColor Cyan -BackgroundColor DarkBlue }
#endregion

#region Supported Resource Types
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
    ManagingTenantId = $ManagingTenantId
    SourceTenantId = $SourceTenantId
    WorkspaceResourceId = $WorkspaceResourceId
    DiagnosticSettingName = $DiagnosticSettingName
    SubscriptionsProcessed = @()
    ResourcesConfigured = @()
    ResourcesFailed = @()
    PolicyAssignmentsCreated = @()
    RoleAssignmentsCreated = @()
    RemediationTasksCreated = @()
    Errors = @()
}
#endregion

# Main Script Execution
Write-Host ""
Write-Header "======================================================================"
Write-Header "   Configure Resource Diagnostic Logs - GLOBAL ADMIN OPTIMIZED       "
Write-Header "======================================================================"
Write-Host ""

Write-Info "This optimized script leverages Global Admin access on both tenants"
Write-Info "to complete the entire configuration in a single session."
Write-Host ""

#region Phase 1: Validate Managing Tenant and Workspace
Write-Header "Phase 1: Validating Managing Tenant Configuration"
Write-Host ""

Write-Info "Connecting to Managing Tenant: $ManagingTenantId"

try {
    # Check if already connected
    $context = Get-AzContext -ErrorAction SilentlyContinue
    
    if (-not $context -or $context.Tenant.Id -ne $ManagingTenantId) {
        Connect-AzAccount -TenantId $ManagingTenantId -ErrorAction Stop | Out-Null
        $context = Get-AzContext
    }
    
    Write-Success "  Connected as: $($context.Account.Id)"
    Write-Success "  Tenant: $($context.Tenant.Id)"
}
catch {
    Write-ErrorMsg "Failed to connect to managing tenant: $($_.Exception.Message)"
    exit 1
}

# Validate Workspace Resource ID
Write-Host ""
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

# Verify workspace exists
try {
    Set-AzContext -SubscriptionId $workspaceSubscriptionId -ErrorAction Stop | Out-Null
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $workspaceResourceGroup -Name $workspaceName -ErrorAction Stop
    Write-Success "  ✓ Workspace verified: $workspaceName"
    Write-Success "    Location: $($workspace.Location)"
    Write-Success "    Resource Group: $workspaceResourceGroup"
}
catch {
    Write-ErrorMsg "  ✗ Workspace not found or not accessible: $($_.Exception.Message)"
    exit 1
}

Write-Host ""
Write-Success "Phase 1 Complete: Managing tenant validated"
Write-Host ""
#endregion

#region Phase 2: Switch to Source Tenant and Configure Resources
Write-Header "Phase 2: Configuring Source Tenant Resources"
Write-Host ""

Write-Info "Switching to Source Tenant: $SourceTenantId"
Write-WarningMsg "You may be prompted to authenticate to the source tenant..."
Write-Host ""

try {
    Connect-AzAccount -TenantId $SourceTenantId -ErrorAction Stop | Out-Null
    $context = Get-AzContext
    
    if ($context.Tenant.Id -ne $SourceTenantId) {
        Write-ErrorMsg "Failed to switch to source tenant. Current tenant: $($context.Tenant.Id)"
        exit 1
    }
    
    Write-Success "  Connected to source tenant as: $($context.Account.Id)"
    Write-Success "  Tenant: $($context.Tenant.Id)"
}
catch {
    Write-ErrorMsg "Failed to connect to source tenant: $($_.Exception.Message)"
    exit 1
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

#region Function: Configure Diagnostic Setting using REST API
function Set-DiagnosticSettingWithAllLogs {
    param(
        [string]$ResourceId,
        [string]$SettingName,
        [string]$WorkspaceId
    )
    
    try {
        $resourceType = ($ResourceId -split "/providers/")[-1] -split "/" | Select-Object -First 2
        $resourceTypeString = $resourceType -join "/"
        
        $noMetricsResourceTypes = @("Microsoft.Network/networkSecurityGroups")
        $supportsMetrics = $resourceTypeString -notin $noMetricsResourceTypes
        
        $diagnosticSetting = @{
            properties = @{
                workspaceId = $WorkspaceId
                logs = @(
                    @{
                        categoryGroup = "allLogs"
                        enabled = $true
                    }
                )
            }
        }
        
        if ($supportsMetrics) {
            $diagnosticSetting.properties.metrics = @(
                @{
                    category = "AllMetrics"
                    enabled = $true
                }
            )
        }
        
        $apiVersion = "2021-05-01-preview"
        $uri = "$ResourceId/providers/Microsoft.Insights/diagnosticSettings/${SettingName}?api-version=$apiVersion"
        
        $response = Invoke-AzRestMethod -Path $uri -Method PUT -Payload ($diagnosticSetting | ConvertTo-Json -Depth 10)
        
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            return @{ Success = $true; Message = "Configured successfully" }
        }
        else {
            $errorContent = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            $errorMessage = if ($errorContent.error.message) { $errorContent.error.message } else { "HTTP $($response.StatusCode)" }
            
            # Fallback to audit category if allLogs not supported
            if ($errorMessage -like "*categoryGroup*" -or $errorMessage -like "*allLogs*") {
                return Set-DiagnosticSettingWithAudit -ResourceId $ResourceId -SettingName $SettingName -WorkspaceId $WorkspaceId -SupportsMetrics $supportsMetrics
            }
            
            return @{ Success = $false; Message = $errorMessage }
        }
    }
    catch {
        return @{ Success = $false; Message = $_.Exception.Message }
    }
}

function Set-DiagnosticSettingWithAudit {
    param(
        [string]$ResourceId,
        [string]$SettingName,
        [string]$WorkspaceId,
        [bool]$SupportsMetrics = $true
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
            }
        }
        
        if ($SupportsMetrics) {
            $diagnosticSetting.properties.metrics = @(
                @{
                    category = "AllMetrics"
                    enabled = $true
                }
            )
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

# Process Each Subscription
Write-Info "Configuring diagnostic settings on existing resources..."
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
                continue
            }
            
            Write-Host "    Found $($resources.Count) resource(s)"
            
            foreach ($resource in $resources) {
                $resourceId = $resource.ResourceId
                if (-not $resourceId) { $resourceId = $resource.Id }
                
                $resourceName = $resource.Name
                if (-not $resourceName) { $resourceName = $resource.VaultName }
                
                Write-Host "    Configuring: $resourceName"
                
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
                        }
                    }
                }
                else {
                    $result = Set-DiagnosticSettingWithAllLogs -ResourceId $resourceId -SettingName $DiagnosticSettingName -WorkspaceId $WorkspaceResourceId
                    
                    if ($result.Success) {
                        Write-Success "      ✓ $($result.Message)"
                        $results.ResourcesConfigured += $resourceId
                    }
                    else {
                        Write-ErrorMsg "      ✗ $($result.Message)"
                        $results.ResourcesFailed += $resourceId
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
}

Write-Host ""
Write-Success "Phase 2 Complete: Existing resources configured"
Write-Host ""
#endregion

#region Phase 3: Deploy Azure Policy with Immediate Role Assignment
if (-not $SkipPolicy) {
    Write-Header "Phase 3: Deploying Azure Policy (with Immediate Role Assignment)"
    Write-Host ""
    
    Write-Info "Deploying Azure Policy for automatic diagnostic settings on new resources..."
    Write-Info "Since we're in the SOURCE TENANT context, role assignment will succeed immediately!"
    Write-Host ""
    
    $policyDefinitionId = "/providers/Microsoft.Authorization/policyDefinitions/752154a7-1e0f-45c6-a880-ac75a7e4f648"
    
    foreach ($subId in $SubscriptionIds) {
        Write-Host "  Deploying policy to subscription: $subId"
        
        try {
            Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
            
            $assignmentName = "$PolicyAssignmentPrefix-to-law"
            $scope = "/subscriptions/$subId"
            
            # Check if assignment already exists
            $existingAssignment = Get-AzPolicyAssignment -Name $assignmentName -Scope $scope -ErrorAction SilentlyContinue
            
            $principalId = $null
            $assignmentId = $null
            
            if ($existingAssignment) {
                Write-WarningMsg "    Policy assignment already exists"
                $principalId = $existingAssignment.Identity.PrincipalId
                $assignmentId = $existingAssignment.PolicyAssignmentId
                if (-not $assignmentId) { $assignmentId = $existingAssignment.ResourceId }
            }
            else {
                # Create policy assignment with managed identity
                $policyParams = @{
                    logAnalytics = $WorkspaceResourceId
                    profileName = $DiagnosticSettingName
                }
                
                $newAssignment = New-AzPolicyAssignment `
                    -Name $assignmentName `
                    -DisplayName "Configure diagnostic settings to Log Analytics workspace" `
                    -PolicyDefinition (Get-AzPolicyDefinition -Id $policyDefinitionId) `
                    -Scope $scope `
                    -PolicyParameterObject $policyParams `
                    -Location "westus2" `
                    -IdentityType "SystemAssigned" `
                    -ErrorAction Stop
                
                $principalId = $newAssignment.Identity.PrincipalId
                $assignmentId = $newAssignment.PolicyAssignmentId
                
                Write-Success "    ✓ Policy assigned"
                Write-Host "      Managed Identity Principal ID: $principalId"
            }
            
            $results.PolicyAssignmentsCreated += @{
                SubscriptionId = $subId
                AssignmentName = $assignmentName
                AssignmentId = $assignmentId
                PrincipalId = $principalId
            }
            
            # IMMEDIATE ROLE ASSIGNMENT - This works because we're in the source tenant context!
            if ($principalId) {
                Write-Host "    Assigning Contributor role to managed identity..."
                Write-Host "    (This works immediately because we're in the source tenant context)"
                
                # Wait a moment for identity to propagate
                Start-Sleep -Seconds 5
                
                try {
                    $existingRole = Get-AzRoleAssignment -ObjectId $principalId -Scope $scope -RoleDefinitionName "Contributor" -ErrorAction SilentlyContinue
                    
                    if ($existingRole) {
                        Write-Success "      ✓ Contributor role already assigned"
                    }
                    else {
                        # Retry logic for identity propagation
                        $maxRetries = 3
                        $retryCount = 0
                        $roleAssigned = $false
                        
                        while (-not $roleAssigned -and $retryCount -lt $maxRetries) {
                            try {
                                New-AzRoleAssignment `
                                    -ObjectId $principalId `
                                    -RoleDefinitionName "Contributor" `
                                    -Scope $scope `
                                    -ErrorAction Stop | Out-Null
                                
                                Write-Success "      ✓ Contributor role assigned successfully!"
                                $roleAssigned = $true
                                
                                $results.RoleAssignmentsCreated += @{
                                    PrincipalId = $principalId
                                    Role = "Contributor"
                                    Scope = $scope
                                }
                            }
                            catch {
                                if ($_.Exception.Message -like "*does not exist*" -or $_.Exception.Message -like "*PrincipalNotFound*") {
                                    $retryCount++
                                    if ($retryCount -lt $maxRetries) {
                                        Write-WarningMsg "      Identity not yet available, retrying in 10 seconds..."
                                        Start-Sleep -Seconds 10
                                    }
                                }
                                elseif ($_.Exception.Message -like "*already exists*" -or $_.Exception.Message -like "*Conflict*") {
                                    Write-Success "      ✓ Contributor role already assigned"
                                    $roleAssigned = $true
                                }
                                else {
                                    throw
                                }
                            }
                        }
                        
                        if (-not $roleAssigned) {
                            Write-ErrorMsg "      ✗ Failed to assign role after $maxRetries attempts"
                        }
                    }
                }
                catch {
                    Write-ErrorMsg "      ✗ Role assignment failed: $($_.Exception.Message)"
                    $results.Errors += "Role assignment for $principalId : $($_.Exception.Message)"
                }
            }
        }
        catch {
            Write-ErrorMsg "    ✗ Failed: $($_.Exception.Message)"
            $results.Errors += "Policy assignment in $subId : $($_.Exception.Message)"
        }
        
        Write-Host ""
    }
    
    Write-Success "Phase 3 Complete: Azure Policy deployed with role assignments"
    Write-Host ""
}
#endregion

#region Phase 4: Create Remediation Tasks
if (-not $SkipPolicy -and -not $SkipRemediation -and $results.PolicyAssignmentsCreated.Count -gt 0) {
    Write-Header "Phase 4: Creating Remediation Tasks"
    Write-Host ""
    
    Write-Info "Creating remediation tasks to apply policies to existing non-compliant resources..."
    Write-Host ""
    
    # Wait for role assignments to propagate
    Write-Host "  Waiting 15 seconds for role assignments to propagate..."
    Start-Sleep -Seconds 15
    
    foreach ($assignment in $results.PolicyAssignmentsCreated) {
        $remediationName = "remediate-$($assignment.AssignmentName)-$(Get-Date -Format 'yyyyMMddHHmm')"
        
        Write-Host "  Creating remediation: $remediationName"
        
        try {
            Set-AzContext -SubscriptionId $assignment.SubscriptionId -ErrorAction Stop | Out-Null
            $scope = "/subscriptions/$($assignment.SubscriptionId)"
            
            # Check for existing running remediations
            $existingRemediations = Get-AzPolicyRemediation -Scope $scope -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.PolicyAssignmentId -eq $assignment.AssignmentId -and
                    $_.ProvisioningState -in @("Accepted", "Running", "Evaluating")
                }
            
            if ($existingRemediations) {
                Write-Success "    ✓ Remediation already in progress: $($existingRemediations[0].Name)"
                $results.RemediationTasksCreated += @{
                    Name = $existingRemediations[0].Name
                    PolicyAssignment = $assignment.AssignmentName
                    Status = $existingRemediations[0].ProvisioningState
                    Existing = $true
                }
                continue
            }
            
            $remediation = Start-AzPolicyRemediation `
                -Name $remediationName `
                -PolicyAssignmentId $assignment.AssignmentId `
                -Scope $scope `
                -ErrorAction Stop
            
            Write-Success "    ✓ Remediation task created"
            $results.RemediationTasksCreated += @{
                Name = $remediationName
                PolicyAssignment = $assignment.AssignmentName
                Status = $remediation.ProvisioningState
            }
        }
        catch {
            if ($_.Exception.Message -like "*already running*" -or $_.Exception.Message -like "*InvalidCreateRemediationRequest*") {
                Write-Success "    ✓ Remediation already in progress for this policy"
            }
            else {
                Write-WarningMsg "    ⚠ Could not create remediation: $($_.Exception.Message)"
                $results.Errors += "Remediation for $($assignment.AssignmentName): $($_.Exception.Message)"
            }
        }
    }
    
    Write-Host ""
    Write-Success "Phase 4 Complete: Remediation tasks created"
    Write-Host ""
}
#endregion

#region Phase 5: Verification
if (-not $SkipVerification -and $results.ResourcesConfigured.Count -gt 0) {
    Write-Header "Phase 5: Verifying Configuration"
    Write-Host ""
    
    Write-Info "Verifying diagnostic settings on sample resources..."
    
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
    Write-Success "Phase 5 Complete: Configuration verified"
    Write-Host ""
}
#endregion

#region Output Summary
Write-Host ""
Write-Header "======================================================================"
Write-Header "                              SUMMARY                                 "
Write-Header "======================================================================"
Write-Host ""

Write-Host "Managing Tenant:           $ManagingTenantId"
Write-Host "Source Tenant:             $SourceTenantId"
Write-Host "Workspace:                 $workspaceName"
Write-Host "Diagnostic Setting Name:   $DiagnosticSettingName"
Write-Host ""

Write-Host "Subscriptions Processed:   $($results.SubscriptionsProcessed.Count)"
Write-Success "Resources Configured:      $($results.ResourcesConfigured.Count)"
if ($results.ResourcesFailed.Count -gt 0) {
    Write-ErrorMsg "Resources Failed:          $($results.ResourcesFailed.Count)"
}
if (-not $SkipPolicy) {
    Write-Host "Policy Assignments:        $($results.PolicyAssignmentsCreated.Count)"
    Write-Host "Role Assignments:          $($results.RoleAssignmentsCreated.Count)"
    Write-Host "Remediation Tasks:         $($results.RemediationTasksCreated.Count)"
}
Write-Host ""

if ($results.ResourcesConfigured.Count -gt 0) {
    Write-Success "Successfully configured resources by type:"
    $resourceSummary = $results.ResourcesConfigured | Group-Object { ($_ -split "/providers/")[1] -split "/" | Select-Object -First 2 | Join-String -Separator "/" }
    foreach ($group in $resourceSummary | Select-Object -First 10) {
        Write-Success "  $($group.Name): $($group.Count)"
    }
    Write-Host ""
}

if ($results.RoleAssignmentsCreated.Count -gt 0) {
    Write-Success "Role assignments created (no separate admin step needed!):"
    foreach ($role in $results.RoleAssignmentsCreated) {
        Write-Success "  ✓ $($role.Role) assigned to $($role.PrincipalId)"
    }
    Write-Host ""
}

if ($results.Errors.Count -gt 0) {
    Write-WarningMsg "Errors encountered:"
    foreach ($err in $results.Errors | Select-Object -First 5) {
        Write-ErrorMsg "  - $err"
    }
    Write-Host ""
}

# JSON Output
Write-Info "=== JSON Output (for automation) ==="
Write-Host ""
$jsonOutput = @{
    managingTenantId = $results.ManagingTenantId
    sourceTenantId = $results.SourceTenantId
    workspaceResourceId = $results.WorkspaceResourceId
    diagnosticSettingName = $results.DiagnosticSettingName
    subscriptionsProcessed = $results.SubscriptionsProcessed
    resourcesConfiguredCount = $results.ResourcesConfigured.Count
    resourcesFailedCount = $results.ResourcesFailed.Count
    policyAssignmentsCount = $results.PolicyAssignmentsCreated.Count
    roleAssignmentsCount = $results.RoleAssignmentsCreated.Count
    remediationTasksCount = $results.RemediationTasksCreated.Count
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

Write-Success "======================================================================"
Write-Success "  GLOBAL ADMIN MODE COMPLETE - All steps finished in single session! "
Write-Success "======================================================================"
Write-Host ""
#endregion

# Return results object
return $results
```

## Usage Examples

### Basic Usage

```powershell
# Single command - handles everything
.\Configure-ResourceDiagnosticLogs-GlobalAdmin.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SourceTenantId "<ATEVET17-TENANT-ID>" `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SubscriptionIds @("<SOURCE-SUB-ID>")
```

### Multiple Subscriptions

```powershell
.\Configure-ResourceDiagnosticLogs-GlobalAdmin.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SourceTenantId "<ATEVET17-TENANT-ID>" `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SubscriptionIds @("<SUB-1>", "<SUB-2>", "<SUB-3>")
```

### Specific Resource Types Only

```powershell
.\Configure-ResourceDiagnosticLogs-GlobalAdmin.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SourceTenantId "<ATEVET17-TENANT-ID>" `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SubscriptionIds @("<SOURCE-SUB-ID>") `
    -ResourceTypes @("Microsoft.KeyVault/vaults", "Microsoft.Storage/storageAccounts")
```

### Skip Policy Deployment (Existing Resources Only)

```powershell
.\Configure-ResourceDiagnosticLogs-GlobalAdmin.ps1 `
    -ManagingTenantId "<ATEVET12-TENANT-ID>" `
    -SourceTenantId "<ATEVET17-TENANT-ID>" `
    -WorkspaceResourceId "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
    -SubscriptionIds @("<SOURCE-SUB-ID>") `
    -SkipPolicy
```

### Configure Multiple Source Tenants

```powershell
# Loop through multiple source tenants
$sourceTenants = @(
    @{ TenantId = "<TENANT-1-ID>"; Subscriptions = @("<SUB-1>", "<SUB-2>") },
    @{ TenantId = "<TENANT-2-ID>"; Subscriptions = @("<SUB-3>") },
    @{ TenantId = "<TENANT-3-ID>"; Subscriptions = @("<SUB-4>", "<SUB-5>") }
)

$managingTenantId = "<ATEVET12-TENANT-ID>"
$workspaceResourceId = "/subscriptions/<ATEVET12-SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central"

foreach ($tenant in $sourceTenants) {
    Write-Host "Configuring tenant: $($tenant.TenantId)" -ForegroundColor Cyan
    
    .\Configure-ResourceDiagnosticLogs-GlobalAdmin.ps1 `
        -ManagingTenantId $managingTenantId `
        -SourceTenantId $tenant.TenantId `
        -WorkspaceResourceId $workspaceResourceId `
        -SubscriptionIds $tenant.Subscriptions
    
    Write-Host ""
}
```

## Expected Output

```
======================================================================
   Configure Resource Diagnostic Logs - GLOBAL ADMIN OPTIMIZED
======================================================================

This optimized script leverages Global Admin access on both tenants
to complete the entire configuration in a single session.

Phase 1: Validating Managing Tenant Configuration

Connecting to Managing Tenant: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  Connected as: admin@atevet12.onmicrosoft.com
  Tenant: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

Validating workspace resource ID...
  ✓ Workspace verified: law-central-atevet12
    Location: westus2
    Resource Group: rg-central-logging

Phase 1 Complete: Managing tenant validated

Phase 2: Configuring Source Tenant Resources

Switching to Source Tenant: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
  Connected to source tenant as: admin@atevet17.onmicrosoft.com
  Tenant: yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy

Configuring all supported resource types (17 types)

Configuring diagnostic settings on existing resources...

Processing subscription: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
  Subscription name: Production-Subscription

  Discovering Microsoft.KeyVault/vaults...
    Found 2 resource(s)
    Configuring: kv-prod-secrets
      ✓ Configured successfully
    Configuring: kv-prod-keys
      ✓ Configured successfully

  Discovering Microsoft.Storage/storageAccounts...
    Found 1 resource(s)
    Configuring: stproddata001
      Configuring blobServices...
      ✓ blobServices
      Configuring queueServices...
      ✓ queueServices
      Configuring tableServices...
      ✓ tableServices
      Configuring fileServices...
      ✓ fileServices

Phase 2 Complete: Existing resources configured

Phase 3: Deploying Azure Policy (with Immediate Role Assignment)

Deploying Azure Policy for automatic diagnostic settings on new resources...
Since we're in the SOURCE TENANT context, role assignment will succeed immediately!

  Deploying policy to subscription: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
    ✓ Policy assigned
      Managed Identity Principal ID: zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz
    Assigning Contributor role to managed identity...
    (This works immediately because we're in the source tenant context)
      ✓ Contributor role assigned successfully!

Phase 3 Complete: Azure Policy deployed with role assignments

Phase 4: Creating Remediation Tasks

Creating remediation tasks to apply policies to existing non-compliant resources...

  Waiting 15 seconds for role assignments to propagate...
  Creating remediation: remediate-diag-settings-to-law-202401151030
    ✓ Remediation task created

Phase 4 Complete: Remediation tasks created

Phase 5: Verifying Configuration

Verifying diagnostic settings on sample resources...
  ✓ Verified: kv-prod-secrets
  ✓ Verified: kv-prod-keys
  ✓ Verified: default (blobServices)

  Verified 3 of 3 sampled resources

Phase 5 Complete: Configuration verified

======================================================================
                              SUMMARY
======================================================================

Managing Tenant:           xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Source Tenant:             yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy
Workspace:                 law-central-atevet12
Diagnostic Setting Name:   SendToLogAnalytics

Subscriptions Processed:   1
Resources Configured:      6
Policy Assignments:        1
Role Assignments:          1
Remediation Tasks:         1

Successfully configured resources by type:
  Microsoft.KeyVault/vaults: 2
  Microsoft.Storage/storageAccounts/blobServices: 1
  Microsoft.Storage/storageAccounts/queueServices: 1
  Microsoft.Storage/storageAccounts/tableServices: 1
  Microsoft.Storage/storageAccounts/fileServices: 1

Role assignments created (no separate admin step needed!):
  ✓ Contributor assigned to zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz

=== Next Steps ===

1. Wait 5-15 minutes for logs to start flowing
2. Run the verification queries in Log Analytics
3. Configure Microsoft Sentinel analytics rules
4. Set up workbooks for cross-tenant visibility

======================================================================
  GLOBAL ADMIN MODE COMPLETE - All steps finished in single session!
======================================================================
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Failed to connect to managing tenant" | Ensure you have Global Admin on the managing tenant and run `Connect-AzAccount -TenantId <MANAGING-TENANT-ID>` |
| "Failed to connect to source tenant" | Ensure you have Global Admin on the source tenant; you'll be prompted to authenticate |
| "Workspace not found" | Verify the workspace resource ID is correct and you have access to the managing tenant subscription |
| "Role assignment failed" | This shouldn't happen in Global Admin mode; check if the managed identity was created successfully |
| "Remediation task failed" | Wait for role assignment propagation (script waits 15 seconds); retry if needed |

## Comparison with Standard Mode

| Aspect | Standard Mode | Global Admin Mode |
|--------|--------------|-------------------|
| **Scripts Required** | 2 (main + source admin) | 1 |
| **Authentication** | Multiple logins | Single session (auto-switch) |
| **Role Assignment** | Often fails, requires manual step | Automatic (same tenant context) |
| **Remediation** | Separate step | Immediate |
| **Total Time** | 30+ minutes | 10-15 minutes |
| **Coordination** | Requires source tenant admin | Self-service |
| **Error Handling** | Complex (cross-tenant issues) | Simplified |

## When to Use Standard Mode Instead

Use the standard (non-Global Admin) mode when:
- You don't have Global Admin on the source tenant
- Security policies require separation of duties
- You're working with a managed service provider (MSP) model
- The source tenant admin prefers to control role assignments

For the standard mode, refer to the original [`Configure-ResourceDiagnosticLogs.ps1`](../scripts/Configure-ResourceDiagnosticLogs.ps1) script.