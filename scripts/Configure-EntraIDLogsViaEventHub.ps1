<#
.SYNOPSIS
    Configures Microsoft Entra ID log collection via Azure Event Hub for cross-tenant scenarios.

.DESCRIPTION
    This script is used as Step 6 in the Azure Cross-Tenant Log Collection setup.
    It configures Entra ID log collection using Azure Event Hub to bypass the
    cross-tenant limitations of direct Log Analytics workspace configuration.
    
    The script:
    - Creates an Event Hub namespace and Event Hub in the managing tenant
    - Creates a Shared Access Policy for the source tenant to send logs
    - Deploys an Azure Function to process events and forward to Log Analytics
    - Configures Entra ID diagnostic settings in the source tenant
    - Stores connection strings securely in Key Vault
    - Updates tenant tracking in Key Vault

    USAGE OPTIONS:
    1. Edit the CONFIGURATION section below and run: .\Configure-EntraIDLogsViaEventHub.ps1
    2. Or pass parameters on command line (parameters override configuration section)

.PARAMETER ManagingTenantId
    The Azure tenant ID (GUID) of the managing tenant (e.g., Atevet12).

.PARAMETER ManagingSubscriptionId
    The subscription ID in the managing tenant where Event Hub and Function will be created.

.PARAMETER SourceTenantId
    The Azure tenant ID (GUID) of the source tenant (e.g., Atevet17).

.PARAMETER SourceTenantName
    A friendly name for the source tenant (used for tracking and naming).

.PARAMETER ResourceGroupName
    Resource group for Event Hub and Function App. Default: "rg-entra-logs-eventhub"

.PARAMETER EventHubNamespaceName
    Name for the Event Hub namespace. Must be globally unique.

.PARAMETER EventHubName
    Name for the Event Hub. Default: "eh-entra-id-logs"

.PARAMETER FunctionAppName
    Name for the Azure Function App. Must be globally unique.

.PARAMETER KeyVaultName
    Name of the Key Vault in the managing tenant (from Step 1).

.PARAMETER WorkspaceResourceId
    Full resource ID of the Log Analytics workspace in the managing tenant.

.PARAMETER Location
    Azure region for resources. Default: "westus2"

.PARAMETER LogCategories
    Array of Entra ID log categories to collect. Default: All available categories.

.PARAMETER DiagnosticSettingName
    Name for the diagnostic setting in the source tenant. Default: "SendToEventHub"

.PARAMETER SkipEventHubCreation
    Skip Event Hub creation if it already exists.

.PARAMETER SkipFunctionDeployment
    Skip Azure Function deployment if it already exists.

.PARAMETER SkipDiagnosticSettings
    Skip configuring diagnostic settings in the source tenant.

.PARAMETER VerifyOnly
    Only verify existing configuration without making changes.

.EXAMPLE
    # OPTION 1 (RECOMMENDED): Edit the CONFIGURATION SECTION in this script, then run:
    .\Configure-EntraIDLogsViaEventHub.ps1

.EXAMPLE
    # OPTION 2: Pass all parameters on the command line
    .\Configure-EntraIDLogsViaEventHub.ps1 `
        -ManagingTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ManagingSubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
        -SourceTenantId "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz" `
        -SourceTenantName "Atevet17" `
        -EventHubNamespaceName "eh-ns-entra-logs-atevet17" `
        -FunctionAppName "func-entra-logs-atevet17" `
        -KeyVaultName "kv-central-atevet12" `
        -WorkspaceResourceId "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

.EXAMPLE
    # Skip Event Hub creation if it already exists
    .\Configure-EntraIDLogsViaEventHub.ps1 -SkipEventHubCreation

.EXAMPLE
    # Verify existing configuration without making changes
    .\Configure-EntraIDLogsViaEventHub.ps1 -VerifyOnly

.NOTES
    Author: Cross-Tenant Log Collection Guide
    Requires: Az.Accounts, Az.EventHub, Az.Functions, Az.KeyVault, Az.Monitor, Az.OperationalInsights modules
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ManagingTenantId,

    [Parameter(Mandatory = $false)]
    [string]$ManagingSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$SourceTenantId,

    [Parameter(Mandatory = $false)]
    [string]$SourceTenantName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$EventHubNamespaceName,

    [Parameter(Mandatory = $false)]
    [string]$EventHubName,

    [Parameter(Mandatory = $false)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceResourceId,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [string[]]$LogCategories,

    [Parameter(Mandatory = $false)]
    [string]$DiagnosticSettingName,

    [Parameter(Mandatory = $false)]
    [switch]$SkipEventHubCreation,

    [Parameter(Mandatory = $false)]
    [switch]$SkipFunctionDeployment,

    [Parameter(Mandatory = $false)]
    [switch]$SkipDiagnosticSettings,

    [Parameter(Mandatory = $false)]
    [switch]$VerifyOnly
)

#region ==================== CONFIGURATION SECTION ====================
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║  INSTRUCTIONS: Edit the values below with your environment details ║
# ║  After editing, simply run: .\Configure-EntraIDLogsViaEventHub.ps1 ║
# ║                                                                     ║
# ║  Command-line parameters will OVERRIDE these values if provided.   ║
# ╚═══════════════════════════════════════════════════════════════════╝
#
# =====================================================================

# REQUIRED: Managing Tenant Configuration
$Config_ManagingTenantId       = ""    # e.g., "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
$Config_ManagingSubscriptionId = ""    # e.g., "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"

# REQUIRED: Source Tenant Configuration
$Config_SourceTenantId         = ""    # e.g., "zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz"
$Config_SourceTenantName       = ""    # e.g., "Atevet17" (friendly name, used in resource naming)

# REQUIRED: Resource Names (must be globally unique for Event Hub and Function App)
$Config_EventHubNamespaceName  = ""    # e.g., "eh-ns-entra-logs-atevet17"
$Config_FunctionAppName        = ""    # e.g., "func-entra-logs-atevet17"
$Config_KeyVaultName           = ""    # e.g., "kv-central-atevet12" (from Step 1)

# REQUIRED: Log Analytics Workspace
$Config_WorkspaceResourceId    = ""    # e.g., "/subscriptions/xxx/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

# OPTIONAL: Resource Configuration (defaults are usually fine)
$Config_ResourceGroupName      = "rg-entra-logs-eventhub"
$Config_EventHubName           = "eh-entra-id-logs"
$Config_Location               = "westus2"
$Config_DiagnosticSettingName  = "SendToEventHub"

# OPTIONAL: Log Categories to collect (comment out any you don't need)
$Config_LogCategories = @(
    "AuditLogs",                    # Directory changes - FREE
    "SignInLogs",                   # Interactive sign-ins - P1/P2
    "NonInteractiveUserSignInLogs", # Non-interactive sign-ins - P1/P2
    "ServicePrincipalSignInLogs",   # App sign-ins - P1/P2
    "ManagedIdentitySignInLogs",    # Managed identity sign-ins - P1/P2
    "ProvisioningLogs",             # User provisioning - P1/P2
    "ADFSSignInLogs",               # AD FS sign-ins - P1/P2
    "RiskyUsers",                   # Risky users - P2
    "UserRiskEvents",               # Risk events - P2
    "RiskyServicePrincipals",       # Risky service principals - P2
    "ServicePrincipalRiskEvents",   # SP risk events - P2
    "MicrosoftGraphActivityLogs",   # Graph API activity - P1/P2
    "NetworkAccessTrafficLogs"      # Global Secure Access - P1/P2
)

#endregion ================ END CONFIGURATION SECTION =================

# Apply configuration values if parameters were not provided
if ([string]::IsNullOrWhiteSpace($ManagingTenantId)) { $ManagingTenantId = $Config_ManagingTenantId }
if ([string]::IsNullOrWhiteSpace($ManagingSubscriptionId)) { $ManagingSubscriptionId = $Config_ManagingSubscriptionId }
if ([string]::IsNullOrWhiteSpace($SourceTenantId)) { $SourceTenantId = $Config_SourceTenantId }
if ([string]::IsNullOrWhiteSpace($SourceTenantName)) { $SourceTenantName = $Config_SourceTenantName }
if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) { $ResourceGroupName = $Config_ResourceGroupName }
if ([string]::IsNullOrWhiteSpace($EventHubNamespaceName)) { $EventHubNamespaceName = $Config_EventHubNamespaceName }
if ([string]::IsNullOrWhiteSpace($EventHubName)) { $EventHubName = $Config_EventHubName }
if ([string]::IsNullOrWhiteSpace($FunctionAppName)) { $FunctionAppName = $Config_FunctionAppName }
if ([string]::IsNullOrWhiteSpace($KeyVaultName)) { $KeyVaultName = $Config_KeyVaultName }
if ([string]::IsNullOrWhiteSpace($WorkspaceResourceId)) { $WorkspaceResourceId = $Config_WorkspaceResourceId }
if ([string]::IsNullOrWhiteSpace($Location)) { $Location = $Config_Location }
if ($null -eq $LogCategories -or $LogCategories.Count -eq 0) { $LogCategories = $Config_LogCategories }
if ([string]::IsNullOrWhiteSpace($DiagnosticSettingName)) { $DiagnosticSettingName = $Config_DiagnosticSettingName }

# Validate required parameters
$missingParams = @()
if ([string]::IsNullOrWhiteSpace($ManagingTenantId)) { $missingParams += "ManagingTenantId" }
if ([string]::IsNullOrWhiteSpace($ManagingSubscriptionId)) { $missingParams += "ManagingSubscriptionId" }
if ([string]::IsNullOrWhiteSpace($SourceTenantId)) { $missingParams += "SourceTenantId" }
if ([string]::IsNullOrWhiteSpace($SourceTenantName)) { $missingParams += "SourceTenantName" }
if ([string]::IsNullOrWhiteSpace($EventHubNamespaceName)) { $missingParams += "EventHubNamespaceName" }
if ([string]::IsNullOrWhiteSpace($KeyVaultName)) { $missingParams += "KeyVaultName" }
if ([string]::IsNullOrWhiteSpace($WorkspaceResourceId)) { $missingParams += "WorkspaceResourceId" }

if ($missingParams.Count -gt 0) {
    Write-Host ""
    Write-Host "╔═══════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║  ERROR: Missing required configuration values                      ║" -ForegroundColor Red
    Write-Host "╚═══════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    foreach ($param in $missingParams) {
        Write-Host "  ✗ $param" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Please either:" -ForegroundColor Cyan
    Write-Host "  1. Edit the CONFIGURATION SECTION in this script (lines 165-200)" -ForegroundColor White
    Write-Host "  2. Or pass the values as command-line parameters" -ForegroundColor White
    Write-Host ""
    Write-Host "Example:" -ForegroundColor Cyan
    Write-Host '  .\Configure-EntraIDLogsViaEventHub.ps1 `' -ForegroundColor Gray
    Write-Host '      -ManagingTenantId "your-managing-tenant-id" `' -ForegroundColor Gray
    Write-Host '      -ManagingSubscriptionId "your-subscription-id" `' -ForegroundColor Gray
    Write-Host '      -SourceTenantId "your-source-tenant-id" `' -ForegroundColor Gray
    Write-Host '      -SourceTenantName "SourceTenantName" `' -ForegroundColor Gray
    Write-Host '      -EventHubNamespaceName "eh-ns-entra-logs-unique" `' -ForegroundColor Gray
    Write-Host '      -KeyVaultName "kv-central-name" `' -ForegroundColor Gray
    Write-Host '      -WorkspaceResourceId "/subscriptions/.../workspaces/law-name"' -ForegroundColor Gray
    Write-Host ""
    exit 1
}

# Color functions for output
function Write-Success { param($Message) Write-Host $Message -ForegroundColor Green }
function Write-ErrorMsg { param($Message) Write-Host $Message -ForegroundColor Red }
function Write-WarningMsg { param($Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Info { param($Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Header { param($Message) Write-Host $Message -ForegroundColor Cyan -BackgroundColor DarkBlue }

# Results tracking
$results = @{
    ManagingTenantId = $ManagingTenantId
    SourceTenantId = $SourceTenantId
    SourceTenantName = $SourceTenantName
    EventHubNamespace = $null
    EventHubName = $EventHubName
    EventHubConnectionString = $null
    EventHubAuthRuleId = $null
    FunctionAppName = $FunctionAppName
    DiagnosticSettingConfigured = $false
    LogCategoriesEnabled = @()
    Errors = @()
}

# Main script execution
Write-Host ""
Write-Header "======================================================================"
Write-Header "    Configure Entra ID Logs via Event Hub - Cross-Tenant Collection   "
Write-Header "======================================================================"
Write-Host ""

#region Verify Only Mode
if ($VerifyOnly) {
    Write-Info "Running in VERIFY ONLY mode - no changes will be made"
    Write-Host ""
    
    # Connect to managing tenant
    Write-Info "Connecting to managing tenant..."
    Connect-AzAccount -TenantId $ManagingTenantId -Subscription $ManagingSubscriptionId -ErrorAction Stop | Out-Null
    
    # Check Event Hub
    Write-Info "Checking Event Hub configuration..."
    $ehNamespace = Get-AzEventHubNamespace -ResourceGroupName $ResourceGroupName -Name $EventHubNamespaceName -ErrorAction SilentlyContinue
    if ($ehNamespace) {
        Write-Success "  ✓ Event Hub Namespace exists: $EventHubNamespaceName"
        $eh = Get-AzEventHub -ResourceGroupName $ResourceGroupName -NamespaceName $EventHubNamespaceName -Name $EventHubName -ErrorAction SilentlyContinue
        if ($eh) {
            Write-Success "  ✓ Event Hub exists: $EventHubName"
        } else {
            Write-WarningMsg "  ⚠ Event Hub not found: $EventHubName"
        }
    } else {
        Write-WarningMsg "  ⚠ Event Hub Namespace not found: $EventHubNamespaceName"
    }
    
    # Check Function App
    if ($FunctionAppName) {
        Write-Info "Checking Function App..."
        $funcApp = Get-AzFunctionApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction SilentlyContinue
        if ($funcApp) {
            Write-Success "  ✓ Function App exists: $FunctionAppName"
        } else {
            Write-WarningMsg "  ⚠ Function App not found: $FunctionAppName"
        }
    }
    
    # Connect to source tenant and check diagnostic settings
    Write-Info "Connecting to source tenant to check diagnostic settings..."
    Connect-AzAccount -TenantId $SourceTenantId -ErrorAction Stop | Out-Null
    
    $diagSettings = Invoke-AzRestMethod -Path "/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01" -Method GET
    if ($diagSettings.StatusCode -eq 200) {
        $settings = ($diagSettings.Content | ConvertFrom-Json).value
        $eventHubSetting = $settings | Where-Object { $_.name -eq $DiagnosticSettingName }
        if ($eventHubSetting) {
            Write-Success "  ✓ Diagnostic setting exists: $DiagnosticSettingName"
            $enabledCategories = $eventHubSetting.properties.logs | Where-Object { $_.enabled -eq $true } | Select-Object -ExpandProperty category
            Write-Success "    Enabled categories: $($enabledCategories -join ', ')"
        } else {
            Write-WarningMsg "  ⚠ Diagnostic setting not found: $DiagnosticSettingName"
        }
    }
    
    Write-Host ""
    Write-Info "Verification complete."
    return $results
}
#endregion

#region Step 1: Connect to Managing Tenant and Create Event Hub
Write-Info "Step 1: Setting up Event Hub in Managing Tenant"
Write-Host ""

if (-not $SkipEventHubCreation) {
    Write-Info "Connecting to managing tenant: $ManagingTenantId"
    Write-Info "  Using subscription: $ManagingSubscriptionId"
    Connect-AzAccount -TenantId $ManagingTenantId -Subscription $ManagingSubscriptionId -ErrorAction Stop | Out-Null
    Write-Success "  Connected to managing tenant"
    
    # Create Resource Group if not exists
    Write-Info "Creating resource group: $ResourceGroupName"
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg) {
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop | Out-Null
        Write-Success "  ✓ Resource group created"
    } else {
        Write-WarningMsg "  Resource group already exists"
    }
    
    # Create Event Hub Namespace
    Write-Info "Creating Event Hub Namespace: $EventHubNamespaceName"
    $ehNamespace = Get-AzEventHubNamespace -ResourceGroupName $ResourceGroupName -Name $EventHubNamespaceName -ErrorAction SilentlyContinue
    if (-not $ehNamespace) {
        $ehNamespace = New-AzEventHubNamespace `
            -ResourceGroupName $ResourceGroupName `
            -Name $EventHubNamespaceName `
            -Location $Location `
            -SkuName "Standard" `
            -SkuCapacity 1 `
            -EnableAutoInflate `
            -MaximumThroughputUnit 10 `
            -ErrorAction Stop
        Write-Success "  ✓ Event Hub Namespace created"
        # Wait for namespace to be fully provisioned
        Write-Info "  Waiting for namespace to be ready..."
        Start-Sleep -Seconds 30
    } else {
        Write-WarningMsg "  Event Hub Namespace already exists"
    }
    $results.EventHubNamespace = $EventHubNamespaceName
    
    # Create Event Hub
    Write-Info "Creating Event Hub: $EventHubName"
    $eh = Get-AzEventHub -ResourceGroupName $ResourceGroupName -NamespaceName $EventHubNamespaceName -Name $EventHubName -ErrorAction SilentlyContinue
    if (-not $eh) {
        New-AzEventHub `
            -ResourceGroupName $ResourceGroupName `
            -NamespaceName $EventHubNamespaceName `
            -Name $EventHubName `
            -PartitionCount 4 `
            -RetentionTimeInHour 168 `
            -ErrorAction Stop | Out-Null
        Write-Success "  ✓ Event Hub created"
        # Wait for Event Hub to be fully provisioned
        Start-Sleep -Seconds 10
    } else {
        Write-WarningMsg "  Event Hub already exists"
    }
    
    # Create Consumer Group for Log Analytics
    Write-Info "Creating consumer group: cg-loganalytics"
    $cg = Get-AzEventHubConsumerGroup -ResourceGroupName $ResourceGroupName -NamespaceName $EventHubNamespaceName -EventHubName $EventHubName -Name "cg-loganalytics" -ErrorAction SilentlyContinue
    if (-not $cg) {
        New-AzEventHubConsumerGroup `
            -ResourceGroupName $ResourceGroupName `
            -NamespaceName $EventHubNamespaceName `
            -EventHubName $EventHubName `
            -Name "cg-loganalytics" `
            -ErrorAction Stop | Out-Null
        Write-Success "  ✓ Consumer group created"
    } else {
        Write-WarningMsg "  Consumer group already exists"
    }
    
    # Create Shared Access Policy for source tenant (Send only)
    $policyName = "$SourceTenantName-send-policy"
    Write-Info "Creating Shared Access Policy: $policyName"
    $policy = Get-AzEventHubAuthorizationRule -ResourceGroupName $ResourceGroupName -NamespaceName $EventHubNamespaceName -Name $policyName -ErrorAction SilentlyContinue
    if (-not $policy) {
        New-AzEventHubAuthorizationRule `
            -ResourceGroupName $ResourceGroupName `
            -NamespaceName $EventHubNamespaceName `
            -Name $policyName `
            -Rights @("Send") `
            -ErrorAction Stop | Out-Null
        Write-Success "  ✓ Shared Access Policy created (Send only)"
    } else {
        Write-WarningMsg "  Shared Access Policy already exists"
    }
    
    # Get connection string and authorization rule ID
    $keys = Get-AzEventHubKey -ResourceGroupName $ResourceGroupName -NamespaceName $EventHubNamespaceName -Name $policyName
    $results.EventHubConnectionString = $keys.PrimaryConnectionString
    
    # Get the authorization rule resource ID
    $authRule = Get-AzEventHubAuthorizationRule -ResourceGroupName $ResourceGroupName -NamespaceName $EventHubNamespaceName -Name $policyName
    $results.EventHubAuthRuleId = $authRule.Id
    
    Write-Success "  ✓ Connection string retrieved"
    Write-Info "  Authorization Rule ID: $($results.EventHubAuthRuleId)"
    
    # Store connection string in Key Vault
    Write-Info "Storing connection string in Key Vault: $KeyVaultName"
    $secretName = "EventHub-$SourceTenantName-EntraID-ConnectionString"
    try {
        Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -SecretValue (ConvertTo-SecureString $keys.PrimaryConnectionString -AsPlainText -Force) -ErrorAction Stop | Out-Null
        Write-Success "  ✓ Connection string stored in Key Vault"
    } catch {
        Write-WarningMsg "  ⚠ Could not store in Key Vault: $($_.Exception.Message)"
        $results.Errors += "Key Vault storage failed: $($_.Exception.Message)"
    }
    
    Write-Host ""
} else {
    Write-Info "Skipping Event Hub creation (--SkipEventHubCreation specified)"
    
    # Still need to get the authorization rule ID for diagnostic settings
    Write-Info "Retrieving existing Event Hub configuration..."
    Connect-AzAccount -TenantId $ManagingTenantId -Subscription $ManagingSubscriptionId -ErrorAction Stop | Out-Null
    
    $policyName = "$SourceTenantName-send-policy"
    $authRule = Get-AzEventHubAuthorizationRule -ResourceGroupName $ResourceGroupName -NamespaceName $EventHubNamespaceName -Name $policyName -ErrorAction SilentlyContinue
    if ($authRule) {
        $results.EventHubAuthRuleId = $authRule.Id
        $results.EventHubNamespace = $EventHubNamespaceName
        Write-Success "  ✓ Found existing authorization rule"
    } else {
        Write-ErrorMsg "  ✗ Could not find authorization rule: $policyName"
        $results.Errors += "Authorization rule not found"
    }
    
    Write-Host ""
}
#endregion

#region Step 2: Deploy Azure Function for Log Processing
Write-Info "Step 2: Azure Function for Log Processing"
Write-Host ""

if (-not $SkipFunctionDeployment -and $FunctionAppName) {
    # Ensure we're in managing tenant context
    Set-AzContext -SubscriptionId $ManagingSubscriptionId -ErrorAction Stop | Out-Null
    
    # Create Storage Account for Function App
    $storageAccountName = "st" + ($FunctionAppName -replace '[^a-z0-9]', '').ToLower()
    if ($storageAccountName.Length -gt 24) {
        $storageAccountName = $storageAccountName.Substring(0, 24)
    }
    
    Write-Info "Creating Storage Account: $storageAccountName"
    $storage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $storageAccountName -ErrorAction SilentlyContinue
    if (-not $storage) {
        try {
            New-AzStorageAccount `
                -ResourceGroupName $ResourceGroupName `
                -Name $storageAccountName `
                -Location $Location `
                -SkuName "Standard_LRS" `
                -Kind "StorageV2" `
                -ErrorAction Stop | Out-Null
            Write-Success "  ✓ Storage Account created"
        } catch {
            Write-WarningMsg "  ⚠ Storage Account creation failed: $($_.Exception.Message)"
            $results.Errors += "Storage Account creation failed: $($_.Exception.Message)"
        }
    } else {
        Write-WarningMsg "  Storage Account already exists"
    }
    
    # Create Function App
    Write-Info "Creating Function App: $FunctionAppName"
    $funcApp = Get-AzFunctionApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction SilentlyContinue
    if (-not $funcApp) {
        try {
            New-AzFunctionApp `
                -ResourceGroupName $ResourceGroupName `
                -Name $FunctionAppName `
                -StorageAccountName $storageAccountName `
                -Location $Location `
                -Runtime "Python" `
                -RuntimeVersion "3.9" `
                -FunctionsVersion "4" `
                -OSType "Linux" `
                -ErrorAction Stop | Out-Null
            Write-Success "  ✓ Function App created"
            
            # Enable System-Assigned Managed Identity
            Update-AzFunctionApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -IdentityType SystemAssigned -ErrorAction Stop | Out-Null
            Write-Success "  ✓ Managed Identity enabled"
        } catch {
            Write-WarningMsg "  ⚠ Function App creation failed: $($_.Exception.Message)"
            $results.Errors += "Function App creation failed: $($_.Exception.Message)"
        }
    } else {
        Write-WarningMsg "  Function App already exists"
    }
    
    # Get Log Analytics Workspace details
    $workspaceIdParts = $WorkspaceResourceId -split "/"
    $workspaceSubscriptionId = $workspaceIdParts[2]
    $workspaceResourceGroup = $workspaceIdParts[4]
    $workspaceName = $workspaceIdParts[8]
    
    try {
        $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $workspaceResourceGroup -Name $workspaceName -ErrorAction Stop
        $workspaceKeys = Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $workspaceResourceGroup -Name $workspaceName -ErrorAction Stop
        
        # Get Event Hub connection string for listening
        $listenKeys = Get-AzEventHubKey -ResourceGroupName $ResourceGroupName -NamespaceName $EventHubNamespaceName -Name "RootManageSharedAccessKey"
        
        # Configure Function App settings
        Write-Info "Configuring Function App settings..."
        $appSettings = @{
            "EventHubConnection" = $listenKeys.PrimaryConnectionString
            "EventHubName" = $EventHubName
            "LOG_ANALYTICS_WORKSPACE_ID" = $workspace.CustomerId.ToString()
            "LOG_ANALYTICS_WORKSPACE_KEY" = $workspaceKeys.PrimarySharedKey
            "SOURCE_TENANT_NAME" = $SourceTenantName
            "SOURCE_TENANT_ID" = $SourceTenantId
        }
        
        Update-AzFunctionAppSetting -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -AppSetting $appSettings -ErrorAction Stop | Out-Null
        Write-Success "  ✓ Function App settings configured"
    } catch {
        Write-WarningMsg "  ⚠ Could not configure Function App settings: $($_.Exception.Message)"
        $results.Errors += "Function App settings failed: $($_.Exception.Message)"
    }
    
    # Output Function code deployment instructions
    Write-Host ""
    Write-Info "=== Function Code Deployment Required ==="
    Write-Host ""
    Write-Host "Deploy the Azure Function code from the 'EntraIDLogsProcessor' folder:"
    Write-Host ""
    Write-Host "  cd EntraIDLogsProcessor"
    Write-Host "  func azure functionapp publish $FunctionAppName --python"
    Write-Host ""
    Write-Host "Or use zip deployment:"
    Write-Host ""
    Write-Host "  zip -r function.zip ."
    Write-Host "  az functionapp deployment source config-zip \"
    Write-Host "      --name `"$FunctionAppName`" \"
    Write-Host "      --resource-group `"$ResourceGroupName`" \"
    Write-Host "      --src `"function.zip`""
    Write-Host ""
    
} elseif (-not $FunctionAppName) {
    Write-WarningMsg "Function App name not provided - skipping Function deployment"
    Write-Info "You will need to manually deploy an Azure Function to process Event Hub events"
    Write-Host ""
} else {
    Write-Info "Skipping Function deployment (--SkipFunctionDeployment specified)"
    Write-Host ""
}
#endregion

#region Step 3: Configure Entra ID Diagnostic Settings in Source Tenant
Write-Info "Step 3: Configuring Entra ID Diagnostic Settings in Source Tenant"
Write-Host ""

if (-not $SkipDiagnosticSettings -and $results.EventHubAuthRuleId) {
    Write-Info "Connecting to source tenant: $SourceTenantId"
    Write-WarningMsg "  You will be prompted to authenticate as Global Administrator"
    
    try {
        Connect-AzAccount -TenantId $SourceTenantId -ErrorAction Stop | Out-Null
        Write-Success "  Connected to source tenant"
        
        # Build the logs array for the API call
        $logsArray = $LogCategories | ForEach-Object {
            @{
                category = $_
                enabled = $true
            }
        }
        
        # Create the diagnostic setting using REST API
        $body = @{
            properties = @{
                eventHubAuthorizationRuleId = $results.EventHubAuthRuleId
                eventHubName = $EventHubName
                logs = $logsArray
            }
        } | ConvertTo-Json -Depth 10
        
        $uri = "https://management.azure.com/providers/microsoft.aadiam/diagnosticSettings/${DiagnosticSettingName}?api-version=2017-04-01"
        
        Write-Info "Creating diagnostic setting: $DiagnosticSettingName"
        $response = Invoke-AzRestMethod -Uri $uri -Method PUT -Payload $body
        
        if ($response.StatusCode -in @(200, 201)) {
            Write-Success "  ✓ Diagnostic setting created successfully"
            $results.DiagnosticSettingConfigured = $true
            $results.LogCategoriesEnabled = $LogCategories
        } else {
            $errorContent = $response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
            $errorMessage = if ($errorContent.error) { $errorContent.error.message } else { $response.Content }
            Write-ErrorMsg "  ✗ Failed to create diagnostic setting: $errorMessage"
            $results.Errors += "Diagnostic setting failed: $errorMessage"
        }
    } catch {
        Write-ErrorMsg "  ✗ Error configuring diagnostic settings: $($_.Exception.Message)"
        $results.Errors += "Diagnostic settings error: $($_.Exception.Message)"
    }
} elseif (-not $results.EventHubAuthRuleId) {
    Write-ErrorMsg "Cannot configure diagnostic settings - Event Hub authorization rule ID not available"
    $results.Errors += "Missing Event Hub authorization rule ID"
} else {
    Write-Info "Skipping diagnostic settings configuration (--SkipDiagnosticSettings specified)"
}
Write-Host ""
#endregion

#region Output Summary
Write-Host ""
Write-Header "======================================================================"
Write-Header "                              SUMMARY                                 "
Write-Header "======================================================================"
Write-Host ""

Write-Host "Managing Tenant ID:        $ManagingTenantId"
Write-Host "Source Tenant ID:          $SourceTenantId"
Write-Host "Source Tenant Name:        $SourceTenantName"
Write-Host ""
Write-Host "Event Hub Namespace:       $($results.EventHubNamespace)"
Write-Host "Event Hub Name:            $($results.EventHubName)"
Write-Host "Event Hub Auth Rule ID:    $($results.EventHubAuthRuleId)"
Write-Host ""

if ($results.DiagnosticSettingConfigured) {
    Write-Success "Diagnostic Setting:        ✓ Configured"
    Write-Success "Log Categories Enabled:    $($results.LogCategoriesEnabled -join ', ')"
} else {
    Write-WarningMsg "Diagnostic Setting:        Not configured"
}
Write-Host ""

if ($results.Errors.Count -gt 0) {
    Write-WarningMsg "Errors encountered:"
    foreach ($err in $results.Errors) {
        Write-ErrorMsg "  - $err"
    }
    Write-Host ""
}

Write-Info "=== Next Steps ==="
Write-Host ""
if (-not $SkipFunctionDeployment -and $FunctionAppName) {
    Write-Host "1. Deploy the Azure Function code to process Event Hub events"
}
Write-Host "2. Wait 5-15 minutes for logs to start flowing"
Write-Host "3. Verify logs in Log Analytics using the KQL queries in the documentation"
Write-Host "4. Proceed to Step 7 to configure Microsoft 365 Audit Logs"
Write-Host ""

# Output as JSON for automation
Write-Info "=== JSON Output (for automation) ==="
Write-Host ""
$jsonOutput = @{
    managingTenantId = $results.ManagingTenantId
    sourceTenantId = $results.SourceTenantId
    sourceTenantName = $results.SourceTenantName
    eventHubNamespace = $results.EventHubNamespace
    eventHubName = $results.EventHubName
    eventHubAuthRuleId = $results.EventHubAuthRuleId
    diagnosticSettingConfigured = $results.DiagnosticSettingConfigured
    logCategoriesEnabled = $results.LogCategoriesEnabled
    errors = $results.Errors
} | ConvertTo-Json -Depth 3

Write-Host $jsonOutput
Write-Host ""
#endregion

# Return results
return $results
