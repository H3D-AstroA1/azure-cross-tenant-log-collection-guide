<#
.SYNOPSIS
    Configures Microsoft Entra ID (Azure AD) diagnostic settings to send logs to a Log Analytics workspace.

.DESCRIPTION
    This script automates Step 6 of the Azure Cross-Tenant Log Collection Guide.
    It configures Microsoft Entra ID diagnostic settings to stream identity logs
    (Sign-in, Audit, Risk events, etc.) to a specified Log Analytics workspace.
    
    The script supports:
    - Cross-tenant log collection (source tenant logs to destination tenant workspace)
    - ARM template deployment for consistent, repeatable configuration
    - REST API fallback for environments where ARM deployment is not available
    - Verification of existing diagnostic settings
    - Removal of existing settings before reconfiguration
    
    IMPORTANT: This script must be run by a Global Administrator or Security Administrator
    in the SOURCE tenant (where Entra ID logs originate). Azure Lighthouse does NOT provide
    access to configure Entra ID diagnostic settings cross-tenant.

.PARAMETER SourceTenantId
    The Tenant ID of the source tenant (where Entra ID logs originate).
    This is the tenant where the diagnostic settings will be configured.

.PARAMETER DestinationWorkspaceResourceId
    The full resource ID of the Log Analytics workspace in the destination tenant.
    Format: /subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/Microsoft.OperationalInsights/workspaces/{workspaceName}

.PARAMETER DiagnosticSettingName
    The name for the diagnostic setting. Default: "SendEntraLogsToLogAnalytics"

.PARAMETER LogCategories
    Array of log categories to enable. If not specified, all available categories will be enabled.
    Available categories:
    - AuditLogs (Free tier)
    - SignInLogs (P1/P2 required)
    - NonInteractiveUserSignInLogs (P1/P2 required)
    - ServicePrincipalSignInLogs (P1/P2 required)
    - ManagedIdentitySignInLogs (P1/P2 required)
    - ProvisioningLogs (P1/P2 required)
    - RiskyUsers (P2 required)
    - UserRiskEvents (P2 required)
    - RiskyServicePrincipals (P2 required)
    - ServicePrincipalRiskEvents (P2 required)
    - MicrosoftGraphActivityLogs (P1/P2 required)
    - NetworkAccessTrafficLogs (P1/P2 required)
    - EnrichedOffice365AuditLogs (E5 required)

.PARAMETER UseArmTemplate
    If specified, deploys using ARM template. Otherwise uses REST API directly.

.PARAMETER RemoveExisting
    If specified, removes any existing diagnostic setting with the same name before creating a new one.

.PARAMETER VerifyOnly
    If specified, only verifies existing diagnostic settings without making changes.

.PARAMETER WhatIf
    Shows what would happen if the script runs without making actual changes.

.EXAMPLE
    # Configure all log categories using REST API
    .\Configure-EntraIDDiagnosticSettings.ps1 `
        -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -DestinationWorkspaceResourceId "/subscriptions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central"

.EXAMPLE
    # Configure specific log categories only
    .\Configure-EntraIDDiagnosticSettings.ps1 `
        -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -DestinationWorkspaceResourceId "/subscriptions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central" `
        -LogCategories @("AuditLogs", "SignInLogs", "NonInteractiveUserSignInLogs")

.EXAMPLE
    # Deploy using ARM template
    .\Configure-EntraIDDiagnosticSettings.ps1 `
        -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -DestinationWorkspaceResourceId "/subscriptions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central" `
        -UseArmTemplate

.EXAMPLE
    # Verify existing settings only
    .\Configure-EntraIDDiagnosticSettings.ps1 `
        -SourceTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -DestinationWorkspaceResourceId "/subscriptions/yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central" `
        -VerifyOnly

.NOTES
    Author: Azure Cross-Tenant Log Collection Guide
    Version: 1.0.0
    Requires: 
        - Az PowerShell module (Az.Accounts)
        - Global Administrator or Security Administrator role in source tenant
        - Microsoft Entra ID P1/P2 license for sign-in logs
        - Microsoft Entra ID P2 license for risk-based logs

.LINK
    https://docs.microsoft.com/azure/active-directory/reports-monitoring/howto-integrate-activity-logs-with-log-analytics
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, HelpMessage = "The Tenant ID of the source tenant where Entra ID logs originate")]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SourceTenantId,

    [Parameter(Mandatory = $true, HelpMessage = "Full resource ID of the destination Log Analytics workspace")]
    [ValidatePattern('^/subscriptions/[0-9a-fA-F-]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$')]
    [string]$DestinationWorkspaceResourceId,

    [Parameter(Mandatory = $false, HelpMessage = "Name for the diagnostic setting")]
    [ValidateLength(1, 260)]
    [string]$DiagnosticSettingName = "SendEntraLogsToLogAnalytics",

    [Parameter(Mandatory = $false, HelpMessage = "Array of log categories to enable")]
    [ValidateSet(
        "AuditLogs",
        "SignInLogs", 
        "NonInteractiveUserSignInLogs",
        "ServicePrincipalSignInLogs",
        "ManagedIdentitySignInLogs",
        "ProvisioningLogs",
        "RiskyUsers",
        "UserRiskEvents",
        "RiskyServicePrincipals",
        "ServicePrincipalRiskEvents",
        "MicrosoftGraphActivityLogs",
        "NetworkAccessTrafficLogs",
        "EnrichedOffice365AuditLogs",
        "ADFSSignInLogs"
    )]
    [string[]]$LogCategories,

    [Parameter(Mandatory = $false, HelpMessage = "Deploy using ARM template instead of REST API")]
    [switch]$UseArmTemplate,

    [Parameter(Mandatory = $false, HelpMessage = "Remove existing diagnostic setting before creating new one")]
    [switch]$RemoveExisting,

    [Parameter(Mandatory = $false, HelpMessage = "Only verify existing settings without making changes")]
    [switch]$VerifyOnly
)

#region Script Configuration
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# API version for Entra ID diagnostic settings
$ApiVersion = "2017-04-01"

# Default log categories if none specified (all available categories)
$DefaultLogCategories = @(
    "AuditLogs",
    "SignInLogs",
    "NonInteractiveUserSignInLogs",
    "ServicePrincipalSignInLogs",
    "ManagedIdentitySignInLogs",
    "ProvisioningLogs",
    "RiskyUsers",
    "UserRiskEvents",
    "RiskyServicePrincipals",
    "ServicePrincipalRiskEvents",
    "MicrosoftGraphActivityLogs"
)

# Log category license requirements
$LogCategoryLicenseRequirements = @{
    "AuditLogs"                    = "Free"
    "SignInLogs"                   = "P1/P2"
    "NonInteractiveUserSignInLogs" = "P1/P2"
    "ServicePrincipalSignInLogs"   = "P1/P2"
    "ManagedIdentitySignInLogs"    = "P1/P2"
    "ProvisioningLogs"             = "P1/P2"
    "RiskyUsers"                   = "P2"
    "UserRiskEvents"               = "P2"
    "RiskyServicePrincipals"       = "P2"
    "ServicePrincipalRiskEvents"   = "P2"
    "MicrosoftGraphActivityLogs"   = "P1/P2"
    "NetworkAccessTrafficLogs"     = "P1/P2"
    "EnrichedOffice365AuditLogs"   = "E5"
    "ADFSSignInLogs"               = "P1/P2"
}
#endregion

#region ARM Template Definition
$ArmTemplate = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "settingName": {
            "type": "string",
            "metadata": {
                "description": "Name of the diagnostic setting"
            }
        },
        "workspaceId": {
            "type": "string",
            "metadata": {
                "description": "Resource ID of the Log Analytics workspace"
            }
        },
        "logs": {
            "type": "array",
            "metadata": {
                "description": "Array of log category configurations"
            }
        }
    },
    "resources": [
        {
            "type": "microsoft.aadiam/diagnosticSettings",
            "apiVersion": "2017-04-01",
            "name": "[parameters('settingName')]",
            "properties": {
                "workspaceId": "[parameters('workspaceId')]",
                "logs": "[parameters('logs')]"
            }
        }
    ],
    "outputs": {
        "diagnosticSettingId": {
            "type": "string",
            "value": "[resourceId('microsoft.aadiam/diagnosticSettings', parameters('settingName'))]"
        },
        "diagnosticSettingName": {
            "type": "string",
            "value": "[parameters('settingName')]"
        }
    }
}
'@
#endregion

#region Helper Functions

function Write-Log {
    <#
    .SYNOPSIS
        Writes a log message with timestamp and severity level.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS", "DEBUG")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "INFO"    { "White" }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
        "DEBUG"   { "Cyan" }
    }
    
    $prefix = switch ($Level) {
        "INFO"    { "[INFO]   " }
        "WARNING" { "[WARN]   " }
        "ERROR"   { "[ERROR]  " }
        "SUCCESS" { "[OK]     " }
        "DEBUG"   { "[DEBUG]  " }
    }
    
    Write-Host "$timestamp $prefix$Message" -ForegroundColor $color
}

function Test-AzureConnection {
    <#
    .SYNOPSIS
        Tests if connected to Azure and to the correct tenant.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedTenantId
    )
    
    try {
        $context = Get-AzContext -ErrorAction Stop
        
        if (-not $context) {
            Write-Log "Not connected to Azure. Please run Connect-AzAccount first." -Level "ERROR"
            return $false
        }
        
        if ($context.Tenant.Id -ne $ExpectedTenantId) {
            Write-Log "Connected to tenant $($context.Tenant.Id), but expected $ExpectedTenantId" -Level "WARNING"
            Write-Log "Please run: Connect-AzAccount -TenantId $ExpectedTenantId" -Level "INFO"
            return $false
        }
        
        Write-Log "Connected to Azure tenant: $($context.Tenant.Id)" -Level "SUCCESS"
        Write-Log "Account: $($context.Account.Id)" -Level "INFO"
        return $true
    }
    catch {
        Write-Log "Failed to get Azure context: $_" -Level "ERROR"
        return $false
    }
}

function Get-AzureAccessToken {
    <#
    .SYNOPSIS
        Gets an access token for Azure Resource Manager API.
    #>
    try {
        $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com" -ErrorAction Stop).Token
        return $token
    }
    catch {
        Write-Log "Failed to get access token: $_" -Level "ERROR"
        throw
    }
}

function Get-ExistingDiagnosticSettings {
    <#
    .SYNOPSIS
        Retrieves existing Entra ID diagnostic settings.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessToken,
        
        [Parameter(Mandatory = $false)]
        [string]$SettingName
    )
    
    $headers = @{
        "Authorization" = "Bearer $AccessToken"
        "Content-Type"  = "application/json"
    }
    
    try {
        if ($SettingName) {
            $uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/${SettingName}?api-version=$ApiVersion"
        }
        else {
            $uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings?api-version=$ApiVersion"
        }
        
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -ErrorAction Stop
        return $response
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            return $null
        }
        throw
    }
}

function Remove-DiagnosticSetting {
    <#
    .SYNOPSIS
        Removes an existing Entra ID diagnostic setting.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessToken,
        
        [Parameter(Mandatory = $true)]
        [string]$SettingName
    )
    
    $headers = @{
        "Authorization" = "Bearer $AccessToken"
        "Content-Type"  = "application/json"
    }
    
    $uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/${SettingName}?api-version=$ApiVersion"
    
    try {
        Invoke-RestMethod -Uri $uri -Method Delete -Headers $headers -ErrorAction Stop
        Write-Log "Successfully removed diagnostic setting: $SettingName" -Level "SUCCESS"
        return $true
    }
    catch {
        Write-Log "Failed to remove diagnostic setting: $_" -Level "ERROR"
        return $false
    }
}

function New-DiagnosticSettingViaRestApi {
    <#
    .SYNOPSIS
        Creates a new Entra ID diagnostic setting using REST API.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessToken,
        
        [Parameter(Mandatory = $true)]
        [string]$SettingName,
        
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceResourceId,
        
        [Parameter(Mandatory = $true)]
        [array]$LogCategories
    )
    
    $headers = @{
        "Authorization" = "Bearer $AccessToken"
        "Content-Type"  = "application/json"
    }
    
    # Build logs array
    $logs = @()
    foreach ($category in $LogCategories) {
        $logs += @{
            category = $category
            enabled  = $true
        }
    }
    
    $body = @{
        properties = @{
            workspaceId = $WorkspaceResourceId
            logs        = $logs
        }
    } | ConvertTo-Json -Depth 10
    
    $uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/${SettingName}?api-version=$ApiVersion"
    
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $body -ErrorAction Stop
        return $response
    }
    catch {
        Write-Log "REST API Error: $($_.Exception.Message)" -Level "ERROR"
        if ($_.ErrorDetails.Message) {
            Write-Log "Error Details: $($_.ErrorDetails.Message)" -Level "ERROR"
        }
        throw
    }
}

function New-DiagnosticSettingViaArmTemplate {
    <#
    .SYNOPSIS
        Creates a new Entra ID diagnostic setting using ARM template deployment.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingName,
        
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceResourceId,
        
        [Parameter(Mandatory = $true)]
        [array]$LogCategories,
        
        [Parameter(Mandatory = $true)]
        [string]$Location
    )
    
    # Build logs array for ARM template
    $logs = @()
    foreach ($category in $LogCategories) {
        $logs += @{
            category = $category
            enabled  = $true
        }
    }
    
    # Create temporary file for ARM template
    $tempTemplatePath = Join-Path $env:TEMP "entra-diagnostic-settings-template.json"
    $ArmTemplate | Out-File -FilePath $tempTemplatePath -Encoding UTF8 -Force
    
    try {
        # Deploy ARM template at tenant scope
        $deploymentName = "EntraIDDiagnostics-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        
        $templateParams = @{
            settingName = $SettingName
            workspaceId = $WorkspaceResourceId
            logs        = $logs
        }
        
        Write-Log "Deploying ARM template at tenant scope..." -Level "INFO"
        
        $deployment = New-AzTenantDeployment `
            -Name $deploymentName `
            -Location $Location `
            -TemplateFile $tempTemplatePath `
            -TemplateParameterObject $templateParams `
            -ErrorAction Stop
        
        return $deployment
    }
    finally {
        # Clean up temporary file
        if (Test-Path $tempTemplatePath) {
            Remove-Item $tempTemplatePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Show-DiagnosticSettingSummary {
    <#
    .SYNOPSIS
        Displays a summary of the diagnostic setting configuration.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Setting
    )
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  DIAGNOSTIC SETTING SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    if ($Setting.name) {
        Write-Host "  Setting Name:     $($Setting.name)" -ForegroundColor White
    }
    
    if ($Setting.properties.workspaceId) {
        Write-Host "  Workspace ID:     $($Setting.properties.workspaceId)" -ForegroundColor White
    }
    
    Write-Host ""
    Write-Host "  Enabled Log Categories:" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    
    foreach ($log in $Setting.properties.logs) {
        $status = if ($log.enabled) { "✓" } else { "✗" }
        $color = if ($log.enabled) { "Green" } else { "Red" }
        $license = $LogCategoryLicenseRequirements[$log.category]
        Write-Host "    $status $($log.category) " -ForegroundColor $color -NoNewline
        Write-Host "(License: $license)" -ForegroundColor DarkGray
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

function Show-LicenseRequirements {
    <#
    .SYNOPSIS
        Displays license requirements for the selected log categories.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [array]$Categories
    )
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  LICENSE REQUIREMENTS" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
    
    $p1p2Required = $false
    $p2Required = $false
    $e5Required = $false
    
    foreach ($category in $Categories) {
        $license = $LogCategoryLicenseRequirements[$category]
        Write-Host "    • $category " -ForegroundColor White -NoNewline
        
        switch ($license) {
            "Free" { 
                Write-Host "(Free)" -ForegroundColor Green 
            }
            "P1/P2" { 
                Write-Host "(Requires Entra ID P1 or P2)" -ForegroundColor Yellow
                $p1p2Required = $true
            }
            "P2" { 
                Write-Host "(Requires Entra ID P2)" -ForegroundColor Red
                $p2Required = $true
            }
            "E5" { 
                Write-Host "(Requires Microsoft 365 E5)" -ForegroundColor Red
                $e5Required = $true
            }
        }
    }
    
    Write-Host ""
    
    if ($p2Required) {
        Write-Host "  ⚠ WARNING: Some categories require Microsoft Entra ID P2 license." -ForegroundColor Red
        Write-Host "             Without P2, these categories will not collect data." -ForegroundColor Red
    }
    elseif ($p1p2Required) {
        Write-Host "  ⚠ NOTE: Some categories require Microsoft Entra ID P1 or P2 license." -ForegroundColor Yellow
        Write-Host "          Without P1/P2, these categories will not collect data." -ForegroundColor Yellow
    }
    
    if ($e5Required) {
        Write-Host "  ⚠ WARNING: EnrichedOffice365AuditLogs requires Microsoft 365 E5 license." -ForegroundColor Red
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
}
#endregion

#region Main Script Execution

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║                                                                   ║" -ForegroundColor Cyan
Write-Host "║   MICROSOFT ENTRA ID DIAGNOSTIC SETTINGS CONFIGURATION           ║" -ForegroundColor Cyan
Write-Host "║   Azure Cross-Tenant Log Collection Guide - Step 6               ║" -ForegroundColor Cyan
Write-Host "║                                                                   ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Validate Azure connection
Write-Log "Validating Azure connection..." -Level "INFO"
if (-not (Test-AzureConnection -ExpectedTenantId $SourceTenantId)) {
    Write-Log "Please connect to the source tenant and run the script again." -Level "ERROR"
    Write-Host ""
    Write-Host "Run the following command to connect:" -ForegroundColor Yellow
    Write-Host "  Connect-AzAccount -TenantId $SourceTenantId" -ForegroundColor White
    Write-Host ""
    exit 1
}

# Determine which log categories to use
$categoriesToEnable = if ($LogCategories -and $LogCategories.Count -gt 0) {
    $LogCategories
}
else {
    Write-Log "No specific log categories specified. Using default categories." -Level "INFO"
    $DefaultLogCategories
}

Write-Log "Log categories to enable: $($categoriesToEnable -join ', ')" -Level "INFO"

# Show license requirements
Show-LicenseRequirements -Categories $categoriesToEnable

# Get access token
Write-Log "Obtaining access token..." -Level "INFO"
$accessToken = Get-AzureAccessToken

# Check for existing diagnostic settings
Write-Log "Checking for existing diagnostic settings..." -Level "INFO"
$existingSettings = Get-ExistingDiagnosticSettings -AccessToken $accessToken

if ($existingSettings) {
    if ($existingSettings.value) {
        Write-Log "Found $($existingSettings.value.Count) existing diagnostic setting(s):" -Level "INFO"
        foreach ($setting in $existingSettings.value) {
            Write-Host "    • $($setting.name)" -ForegroundColor White
        }
    }
    else {
        Write-Log "Found existing diagnostic setting: $($existingSettings.name)" -Level "INFO"
    }
}
else {
    Write-Log "No existing diagnostic settings found." -Level "INFO"
}

# If VerifyOnly mode, show existing settings and exit
if ($VerifyOnly) {
    Write-Log "Verify-only mode. Displaying existing settings..." -Level "INFO"
    
    if ($existingSettings) {
        $settingsToShow = if ($existingSettings.value) { $existingSettings.value } else { @($existingSettings) }
        foreach ($setting in $settingsToShow) {
            Show-DiagnosticSettingSummary -Setting $setting
        }
    }
    else {
        Write-Log "No diagnostic settings configured for Entra ID." -Level "WARNING"
    }
    
    Write-Host ""
    Write-Log "Verification complete. No changes were made." -Level "SUCCESS"
    exit 0
}

# Check if setting with same name exists
$existingSettingWithSameName = Get-ExistingDiagnosticSettings -AccessToken $accessToken -SettingName $DiagnosticSettingName

if ($existingSettingWithSameName) {
    if ($RemoveExisting) {
        if ($PSCmdlet.ShouldProcess($DiagnosticSettingName, "Remove existing diagnostic setting")) {
            Write-Log "Removing existing diagnostic setting: $DiagnosticSettingName" -Level "WARNING"
            $removed = Remove-DiagnosticSetting -AccessToken $accessToken -SettingName $DiagnosticSettingName
            if (-not $removed) {
                Write-Log "Failed to remove existing setting. Aborting." -Level "ERROR"
                exit 1
            }
            Start-Sleep -Seconds 2  # Brief pause to allow deletion to propagate
        }
    }
    else {
        Write-Log "Diagnostic setting '$DiagnosticSettingName' already exists." -Level "WARNING"
        Write-Log "Use -RemoveExisting to replace it, or choose a different name." -Level "INFO"
        Show-DiagnosticSettingSummary -Setting $existingSettingWithSameName
        exit 0
    }
}

# Create the diagnostic setting
Write-Log "Creating diagnostic setting: $DiagnosticSettingName" -Level "INFO"
Write-Log "Destination workspace: $DestinationWorkspaceResourceId" -Level "INFO"

if ($PSCmdlet.ShouldProcess($DiagnosticSettingName, "Create Entra ID diagnostic setting")) {
    try {
        if ($UseArmTemplate) {
            Write-Log "Using ARM template deployment method..." -Level "INFO"
            $result = New-DiagnosticSettingViaArmTemplate `
                -SettingName $DiagnosticSettingName `
                -WorkspaceResourceId $DestinationWorkspaceResourceId `
                -LogCategories $categoriesToEnable `
                -Location "westus2"
            
            if ($result.ProvisioningState -eq "Succeeded") {
                Write-Log "ARM template deployment succeeded!" -Level "SUCCESS"
            }
            else {
                Write-Log "ARM template deployment status: $($result.ProvisioningState)" -Level "WARNING"
            }
        }
        else {
            Write-Log "Using REST API deployment method..." -Level "INFO"
            $result = New-DiagnosticSettingViaRestApi `
                -AccessToken $accessToken `
                -SettingName $DiagnosticSettingName `
                -WorkspaceResourceId $DestinationWorkspaceResourceId `
                -LogCategories $categoriesToEnable
            
            Write-Log "REST API deployment succeeded!" -Level "SUCCESS"
        }
        
        # Verify the setting was created
        Write-Log "Verifying diagnostic setting creation..." -Level "INFO"
        Start-Sleep -Seconds 3  # Brief pause to allow creation to propagate
        
        $verifiedSetting = Get-ExistingDiagnosticSettings -AccessToken $accessToken -SettingName $DiagnosticSettingName
        
        if ($verifiedSetting) {
            Write-Log "Diagnostic setting verified successfully!" -Level "SUCCESS"
            Show-DiagnosticSettingSummary -Setting $verifiedSetting
        }
        else {
            Write-Log "Could not verify diagnostic setting. It may take a few minutes to appear." -Level "WARNING"
        }
    }
    catch {
        Write-Log "Failed to create diagnostic setting: $_" -Level "ERROR"
        
        # Provide troubleshooting guidance
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host "  TROUBLESHOOTING" -ForegroundColor Red
        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Common issues and solutions:" -ForegroundColor White
        Write-Host ""
        Write-Host "  1. 'AuthorizationFailed' error:" -ForegroundColor Yellow
        Write-Host "     - Ensure you have Global Administrator or Security Administrator role" -ForegroundColor Gray
        Write-Host "     - Run: Connect-AzAccount -TenantId $SourceTenantId" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  2. 'ResourceNotFound' error:" -ForegroundColor Yellow
        Write-Host "     - Verify the Log Analytics workspace resource ID is correct" -ForegroundColor Gray
        Write-Host "     - Ensure the workspace exists and is accessible" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  3. 'BadRequest' error:" -ForegroundColor Yellow
        Write-Host "     - Check if the log category is supported by your license" -ForegroundColor Gray
        Write-Host "     - Some categories require Entra ID P1/P2 or E5 license" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  4. Cross-tenant workspace access:" -ForegroundColor Yellow
        Write-Host "     - Ensure the destination workspace allows cross-tenant data ingestion" -ForegroundColor Gray
        Write-Host "     - Verify network connectivity to the workspace" -ForegroundColor Gray
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════════════════════════" -ForegroundColor Red
        Write-Host ""
        
        exit 1
    }
}

#endregion

#region Post-Configuration Information

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                                                                   ║" -ForegroundColor Green
Write-Host "║   CONFIGURATION COMPLETE                                          ║" -ForegroundColor Green
Write-Host "║                                                                   ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Log "Entra ID diagnostic settings have been configured successfully!" -Level "SUCCESS"
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  1. Wait 5-15 minutes for initial data to appear in Log Analytics" -ForegroundColor White
Write-Host ""
Write-Host "  2. Verify data ingestion with these KQL queries:" -ForegroundColor White
Write-Host ""
Write-Host "     // Check Sign-in Logs" -ForegroundColor Gray
Write-Host "     SigninLogs" -ForegroundColor Yellow
Write-Host "     | where TimeGenerated > ago(1h)" -ForegroundColor Yellow
Write-Host "     | summarize count() by ResultType" -ForegroundColor Yellow
Write-Host ""
Write-Host "     // Check Audit Logs" -ForegroundColor Gray
Write-Host "     AuditLogs" -ForegroundColor Yellow
Write-Host "     | where TimeGenerated > ago(1h)" -ForegroundColor Yellow
Write-Host "     | summarize count() by OperationName" -ForegroundColor Yellow
Write-Host ""
Write-Host "  3. Log Analytics Tables that will be populated:" -ForegroundColor White
Write-Host ""
Write-Host "     Table Name                          Description" -ForegroundColor Gray
Write-Host "     ─────────────────────────────────── ─────────────────────────────────" -ForegroundColor DarkGray
Write-Host "     SigninLogs                          Interactive user sign-ins" -ForegroundColor White
Write-Host "     AADNonInteractiveUserSignInLogs     Non-interactive sign-ins" -ForegroundColor White
Write-Host "     AADServicePrincipalSignInLogs       Service principal sign-ins" -ForegroundColor White
Write-Host "     AADManagedIdentitySignInLogs        Managed identity sign-ins" -ForegroundColor White
Write-Host "     AuditLogs                           Directory audit events" -ForegroundColor White
Write-Host "     AADProvisioningLogs                 Provisioning activities" -ForegroundColor White
Write-Host "     AADRiskyUsers                       Risky user information" -ForegroundColor White
Write-Host "     AADUserRiskEvents                   User risk events" -ForegroundColor White
Write-Host "     MicrosoftGraphActivityLogs          Graph API activity" -ForegroundColor White
Write-Host ""
Write-Host "─────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# Display verification command
Write-Host "To verify the diagnostic setting later, run:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  .\Configure-EntraIDDiagnosticSettings.ps1 ``" -ForegroundColor White
Write-Host "      -SourceTenantId `"$SourceTenantId`" ``" -ForegroundColor White
Write-Host "      -DestinationWorkspaceResourceId `"$DestinationWorkspaceResourceId`" ``" -ForegroundColor White
Write-Host "      -VerifyOnly" -ForegroundColor White
Write-Host ""

# Display removal command
Write-Host "To remove this diagnostic setting, run:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  # Using PowerShell REST API:" -ForegroundColor Gray
Write-Host "  `$token = (Get-AzAccessToken -ResourceUrl `"https://management.azure.com`").Token" -ForegroundColor White
Write-Host "  `$headers = @{ `"Authorization`" = `"Bearer `$token`"; `"Content-Type`" = `"application/json`" }" -ForegroundColor White
Write-Host "  Invoke-RestMethod -Uri `"https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/$DiagnosticSettingName`?api-version=2017-04-01`" -Method Delete -Headers `$headers" -ForegroundColor White
Write-Host ""

#endregion

Write-Log "Script execution completed." -Level "SUCCESS"