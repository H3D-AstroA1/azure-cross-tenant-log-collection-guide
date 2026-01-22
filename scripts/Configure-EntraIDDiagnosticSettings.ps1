<#
.SYNOPSIS
    Configures Microsoft Entra ID diagnostic settings from the managing tenant using ARM templates.

.DESCRIPTION
    Step 6 of the Azure Cross-Tenant Log Collection Guide. This script runs from the MANAGING TENANT
    and configures Entra ID diagnostic settings in source tenants to send logs to a central
    Log Analytics workspace.
    
    Uses embedded ARM templates for:
    - Entra ID diagnostic settings deployment
    
    The script performs:
    1. Connects to source tenant with Global Admin credentials
    2. Deploys Entra ID diagnostic settings via ARM template
    3. Stores configuration in Key Vault for tracking
    4. Verifies log flow
    
    IMPORTANT: Requires Global Administrator access to the SOURCE tenant.
    Unlike M365 logs, Entra ID logs are PUSHED directly via diagnostic settings (no runbook needed).

.PARAMETER ManagingTenantId
    The Tenant ID of the managing tenant (where Log Analytics workspace exists).

.PARAMETER SourceTenantId
    The Tenant ID of the source tenant (where Entra ID logs originate).

.PARAMETER SourceTenantName
    A friendly name for the source tenant.

.PARAMETER KeyVaultName
    The name of the Key Vault in the managing tenant to store configuration.
    Use this parameter to specify which Key Vault to use when multiple exist.
    Default Key Vault name from Step 1: "kv-central-logging"
    If not specified, the script will auto-discover Key Vaults in the resource group:
    - If one Key Vault is found, it will be used automatically
    - If multiple Key Vaults are found, the script will list them and exit (use -KeyVaultName to select)

.PARAMETER WorkspaceResourceId
    The full resource ID of the Log Analytics workspace in the managing tenant.

.PARAMETER DiagnosticSettingName
    Name for the diagnostic setting. Default: "SendEntraLogsToManagingTenant"

.PARAMETER LogCategories
    Array of Entra ID log categories to enable. Default: All available categories.

.PARAMETER SkipKeyVaultUpdate
    If specified, skips updating the Key Vault tenant tracking.

.PARAMETER SkipDiagnosticSettings
    If specified, skips the diagnostic settings configuration and only updates Key Vault tracking.
    Use this after manually configuring diagnostic settings via Azure Portal.
    This is the RECOMMENDED approach for cross-tenant scenarios since all automated methods fail.

.PARAMETER VerifyOnly
    If specified, only verifies existing configuration without making changes.

.EXAMPLE
    # Full setup: Configure Entra ID diagnostic settings
    .\Configure-EntraIDDiagnosticSettings.ps1 `
        -ManagingTenantId "<ATEVET12-TENANT-ID>" `
        -SourceTenantId "<ATEVET17-TENANT-ID>" `
        -SourceTenantName "Atevet17" `
        -KeyVaultName "kv-central-atevet12" `
        -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

.EXAMPLE
    # Configure with specific log categories only (P1 license)
    .\Configure-EntraIDDiagnosticSettings.ps1 `
        -ManagingTenantId "<ATEVET12-TENANT-ID>" `
        -SourceTenantId "<ATEVET17-TENANT-ID>" `
        -SourceTenantName "Atevet17" `
        -KeyVaultName "kv-central-atevet12" `
        -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
        -LogCategories @("AuditLogs", "SignInLogs", "NonInteractiveUserSignInLogs")

.NOTES
    Author: Azure Cross-Tenant Log Collection Guide
    Version: 2.3
    Requires: Az.Accounts, Az.KeyVault, Az.Resources PowerShell modules
    
    Key difference from Step 7 (M365):
    - Entra ID logs are PUSHED directly via diagnostic settings
    - No runbook/polling needed - logs flow automatically once configured
    
    Prerequisites:
    - Key Vault must exist in the managing tenant (created in Step 1)
    - Az.KeyVault module must be installed
    
    Key Vault Handling:
    - If -KeyVaultName is specified, that Key Vault is used directly
    - If not specified, auto-discovers Key Vaults in the resource group
    - If multiple Key Vaults exist, lists them and exits (re-run with -KeyVaultName to select)
    
    Deployment Methods Attempted (in order):
    1. Direct REST API from SOURCE tenant using Invoke-AzRestMethod
    2. Direct REST with explicit token using Invoke-RestMethod
    3. Cross-tenant auxiliary token (x-ms-authorization-auxiliary header)
    4. Lighthouse delegation from MANAGING tenant with x-ms-tenant-id header
    5. ARM Template deployment at tenant scope using New-AzTenantDeployment
    6. Microsoft Graph API check (not supported - diagnostic settings are ARM only)
    
    IMPORTANT: Cross-tenant diagnostic settings (workspace in different tenant)
    WILL FAIL with LinkedAuthorizationFailed error. This is a known Azure API
    limitation - the microsoft.aadiam API does not support cross-tenant workspace
    references via any programmatic method (REST API, ARM templates, or auxiliary tokens).
    
    The Azure Portal UI is the ONLY method that works for cross-tenant scenarios
    because it uses interactive session tokens that can authenticate to both tenants.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ManagingTenantId,
    [Parameter(Mandatory)][string]$SourceTenantId,
    [Parameter(Mandatory)][string]$SourceTenantName,
    [Parameter(Mandatory=$false)][string]$KeyVaultName,
    [Parameter(Mandatory)][string]$WorkspaceResourceId,
    [string]$DiagnosticSettingName = "SendEntraLogsToManagingTenant",
    [string[]]$LogCategories = @(
        "AuditLogs",
        "SignInLogs",
        "NonInteractiveUserSignInLogs",
        "ServicePrincipalSignInLogs",
        "ManagedIdentitySignInLogs",
        "ProvisioningLogs",
        "ADFSSignInLogs",
        "RiskyUsers",
        "UserRiskEvents",
        "RiskyServicePrincipals",
        "ServicePrincipalRiskEvents",
        "EnrichedOffice365AuditLogs",
        "MicrosoftGraphActivityLogs",
        "NetworkAccessTrafficLogs"
    ),
    [switch]$SkipKeyVaultUpdate,
    [switch]$SkipDiagnosticSettings,
    [switch]$VerifyOnly
)

#region Embedded ARM Template - Entra ID Diagnostic Settings
$armTemplateEntraIDDiagnostics = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "diagnosticSettingName": {
            "type": "string",
            "metadata": {
                "description": "Name of the diagnostic setting"
            }
        },
        "workspaceResourceId": {
            "type": "string",
            "metadata": {
                "description": "Full resource ID of the Log Analytics workspace"
            }
        },
        "logCategories": {
            "type": "array",
            "metadata": {
                "description": "Array of log category names to enable"
            }
        }
    },
    "variables": {
        "logs": {
            "copy": [
                {
                    "name": "logSettings",
                    "count": "[length(parameters('logCategories'))]",
                    "input": {
                        "category": "[parameters('logCategories')[copyIndex('logSettings')]]",
                        "enabled": true
                    }
                }
            ]
        }
    },
    "resources": [
        {
            "type": "microsoft.aadiam/diagnosticSettings",
            "apiVersion": "2017-04-01",
            "name": "[parameters('diagnosticSettingName')]",
            "properties": {
                "workspaceId": "[parameters('workspaceResourceId')]",
                "logs": "[variables('logs').logSettings]"
            }
        }
    ],
    "outputs": {
        "diagnosticSettingId": {
            "type": "string",
            "value": "[resourceId('microsoft.aadiam/diagnosticSettings', parameters('diagnosticSettingName'))]"
        }
    }
}
'@
#endregion

#region Helper Functions
function Write-Log([string]$Message, [string]$Level="Info") {
    $colors = @{Info="Cyan";Success="Green";Warning="Yellow";Error="Red"}
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message" -ForegroundColor $colors[$Level]
}

function Deploy-ArmTemplateToTenant($Template, $Parameters, $DeploymentName) {
    $tempFile = [IO.Path]::GetTempFileName() + ".json"
    $Template | Out-File $tempFile -Encoding UTF8
    try {
        # Deploy at tenant scope (no resource group for Entra ID diagnostic settings)
        return New-AzDeployment -Location "uksouth" -TemplateFile $tempFile -TemplateParameterObject $Parameters -Name $DeploymentName -ErrorAction Stop
    } finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-ValidLogCategories($RequestedCategories) {
    # Define which categories require which license
    $licenseRequirements = @{
        "Free" = @("AuditLogs")
        "P1" = @("SignInLogs", "NonInteractiveUserSignInLogs", "ServicePrincipalSignInLogs", "ManagedIdentitySignInLogs", "ProvisioningLogs", "ADFSSignInLogs", "MicrosoftGraphActivityLogs", "NetworkAccessTrafficLogs")
        "P2" = @("RiskyUsers", "UserRiskEvents", "RiskyServicePrincipals", "ServicePrincipalRiskEvents")
        "E5" = @("EnrichedOffice365AuditLogs")
    }
    
    Write-Log "Requested log categories:" -Level Info
    foreach($cat in $RequestedCategories) {
        $license = "Unknown"
        foreach($lic in $licenseRequirements.Keys) {
            if($licenseRequirements[$lic] -contains $cat) { $license = $lic; break }
        }
        Write-Log "  - $cat (requires: $license)" -Level Info
    }
    
    return $RequestedCategories
}
#endregion

#region Main Script
Write-Log "========================================" -Level Info
Write-Log "Step 6: Configure Microsoft Entra ID Logs" -Level Info
Write-Log "========================================" -Level Info
Write-Log "" -Level Info
Write-Log "This script runs from the MANAGING TENANT but configures" -Level Info
Write-Log "diagnostic settings in the SOURCE TENANT." -Level Info
Write-Log "" -Level Info
Write-Log "╔══════════════════════════════════════════════════════════════════════╗" -Level Info
Write-Log "║  TENANT AND SUBSCRIPTION CONTEXT OVERVIEW                            ║" -Level Info
Write-Log "╚══════════════════════════════════════════════════════════════════════╝" -Level Info
Write-Log "" -Level Info
Write-Log "  MANAGING TENANT: $ManagingTenantId" -Level Info
Write-Log "    - Contains: Key Vault, Log Analytics Workspace" -Level Info
Write-Log "    - Subscription: (parsed from WorkspaceResourceId)" -Level Info
Write-Log "" -Level Info
Write-Log "  SOURCE TENANT: $SourceTenantId ($SourceTenantName)" -Level Info
Write-Log "    - Contains: Entra ID logs to be collected" -Level Info
Write-Log "    - Diagnostic settings will be created HERE" -Level Info
Write-Log "" -Level Info
Write-Log "  The script will:" -Level Info
Write-Log "    1. Connect to MANAGING tenant to update Key Vault tracking" -Level Info
Write-Log "    2. Connect to SOURCE tenant to create diagnostic settings" -Level Info
Write-Log "    3. Attempt cross-tenant deployment (workspace in managing tenant)" -Level Info
Write-Log "" -Level Info

# Parse workspace resource ID
$subscriptionId = $null
if($WorkspaceResourceId -match "/subscriptions/([^/]+)/resourceGroups/([^/]+)/.*workspaces/([^/]+)") {
    $subscriptionId = $Matches[1]
    $resourceGroupName = $Matches[2]
    $workspaceName = $Matches[3]
}

# Validate log categories
$validCategories = Get-ValidLogCategories -RequestedCategories $LogCategories

#region Check Prerequisites
Write-Log "" -Level Info
Write-Log "Checking prerequisites..." -Level Info

# Check Az.KeyVault module
$keyVaultModule = Get-Module -ListAvailable Az.KeyVault -ErrorAction SilentlyContinue
if(-not $keyVaultModule) {
    Write-Log "Az.KeyVault module is not installed" -Level Error
    Write-Log "Install it with: Install-Module Az.KeyVault -Scope CurrentUser" -Level Error
    exit 1
}
Write-Log "  Az.KeyVault module: Installed" -Level Success

# Connect to managing tenant to check Key Vault
$ctx = Get-AzContext
if(-not $ctx -or $ctx.Tenant.Id -ne $ManagingTenantId) {
    Write-Log "Connecting to managing tenant ($ManagingTenantId)..." -Level Info
    Connect-AzAccount -TenantId $ManagingTenantId -ErrorAction Stop
}
Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null

# Handle Key Vault discovery/selection
$keyVault = $null

if($KeyVaultName) {
    # User specified a Key Vault name - use it directly
    $keyVault = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction SilentlyContinue
    if(-not $keyVault) {
        Write-Log "Key Vault '$KeyVaultName' not found in subscription $subscriptionId" -Level Error
        Write-Log "" -Level Error
        Write-Log "The Key Vault should have been created in Step 1 (Prepare-ManagingTenant.ps1)." -Level Error
        Write-Log "Please ensure you have:" -Level Error
        Write-Log "  1. Run Step 1 to create the Key Vault" -Level Error
        Write-Log "  2. Specified the correct Key Vault name" -Level Error
        Write-Log "  3. Access to the subscription containing the Key Vault" -Level Error
        exit 1
    }
} else {
    # No Key Vault specified - discover Key Vaults in the resource group
    Write-Log "No Key Vault name specified. Discovering Key Vaults in resource group '$resourceGroupName'..." -Level Info
    
    $keyVaults = Get-AzKeyVault -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
    
    if(-not $keyVaults -or $keyVaults.Count -eq 0) {
        Write-Log "No Key Vaults found in resource group '$resourceGroupName'" -Level Error
        Write-Log "" -Level Error
        Write-Log "The Key Vault should have been created in Step 1 (Prepare-ManagingTenant.ps1)." -Level Error
        Write-Log "Please either:" -Level Error
        Write-Log "  1. Run Step 1 to create the Key Vault" -Level Error
        Write-Log "  2. Specify the Key Vault name with -KeyVaultName parameter" -Level Error
        Write-Log "" -Level Error
        Write-Log "To create the Key Vault manually:" -Level Error
        Write-Log "  New-AzKeyVault -VaultName 'kv-central-logging' -ResourceGroupName '$resourceGroupName' -Location '<location>' -EnableRbacAuthorization" -Level Error
        exit 1
    }
    elseif($keyVaults.Count -eq 1) {
        # Only one Key Vault found - use it
        $keyVault = $keyVaults[0]
        $KeyVaultName = $keyVault.VaultName
        Write-Log "Found single Key Vault: $KeyVaultName" -Level Success
    }
    else {
        # Multiple Key Vaults found - list them and exit with instructions
        Write-Log "Found $($keyVaults.Count) Key Vaults in resource group '$resourceGroupName':" -Level Error
        Write-Log "" -Level Info
        
        foreach($kv in $keyVaults) {
            Write-Log "  - $($kv.VaultName)" -Level Info
        }
        Write-Log "" -Level Error
        Write-Log "Multiple Key Vaults found. Please specify which one to use with the -KeyVaultName parameter." -Level Error
        Write-Log "" -Level Info
        Write-Log "Example:" -Level Info
        Write-Log "  .\Configure-EntraIDDiagnosticSettings.ps1 -KeyVaultName '$($keyVaults[0].VaultName)' ..." -Level Info
        exit 1
    }
}

Write-Log "  Key Vault '$KeyVaultName': Found" -Level Success
Write-Log "    Resource ID: $($keyVault.ResourceId)" -Level Info
Write-Log "    URI: $($keyVault.VaultUri)" -Level Info
#endregion

# Step 1: Connect to Managing Tenant and update Key Vault
if(-not $SkipKeyVaultUpdate -and -not $VerifyOnly) {
    Write-Log "" -Level Info
    Write-Log "════════════════════════════════════════════════════════════════════════" -Level Info
    Write-Log "Step 1: Updating tenant tracking in Key Vault" -Level Info
    Write-Log "════════════════════════════════════════════════════════════════════════" -Level Info
    Write-Log "" -Level Info
    Write-Log "  ACTION: Connect to MANAGING TENANT" -Level Warning
    Write-Log "  Tenant ID: $ManagingTenantId" -Level Info
    Write-Log "  Subscription: $subscriptionId" -Level Info
    Write-Log "  Purpose: Update Key Vault with source tenant tracking info" -Level Info
    Write-Log "" -Level Info
    
    $ctx = Get-AzContext
    if(-not $ctx -or $ctx.Tenant.Id -ne $ManagingTenantId) {
        Write-Log "  → Connecting to managing tenant..." -Level Info
        Connect-AzAccount -TenantId $ManagingTenantId -ErrorAction Stop
    }
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
    Write-Log "  ✓ Connected to managing tenant, subscription: $subscriptionId" -Level Success
    
    # Update tenants list in Key Vault
    $tenantsSecretName = "EntraID-ConfiguredTenants"
    try {
        $existingJson = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $tenantsSecretName -AsPlainText -ErrorAction SilentlyContinue
        if($existingJson) { $cfg = $existingJson | ConvertFrom-Json } else { $cfg = @{tenants=@()} }
    } catch { $cfg = @{tenants=@()} }
    if(-not $cfg) { $cfg = @{tenants=@()} }
    
    if(-not ($cfg.tenants | Where-Object {$_.tenantId -eq $SourceTenantId})) {
        $cfg.tenants += @{
            tenantId = $SourceTenantId
            name = $SourceTenantName
            configuredDate = (Get-Date -Format "yyyy-MM-dd")
            diagnosticSettingName = $DiagnosticSettingName
            logCategories = $validCategories
        }
        Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $tenantsSecretName -SecretValue (ConvertTo-SecureString ($cfg | ConvertTo-Json -Depth 5) -AsPlainText -Force) -ErrorAction Stop | Out-Null
        Write-Log "Added $SourceTenantName to configured tenants list" -Level Success
    } else {
        Write-Log "$SourceTenantName already in configured tenants list" -Level Info
    }
}

# Check if we should skip diagnostic settings configuration
if($SkipDiagnosticSettings) {
    Write-Log "" -Level Info
    Write-Log "════════════════════════════════════════════════════════════════════════" -Level Info
    Write-Log "SKIP DIAGNOSTIC SETTINGS MODE" -Level Warning
    Write-Log "════════════════════════════════════════════════════════════════════════" -Level Info
    Write-Log "" -Level Info
    Write-Log "  -SkipDiagnosticSettings was specified." -Level Info
    Write-Log "  Key Vault tracking has been updated (if not skipped)." -Level Info
    Write-Log "" -Level Info
    Write-Log "  For cross-tenant scenarios, configure diagnostic settings via Azure Portal:" -Level Warning
    Write-Log "    1. Open: https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/DiagnosticSettings" -Level Info
    Write-Log "    2. Sign in as Global Admin of SOURCE tenant ($SourceTenantName)" -Level Info
    Write-Log "    3. Click '+ Add diagnostic setting'" -Level Info
    Write-Log "    4. Name: $DiagnosticSettingName" -Level Info
    Write-Log "    5. Select log categories" -Level Info
    Write-Log "    6. Check 'Send to Log Analytics workspace'" -Level Info
    Write-Log "    7. Click 'Change directory' to select MANAGING tenant" -Level Info
    Write-Log "    8. Select workspace: $workspaceName" -Level Info
    Write-Log "    9. Click 'Save'" -Level Info
    Write-Log "" -Level Info
    Write-Log "Target workspace details:" -Level Info
    Write-Log "  Workspace Resource ID: $WorkspaceResourceId" -Level Info
    Write-Log "  Workspace Name: $workspaceName" -Level Info
    Write-Log "  Managing Tenant: $ManagingTenantId" -Level Info
    Write-Log "" -Level Success
    Write-Log "Key Vault tracking updated. Configure diagnostic settings via Portal." -Level Success
    exit 0
}

# Step 2: Connect to Source Tenant
Write-Log "" -Level Info
Write-Log "════════════════════════════════════════════════════════════════════════" -Level Info
Write-Log "Step 2: Connecting to SOURCE TENANT" -Level Info
Write-Log "════════════════════════════════════════════════════════════════════════" -Level Info
Write-Log "" -Level Info
Write-Log "  ACTION: Connect to SOURCE TENANT" -Level Warning
Write-Log "  Tenant ID: $SourceTenantId" -Level Info
Write-Log "  Tenant Name: $SourceTenantName" -Level Info
Write-Log "  Purpose: Create Entra ID diagnostic settings in this tenant" -Level Info
Write-Log "" -Level Info
Write-Log "  NOTE: You need Global Administrator role in the SOURCE tenant" -Level Warning
Write-Log "" -Level Info

try {
    Write-Log "  → Connecting to source tenant..." -Level Info
    Connect-AzAccount -TenantId $SourceTenantId -ErrorAction Stop
    Write-Log "  ✓ Connected to source tenant" -Level Success
    
    # Get a subscription in the source tenant to set context
    # This is required for the Azure Management API to work properly
    $sourceSubscriptions = Get-AzSubscription -TenantId $SourceTenantId -ErrorAction SilentlyContinue
    if($sourceSubscriptions -and $sourceSubscriptions.Count -gt 0) {
        $sourceSub = $sourceSubscriptions | Select-Object -First 1
        Set-AzContext -SubscriptionId $sourceSub.Id -TenantId $SourceTenantId -ErrorAction Stop | Out-Null
        Write-Log "  ✓ Set context to subscription: $($sourceSub.Name) ($($sourceSub.Id))" -Level Success
    } else {
        Write-Log "  ⚠ No subscriptions found in source tenant. This may cause issues with API calls." -Level Warning
        Write-Log "    Entra ID diagnostic settings require at least one subscription in the tenant." -Level Warning
    }
} catch {
    Write-Log "  ✗ Failed to connect to source tenant: $($_.Exception.Message)" -Level Error
    Write-Log "    Ensure you have Global Administrator access to $SourceTenantName" -Level Error
    exit 1
}

# Step 3: Check existing diagnostic settings
Write-Log "" -Level Info
Write-Log "════════════════════════════════════════════════════════════════════════" -Level Info
Write-Log "Step 3: Checking existing Entra ID diagnostic settings" -Level Info
Write-Log "════════════════════════════════════════════════════════════════════════" -Level Info
Write-Log "" -Level Info
Write-Log "  CURRENT CONTEXT: SOURCE TENANT" -Level Warning
Write-Log "  Purpose: Query existing diagnostic settings in source tenant's Entra ID" -Level Info
Write-Log "" -Level Info

# Verify the current context is for the correct tenant
$currentContext = Get-AzContext
Write-Log "  Current context:" -Level Info
Write-Log "    Tenant: $($currentContext.Tenant.Id)" -Level Info
Write-Log "    Subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))" -Level Info

if($currentContext.Tenant.Id -ne $SourceTenantId) {
    Write-Log "Context is for wrong tenant! Expected: $SourceTenantId, Got: $($currentContext.Tenant.Id)" -Level Error
    Write-Log "Please ensure you are authenticated to the source tenant." -Level Error
    exit 1
}

# Use Invoke-AzRestMethod which handles authentication automatically and correctly
# This is more reliable than manually getting tokens for cross-tenant scenarios
Write-Log "  Querying Entra ID diagnostic settings using Invoke-AzRestMethod..." -Level Info
$existingSettings = $null
$useAzRestMethod = $true

try {
    # Use the ARM path format for Invoke-AzRestMethod (without the https://management.azure.com prefix)
    $apiPath = "/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01"
    $response = Invoke-AzRestMethod -Path $apiPath -Method GET -ErrorAction Stop
    
    if($response.StatusCode -eq 200) {
        $existingSettings = ($response.Content | ConvertFrom-Json).value
        Write-Log "  Successfully queried diagnostic settings" -Level Success
        
        if($existingSettings -and $existingSettings.Count -gt 0) {
            Write-Log "Found $($existingSettings.Count) existing diagnostic setting(s):" -Level Info
            foreach($setting in $existingSettings) {
                $enabledCategories = ($setting.properties.logs | Where-Object {$_.enabled -eq $true}).category -join ", "
                Write-Log "  - $($setting.name): $enabledCategories" -Level Info
                if($setting.properties.workspaceId -eq $WorkspaceResourceId) {
                    Write-Log "    → Already sending to target workspace" -Level Success
                }
            }
        } else {
            Write-Log "No existing diagnostic settings found" -Level Info
        }
    } else {
        throw "HTTP $($response.StatusCode): $($response.Content)"
    }
} catch {
    $errorMessage = $_.Exception.Message
    Write-Log "Could not check existing settings using Invoke-AzRestMethod: $errorMessage" -Level Warning
    
    # Provide more detailed troubleshooting for 401 errors
    if($errorMessage -like "*401*" -or $errorMessage -like "*Unauthorized*") {
        Write-Log "" -Level Warning
        Write-Log "╔══════════════════════════════════════════════════════════════════════╗" -Level Warning
        Write-Log "║  TROUBLESHOOTING: 401 Unauthorized Error                             ║" -Level Warning
        Write-Log "╚══════════════════════════════════════════════════════════════════════╝" -Level Warning
        Write-Log "" -Level Warning
        Write-Log "This error typically occurs when:" -Level Warning
        Write-Log "  1. You don't have Global Administrator or Security Administrator role" -Level Warning
        Write-Log "  2. The Entra ID diagnostic settings API requires elevated permissions" -Level Warning
        Write-Log "  3. The tenant may not have the required license (P1/P2) for some log categories" -Level Warning
        Write-Log "" -Level Warning
        Write-Log "Current authentication context:" -Level Info
        $ctx = Get-AzContext
        Write-Log "  Account: $($ctx.Account.Id)" -Level Info
        Write-Log "  Tenant: $($ctx.Tenant.Id)" -Level Info
        Write-Log "  Subscription: $($ctx.Subscription.Name) ($($ctx.Subscription.Id))" -Level Info
        Write-Log "" -Level Warning
        Write-Log "IMPORTANT: The microsoft.aadiam/diagnosticSettings API requires:" -Level Warning
        Write-Log "  - Global Administrator OR Security Administrator role in Entra ID" -Level Warning
        Write-Log "  - The role must be ACTIVE (if using PIM, ensure it's activated)" -Level Warning
        Write-Log "" -Level Warning
        Write-Log "To fix this issue:" -Level Warning
        Write-Log "  1. Verify your Entra ID role (not just Azure RBAC role):" -Level Warning
        Write-Log "     https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RolesAndAdministrators" -Level Warning
        Write-Log "  2. If using PIM, activate your Global Administrator role first" -Level Warning
        Write-Log "  3. Try configuring via Azure Portal instead:" -Level Warning
        Write-Log "     https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/DiagnosticSettings" -Level Warning
        Write-Log "" -Level Warning
    }
}

if($VerifyOnly) {
    Write-Log "" -Level Info
    Write-Log "Verify-only mode - no changes made" -Level Info
    exit 0
}

# Step 4: Deploy Entra ID Diagnostic Settings via REST API
Write-Log "" -Level Info
Write-Log "════════════════════════════════════════════════════════════════════════" -Level Info
Write-Log "Step 4: Deploying Entra ID diagnostic settings" -Level Info
Write-Log "════════════════════════════════════════════════════════════════════════" -Level Info
Write-Log "" -Level Info
Write-Log "  CURRENT CONTEXT: SOURCE TENANT ($SourceTenantName)" -Level Warning
Write-Log "  Purpose: Create diagnostic setting to send logs to MANAGING tenant workspace" -Level Info
Write-Log "" -Level Info
Write-Log "  CROSS-TENANT CHALLENGE:" -Level Warning
Write-Log "    - Diagnostic setting is created in SOURCE tenant's Entra ID" -Level Info
Write-Log "    - But the destination workspace is in MANAGING tenant" -Level Info
Write-Log "    - This requires special cross-tenant authorization" -Level Info
Write-Log "" -Level Info

# Check if setting with same name exists
$existingWithSameName = $existingSettings | Where-Object { $_.name -eq $DiagnosticSettingName }
if($existingWithSameName) {
    Write-Log "Diagnostic setting '$DiagnosticSettingName' already exists" -Level Warning
    $response = Read-Host "Do you want to update it? (y/n)"
    if($response -ne 'y') {
        Write-Log "Skipping deployment" -Level Warning
        exit 0
    }
    
    # Delete existing setting first using Invoke-AzRestMethod
    Write-Log "Removing existing diagnostic setting..." -Level Info
    try {
        $deletePath = "/providers/microsoft.aadiam/diagnosticSettings/$DiagnosticSettingName`?api-version=2017-04-01"
        $deleteResponse = Invoke-AzRestMethod -Path $deletePath -Method DELETE -ErrorAction Stop
        if($deleteResponse.StatusCode -in @(200, 202, 204)) {
            Write-Log "Existing setting removed" -Level Success
        } else {
            Write-Log "Delete returned status $($deleteResponse.StatusCode): $($deleteResponse.Content)" -Level Warning
        }
        Start-Sleep -Seconds 5  # Wait for deletion to propagate
    } catch {
        Write-Log "Could not remove existing setting: $($_.Exception.Message)" -Level Warning
    }
}

# Deploy via REST API - Try multiple methods for cross-tenant scenarios
Write-Log "Creating diagnostic setting..." -Level Info

$logsArray = $validCategories | ForEach-Object {
    @{ category = $_; enabled = $true }
}

$body = @{
    properties = @{
        workspaceId = $WorkspaceResourceId
        logs = $logsArray
    }
} | ConvertTo-Json -Depth 10

$createPath = "/providers/microsoft.aadiam/diagnosticSettings/$DiagnosticSettingName`?api-version=2017-04-01"
$deploymentSucceeded = $false

# Method 1: Direct REST API call from SOURCE tenant context
# This is the simplest approach - we're already authenticated to the source tenant
# The API should accept the cross-tenant workspace reference if we have proper permissions
Write-Log "" -Level Info
Write-Log "────────────────────────────────────────────────────────────────────────" -Level Info
Write-Log "Method 1: Direct REST API from SOURCE tenant" -Level Info
Write-Log "────────────────────────────────────────────────────────────────────────" -Level Info
Write-Log "  Strategy: Use current SOURCE tenant context to call Entra ID API" -Level Info
Write-Log "  The workspace resource ID points to the MANAGING tenant" -Level Info
Write-Log "" -Level Info

try {
    # Ensure we're in the source tenant context
    $ctx = Get-AzContext
    if($ctx.Tenant.Id -ne $SourceTenantId) {
        Write-Log "  → Reconnecting to SOURCE tenant..." -Level Info
        Connect-AzAccount -TenantId $SourceTenantId -ErrorAction Stop | Out-Null
        $sourceSubscriptions = Get-AzSubscription -TenantId $SourceTenantId -ErrorAction SilentlyContinue
        if($sourceSubscriptions -and $sourceSubscriptions.Count -gt 0) {
            Set-AzContext -SubscriptionId $sourceSubscriptions[0].Id -TenantId $SourceTenantId -ErrorAction Stop | Out-Null
        }
    }
    
    Write-Log "  Current context: Tenant=$($ctx.Tenant.Id), Account=$($ctx.Account.Id)" -Level Info
    
    if($PSCmdlet.ShouldProcess($DiagnosticSettingName, "Create Diagnostic Setting")) {
        $createResponse = Invoke-AzRestMethod -Path $createPath -Method PUT -Payload $body -ErrorAction Stop
        
        if($createResponse.StatusCode -in @(200, 201)) {
            Write-Log "Diagnostic setting created successfully!" -Level Success
            Write-Log "  Name: $DiagnosticSettingName" -Level Info
            Write-Log "  Destination: $WorkspaceResourceId" -Level Info
            Write-Log "  Categories: $($validCategories -join ', ')" -Level Info
            $deploymentSucceeded = $true
        } else {
            $responseContent = $createResponse.Content
            Write-Log "  Method 1 returned HTTP $($createResponse.StatusCode)" -Level Warning
            
            # Check for specific error types
            if($responseContent -like "*LinkedAuthorizationFailed*") {
                Write-Log "  LinkedAuthorizationFailed: Cannot access workspace in different tenant" -Level Warning
            } elseif($responseContent -like "*AuthorizationFailed*") {
                Write-Log "  AuthorizationFailed: Check permissions on the workspace" -Level Warning
            }
            
            # Parse and show the error message
            try {
                $errorObj = $responseContent | ConvertFrom-Json
                if($errorObj.error.message) {
                    Write-Log "  Error: $($errorObj.error.message)" -Level Warning
                }
            } catch {}
        }
    }
} catch {
    Write-Log "  Method 1 failed: $($_.Exception.Message)" -Level Warning
}

# Method 2: Try with direct REST call using explicit token for both tenants
if(-not $deploymentSucceeded) {
    Write-Log "" -Level Info
    Write-Log "────────────────────────────────────────────────────────────────────────" -Level Info
    Write-Log "Method 2: Direct REST with multi-tenant token" -Level Info
    Write-Log "────────────────────────────────────────────────────────────────────────" -Level Info
    Write-Log "  Strategy: Get token from SOURCE tenant, call ARM API directly" -Level Info
    Write-Log "  This bypasses some PowerShell module limitations" -Level Info
    Write-Log "" -Level Info
    
    try {
        # Ensure we're in source tenant
        $ctx = Get-AzContext
        if($ctx.Tenant.Id -ne $SourceTenantId) {
            Connect-AzAccount -TenantId $SourceTenantId -ErrorAction Stop | Out-Null
            $sourceSubscriptions = Get-AzSubscription -TenantId $SourceTenantId -ErrorAction SilentlyContinue
            if($sourceSubscriptions -and $sourceSubscriptions.Count -gt 0) {
                Set-AzContext -SubscriptionId $sourceSubscriptions[0].Id -TenantId $SourceTenantId -ErrorAction Stop | Out-Null
            }
        }
        
        # Get token for ARM API
        $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
        
        $headers = @{
            "Authorization" = "Bearer $token"
            "Content-Type" = "application/json"
        }
        
        $uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/$DiagnosticSettingName`?api-version=2017-04-01"
        
        Write-Log "  Calling ARM API directly with source tenant token..." -Level Info
        $response = Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -Body $body -ErrorAction Stop
        
        Write-Log "Diagnostic setting created successfully!" -Level Success
        Write-Log "  Name: $DiagnosticSettingName" -Level Info
        Write-Log "  Destination: $WorkspaceResourceId" -Level Info
        Write-Log "  Categories: $($validCategories -join ', ')" -Level Info
        $deploymentSucceeded = $true
        
    } catch {
        $errorMessage = $_.Exception.Message
        Write-Log "  Method 2 failed: $errorMessage" -Level Warning
        
        # Check for specific error types
        if($errorMessage -like "*LinkedAuthorizationFailed*" -or $errorMessage -like "*403*") {
            Write-Log "  Cross-tenant authorization error - workspace in different tenant" -Level Warning
        }
    }
}

# Method 3: Try with auxiliary token header for cross-tenant authorization
if(-not $deploymentSucceeded) {
    Write-Log "" -Level Info
    Write-Log "────────────────────────────────────────────────────────────────────────" -Level Info
    Write-Log "Method 3: Cross-tenant auxiliary token (x-ms-authorization-auxiliary)" -Level Info
    Write-Log "────────────────────────────────────────────────────────────────────────" -Level Info
    Write-Log "  Strategy: Cache managing tenant token, use as auxiliary header" -Level Info
    Write-Log "  This allows Azure to verify permissions in both tenants" -Level Info
    Write-Log "" -Level Info
    
    try {
        # First, connect to managing tenant to get a token for the workspace
        Write-Log "  → Connecting to MANAGING tenant to cache token..." -Level Info
        Connect-AzAccount -TenantId $ManagingTenantId -ErrorAction Stop | Out-Null
        Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
        
        # Cache the managing tenant token
        $managingToken = (Get-AzAccessToken -ResourceUrl "https://management.azure.com" -ErrorAction Stop).Token
        Write-Log "  ✓ Managing tenant token cached" -Level Success
        
        # Now switch back to source tenant
        Write-Log "  → Switching to SOURCE tenant..." -Level Info
        Connect-AzAccount -TenantId $SourceTenantId -ErrorAction Stop | Out-Null
        $sourceSubscriptions = Get-AzSubscription -TenantId $SourceTenantId -ErrorAction SilentlyContinue
        if($sourceSubscriptions -and $sourceSubscriptions.Count -gt 0) {
            Set-AzContext -SubscriptionId $sourceSubscriptions[0].Id -TenantId $SourceTenantId -ErrorAction Stop | Out-Null
        }
        
        # Get source tenant token
        $sourceToken = (Get-AzAccessToken -ResourceUrl "https://management.azure.com" -ErrorAction Stop).Token
        
        # Make REST call with auxiliary token header
        $headers = @{
            "Authorization" = "Bearer $sourceToken"
            "Content-Type" = "application/json"
            "x-ms-authorization-auxiliary" = "Bearer $managingToken"
        }
        
        $uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/$DiagnosticSettingName`?api-version=2017-04-01"
        
        Write-Log "  Creating diagnostic setting with auxiliary token..." -Level Info
        $response = Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -Body $body -ErrorAction Stop
        
        Write-Log "Diagnostic setting created successfully via auxiliary token!" -Level Success
        Write-Log "  Name: $DiagnosticSettingName" -Level Info
        Write-Log "  Destination: $WorkspaceResourceId" -Level Info
        $deploymentSucceeded = $true
        
    } catch {
        $errorMessage = $_.Exception.Message
        Write-Log "  Method 3 failed: $errorMessage" -Level Warning
        
        if($errorMessage -like "*401*" -or $errorMessage -like "*Unauthorized*") {
            Write-Log "  Note: The microsoft.aadiam API does not support auxiliary tokens" -Level Warning
        }
    }
}

# Method 4: Try with token from managing tenant context (Lighthouse scenario)
if(-not $deploymentSucceeded) {
    Write-Log "" -Level Info
    Write-Log "────────────────────────────────────────────────────────────────────────" -Level Info
    Write-Log "Method 4: Lighthouse delegation from MANAGING tenant" -Level Info
    Write-Log "────────────────────────────────────────────────────────────────────────" -Level Info
    Write-Log "  Strategy: Connect to MANAGING tenant, use x-ms-tenant-id header for SOURCE" -Level Info
    Write-Log "  Note: Requires Lighthouse delegation to be configured" -Level Info
    Write-Log "" -Level Info
    
    try {
        # Switch to managing tenant but target the source tenant's Entra ID
        Write-Log "  → Connecting to MANAGING tenant ($ManagingTenantId)..." -Level Info
        Connect-AzAccount -TenantId $ManagingTenantId -ErrorAction Stop | Out-Null
        Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
        
        # Get token for management.azure.com
        $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
        
        # Make REST call with explicit tenant header
        $headers = @{
            "Authorization" = "Bearer $token"
            "Content-Type" = "application/json"
            "x-ms-tenant-id" = $SourceTenantId  # Target the source tenant's Entra ID
        }
        
        $uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/$DiagnosticSettingName`?api-version=2017-04-01"
        
        Write-Log "  Creating diagnostic setting with Lighthouse delegation..." -Level Info
        $response = Invoke-RestMethod -Uri $uri -Method PUT -Headers $headers -Body $body -ErrorAction Stop
        
        Write-Log "Diagnostic setting created successfully via Lighthouse" -Level Success
        Write-Log "  Name: $DiagnosticSettingName" -Level Info
        Write-Log "  Destination: $WorkspaceResourceId" -Level Info
        $deploymentSucceeded = $true
        
    } catch {
        Write-Log "  Lighthouse method failed: $($_.Exception.Message)" -Level Warning
    }
}

# Method 5: ARM Template deployment at tenant scope
if(-not $deploymentSucceeded) {
    Write-Log "" -Level Info
    Write-Log "────────────────────────────────────────────────────────────────────────" -Level Info
    Write-Log "Method 5: ARM Template deployment at tenant scope" -Level Info
    Write-Log "────────────────────────────────────────────────────────────────────────" -Level Info
    Write-Log "  Strategy: Deploy ARM template at tenant scope using New-AzTenantDeployment" -Level Info
    Write-Log "  This uses the ARM deployment engine which may handle cross-tenant differently" -Level Info
    Write-Log "" -Level Info
    
    try {
        # Ensure we're in the source tenant
        Write-Log "  → Connecting to SOURCE tenant ($SourceTenantId)..." -Level Info
        Connect-AzAccount -TenantId $SourceTenantId -ErrorAction Stop | Out-Null
        
        # Create ARM template for tenant-scope deployment
        $tenantScopeTemplate = @{
            '$schema' = "https://schema.management.azure.com/schemas/2019-08-01/tenantDeploymentTemplate.json#"
            contentVersion = "1.0.0.0"
            parameters = @{
                diagnosticSettingName = @{
                    type = "string"
                    defaultValue = $DiagnosticSettingName
                }
                workspaceResourceId = @{
                    type = "string"
                    defaultValue = $WorkspaceResourceId
                }
            }
            resources = @(
                @{
                    type = "microsoft.aadiam/diagnosticSettings"
                    apiVersion = "2017-04-01"
                    name = "[parameters('diagnosticSettingName')]"
                    properties = @{
                        workspaceId = "[parameters('workspaceResourceId')]"
                        logs = $logsArray
                    }
                }
            )
        }
        
        # Save template to temp file
        $tempTemplateFile = [IO.Path]::GetTempFileName() -replace '\.tmp$', '.json'
        $tenantScopeTemplate | ConvertTo-Json -Depth 20 | Out-File $tempTemplateFile -Encoding UTF8
        
        Write-Log "  Template saved to: $tempTemplateFile" -Level Info
        Write-Log "  Deploying ARM template at tenant scope..." -Level Info
        
        $deploymentName = "EntraIDDiagnostics-$(Get-Date -Format 'yyyyMMddHHmmss')"
        
        # Use New-AzTenantDeployment for tenant-scope deployment
        $deployment = New-AzTenantDeployment `
            -Name $deploymentName `
            -Location "uksouth" `
            -TemplateFile $tempTemplateFile `
            -ErrorAction Stop
        
        if($deployment.ProvisioningState -eq "Succeeded") {
            Write-Log "ARM template deployment succeeded!" -Level Success
            Write-Log "  Deployment Name: $deploymentName" -Level Info
            Write-Log "  Provisioning State: $($deployment.ProvisioningState)" -Level Info
            $deploymentSucceeded = $true
        } else {
            Write-Log "  Deployment state: $($deployment.ProvisioningState)" -Level Warning
        }
        
        # Cleanup temp file
        Remove-Item $tempTemplateFile -Force -ErrorAction SilentlyContinue
        
    } catch {
        $errorMessage = $_.Exception.Message
        Write-Log "  ARM template deployment failed: $errorMessage" -Level Warning
        
        # Check for specific error types
        if($errorMessage -like "*LinkedAuthorizationFailed*") {
            Write-Log "  LinkedAuthorizationFailed: ARM deployment also cannot authorize cross-tenant workspace" -Level Warning
        } elseif($errorMessage -like "*InvalidTemplateDeployment*") {
            Write-Log "  InvalidTemplateDeployment: Template may not be valid for tenant scope" -Level Warning
        }
        
        # Cleanup temp file on error
        if($tempTemplateFile -and (Test-Path $tempTemplateFile)) {
            Remove-Item $tempTemplateFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# Method 6: Microsoft Graph API (for completeness - diagnostic settings not supported)
if(-not $deploymentSucceeded) {
    Write-Log "" -Level Info
    Write-Log "────────────────────────────────────────────────────────────────────────" -Level Info
    Write-Log "Method 6: Microsoft Graph API check" -Level Info
    Write-Log "────────────────────────────────────────────────────────────────────────" -Level Info
    Write-Log "  Note: Microsoft Graph API does NOT support diagnostic settings" -Level Warning
    Write-Log "  Diagnostic settings are an ARM concept (microsoft.aadiam provider)" -Level Info
    Write-Log "  Graph API provides access to Entra ID data but not configuration" -Level Info
    Write-Log "" -Level Info
    Write-Log "  Graph API capabilities:" -Level Info
    Write-Log "    ✓ Read audit logs: GET /auditLogs/directoryAudits" -Level Info
    Write-Log "    ✓ Read sign-in logs: GET /auditLogs/signIns" -Level Info
    Write-Log "    ✗ Configure diagnostic settings: NOT AVAILABLE" -Level Warning
    Write-Log "" -Level Info
    Write-Log "  For diagnostic settings, you must use:" -Level Info
    Write-Log "    - Azure Resource Manager API (microsoft.aadiam/diagnosticSettings)" -Level Info
    Write-Log "    - Azure Portal UI" -Level Info
    Write-Log "    - Azure CLI: az monitor diagnostic-settings create" -Level Info
    Write-Log "" -Level Info
}

# If all automated methods failed, provide guidance
if(-not $deploymentSucceeded) {
    Write-Log "" -Level Error
    Write-Log "╔══════════════════════════════════════════════════════════════════════╗" -Level Error
    Write-Log "║  ALL AUTOMATED METHODS FAILED                                        ║" -Level Error
    Write-Log "╚══════════════════════════════════════════════════════════════════════╝" -Level Error
    Write-Log "" -Level Error
    Write-Log "The cross-tenant Entra ID diagnostic settings could not be configured" -Level Error
    Write-Log "automatically. This is a known limitation of the Azure API when the" -Level Error
    Write-Log "Log Analytics workspace is in a different tenant." -Level Error
    Write-Log "" -Level Error
    
    Write-Log "╔══════════════════════════════════════════════════════════════════════╗" -Level Warning
    Write-Log "║  RECOMMENDED: Use Azure Portal (handles cross-tenant correctly)      ║" -Level Warning
    Write-Log "╚══════════════════════════════════════════════════════════════════════╝" -Level Warning
    Write-Log "" -Level Warning
    Write-Log "The Azure Portal's UI handles cross-tenant authorization correctly." -Level Warning
    Write-Log "" -Level Warning
    Write-Log "Quick steps:" -Level Info
    Write-Log "  1. Open: https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/DiagnosticSettings" -Level Info
    Write-Log "  2. Sign in as Global Admin of SOURCE tenant ($SourceTenantName)" -Level Info
    Write-Log "  3. Click '+ Add diagnostic setting'" -Level Info
    Write-Log "  4. Name: $DiagnosticSettingName" -Level Info
    Write-Log "  5. Select log categories (AuditLogs, SignInLogs, etc.)" -Level Info
    Write-Log "  6. Check 'Send to Log Analytics workspace'" -Level Info
    Write-Log "  7. Click 'Change directory' in Subscription dropdown" -Level Info
    Write-Log "  8. Select the MANAGING tenant directory" -Level Info
    Write-Log "  9. Select workspace: $workspaceName" -Level Info
    Write-Log "  10. Click 'Save'" -Level Info
    Write-Log "" -Level Info
    
    Write-Log "╔══════════════════════════════════════════════════════════════════════╗" -Level Info
    Write-Log "║  ALTERNATIVE: Automate with Selenium/Playwright (Advanced)           ║" -Level Info
    Write-Log "╚══════════════════════════════════════════════════════════════════════╝" -Level Info
    Write-Log "" -Level Info
    Write-Log "For full automation, you could use browser automation tools like:" -Level Info
    Write-Log "  - Selenium WebDriver with PowerShell" -Level Info
    Write-Log "  - Playwright for .NET/PowerShell" -Level Info
    Write-Log "  - Azure DevOps pipeline with UI testing" -Level Info
    Write-Log "" -Level Info
    Write-Log "This would automate the Portal steps above programmatically." -Level Info
    Write-Log "" -Level Info
    
    Write-Log "Target workspace details:" -Level Info
    Write-Log "  Workspace Resource ID: $WorkspaceResourceId" -Level Info
    Write-Log "  Workspace Name: $workspaceName" -Level Info
    Write-Log "  Managing Tenant: $ManagingTenantId" -Level Info
    Write-Log "  Managing Subscription: $subscriptionId" -Level Info
    Write-Log "" -Level Info
    
    # Re-connect to source tenant for any subsequent operations
    Write-Log "Reconnecting to source tenant for verification..." -Level Info
    Connect-AzAccount -TenantId $SourceTenantId -ErrorAction SilentlyContinue | Out-Null
    
    exit 1
}

# Step 5: Verify Configuration
Write-Log "" -Level Info
Write-Log "════════════════════════════════════════════════════════════════════════" -Level Info
Write-Log "Step 5: Verifying configuration" -Level Info
Write-Log "════════════════════════════════════════════════════════════════════════" -Level Info
Write-Log "" -Level Info
Write-Log "  CURRENT CONTEXT: SOURCE TENANT ($SourceTenantName)" -Level Warning
Write-Log "  Purpose: Verify the diagnostic setting was created successfully" -Level Info
Write-Log "" -Level Info

Start-Sleep -Seconds 5  # Wait for setting to propagate

try {
    $verifyPath = "/providers/microsoft.aadiam/diagnosticSettings/$DiagnosticSettingName`?api-version=2017-04-01"
    $verifyResponse = Invoke-AzRestMethod -Path $verifyPath -Method GET -ErrorAction Stop
    
    if($verifyResponse.StatusCode -eq 200) {
        $verifySetting = $verifyResponse.Content | ConvertFrom-Json
        Write-Log "Diagnostic setting verified:" -Level Success
        Write-Log "  Name: $($verifySetting.name)" -Level Info
        Write-Log "  Workspace: $($verifySetting.properties.workspaceId)" -Level Info
        $enabledCats = ($verifySetting.properties.logs | Where-Object {$_.enabled -eq $true}).category
        Write-Log "  Enabled categories: $($enabledCats -join ', ')" -Level Info
    } else {
        Write-Log "Verification returned status $($verifyResponse.StatusCode)" -Level Warning
    }
} catch {
    Write-Log "Could not verify setting: $($_.Exception.Message)" -Level Warning
}

# Summary
Write-Log "" -Level Info
Write-Log "========================================" -Level Success
Write-Log "CONFIGURATION COMPLETE" -Level Success
Write-Log "========================================" -Level Success
Write-Log "" -Level Info
Write-Log "Summary:" -Level Info
Write-Log "  Managing Tenant: $ManagingTenantId" -Level Info
Write-Log "  Source Tenant: $SourceTenantName ($SourceTenantId)" -Level Info
Write-Log "  Diagnostic Setting: $DiagnosticSettingName" -Level Info
Write-Log "  Destination Workspace: $workspaceName" -Level Info
Write-Log "" -Level Info
Write-Log "Entra ID logs will now flow automatically to your Log Analytics workspace." -Level Info
Write-Log "No runbook needed - logs are pushed directly via diagnostic settings." -Level Info
Write-Log "" -Level Info
Write-Log "Log Analytics Tables:" -Level Info
Write-Log "  - SigninLogs (interactive sign-ins)" -Level Info
Write-Log "  - AADNonInteractiveUserSignInLogs" -Level Info
Write-Log "  - AADServicePrincipalSignInLogs" -Level Info
Write-Log "  - AADManagedIdentitySignInLogs" -Level Info
Write-Log "  - AuditLogs (directory changes)" -Level Info
Write-Log "" -Level Info
Write-Log "To add another source tenant, run:" -Level Info
Write-Log "  .\Configure-EntraIDDiagnosticSettings.ps1 -ManagingTenantId '$ManagingTenantId' -SourceTenantId '<NEW-TENANT-ID>' -SourceTenantName '<NAME>' -KeyVaultName '$KeyVaultName' -WorkspaceResourceId '$WorkspaceResourceId'" -Level Info
#endregion
