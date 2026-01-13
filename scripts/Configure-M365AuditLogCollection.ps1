<#
.SYNOPSIS
    Configures Microsoft 365 audit log collection from source tenants to a central Log Analytics workspace.

.DESCRIPTION
    This script automates Step 7 of the Azure Cross-Tenant Log Collection Guide.
    It sets up a multi-tenant application with Office 365 Management API permissions
    to collect M365 audit logs from source tenants and send them to a central
    Log Analytics workspace in the managing tenant.
    
    The script performs the following:
    1. Creates a multi-tenant app registration in the managing tenant
    2. Configures Office 365 Management API permissions (ActivityFeed.Read, ActivityFeed.ReadDlp)
    3. Creates a client secret and stores it in Key Vault
    4. Grants admin consent in the source tenant (requires Global Admin)
    5. Creates subscriptions to M365 audit content types
    
    IMPORTANT: This script requires Global Administrator access to BOTH tenants.
    Azure Lighthouse does NOT provide access to M365 audit logs.

.PARAMETER ManagingTenantId
    The Tenant ID of the managing tenant (where the app registration and Key Vault exist).

.PARAMETER SourceTenantId
    The Tenant ID of the source tenant (where M365 audit logs originate).

.PARAMETER SourceTenantName
    A friendly name for the source tenant (used for logging and Key Vault secrets).

.PARAMETER KeyVaultName
    The name of the Key Vault in the managing tenant to store credentials.

.PARAMETER WorkspaceResourceId
    The full resource ID of the Log Analytics workspace in the managing tenant.

.PARAMETER AppDisplayName
    The display name for the multi-tenant app registration. Default: "M365-AuditLogs-Collector"

.PARAMETER ContentTypes
    Array of M365 content types to subscribe to. Default: All available types.

.PARAMETER SecretValidityYears
    How many years the client secret should be valid. Default: 1

.PARAMETER SkipAppCreation
    If specified, skips app creation and uses existing app credentials from Key Vault.

.PARAMETER VerifyOnly
    If specified, only verifies existing configuration without making changes.

.EXAMPLE
    # Full setup: Create app, grant consent, create subscriptions
    .\Configure-M365AuditLogCollection.ps1 `
        -ManagingTenantId "<ATEVET12-TENANT-ID>" `
        -SourceTenantId "<ATEVET17-TENANT-ID>" `
        -SourceTenantName "Atevet17" `
        -KeyVaultName "kv-central-atevet12" `
        -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

.EXAMPLE
    # Add another source tenant (app already exists)
    .\Configure-M365AuditLogCollection.ps1 `
        -ManagingTenantId "<ATEVET12-TENANT-ID>" `
        -SourceTenantId "<ATEVET18-TENANT-ID>" `
        -SourceTenantName "Atevet18" `
        -KeyVaultName "kv-central-atevet12" `
        -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
        -SkipAppCreation

.EXAMPLE
    # Verify existing configuration
    .\Configure-M365AuditLogCollection.ps1 `
        -ManagingTenantId "<ATEVET12-TENANT-ID>" `
        -SourceTenantId "<ATEVET17-TENANT-ID>" `
        -SourceTenantName "Atevet17" `
        -KeyVaultName "kv-central-atevet12" `
        -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
        -VerifyOnly

.NOTES
    Author: Azure Cross-Tenant Log Collection Guide
    Version: 1.0
    Requires: Microsoft.Graph PowerShell SDK, Az PowerShell module
    
    Office 365 Management API Reference:
    https://docs.microsoft.com/en-us/office/office-365-management-api/office-365-management-apis-overview
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManagingTenantId,

    [Parameter(Mandatory = $true)]
    [string]$SourceTenantId,

    [Parameter(Mandatory = $true)]
    [string]$SourceTenantName,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceResourceId,

    [Parameter(Mandatory = $false)]
    [string]$AppDisplayName = "M365-AuditLogs-Collector",

    [Parameter(Mandatory = $false)]
    [string[]]$ContentTypes = @(
        "Audit.AzureActiveDirectory",
        "Audit.Exchange",
        "Audit.SharePoint",
        "Audit.General",
        "DLP.All"
    ),

    [Parameter(Mandatory = $false)]
    [int]$SecretValidityYears = 1,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAppCreation,

    [Parameter(Mandatory = $false)]
    [switch]$VerifyOnly
)

#region Helper Functions

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "Info"    { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
    }
    
    $prefix = switch ($Level) {
        "Info"    { "[INFO]" }
        "Success" { "[SUCCESS]" }
        "Warning" { "[WARNING]" }
        "Error"   { "[ERROR]" }
    }
    
    Write-Host "$timestamp $prefix $Message" -ForegroundColor $color
}

function Test-ModuleInstalled {
    param([string]$ModuleName)
    
    $module = Get-Module -ListAvailable -Name $ModuleName
    return $null -ne $module
}

#endregion

#region Prerequisites Check

Write-Log "========================================" -Level Info
Write-Log "Step 7: Configure Microsoft 365 Audit Logs" -Level Info
Write-Log "========================================" -Level Info

# Check required modules
Write-Log "Checking prerequisites..." -Level Info

if (-not (Test-ModuleInstalled "Microsoft.Graph.Applications")) {
    Write-Log "Microsoft.Graph module not found. Install with: Install-Module Microsoft.Graph" -Level Error
    exit 1
}

if (-not (Test-ModuleInstalled "Az.Accounts")) {
    Write-Log "Az module not found. Install with: Install-Module Az" -Level Error
    exit 1
}

Write-Log "All required modules are installed" -Level Success

#endregion

#region Variables

# Office 365 Management API well-known IDs
$office365ManagementApiAppId = "c5393580-f805-4401-95e8-94b7a6ef2fc2"

# Permission IDs for Office 365 Management APIs
$permissionIds = @{
    "ActivityFeed.Read"     = "594c1fb6-4f81-4f82-b6fd-d5b5a0e7e4a6"
    "ActivityFeed.ReadDlp"  = "4807a72c-ad38-4250-94c9-4eabfe26cd55"
    "ServiceHealth.Read"    = "e2cea78f-e743-4d8f-a16a-75b629a038ae"
}

$appId = $null
$appSecret = $null
$endDate = (Get-Date).AddYears($SecretValidityYears)

#endregion

#region Step 1: Create Multi-Tenant App in Managing Tenant

if (-not $SkipAppCreation -and -not $VerifyOnly) {
    Write-Log "" -Level Info
    Write-Log "Step 1: Creating multi-tenant app in managing tenant..." -Level Info
    Write-Log "Connecting to Microsoft Graph in managing tenant ($ManagingTenantId)..." -Level Info
    
    try {
        Connect-MgGraph -TenantId $ManagingTenantId -Scopes "Application.ReadWrite.All" -NoWelcome -ErrorAction Stop
        Write-Log "Connected to Microsoft Graph" -Level Success
    }
    catch {
        Write-Log "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -Level Error
        exit 1
    }
    
    # Check if app already exists
    $existingApp = Get-MgApplication -Filter "displayName eq '$AppDisplayName'" -ErrorAction SilentlyContinue
    
    if ($existingApp) {
        Write-Log "App '$AppDisplayName' already exists (AppId: $($existingApp.AppId))" -Level Warning
        $response = Read-Host "Do you want to create a new secret and continue? (y/n)"
        if ($response -ne 'y') {
            Write-Log "Exiting without changes" -Level Warning
            exit 0
        }
        $app = $existingApp
    }
    else {
        # Create new multi-tenant app registration
        Write-Log "Creating new app registration: $AppDisplayName" -Level Info
        
        $requiredResourceAccess = @{
            ResourceAppId = $office365ManagementApiAppId
            ResourceAccess = @(
                @{
                    Id = $permissionIds["ActivityFeed.Read"]
                    Type = "Role"
                },
                @{
                    Id = $permissionIds["ActivityFeed.ReadDlp"]
                    Type = "Role"
                },
                @{
                    Id = $permissionIds["ServiceHealth.Read"]
                    Type = "Role"
                }
            )
        }
        
        $appParams = @{
            DisplayName = $AppDisplayName
            SignInAudience = "AzureADMultipleOrgs"
            RequiredResourceAccess = @($requiredResourceAccess)
        }
        
        if ($PSCmdlet.ShouldProcess($AppDisplayName, "Create App Registration")) {
            $app = New-MgApplication @appParams -ErrorAction Stop
            Write-Log "App registration created successfully" -Level Success
            Write-Log "  Display Name: $($app.DisplayName)" -Level Info
            Write-Log "  Application ID: $($app.AppId)" -Level Info
            Write-Log "  Object ID: $($app.Id)" -Level Info
        }
    }
    
    $appId = $app.AppId
    
    # Create client secret
    Write-Log "Creating client secret (valid for $SecretValidityYears year(s))..." -Level Info
    
    $secretParams = @{
        PasswordCredential = @{
            DisplayName = "M365AuditCollector-$SourceTenantName"
            EndDateTime = $endDate
        }
    }
    
    if ($PSCmdlet.ShouldProcess("Client Secret", "Create")) {
        $secretResult = Add-MgApplicationPassword -ApplicationId $app.Id -BodyParameter $secretParams -ErrorAction Stop
        $appSecret = $secretResult.SecretText
        Write-Log "Client secret created (expires: $endDate)" -Level Success
    }
    
    # Create service principal in managing tenant
    Write-Log "Creating service principal in managing tenant..." -Level Info
    $existingSp = Get-MgServicePrincipal -Filter "appId eq '$appId'" -ErrorAction SilentlyContinue
    
    if (-not $existingSp) {
        if ($PSCmdlet.ShouldProcess("Service Principal", "Create")) {
            $sp = New-MgServicePrincipal -AppId $appId -ErrorAction Stop
            Write-Log "Service principal created" -Level Success
        }
    }
    else {
        Write-Log "Service principal already exists" -Level Info
    }
    
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}

#endregion

#region Step 2: Store Credentials in Key Vault

if (-not $VerifyOnly) {
    Write-Log "" -Level Info
    Write-Log "Step 2: Storing credentials in Key Vault..." -Level Info
    
    # Connect to Azure
    Write-Log "Connecting to Azure (managing tenant)..." -Level Info
    
    try {
        $azContext = Get-AzContext
        if (-not $azContext -or $azContext.Tenant.Id -ne $ManagingTenantId) {
            Connect-AzAccount -TenantId $ManagingTenantId -ErrorAction Stop
        }
        Write-Log "Connected to Azure" -Level Success
    }
    catch {
        Write-Log "Failed to connect to Azure: $($_.Exception.Message)" -Level Error
        exit 1
    }
    
    # Verify Key Vault access
    try {
        $keyVault = Get-AzKeyVault -VaultName $KeyVaultName -ErrorAction Stop
        Write-Log "Key Vault '$KeyVaultName' found" -Level Success
    }
    catch {
        Write-Log "Key Vault '$KeyVaultName' not found or no access: $($_.Exception.Message)" -Level Error
        exit 1
    }
    
    if (-not $SkipAppCreation -and $appId -and $appSecret) {
        # Store App ID
        if ($PSCmdlet.ShouldProcess("M365Collector-AppId", "Store in Key Vault")) {
            Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-AppId" `
                -SecretValue (ConvertTo-SecureString $appId -AsPlainText -Force) -ErrorAction Stop | Out-Null
            Write-Log "Stored: M365Collector-AppId" -Level Success
        }
        
        # Store Client Secret
        if ($PSCmdlet.ShouldProcess("M365Collector-Secret", "Store in Key Vault")) {
            Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Secret" `
                -SecretValue (ConvertTo-SecureString $appSecret -AsPlainText -Force) `
                -Expires $endDate -ErrorAction Stop | Out-Null
            Write-Log "Stored: M365Collector-Secret (expires: $endDate)" -Level Success
        }
    }
    else {
        # Retrieve existing credentials
        Write-Log "Retrieving existing app credentials from Key Vault..." -Level Info
        $appId = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-AppId" -AsPlainText -ErrorAction Stop
        $appSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Secret" -AsPlainText -ErrorAction Stop
        Write-Log "Retrieved existing credentials" -Level Success
    }
    
    # Update source tenants list
    Write-Log "Updating source tenants list..." -Level Info
    $tenantsSecretName = "M365Collector-Tenants"
    
    try {
        $existingTenantsJson = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $tenantsSecretName -AsPlainText -ErrorAction SilentlyContinue
        if ($existingTenantsJson) {
            $tenantsConfig = $existingTenantsJson | ConvertFrom-Json
        }
        else {
            $tenantsConfig = @{ tenants = @() }
        }
    }
    catch {
        $tenantsConfig = @{ tenants = @() }
    }
    
    # Check if tenant already exists
    $existingTenant = $tenantsConfig.tenants | Where-Object { $_.tenantId -eq $SourceTenantId }
    if (-not $existingTenant) {
        $tenantsConfig.tenants += @{
            tenantId = $SourceTenantId
            name = $SourceTenantName
            addedDate = (Get-Date -Format "yyyy-MM-dd")
        }
        
        if ($PSCmdlet.ShouldProcess($tenantsSecretName, "Update in Key Vault")) {
            $updatedJson = $tenantsConfig | ConvertTo-Json -Depth 5
            Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $tenantsSecretName `
                -SecretValue (ConvertTo-SecureString $updatedJson -AsPlainText -Force) -ErrorAction Stop | Out-Null
            Write-Log "Added '$SourceTenantName' to source tenants list" -Level Success
        }
    }
    else {
        Write-Log "Tenant '$SourceTenantName' already in source tenants list" -Level Info
    }
}

#endregion

#region Step 3: Grant Admin Consent in Source Tenant

if (-not $VerifyOnly) {
    Write-Log "" -Level Info
    Write-Log "Step 3: Granting admin consent in source tenant ($SourceTenantName)..." -Level Info
    Write-Log "Connecting to Microsoft Graph in source tenant ($SourceTenantId)..." -Level Info
    
    try {
        Connect-MgGraph -TenantId $SourceTenantId -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All" -NoWelcome -ErrorAction Stop
        Write-Log "Connected to Microsoft Graph in source tenant" -Level Success
    }
    catch {
        Write-Log "Failed to connect to source tenant: $($_.Exception.Message)" -Level Error
        Write-Log "Manual admin consent URL: https://login.microsoftonline.com/$SourceTenantId/adminconsent?client_id=$appId" -Level Warning
        exit 1
    }
    
    # Create service principal in source tenant (this is the "consent" action)
    Write-Log "Creating service principal in source tenant..." -Level Info
    $sourceSp = Get-MgServicePrincipal -Filter "appId eq '$appId'" -ErrorAction SilentlyContinue
    
    if (-not $sourceSp) {
        if ($PSCmdlet.ShouldProcess("Service Principal in Source Tenant", "Create")) {
            $sourceSp = New-MgServicePrincipal -AppId $appId -ErrorAction Stop
            Write-Log "Service principal created in source tenant" -Level Success
        }
    }
    else {
        Write-Log "Service principal already exists in source tenant" -Level Info
    }
    
    # Get Office 365 Management API service principal
    Write-Log "Granting Office 365 Management API permissions..." -Level Info
    $o365Sp = Get-MgServicePrincipal -Filter "appId eq '$office365ManagementApiAppId'" -ErrorAction Stop
    
    if (-not $o365Sp) {
        Write-Log "Office 365 Management API service principal not found in source tenant" -Level Error
        exit 1
    }
    
    # Grant app role assignments
    $permissionsToGrant = @("ActivityFeed.Read", "ActivityFeed.ReadDlp", "ServiceHealth.Read")
    
    foreach ($permName in $permissionsToGrant) {
        $permId = $permissionIds[$permName]
        
        # Check if already granted
        $existingAssignment = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sourceSp.Id -ErrorAction SilentlyContinue | 
            Where-Object { $_.AppRoleId -eq $permId }
        
        if (-not $existingAssignment) {
            if ($PSCmdlet.ShouldProcess($permName, "Grant Permission")) {
                $params = @{
                    PrincipalId = $sourceSp.Id
                    ResourceId = $o365Sp.Id
                    AppRoleId = $permId
                }
                New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sourceSp.Id -BodyParameter $params -ErrorAction Stop | Out-Null
                Write-Log "Granted: $permName" -Level Success
            }
        }
        else {
            Write-Log "Already granted: $permName" -Level Info
        }
    }
    
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}

#endregion

#region Step 4: Create M365 Audit Log Subscriptions

Write-Log "" -Level Info
Write-Log "Step 4: Creating M365 audit log subscriptions..." -Level Info

# Get credentials if not already set
if (-not $appId -or -not $appSecret) {
    Write-Log "Retrieving app credentials from Key Vault..." -Level Info
    $appId = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-AppId" -AsPlainText -ErrorAction Stop
    $appSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Secret" -AsPlainText -ErrorAction Stop
}

# Get OAuth token for source tenant
$tokenBody = @{
    grant_type    = "client_credentials"
    client_id     = $appId
    client_secret = $appSecret
    resource      = "https://manage.office.com"
}

try {
    $tokenResponse = Invoke-RestMethod `
        -Uri "https://login.microsoftonline.com/$SourceTenantId/oauth2/token" `
        -Method POST `
        -Body $tokenBody `
        -ErrorAction Stop
    
    $accessToken = $tokenResponse.access_token
    Write-Log "Obtained OAuth token for Office 365 Management API" -Level Success
}
catch {
    Write-Log "Failed to obtain OAuth token: $($_.Exception.Message)" -Level Error
    exit 1
}

$headers = @{
    "Authorization" = "Bearer $accessToken"
    "Content-Type"  = "application/json"
}

# Check existing subscriptions
Write-Log "Checking existing subscriptions..." -Level Info

try {
    $existingSubscriptions = Invoke-RestMethod `
        -Uri "https://manage.office.com/api/v1.0/$SourceTenantId/activity/feed/subscriptions/list" `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop
    
    $activeSubscriptions = $existingSubscriptions | Where-Object { $_.status -eq "enabled" }
    Write-Log "Found $($activeSubscriptions.Count) active subscription(s)" -Level Info
}
catch {
    Write-Log "No existing subscriptions found or error checking: $($_.Exception.Message)" -Level Warning
    $activeSubscriptions = @()
}

if (-not $VerifyOnly) {
    # Create subscriptions for each content type
    foreach ($contentType in $ContentTypes) {
        $existingSub = $activeSubscriptions | Where-Object { $_.contentType -eq $contentType }
        
        if ($existingSub) {
            Write-Log "Subscription already exists: $contentType" -Level Info
            continue
        }
        
        Write-Log "Creating subscription: $contentType" -Level Info
        
        try {
            if ($PSCmdlet.ShouldProcess($contentType, "Create Subscription")) {
                $response = Invoke-RestMethod `
                    -Uri "https://manage.office.com/api/v1.0/$SourceTenantId/activity/feed/subscriptions/start?contentType=$contentType" `
                    -Method POST `
                    -Headers $headers `
                    -ErrorAction Stop
                
                Write-Log "Subscription created: $contentType" -Level Success
            }
        }
        catch {
            Write-Log "Failed to create subscription for $contentType : $($_.Exception.Message)" -Level Warning
        }
    }
}

#endregion

#region Step 5: Verify Configuration

Write-Log "" -Level Info
Write-Log "Step 5: Verifying configuration..." -Level Info

# Re-check subscriptions
try {
    $finalSubscriptions = Invoke-RestMethod `
        -Uri "https://manage.office.com/api/v1.0/$SourceTenantId/activity/feed/subscriptions/list" `
        -Method GET `
        -Headers $headers `
        -ErrorAction Stop
    
    Write-Log "Active subscriptions for $SourceTenantName :" -Level Info
    foreach ($sub in $finalSubscriptions) {
        $status = if ($sub.status -eq "enabled") { "✓" } else { "✗" }
        Write-Log "  $status $($sub.contentType) - $($sub.status)" -Level $(if ($sub.status -eq "enabled") { "Success" } else { "Warning" })
    }
}
catch {
    Write-Log "Failed to verify subscriptions: $($_.Exception.Message)" -Level Warning
}

#endregion

#region Summary

Write-Log "" -Level Info
Write-Log "========================================" -Level Info
Write-Log "CONFIGURATION COMPLETE" -Level Success
Write-Log "========================================" -Level Info

Write-Log "" -Level Info
Write-Log "Summary:" -Level Info
Write-Log "  Managing Tenant: $ManagingTenantId" -Level Info
Write-Log "  Source Tenant: $SourceTenantName ($SourceTenantId)" -Level Info
Write-Log "  App Registration: $AppDisplayName" -Level Info
Write-Log "  Key Vault: $KeyVaultName" -Level Info
Write-Log "  Workspace: $WorkspaceResourceId" -Level Info

Write-Log "" -Level Info
Write-Log "Next Steps:" -Level Info
Write-Log "  1. Set up an Azure Automation Runbook to pull logs periodically" -Level Info
Write-Log "  2. Or use the Collect-M365AuditLogs.ps1 script manually" -Level Info
Write-Log "  3. Verify logs appear in Log Analytics workspace" -Level Info

Write-Log "" -Level Info
Write-Log "To add another source tenant, run:" -Level Info
Write-Log "  .\Configure-M365AuditLogCollection.ps1 -ManagingTenantId '$ManagingTenantId' -SourceTenantId '<NEW-TENANT-ID>' -SourceTenantName '<NEW-TENANT-NAME>' -KeyVaultName '$KeyVaultName' -WorkspaceResourceId '$WorkspaceResourceId' -SkipAppCreation" -Level Info

#endregion
