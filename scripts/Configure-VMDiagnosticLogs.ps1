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

.PARAMETER AutoRunSourceRoleAssignment
    When identities need roles, automatically run a helper script that connects to the
    source tenant and executes -AssignRolesAsSourceAdmin.

.PARAMETER SourceTenantId
    Source tenant ID used when auto-running the role assignment helper script.

.PARAMETER RoleAssignmentScriptPath
    Path to the helper script that performs source-tenant role assignment.
    Default: .\Run-AssignRolesAsSourceAdmin.ps1

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
    [string]$DataCollectionRuleName = "dcr-vmlogs-for-atevet17",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "rg-monitoring-adaptgbmgthd",

    [Parameter(Mandatory = $false)]
    [string]$Location = "westus2",

    [Parameter(Mandatory = $false)]
    [bool]$DeployPolicy = $true,

    [Parameter(Mandatory = $false)]
    [string]$PolicyAssignmentPrefix = "vm-monitoring-atevet17-adaptgbmgthd",

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
    [switch]$AutoRunSourceRoleAssignment,

    [Parameter(Mandatory = $false)]
    [string]$SourceTenantId,

    [Parameter(Mandatory = $false)]
    [string]$RoleAssignmentScriptPath = ".\Run-AssignRolesAsSourceAdmin.ps1",

    [Parameter(Mandatory = $false)]
    [string]$MasterDCRResourceGroup = "rg-atevet17-central-logging",

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
    RoleAssignmentHelperInvoked = $false
    RoleAssignmentHelperTenantId = $null
    RoleAssignmentHelperTenantIds = @()
    RoleAssignmentHelperSubscriptions = @()
    RoleAssignmentHelperStatus = "NotRequired"
    RoleAssignmentHelperMessage = "No additional source-tenant role assignment was needed."
    RoleAssignmentHelperRoleAssignmentsCreated = 0
    RoleAssignmentHelperRoleAssignmentsFailed = 0
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

#region Helper Auto-Run Eligibility
$resolvedSourceTenantId = if (-not [string]::IsNullOrWhiteSpace($SourceTenantId)) { $SourceTenantId } else { "(will prompt at runtime if needed)" }
$autoRunConfigured = $true
Write-Info "=== Role Assignment Helper Auto-Run ==="
if ($autoRunConfigured) {
    Write-Success "Configured: YES"
    Write-Host "Helper Script: $RoleAssignmentScriptPath"
    Write-Host "Source Tenant: $resolvedSourceTenantId"
    Write-Host "Will run only if policy identities still need roles."
}
else {
    Write-WarningMsg "Configured: NO"
    Write-Host "Helper auto-run is disabled."
    Write-Host "To enable, pass -AutoRunSourceRoleAssignment or -SourceTenantId."
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
                                    TenantId = $assignmentResult.TenantId
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
                                            TenantId = $assignmentResult.TenantId
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

#region Always Run Role Assignment Helper
Write-Host ""
Write-Info "Running role assignment helper (default behavior)..."

$results.RoleAssignmentHelperInvoked = $false
$results.RoleAssignmentHelperTenantId = $null
$results.RoleAssignmentHelperTenantIds = @()
$results.RoleAssignmentHelperSubscriptions = @()
$results.RoleAssignmentHelperRoleAssignmentsCreated = 0
$results.RoleAssignmentHelperRoleAssignmentsFailed = 0

$defaultSubsForHelper = @($SubscriptionIds | Select-Object -Unique)
$helperGroups = @()

if (-not [string]::IsNullOrWhiteSpace($SourceTenantId)) {
    if ($defaultSubsForHelper.Count -gt 0) {
        $helperGroups += @{
            TenantId = $SourceTenantId
            SubscriptionIds = $defaultSubsForHelper
        }
    }
}
else {
    $tenantIdsFromAssignments = @($results.PolicyAssignmentsCreated |
        Where-Object { $_.TenantId } |
        Select-Object -ExpandProperty TenantId -Unique)

    if ($tenantIdsFromAssignments.Count -gt 0) {
        foreach ($tenantIdCandidate in $tenantIdsFromAssignments) {
            $tenantSubs = @($results.PolicyAssignmentsCreated |
                Where-Object { $_.TenantId -eq $tenantIdCandidate } |
                Select-Object -ExpandProperty SubscriptionId -Unique)

            if ($tenantSubs.Count -eq 0) {
                $tenantSubs = $defaultSubsForHelper
            }

            if ($tenantSubs.Count -gt 0) {
                $helperGroups += @{
                    TenantId = $tenantIdCandidate
                    SubscriptionIds = $tenantSubs
                }
            }
        }
    }
    else {
        $tenantInput = Read-Host "Enter SOURCE TENANT ID for role assignment helper"
        if (-not [string]::IsNullOrWhiteSpace($tenantInput)) {
            if ($defaultSubsForHelper.Count -gt 0) {
                $helperGroups += @{
                    TenantId = $tenantInput.Trim()
                    SubscriptionIds = $defaultSubsForHelper
                }
            }
        }
    }
}

if ($helperGroups.Count -eq 0) {
    $results.RoleAssignmentHelperStatus = "Skipped"
    $results.RoleAssignmentHelperMessage = "No tenant/subscription groups available to run helper."
    Write-WarningMsg $results.RoleAssignmentHelperMessage
}
else {
    $results.RoleAssignmentHelperStatus = "Running"
    $results.RoleAssignmentHelperMessage = "Executing helper script for $($helperGroups.Count) tenant group(s)."
    $groupFailures = 0

    foreach ($helperGroup in $helperGroups) {
        $tenantForHelper = $helperGroup.TenantId
        $subListAuto = @($helperGroup.SubscriptionIds)

        Write-Info "Running helper for tenant: $tenantForHelper"
        Write-Host "  Subscriptions: $($subListAuto -join ', ')"

        $results.RoleAssignmentHelperInvoked = $true
        if (-not $results.RoleAssignmentHelperTenantId) {
            $results.RoleAssignmentHelperTenantId = $tenantForHelper
        }
        $results.RoleAssignmentHelperTenantIds += $tenantForHelper
        $results.RoleAssignmentHelperSubscriptions += $subListAuto

        $helperParams = @{
            TenantId = $tenantForHelper
            SubscriptionIds = $subListAuto
            PolicyAssignmentPrefix = $PolicyAssignmentPrefix
            DataCollectionRuleName = $DataCollectionRuleName
            SkipRemediation = $SkipRemediation
        }

        try {
            $helperResult = & $RoleAssignmentScriptPath @helperParams
            if ($helperResult) {
                if ($helperResult.RoleAssignmentsCreated) {
                    $results.RoleAssignmentHelperRoleAssignmentsCreated += @($helperResult.RoleAssignmentsCreated).Count
                }
                if ($helperResult.RoleAssignmentsFailed) {
                    $results.RoleAssignmentHelperRoleAssignmentsFailed += @($helperResult.RoleAssignmentsFailed).Count
                }
            }
            Write-Success "Helper script completed for tenant '$tenantForHelper'."
        }
        catch {
            $groupFailures++
            $results.Errors += "Role assignment helper failed for tenant ${tenantForHelper}: $($_.Exception.Message)"
            Write-WarningMsg "Helper script failed for tenant '$tenantForHelper': $($_.Exception.Message)"
        }
    }

    $results.RoleAssignmentHelperTenantIds = @($results.RoleAssignmentHelperTenantIds | Select-Object -Unique)
    $results.RoleAssignmentHelperSubscriptions = @($results.RoleAssignmentHelperSubscriptions | Select-Object -Unique)

    if ($groupFailures -gt 0) {
        $results.RoleAssignmentHelperStatus = "Failed"
        $results.RoleAssignmentHelperMessage = "Helper completed with failures ($groupFailures of $($helperGroups.Count) tenant group(s) failed)."
    }
    else {
        $results.RoleAssignmentHelperStatus = "Completed"
        $results.RoleAssignmentHelperMessage = "Helper script completed for all tenant groups."
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

$helperVerdict = switch ($results.RoleAssignmentHelperStatus) {
    "Completed" { "SUCCESS" }
    "Failed" { "FAILED" }
    "Skipped" { "SKIPPED" }
    default { "NOT-REQUIRED" }
}
switch ($helperVerdict) {
    "SUCCESS" { Write-Success "HELPER RESULT:             $helperVerdict" }
    "FAILED" { Write-ErrorMsg "HELPER RESULT:             $helperVerdict" }
    default { Write-WarningMsg "HELPER RESULT:             $helperVerdict" }
}
if ($results.RoleAssignmentHelperTenantId) {
    Write-Host "HELPER TENANT:             $($results.RoleAssignmentHelperTenantId)"
}
if ($results.RoleAssignmentHelperTenantIds -and $results.RoleAssignmentHelperTenantIds.Count -gt 0) {
    Write-Host "HELPER TENANTS:            $($results.RoleAssignmentHelperTenantIds -join ', ')"
}
Write-Host ""

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
    roleAssignmentHelperInvoked = $results.RoleAssignmentHelperInvoked
    roleAssignmentHelperTenantId = $results.RoleAssignmentHelperTenantId
    roleAssignmentHelperTenantIds = $results.RoleAssignmentHelperTenantIds
    roleAssignmentHelperSubscriptions = $results.RoleAssignmentHelperSubscriptions
    roleAssignmentHelperStatus = $results.RoleAssignmentHelperStatus
    roleAssignmentHelperMessage = $results.RoleAssignmentHelperMessage
    roleAssignmentHelperRoleAssignmentsCreated = $results.RoleAssignmentHelperRoleAssignmentsCreated
    roleAssignmentHelperRoleAssignmentsFailed = $results.RoleAssignmentHelperRoleAssignmentsFailed
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
    Write-Info "A SOURCE TENANT ADMIN should run the helper script (recommended) or this script with -AssignRolesAsSourceAdmin:"
    Write-Host ""
    Write-Success "# ============================================================"
    Write-Success "# COMMAND FOR SOURCE TENANT ADMIN TO RUN:"
    Write-Success "# ============================================================"
    Write-Host ""
    # Build the subscription list for commands
    $subList = ($results.IdentitiesNeedingRoles | Select-Object -ExpandProperty SubscriptionId -Unique) -join "', '"

    Write-Host "# Step 1: Run the helper script (recommended)"
    Write-Host ".\Run-AssignRolesAsSourceAdmin.ps1 -TenantId '<SOURCE-TENANT-ID>' -SubscriptionIds @('$subList')"
    Write-Host ""
    Write-Host "# Step 2 (alternative): Run this script with -AssignRolesAsSourceAdmin parameter"
    Write-Host "Connect-AzAccount -TenantId '<SOURCE-TENANT-ID>'"

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