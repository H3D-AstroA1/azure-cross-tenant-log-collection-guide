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
    - Deploys Azure Policy for automatic coverage of new resources (can be skipped with -SkipPolicy)
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

.PARAMETER SkipPolicy
    Skip Azure Policy deployment for automatic diagnostic settings on new resources.
    By default, the script deploys Azure Policy to ensure new resources automatically get diagnostic settings configured.

.PARAMETER PolicyAssignmentPrefix
    Prefix for policy assignment names. Default: "diag-settings"

.PARAMETER SkipVerification
    Skip the verification step after deployment.

.PARAMETER AssignRolesAsSourceAdmin
    Run in SOURCE TENANT ADMIN mode to assign roles to policy managed identities.
    This mode discovers existing policy assignments and assigns Contributor role to their
    managed identities. Use this when the managing tenant cannot assign roles via Lighthouse.

.EXAMPLE
    .\Configure-ResourceDiagnosticLogs.ps1 -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

.EXAMPLE
    .\Configure-ResourceDiagnosticLogs.ps1 -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" -ResourceTypes @("Microsoft.KeyVault/vaults", "Microsoft.Storage/storageAccounts")

.EXAMPLE
    .\Configure-ResourceDiagnosticLogs.ps1 -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" -SkipPolicy

.EXAMPLE
    # SOURCE TENANT ADMIN: Assign roles to policy managed identities
    .\Configure-ResourceDiagnosticLogs.ps1 -AssignRolesAsSourceAdmin -SubscriptionIds @("sub-id-1")

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
    [switch]$SkipPolicy,

    [Parameter(Mandatory = $false)]
    [string]$PolicyAssignmentPrefix = "diag-settings",

    [Parameter(Mandatory = $false)]
    [switch]$SkipVerification,

    [Parameter(Mandatory = $false)]
    [switch]$AssignRolesAsSourceAdmin
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
    IdentitiesNeedingRoles = @()
    RemediationTasksCreated = @()
    Errors = @()
}
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
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $context) {
            Write-ErrorMsg "Not connected to Azure. Please connect first."
            exit 1
        }
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
                
                Write-Host ""
            }
            
            # Create remediation tasks if roles were assigned
            if ($adminResults.RoleAssignmentsCreated.Count -gt 0) {
                Write-Host ""
                Write-Info "Creating remediation tasks for existing non-compliant resources..."
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
    Write-Host "2. Verify resources are getting diagnostic settings configured"
    Write-Host "3. Check Log Analytics workspace for incoming resource logs"
    Write-Host ""
    
    # Return results and exit (don't continue with normal mode)
    return $adminResults
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
        # Determine if this resource type supports metrics
        # Some resources like NSGs don't support AllMetrics
        $resourceType = ($ResourceId -split "/providers/")[-1] -split "/" | Select-Object -First 2
        $resourceTypeString = $resourceType -join "/"
        
        # Resource types that do NOT support metrics
        $noMetricsResourceTypes = @(
            "Microsoft.Network/networkSecurityGroups"
        )
        
        $supportsMetrics = $resourceTypeString -notin $noMetricsResourceTypes
        
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
            }
        }
        
        # Only add metrics if the resource type supports them
        if ($supportsMetrics) {
            $diagnosticSetting.properties.metrics = @(
                @{
                    category = "AllMetrics"
                    enabled = $true
                }
            )
        }
        
        # Use REST API to create the diagnostic setting
        $apiVersion = "2021-05-01-preview"
        $uri = "$ResourceId/providers/Microsoft.Insights/diagnosticSettings/${SettingName}?api-version=$apiVersion"
        
        $response = Invoke-AzRestMethod -Path $uri -Method PUT -Payload ($diagnosticSetting | ConvertTo-Json -Depth 10)
        
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            $metricsNote = if (-not $supportsMetrics) { " (logs only, no metrics)" } else { "" }
            return @{ Success = $true; Message = "Configured successfully$metricsNote" }
        }
        else {
            $errorContent = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            $errorMessage = if ($errorContent.error.message) { $errorContent.error.message } else { $response.Content }
            if (-not $errorMessage) { $errorMessage = "HTTP $($response.StatusCode)" }
            
            # If allLogs is not supported, try with audit category group
            if ($errorMessage -like "*categoryGroup*" -or $errorMessage -like "*allLogs*" -or $errorMessage -like "*not valid*") {
                return Set-DiagnosticSettingWithAudit -ResourceId $ResourceId -SettingName $SettingName -WorkspaceId $WorkspaceId -SupportsMetrics $supportsMetrics
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
        
        # Only add metrics if the resource type supports them
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
            $metricsNote = if (-not $SupportsMetrics) { " (logs only, no metrics)" } else { "" }
            return @{ Success = $true; Message = "Configured with audit category$metricsNote" }
        }
        else {
            $errorContent = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            $errorMessage = if ($errorContent.error.message) { $errorContent.error.message } else { $response.Content }
            if (-not $errorMessage) { $errorMessage = "HTTP $($response.StatusCode)" }
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

#region Deploy Azure Policy (Default - use -SkipPolicy to disable)
if (-not $SkipPolicy) {
    Write-Host ""
    Write-Info "Deploying Azure Policy for automatic diagnostic settings..."
    Write-Host ""
    Write-Info "This ensures new resources automatically get diagnostic settings configured."
    Write-Info "(Use -SkipPolicy parameter to skip this step)"
    Write-Host ""
    
    # Built-in policy definition for diagnostic settings
    $policyDefinitionId = "/providers/Microsoft.Authorization/policyDefinitions/752154a7-1e0f-45c6-a880-ac75a7e4f648"
    
    foreach ($subId in $SubscriptionIds) {
        Write-Host "  Deploying policy to subscription: $subId"
        
        try {
            Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
            
            $assignmentName = "$PolicyAssignmentPrefix-to-law"
            $scope = "/subscriptions/$subId"
            
            # Check if assignment already exists
            $existingAssignment = Get-AzPolicyAssignment -Name $assignmentName -Scope $scope -ErrorAction SilentlyContinue
            
            if ($existingAssignment) {
                Write-WarningMsg "    Policy assignment already exists"
                $principalId = $existingAssignment.Identity.PrincipalId
                $results.PolicyAssignmentsCreated += @{
                    SubscriptionId = $subId
                    AssignmentName = $assignmentName
                    PrincipalId = $principalId
                    Existing = $true
                }
                
                # Track identity for role assignment
                if ($principalId) {
                    $results.IdentitiesNeedingRoles += @{
                        SubscriptionId = $subId
                        AssignmentName = $assignmentName
                        PrincipalId = $principalId
                        AssignmentId = $existingAssignment.PolicyAssignmentId
                    }
                }
            }
            else {
                # Create policy assignment
                # Note: The built-in policy definition requires both 'logAnalytics' and 'profileName' parameters
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
                
                Write-Success "    ✓ Policy assigned"
                Write-Host "      Managed Identity Principal ID: $principalId"
                
                $results.PolicyAssignmentsCreated += @{
                    SubscriptionId = $subId
                    AssignmentName = $assignmentName
                    PrincipalId = $principalId
                    Existing = $false
                }
                
                # Track identity for role assignment
                if ($principalId) {
                    $results.IdentitiesNeedingRoles += @{
                        SubscriptionId = $subId
                        AssignmentName = $assignmentName
                        PrincipalId = $principalId
                        AssignmentId = $newAssignment.PolicyAssignmentId
                    }
                }
            }
            
            # Try to assign Contributor role to the managed identity
            # This may fail in cross-tenant scenarios due to Lighthouse restrictions
            $principalId = $results.PolicyAssignmentsCreated[-1].PrincipalId
            if ($principalId) {
                Write-Host "    Attempting to assign Contributor role to managed identity..."
                try {
                    $existingRole = Get-AzRoleAssignment -ObjectId $principalId -Scope $scope -RoleDefinitionName "Contributor" -ErrorAction SilentlyContinue
                    
                    if ($existingRole) {
                        Write-Success "      ✓ Contributor role already assigned"
                    }
                    else {
                        New-AzRoleAssignment `
                            -ObjectId $principalId `
                            -RoleDefinitionName "Contributor" `
                            -Scope $scope `
                            -ErrorAction Stop | Out-Null
                        
                        Write-Success "      ✓ Contributor role assigned"
                    }
                }
                catch {
                    Write-WarningMsg "      ⚠ Could not assign role (cross-tenant restriction)"
                    Write-WarningMsg "        A SOURCE TENANT ADMIN must assign the role"
                }
            }
        }
        catch {
            Write-ErrorMsg "    ✗ Failed: $($_.Exception.Message)"
            $results.Errors += "Policy assignment in $subId : $($_.Exception.Message)"
        }
    }
    Write-Host ""
    
    # Output instructions for source tenant admin if there are identities needing roles
    if ($results.IdentitiesNeedingRoles.Count -gt 0) {
        Write-Host ""
        Write-Header "======================================================================"
        Write-Header "    IMPORTANT: Managed Identity Role Assignment Required              "
        Write-Header "======================================================================"
        Write-Host ""
        Write-WarningMsg "The policy managed identities need Contributor role to configure diagnostic settings."
        Write-WarningMsg "If role assignment failed above, a SOURCE TENANT ADMIN must run this script"
        Write-WarningMsg "with the -AssignRolesAsSourceAdmin parameter:"
        Write-Host ""
        Write-Host "# Step 1: Connect to the SOURCE tenant as an admin"
        Write-Host "Connect-AzAccount -TenantId '<SOURCE-TENANT-ID>'"
        Write-Host ""
        Write-Host "# Step 2: Run this script with -AssignRolesAsSourceAdmin parameter"
        $subList = ($results.IdentitiesNeedingRoles | Select-Object -ExpandProperty SubscriptionId -Unique) -join "', '"
        Write-Host ".\Configure-ResourceDiagnosticLogs.ps1 -AssignRolesAsSourceAdmin -SubscriptionIds @('$subList')"
        Write-Host ""
        Write-Host "Managed Identities requiring role assignment:"
        foreach ($identity in $results.IdentitiesNeedingRoles) {
            Write-Host "  - Subscription: $($identity.SubscriptionId)"
            Write-Host "    Principal ID: $($identity.PrincipalId)"
            Write-Host "    Assignment: $($identity.AssignmentName)"
        }
        Write-Host ""
    }
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
if (-not $SkipPolicy) {
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