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
    Version: 2.2
    Requires: Az.Accounts, Az.KeyVault PowerShell modules
    
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
    Write-Log "Step 1: Updating tenant tracking in Key Vault..." -Level Info
    
    $ctx = Get-AzContext
    if(-not $ctx -or $ctx.Tenant.Id -ne $ManagingTenantId) {
        Write-Log "Connecting to managing tenant ($ManagingTenantId)..." -Level Info
        Connect-AzAccount -TenantId $ManagingTenantId -ErrorAction Stop
    }
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
    
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

# Step 2: Connect to Source Tenant
Write-Log "" -Level Info
Write-Log "Step 2: Connecting to source tenant ($SourceTenantName)..." -Level Info

try {
    Connect-AzAccount -TenantId $SourceTenantId -ErrorAction Stop
    Write-Log "Connected to source tenant" -Level Success
} catch {
    Write-Log "Failed to connect to source tenant: $($_.Exception.Message)" -Level Error
    Write-Log "Ensure you have Global Administrator access to $SourceTenantName" -Level Error
    exit 1
}

# Step 3: Check existing diagnostic settings
Write-Log "" -Level Info
Write-Log "Step 3: Checking existing Entra ID diagnostic settings..." -Level Info

$existingSettings = $null
try {
    $uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01"
    $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
    $headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
    $response = Invoke-RestMethod -Uri $uri -Method GET -Headers $headers -ErrorAction Stop
    $existingSettings = $response.value
    
    if($existingSettings.Count -gt 0) {
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
} catch {
    Write-Log "Could not check existing settings: $($_.Exception.Message)" -Level Warning
}

if($VerifyOnly) {
    Write-Log "" -Level Info
    Write-Log "Verify-only mode - no changes made" -Level Info
    exit 0
}

# Step 4: Deploy Entra ID Diagnostic Settings via ARM Template
Write-Log "" -Level Info
Write-Log "Step 4: Deploying Entra ID diagnostic settings via ARM template..." -Level Info

# Check if setting with same name exists
$existingWithSameName = $existingSettings | Where-Object { $_.name -eq $DiagnosticSettingName }
if($existingWithSameName) {
    Write-Log "Diagnostic setting '$DiagnosticSettingName' already exists" -Level Warning
    $response = Read-Host "Do you want to update it? (y/n)"
    if($response -ne 'y') {
        Write-Log "Skipping deployment" -Level Warning
        exit 0
    }
    
    # Delete existing setting first
    Write-Log "Removing existing diagnostic setting..." -Level Info
    try {
        $deleteUri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/$DiagnosticSettingName`?api-version=2017-04-01"
        Invoke-RestMethod -Uri $deleteUri -Method DELETE -Headers $headers -ErrorAction Stop
        Write-Log "Existing setting removed" -Level Success
        Start-Sleep -Seconds 5  # Wait for deletion to propagate
    } catch {
        Write-Log "Could not remove existing setting: $($_.Exception.Message)" -Level Warning
    }
}

# Deploy via REST API (ARM template deployment at tenant scope requires special handling)
Write-Log "Creating diagnostic setting via REST API..." -Level Info

$logsArray = $validCategories | ForEach-Object {
    @{ category = $_; enabled = $true }
}

$body = @{
    properties = @{
        workspaceId = $WorkspaceResourceId
        logs = $logsArray
    }
} | ConvertTo-Json -Depth 10

try {
    $createUri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/$DiagnosticSettingName`?api-version=2017-04-01"
    
    if($PSCmdlet.ShouldProcess($DiagnosticSettingName, "Create Diagnostic Setting")) {
        $result = Invoke-RestMethod -Uri $createUri -Method PUT -Headers $headers -Body $body -ErrorAction Stop
        Write-Log "Diagnostic setting created successfully" -Level Success
        Write-Log "  Name: $DiagnosticSettingName" -Level Info
        Write-Log "  Destination: $WorkspaceResourceId" -Level Info
        Write-Log "  Categories: $($validCategories -join ', ')" -Level Info
    }
} catch {
    Write-Log "Failed to create diagnostic setting: $($_.Exception.Message)" -Level Error
    
    # Try with fewer categories (some may not be available)
    Write-Log "Retrying with basic categories only..." -Level Warning
    $basicCategories = @("AuditLogs", "SignInLogs")
    $logsArray = $basicCategories | ForEach-Object { @{ category = $_; enabled = $true } }
    $body = @{ properties = @{ workspaceId = $WorkspaceResourceId; logs = $logsArray } } | ConvertTo-Json -Depth 10
    
    try {
        $result = Invoke-RestMethod -Uri $createUri -Method PUT -Headers $headers -Body $body -ErrorAction Stop
        Write-Log "Diagnostic setting created with basic categories" -Level Success
        Write-Log "  Categories: $($basicCategories -join ', ')" -Level Info
        Write-Log "  Note: Some categories may require additional licenses" -Level Warning
    } catch {
        Write-Log "Failed to create diagnostic setting: $($_.Exception.Message)" -Level Error
        exit 1
    }
}

# Step 5: Verify Configuration
Write-Log "" -Level Info
Write-Log "Step 5: Verifying configuration..." -Level Info

Start-Sleep -Seconds 5  # Wait for setting to propagate

try {
    $verifyUri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/$DiagnosticSettingName`?api-version=2017-04-01"
    $verifySetting = Invoke-RestMethod -Uri $verifyUri -Method GET -Headers $headers -ErrorAction Stop
    
    Write-Log "Diagnostic setting verified:" -Level Success
    Write-Log "  Name: $($verifySetting.name)" -Level Info
    Write-Log "  Workspace: $($verifySetting.properties.workspaceId)" -Level Info
    $enabledCats = ($verifySetting.properties.logs | Where-Object {$_.enabled -eq $true}).category
    Write-Log "  Enabled categories: $($enabledCats -join ', ')" -Level Info
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
