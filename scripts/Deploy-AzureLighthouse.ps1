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
    [string]$SecurityGroupDisplayName = "Atevet17-Management-Group",

    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$RegistrationDefinitionName = "Atevet17-adaptgbmgthdfeb26 Logs Delegation",

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
function Write-WarningMsg { param($Message) Write-Host $Message -ForegroundColor Yellow }
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
    # User Access Administrator requires delegatedRoleDefinitionIds to specify which roles can be assigned.
    # This prevents unlimited role assignment capability via Lighthouse.
    $authorizations += @{
        principalId = $SecurityGroupObjectId
        roleDefinitionId = $roleDefinitions["UserAccessAdministrator"]
        principalIdDisplayName = $SecurityGroupDisplayName
        delegatedRoleDefinitionIds = @(
            $roleDefinitions["Contributor"],
            $roleDefinitions["MonitoringContributor"],
            $roleDefinitions["MonitoringReader"],
            $roleDefinitions["LogAnalyticsReader"]
        )
    }
    Write-Success "  Including User Access Administrator role (for assigning roles to policy managed identities)"
    Write-Info "    Limited to assigning: Contributor, Monitoring Contributor, Monitoring Reader, Log Analytics Reader"
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

        # If an assignment already exists at this subscription scope, do not try to create another.
        # Azure Lighthouse allows only one registration assignment per subscription.
        $existingAssignments = Get-AzManagedServicesAssignment -ErrorAction SilentlyContinue
        if ($existingAssignments) {
            $assignmentForThisDefinition = $existingAssignments | Where-Object {
                $existingDefId = $null
                if ($null -ne $_.Properties -and $null -ne $_.Properties.RegistrationDefinitionId) {
                    $existingDefId = $_.Properties.RegistrationDefinitionId
                }
                elseif ($null -ne $_.RegistrationDefinitionId) {
                    $existingDefId = $_.RegistrationDefinitionId
                }

                $existingDefId -eq $registrationDefinitionId
            } | Select-Object -First 1

            if ($assignmentForThisDefinition) {
                Write-Success "  Assignment already exists for this definition. Skipping assignment deployment."
                Write-Success "  ✓ Delegation complete for $subName"
                $results.SubscriptionsSucceeded += $subId
                continue
            }

            $existingAssignmentIds = @(
                $existingAssignments | ForEach-Object {
                    if ($null -ne $_.Id) { $_.Id } else { $null }
                } | Where-Object { $_ }
            )
            $existingAssignmentIdsText = ($existingAssignmentIds -join '; ')
            throw "Another registration assignment already exists at this subscription scope. Remove the existing assignment(s) first: $existingAssignmentIdsText"
        }
        
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
                $defManagedByTenantId = $null
                if ($null -ne $_.Properties -and $null -ne $_.Properties.ManagedByTenantId) {
                    $defManagedByTenantId = $_.Properties.ManagedByTenantId
                }
                elseif ($null -ne $_.ManagedByTenantId) {
                    $defManagedByTenantId = $_.ManagedByTenantId
                }

                $defManagedByTenantId -eq $ManagingTenantId
            }
            
            if ($matchingDef) {
                Write-Success "  ✓ Verified: $subId"
            }
            else {
                Write-Warning "  ⚠ Could not verify matching Lighthouse definition for managing tenant: $ManagingTenantId"
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