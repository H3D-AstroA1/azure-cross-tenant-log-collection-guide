<#
.SYNOPSIS
    Updates Azure Lighthouse delegation to include Resource Policy Contributor role.

.DESCRIPTION
    This script safely updates an existing Azure Lighthouse delegation by:
    1. Removing the existing delegation
    2. Re-deploying with the updated roles (including Resource Policy Contributor)
    
    This is required to enable Azure Policy assignments for automatic Azure Monitor Agent
    installation on stopped/new VMs.

.PARAMETER ManagingTenantId
    The Azure tenant ID (GUID) of the managing tenant (Atevet12).

.PARAMETER SecurityGroupObjectId
    The Object ID of the security group in the managing tenant.

.PARAMETER SubscriptionId
    The subscription ID in the source tenant to update delegation for.

.PARAMETER SecurityGroupDisplayName
    Display name for the security group. Default: "Lighthouse-CrossTenant-Admins"

.PARAMETER RegistrationDefinitionName
    Name for the Lighthouse registration definition. Default: "Cross-Tenant Log Collection Delegation"

.PARAMETER Location
    Azure region for the deployment. Default: "westus2"

.EXAMPLE
    .\Update-LighthouseDelegation.ps1 -ManagingTenantId "xxx" -SecurityGroupObjectId "yyy" -SubscriptionId "zzz"

.NOTES
    IMPORTANT: This script must be run from the SOURCE tenant (Atevet17), NOT the managing tenant.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManagingTenantId,

    [Parameter(Mandatory = $true)]
    [string]$SecurityGroupObjectId,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$SecurityGroupDisplayName = "Lighthouse-CrossTenant-Admins",

    [Parameter(Mandatory = $false)]
    [string]$RegistrationDefinitionName = "Cross-Tenant Log Collection Delegation",

    [Parameter(Mandatory = $false)]
    [string]$Location = "westus2"
)

# Color functions
function Write-Success { param($Message) Write-Host $Message -ForegroundColor Green }
function Write-ErrorMsg { param($Message) Write-Host $Message -ForegroundColor Red }
function Write-WarningMsg { param($Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Info { param($Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Header { param($Message) Write-Host $Message -ForegroundColor Cyan -BackgroundColor DarkBlue }

# Role Definition IDs (including the new Resource Policy Contributor)
$roleDefinitions = @{
    "Reader" = "acdd72a7-3385-48ef-bd42-f606fba81ae7"
    "Contributor" = "b24988ac-6180-42a0-ab88-20f7382dd24c"
    "MonitoringReader" = "43d0d8ad-25c7-4714-9337-8ba259a9fe05"
    "LogAnalyticsReader" = "73c42c96-874c-492b-b04d-ab87d138a893"
    "MonitoringContributor" = "749f88d5-cbae-40b8-bcfc-e573ddc772fa"
    "ResourcePolicyContributor" = "36243c78-bf99-498c-9df9-86d9f8d28608"
}

Write-Host ""
Write-Header "======================================================================"
Write-Header "        Update Azure Lighthouse Delegation                            "
Write-Header "        Adding Resource Policy Contributor Role                       "
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
    Write-ErrorMsg "This script must be run from the SOURCE tenant!"
    Write-Host ""
    Write-Info "Please run: Connect-AzAccount -TenantId '<SOURCE-TENANT-ID>'"
    exit 1
}

Write-Success "Confirmed: Running in source tenant (not managing tenant)"
Write-Host ""
#endregion

#region Set Subscription Context
Write-Info "Setting subscription context to: $SubscriptionId"
try {
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    $subName = (Get-AzContext).Subscription.Name
    Write-Success "Subscription: $subName"
}
catch {
    Write-ErrorMsg "Failed to set subscription context: $($_.Exception.Message)"
    exit 1
}
Write-Host ""
#endregion

#region Step 1: Remove Existing Delegation
Write-Header "Step 1: Removing existing Lighthouse delegation..."
Write-Host ""

try {
    $existingAssignments = Get-AzManagedServicesAssignment -ErrorAction SilentlyContinue
    
    if ($existingAssignments) {
        Write-Info "Found $($existingAssignments.Count) existing delegation(s)"
        
        foreach ($assignment in $existingAssignments) {
            Write-Host "  Removing: $($assignment.Name)"
            try {
                Remove-AzManagedServicesAssignment -Name $assignment.Name -ErrorAction Stop
                Write-Success "    Removed successfully"
            }
            catch {
                Write-WarningMsg "    Could not remove: $($_.Exception.Message)"
            }
        }
        
        # Also remove definitions
        $existingDefinitions = Get-AzManagedServicesDefinition -ErrorAction SilentlyContinue
        foreach ($definition in $existingDefinitions) {
            if ($definition.Properties.ManagedByTenantId -eq $ManagingTenantId) {
                Write-Host "  Removing definition: $($definition.Name)"
                try {
                    Remove-AzManagedServicesDefinition -Name $definition.Name -ErrorAction Stop
                    Write-Success "    Removed successfully"
                }
                catch {
                    Write-WarningMsg "    Could not remove: $($_.Exception.Message)"
                }
            }
        }
        
        Write-Host ""
        Write-Info "Waiting 30 seconds for changes to propagate..."
        Start-Sleep -Seconds 30
    }
    else {
        Write-WarningMsg "No existing delegations found"
    }
}
catch {
    Write-WarningMsg "Could not check existing delegations: $($_.Exception.Message)"
}
Write-Host ""
#endregion

#region Step 2: Build New Authorizations
Write-Header "Step 2: Building new authorization roles..."
Write-Host ""

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
    },
    @{
        principalId = $SecurityGroupObjectId
        roleDefinitionId = $roleDefinitions["Contributor"]
        principalIdDisplayName = $SecurityGroupDisplayName
    },
    @{
        principalId = $SecurityGroupObjectId
        roleDefinitionId = $roleDefinitions["ResourcePolicyContributor"]
        principalIdDisplayName = $SecurityGroupDisplayName
    }
)

Write-Success "Roles to be assigned:"
Write-Host "  - Reader"
Write-Host "  - Monitoring Reader"
Write-Host "  - Log Analytics Reader"
Write-Host "  - Contributor"
Write-Success "  - Resource Policy Contributor (NEW)"
Write-Host ""
#endregion

#region Step 3: Create ARM Templates
Write-Header "Step 3: Creating ARM templates..."
Write-Host ""

$definitionTemplate = @{
    '$schema' = "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters = @{
        managedByTenantId = @{
            type = "string"
        }
        registrationDefinitionName = @{
            type = "string"
        }
        authorizations = @{
            type = "array"
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
                description = "Delegates access for cross-tenant log collection with Azure Policy support"
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
    }
}

$assignmentTemplate = @{
    '$schema' = "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters = @{
        registrationDefinitionId = @{
            type = "string"
        }
        registrationAssignmentName = @{
            type = "string"
            defaultValue = "[newGuid()]"
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
}

$tempDir = [System.IO.Path]::GetTempPath()
$definitionTemplatePath = Join-Path $tempDir "lighthouse-definition-template.json"
$assignmentTemplatePath = Join-Path $tempDir "lighthouse-assignment-template.json"

$definitionTemplate | ConvertTo-Json -Depth 20 | Set-Content -Path $definitionTemplatePath -Encoding UTF8
$assignmentTemplate | ConvertTo-Json -Depth 20 | Set-Content -Path $assignmentTemplatePath -Encoding UTF8

Write-Success "Templates created"
Write-Host ""
#endregion

#region Step 4: Deploy New Delegation
Write-Header "Step 4: Deploying new Lighthouse delegation..."
Write-Host ""

try {
    # Deploy Registration Definition
    Write-Info "Deploying registration definition..."
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
    Write-Success "  Definition deployed: $registrationDefinitionId"
    
    # Deploy Registration Assignment
    Write-Info "Deploying registration assignment..."
    $assignDeploymentName = "LighthouseAssignment-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    
    $assignDeployment = New-AzSubscriptionDeployment `
        -Name $assignDeploymentName `
        -Location $Location `
        -TemplateFile $assignmentTemplatePath `
        -registrationDefinitionId $registrationDefinitionId `
        -ErrorAction Stop
    
    Write-Success "  Assignment deployed successfully"
    Write-Success "  Delegation complete!"
}
catch {
    Write-ErrorMsg "Deployment failed: $($_.Exception.Message)"
    exit 1
}
finally {
    # Cleanup temp files
    Remove-Item -Path $definitionTemplatePath -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $assignmentTemplatePath -Force -ErrorAction SilentlyContinue
}
Write-Host ""
#endregion

#region Summary
Write-Host ""
Write-Header "======================================================================"
Write-Header "                              SUMMARY                                 "
Write-Header "======================================================================"
Write-Host ""

Write-Success "Lighthouse delegation updated successfully!"
Write-Host ""
Write-Host "Managing Tenant ID:        $ManagingTenantId"
Write-Host "Security Group Object ID:  $SecurityGroupObjectId"
Write-Host "Subscription ID:           $SubscriptionId"
Write-Host ""
Write-Success "Roles now delegated:"
Write-Host "  - Reader"
Write-Host "  - Monitoring Reader"
Write-Host "  - Log Analytics Reader"
Write-Host "  - Contributor"
Write-Success "  - Resource Policy Contributor (NEW)"
Write-Host ""

Write-Info "=== Next Steps ==="
Write-Host ""
Write-Host "1. Switch to the MANAGING tenant (Atevet12):"
Write-Host "   Connect-AzAccount -TenantId '$ManagingTenantId'"
Write-Host ""
Write-Host "2. Re-run the Configure-VMDiagnosticLogs.ps1 script:"
Write-Host "   .\Configure-VMDiagnosticLogs.ps1 -WorkspaceResourceId '<your-workspace-id>'"
Write-Host ""
Write-Host "3. The Azure Policy assignments should now succeed!"
Write-Host ""
#endregion

<#
================================================================================
                              USAGE EXAMPLES
================================================================================

IMPORTANT: This script must be run from the SOURCE tenant (e.g., Atevet17),
           NOT the managing tenant (e.g., Atevet12).

--------------------------------------------------------------------------------
STEP 1: Connect to the SOURCE tenant
--------------------------------------------------------------------------------

    Connect-AzAccount -TenantId "<SOURCE-TENANT-ID>"

    # Example:
    Connect-AzAccount -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

--------------------------------------------------------------------------------
STEP 2: Run the Update-LighthouseDelegation script
--------------------------------------------------------------------------------

    .\Update-LighthouseDelegation.ps1 `
        -ManagingTenantId "<MANAGING-TENANT-ID>" `
        -SecurityGroupObjectId "<SECURITY-GROUP-OBJECT-ID>" `
        -SubscriptionId "<SUBSCRIPTION-ID-TO-DELEGATE>"

    # Example with actual values:
    .\Update-LighthouseDelegation.ps1 `
        -ManagingTenantId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
        -SecurityGroupObjectId "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz" `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

--------------------------------------------------------------------------------
STEP 3: After delegation is updated, switch to the MANAGING tenant
--------------------------------------------------------------------------------

    Connect-AzAccount -TenantId "<MANAGING-TENANT-ID>"

    # Example:
    Connect-AzAccount -TenantId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"

--------------------------------------------------------------------------------
STEP 4: Re-run the Configure-VMDiagnosticLogs script
--------------------------------------------------------------------------------

    .\Configure-VMDiagnosticLogs.ps1 `
        -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/<RG>/providers/Microsoft.OperationalInsights/workspaces/<WORKSPACE-NAME>"

    # Example:
    .\Configure-VMDiagnosticLogs.ps1 `
        -WorkspaceResourceId "/subscriptions/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central"

--------------------------------------------------------------------------------
OPTIONAL: Custom security group display name
--------------------------------------------------------------------------------

    .\Update-LighthouseDelegation.ps1 `
        -ManagingTenantId "<MANAGING-TENANT-ID>" `
        -SecurityGroupObjectId "<SECURITY-GROUP-OBJECT-ID>" `
        -SubscriptionId "<SUBSCRIPTION-ID>" `
        -SecurityGroupDisplayName "My-Custom-Lighthouse-Group"

--------------------------------------------------------------------------------
OPTIONAL: Custom registration definition name
--------------------------------------------------------------------------------

    .\Update-LighthouseDelegation.ps1 `
        -ManagingTenantId "<MANAGING-TENANT-ID>" `
        -SecurityGroupObjectId "<SECURITY-GROUP-OBJECT-ID>" `
        -SubscriptionId "<SUBSCRIPTION-ID>" `
        -RegistrationDefinitionName "Custom Log Collection Delegation"

================================================================================
#>
