<#
.SYNOPSIS
    Updates Azure Lighthouse delegation to include User Access Administrator role.

.DESCRIPTION
    This script updates the existing Lighthouse delegation to add the User Access Administrator
    role as an ELIGIBLE authorization (requires PIM activation).
    
    User Access Administrator is a privileged role that Azure Lighthouse requires to be
    added as an eligible authorization, not a permanent authorization.

.NOTES
    Run this script from the SOURCE tenant (Atevet17).
#>

# Configuration
$ManagingTenantId = 'a9e9e819-a3f8-4d7c-9b7a-1f6e5e4c8b2a'
$SecurityGroupObjectId = '777edd15-52a1-4669-938a-f9b7ea7d3c6e'
$SecurityGroupDisplayName = 'Lighthouse-CrossTenant-Admins'
$SourceSubscriptionId = '9b00bc5e-9abc-45de-9958-02a9d9277b16'
$Location = 'westus2'
$RegistrationDefinitionName = 'Cross-Tenant Log Collection Delegation'

# Role Definition IDs
$roleDefinitions = @{
    'Reader' = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    'Contributor' = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
    'MonitoringReader' = '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
    'LogAnalyticsReader' = '73c42c96-874c-492b-b04d-ab87d138a893'
    'MonitoringContributor' = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
    'ResourcePolicyContributor' = '36243c78-bf99-498c-9df9-86d9f8d28608'
    'UserAccessAdministrator' = '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'
}

Write-Host ""
Write-Host "=== Update Azure Lighthouse Delegation ===" -ForegroundColor Cyan
Write-Host "Adding User Access Administrator as ELIGIBLE authorization" -ForegroundColor Cyan
Write-Host ""

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Managing Tenant ID: $ManagingTenantId"
Write-Host "  Security Group ID: $SecurityGroupObjectId"
Write-Host "  Source Subscription ID: $SourceSubscriptionId"
Write-Host ""

Write-Host "Roles to be assigned:" -ForegroundColor Yellow
Write-Host "  Permanent Authorizations:"
Write-Host "    - Reader"
Write-Host "    - Monitoring Reader"
Write-Host "    - Log Analytics Reader"
Write-Host "    - Contributor"
Write-Host "    - Resource Policy Contributor"
Write-Host "  Eligible Authorizations (requires PIM activation):" -ForegroundColor Green
Write-Host "    - User Access Administrator (NEW)" -ForegroundColor Green
Write-Host "      Can assign: Contributor, Monitoring Contributor" -ForegroundColor DarkGray
Write-Host ""

# Check current context
$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Host "Not connected to Azure. Please run:" -ForegroundColor Red
    Write-Host "  Connect-AzAccount -TenantId '3cd87a41-1f61-4aef-a212-cefdecd9a2d1'" -ForegroundColor Yellow
    exit 1
}

Write-Host "Current Context:" -ForegroundColor Yellow
Write-Host "  Account: $($context.Account.Id)"
Write-Host "  Tenant: $($context.Tenant.Id)"
Write-Host ""

# Set subscription context
Write-Host "Setting subscription context..." -ForegroundColor Yellow
Set-AzContext -SubscriptionId $SourceSubscriptionId -ErrorAction Stop | Out-Null
Write-Host "  Subscription: $((Get-AzContext).Subscription.Name)" -ForegroundColor Green
Write-Host ""

# Create ARM template with eligibleAuthorizations for User Access Administrator
# This is the correct way to add privileged roles in Azure Lighthouse
$templateJson = @"
{
    "`$schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "managedByTenantId": {
            "type": "string"
        },
        "registrationDefinitionName": {
            "type": "string"
        }
    },
    "variables": {
        "definitionGuid": "[guid(concat(parameters('managedByTenantId'), '-', parameters('registrationDefinitionName')))]"
    },
    "resources": [
        {
            "type": "Microsoft.ManagedServices/registrationDefinitions",
            "apiVersion": "2022-10-01",
            "name": "[variables('definitionGuid')]",
            "properties": {
                "registrationDefinitionName": "[parameters('registrationDefinitionName')]",
                "description": "Delegates access for cross-tenant log collection with User Access Administrator (eligible)",
                "managedByTenantId": "[parameters('managedByTenantId')]",
                "authorizations": [
                    {
                        "principalId": "$SecurityGroupObjectId",
                        "roleDefinitionId": "$($roleDefinitions['Reader'])",
                        "principalIdDisplayName": "$SecurityGroupDisplayName"
                    },
                    {
                        "principalId": "$SecurityGroupObjectId",
                        "roleDefinitionId": "$($roleDefinitions['MonitoringReader'])",
                        "principalIdDisplayName": "$SecurityGroupDisplayName"
                    },
                    {
                        "principalId": "$SecurityGroupObjectId",
                        "roleDefinitionId": "$($roleDefinitions['LogAnalyticsReader'])",
                        "principalIdDisplayName": "$SecurityGroupDisplayName"
                    },
                    {
                        "principalId": "$SecurityGroupObjectId",
                        "roleDefinitionId": "$($roleDefinitions['Contributor'])",
                        "principalIdDisplayName": "$SecurityGroupDisplayName"
                    },
                    {
                        "principalId": "$SecurityGroupObjectId",
                        "roleDefinitionId": "$($roleDefinitions['ResourcePolicyContributor'])",
                        "principalIdDisplayName": "$SecurityGroupDisplayName"
                    }
                ],
                "eligibleAuthorizations": [
                    {
                        "principalId": "$SecurityGroupObjectId",
                        "roleDefinitionId": "$($roleDefinitions['UserAccessAdministrator'])",
                        "principalIdDisplayName": "$SecurityGroupDisplayName",
                        "justInTimeAccessPolicy": {
                            "multiFactorAuthProvider": "None",
                            "maximumActivationDuration": "PT8H"
                        }
                    }
                ]
            }
        }
    ],
    "outputs": {
        "registrationDefinitionId": {
            "type": "string",
            "value": "[resourceId('Microsoft.ManagedServices/registrationDefinitions', variables('definitionGuid'))]"
        }
    }
}
"@

# Save template to temp file
$tempPath = [System.IO.Path]::GetTempPath()
$templatePath = Join-Path $tempPath 'lighthouse-update-template.json'
$templateJson | Set-Content -Path $templatePath -Encoding UTF8

Write-Host "Template saved to: $templatePath" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Deploying updated Lighthouse registration definition..." -ForegroundColor Yellow
$deploymentName = "LighthouseUpdate-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

try {
    $deployment = New-AzSubscriptionDeployment `
        -Name $deploymentName `
        -Location $Location `
        -TemplateFile $templatePath `
        -managedByTenantId $ManagingTenantId `
        -registrationDefinitionName $RegistrationDefinitionName `
        -ErrorAction Stop
    
    Write-Host ""
    Write-Host "Deployment successful!" -ForegroundColor Green
    Write-Host "  Deployment Name: $deploymentName"
    Write-Host "  Registration Definition ID: $($deployment.Outputs.registrationDefinitionId.Value)"
    Write-Host ""
    
    # Verify the update
    Write-Host "Verifying Lighthouse definition..." -ForegroundColor Yellow
    Start-Sleep -Seconds 5  # Wait for propagation
    
    $definitions = Get-AzManagedServicesDefinition -ErrorAction SilentlyContinue
    $matchingDef = $definitions | Where-Object { $_.Properties.ManagedByTenantId -eq $ManagingTenantId }
    
    if ($matchingDef) {
        Write-Host "  Definition found!" -ForegroundColor Green
        Write-Host "  Permanent Authorizations:"
        foreach ($auth in $matchingDef.Properties.Authorizations) {
            $roleName = switch ($auth.RoleDefinitionId) {
                'acdd72a7-3385-48ef-bd42-f606fba81ae7' { 'Reader' }
                'b24988ac-6180-42a0-ab88-20f7382dd24c' { 'Contributor' }
                '43d0d8ad-25c7-4714-9337-8ba259a9fe05' { 'Monitoring Reader' }
                '73c42c96-874c-492b-b04d-ab87d138a893' { 'Log Analytics Reader' }
                '36243c78-bf99-498c-9df9-86d9f8d28608' { 'Resource Policy Contributor' }
                '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9' { 'User Access Administrator' }
                default { $auth.RoleDefinitionId }
            }
            Write-Host "    - $roleName"
        }
        
        if ($matchingDef.Properties.EligibleAuthorizations) {
            Write-Host "  Eligible Authorizations (PIM):" -ForegroundColor Green
            foreach ($auth in $matchingDef.Properties.EligibleAuthorizations) {
                $roleName = switch ($auth.RoleDefinitionId) {
                    '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9' { 'User Access Administrator' }
                    default { $auth.RoleDefinitionId }
                }
                Write-Host "    - $roleName (requires activation)" -ForegroundColor Green
            }
        }
    }
    
} catch {
    Write-Host ""
    Write-Host "Deployment failed:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    
    # Try to get more details
    Write-Host ""
    Write-Host "Attempting to get detailed error..." -ForegroundColor Yellow
    try {
        $operations = Get-AzSubscriptionDeploymentOperation -DeploymentName $deploymentName -ErrorAction SilentlyContinue
        foreach ($op in $operations) {
            if ($op.ProvisioningState -eq 'Failed') {
                Write-Host "Error Details:" -ForegroundColor Red
                $msg = $op.StatusMessage | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($msg.error) {
                    Write-Host "  Code: $($msg.error.code)" -ForegroundColor Red
                    Write-Host "  Message: $($msg.error.message)" -ForegroundColor Red
                    if ($msg.error.details) {
                        foreach ($detail in $msg.error.details) {
                            Write-Host "  Detail: $($detail.code) - $($detail.message)" -ForegroundColor Red
                        }
                    }
                }
            }
        }
    } catch {
        Write-Host "Could not retrieve detailed error information." -ForegroundColor Yellow
    }
}

# Cleanup
Remove-Item -Path $templatePath -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== Next Steps ===" -ForegroundColor Cyan
Write-Host "1. If using eligible authorization, activate User Access Administrator via PIM when needed"
Write-Host "2. Re-run Configure-VMDiagnosticLogs.ps1 to create policy assignments"
Write-Host "3. The script will be able to assign Contributor role to managed identities"
Write-Host ""
