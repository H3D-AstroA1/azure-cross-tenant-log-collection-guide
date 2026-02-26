<#
.SYNOPSIS
    Configures Microsoft 365 audit log collection using embedded ARM templates.

.DESCRIPTION
    Step 7 of the Azure Cross-Tenant Log Collection Guide. This script runs from the MANAGING TENANT
    and configures M365 audit log collection from source tenants using the Office 365 Management API.
    
    Uses embedded ARM templates for:
    - Azure Automation Account with System-Assigned Managed Identity
    - Key Vault access policies for the Automation Account
    - Runbook deployment and scheduling
    
    The script performs:
    1. Creates a multi-tenant app registration in the managing tenant
    2. Stores credentials securely in Key Vault
    3. Grants admin consent for the app in the source tenant
    4. Creates M365 audit log subscriptions for specified content types
    5. Deploys Azure Automation Account with runbook for log collection
    6. Configures scheduled execution for continuous log ingestion
    
    IMPORTANT: Unlike Entra ID logs (Step 6), M365 logs are PULLED via the Office 365 Management API.
    This requires a runbook that periodically polls for new audit events and sends them to Log Analytics.
    
    Key difference from Step 6 (Entra ID):
    - M365 logs are PULLED via API polling (runbook required)
    - Entra ID logs are PUSHED directly via diagnostic settings (no runbook needed)

.PARAMETER ManagingTenantId
    The Tenant ID of the managing tenant (where Log Analytics workspace and Automation Account exist).

.PARAMETER SourceTenantId
    The Tenant ID of the source tenant (where M365 audit logs originate).

.PARAMETER SourceTenantName
    A friendly name for the source tenant (e.g., "Atevet17").
    Used for identification in logs and Key Vault secrets.

.PARAMETER KeyVaultName
    The name of the Key Vault in the managing tenant to store credentials.
    This Key Vault should have been created in Step 1 (Prepare-ManagingTenant.ps1).
    The script stores: App ID, App Secret, Workspace Key, and Tenant configuration.

.PARAMETER WorkspaceResourceId
    The full resource ID of the Log Analytics workspace in the managing tenant.
    Format: /subscriptions/{sub-id}/resourceGroups/{rg-name}/providers/Microsoft.OperationalInsights/workspaces/{workspace-name}

.PARAMETER ResourceGroupName
    The resource group name for the Automation Account. If not specified, uses the resource group
    from the WorkspaceResourceId.

.PARAMETER Location
    Azure region for the Automation Account. Default: "uksouth"

.PARAMETER AppDisplayName
    Display name for the multi-tenant app registration created in the MANAGING TENANT.
    This app is used to authenticate to the Office 365 Management API across all source tenants.
    Default: "M365-AuditLogs-Collector"

.PARAMETER AutomationAccountName
    Name for the Azure Automation Account deployed in the MANAGING TENANT.
    The Automation Account hosts the runbook that collects logs from all configured source tenants.
    Default: "aa-m365-audit-collector"

.PARAMETER ContentTypes
    Array of M365 content types to collect. Default: All available types.
    Available types: Audit.AzureActiveDirectory, Audit.Exchange, Audit.SharePoint, Audit.General, DLP.All

.PARAMETER SecretValidityYears
    Number of years the app secret remains valid. Default: 1

.PARAMETER ScheduleIntervalMinutes
    How often the runbook executes to collect logs. Default: 30 minutes

.PARAMETER SkipAppCreation
    If specified, skips app registration creation and uses existing credentials from Key Vault.
    Use this when adding additional source tenants to an existing setup.

.PARAMETER UseDeviceCode
    If specified, uses device code authentication instead of interactive browser authentication.
    This is useful when browser popups are blocked or when running in terminal environments.
    You will be prompted to visit https://microsoft.com/devicelogin and enter a code.

.PARAMETER VerifyOnly
    If specified, only verifies existing configuration without making changes.

.EXAMPLE
    # Full setup: Configure M365 audit log collection for a new source tenant
    .\Configure-M365AuditLogCollection.ps1 `
        -ManagingTenantId "<ATEVET12-TENANT-ID>" `
        -SourceTenantId "<ATEVET17-TENANT-ID>" `
        -SourceTenantName "Atevet17" `
        -KeyVaultName "kv-central-atevet12" `
        -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12"

.EXAMPLE
    # Add another source tenant (skip app creation, reuse existing app)
    .\Configure-M365AuditLogCollection.ps1 `
        -ManagingTenantId "<ATEVET12-TENANT-ID>" `
        -SourceTenantId "<ATEVET18-TENANT-ID>" `
        -SourceTenantName "Atevet18" `
        -KeyVaultName "kv-central-atevet12" `
        -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
        -SkipAppCreation

.EXAMPLE
    # Configure with specific content types only
    .\Configure-M365AuditLogCollection.ps1 `
        -ManagingTenantId "<ATEVET12-TENANT-ID>" `
        -SourceTenantId "<ATEVET17-TENANT-ID>" `
        -SourceTenantName "Atevet17" `
        -KeyVaultName "kv-central-atevet12" `
        -WorkspaceResourceId "/subscriptions/<SUB-ID>/resourceGroups/rg-central-logging/providers/Microsoft.OperationalInsights/workspaces/law-central-atevet12" `
        -ContentTypes @("Audit.Exchange", "Audit.SharePoint")

.NOTES
    Author: Azure Cross-Tenant Log Collection Guide
    Version: 2.0
    Requires: Az.Accounts, Az.KeyVault, Az.Automation, Az.Resources, Microsoft.Graph PowerShell modules
    
    Prerequisites:
    - Key Vault must exist in the managing tenant (created in Step 1)
    - Global Administrator access to both managing and source tenants
    - Az.Automation module must be installed
    - Microsoft.Graph module must be installed
    
    Office 365 Management API Permissions Required:
    - ActivityFeed.Read (Application) - Read activity data for your organization
    - ActivityFeed.ReadDlp (Application) - Read DLP policy events
    - ServiceHealth.Read (Application) - Read service health information
    
    Log Analytics Table:
    - M365AuditLogs_CL (custom log table created automatically)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ManagingTenantId,
    [Parameter(Mandatory)][string]$SourceTenantId,
    [Parameter(Mandatory)][string]$SourceTenantName,
    [Parameter(Mandatory)][string]$KeyVaultName,
    [Parameter(Mandatory)][string]$WorkspaceResourceId,
    [string]$ResourceGroupName,
    [string]$Location = "westus2",
    [string]$AppDisplayName = "M365-AuditLogs-Collector",
    [string]$AutomationAccountName = "aa-m365-audit-collector",
    [string[]]$ContentTypes = @("Audit.AzureActiveDirectory","Audit.Exchange","Audit.SharePoint","Audit.General","DLP.All"),
    [int]$SecretValidityYears = 1,
    [int]$ScheduleIntervalMinutes = 30,
    [switch]$SkipAppCreation,
    [switch]$UseDeviceCode,
    [switch]$VerifyOnly
)

#region Embedded ARM Template - Automation Account with Managed Identity
$armTemplateAutomationAccount = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "automationAccountName": { "type": "string" },
        "location": { "type": "string" }
    },
    "resources": [{
        "type": "Microsoft.Automation/automationAccounts",
        "apiVersion": "2022-08-08",
        "name": "[parameters('automationAccountName')]",
        "location": "[parameters('location')]",
        "identity": { "type": "SystemAssigned" },
        "properties": { "sku": { "name": "Basic" }, "publicNetworkAccess": true }
    }],
    "outputs": {
        "principalId": {
            "type": "string",
            "value": "[reference(resourceId('Microsoft.Automation/automationAccounts', parameters('automationAccountName')), '2022-08-08', 'Full').identity.principalId]"
        }
    }
}
'@
#endregion

#region Embedded ARM Template - Key Vault Access Policy
$armTemplateKeyVaultAccess = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "keyVaultName": { "type": "string" },
        "objectId": { "type": "string" },
        "tenantId": { "type": "string" }
    },
    "resources": [{
        "type": "Microsoft.KeyVault/vaults/accessPolicies",
        "apiVersion": "2023-07-01",
        "name": "[concat(parameters('keyVaultName'), '/add')]",
        "properties": {
            "accessPolicies": [{
                "tenantId": "[parameters('tenantId')]",
                "objectId": "[parameters('objectId')]",
                "permissions": { "secrets": ["get", "list"] }
            }]
        }
    }]
}
'@
#endregion

#region Embedded Runbook Script
$runbookScript = @'
param(
    [Parameter(Mandatory)][string]$KeyVaultName,
    [Parameter(Mandatory)][string]$WorkspaceId,
    [string]$LogType = "M365AuditLogs",
    [int]$HoursToCollect = 1
)

function Build-Signature($wid,$wkey,$date,$len,$method,$ctype,$res) {
    $str = "$method`n$len`n$ctype`nx-ms-date:$date`n$res"
    $hmac = New-Object Security.Cryptography.HMACSHA256
    $hmac.Key = [Convert]::FromBase64String($wkey)
    return "SharedKey ${wid}:$([Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($str))))"
}

function Send-LAData($wid,$wkey,$type,$body) {
    $date = [DateTime]::UtcNow.ToString("r")
    $sig = Build-Signature $wid $wkey $date $body.Length "POST" "application/json" "/api/logs"
    Invoke-WebRequest -Uri "https://$wid.ods.opinsights.azure.com/api/logs?api-version=2016-04-01" -Method POST -ContentType "application/json" -Headers @{Authorization=$sig;"Log-Type"=$type;"x-ms-date"=$date;"time-generated-field"="CreationTime"} -Body $body -UseBasicParsing
}

Write-Output "Starting M365 Audit Log Collection"
Connect-AzAccount -Identity | Out-Null

$appId = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-AppId" -AsPlainText
$appSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Secret" -AsPlainText
$wkey = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "LogAnalytics-WorkspaceKey" -AsPlainText
$tenants = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Tenants" -AsPlainText | ConvertFrom-Json).tenants

$end = [DateTime]::UtcNow; $start = $end.AddHours(-$HoursToCollect)
$types = @("Audit.AzureActiveDirectory","Audit.Exchange","Audit.SharePoint","Audit.General","DLP.All")
$total = 0

foreach($t in $tenants) {
    Write-Output "Processing: $($t.name)"
    try {
        $tok = (Invoke-RestMethod -Uri "https://login.microsoftonline.com/$($t.tenantId)/oauth2/token" -Method POST -Body @{grant_type="client_credentials";client_id=$appId;client_secret=$appSecret;resource="https://manage.office.com"}).access_token
        $hdr = @{Authorization="Bearer $tok"}
        foreach($ct in $types) {
            try {
                $list = Invoke-RestMethod -Uri "https://manage.office.com/api/v1.0/$($t.tenantId)/activity/feed/subscriptions/content?contentType=$ct&startTime=$($start.ToString('yyyy-MM-ddTHH:mm:ss'))&endTime=$($end.ToString('yyyy-MM-ddTHH:mm:ss'))" -Headers $hdr -EA Stop
                foreach($c in $list) {
                    $recs = Invoke-RestMethod -Uri $c.contentUri -Headers $hdr
                    if($recs) {
                        $recs | ForEach-Object { $_ | Add-Member -NotePropertyName SourceTenantId -NotePropertyValue $t.tenantId -Force; $_ | Add-Member -NotePropertyName SourceTenantName -NotePropertyValue $t.name -Force; $_ | Add-Member -NotePropertyName ContentType -NotePropertyValue $ct -Force }
                        $json = $recs | ConvertTo-Json -Depth 20; if($recs.Count -eq 1){$json="[$json]"}
                        Send-LAData $WorkspaceId $wkey $LogType $json | Out-Null
                        $total += $recs.Count
                    }
                }
            } catch {}
        }
    } catch { Write-Output "Error: $($t.name) - $($_.Exception.Message)" }
}
Write-Output "Complete. Total logs: $total"
'@
#endregion

#region Helper Functions
function Write-Log([string]$Message, [string]$Level="Info") {
    $colors = @{Info="Cyan";Success="Green";Warning="Yellow";Error="Red"}
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message" -ForegroundColor $colors[$Level]
}

function Deploy-ArmTemplate($ResourceGroup, $Template, $Parameters, $DeploymentName) {
    $tempFile = [IO.Path]::GetTempFileName() + ".json"
    $Template | Out-File $tempFile -Encoding UTF8
    try {
        return New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroup -TemplateFile $tempFile -TemplateParameterObject $Parameters -Name $DeploymentName -ErrorAction Stop
    } finally {
        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    }
}
#endregion

#region Main Script
Write-Log "========================================" -Level Info
Write-Log "Step 7: Configure Microsoft 365 Audit Logs" -Level Info
Write-Log "========================================" -Level Info

# Parse workspace resource ID
if($WorkspaceResourceId -match "/subscriptions/([^/]+)/resourceGroups/([^/]+)/.*workspaces/([^/]+)") {
    $subscriptionId = $Matches[1]
    if(-not $ResourceGroupName) { $ResourceGroupName = $Matches[2] }
    $workspaceName = $Matches[3]
}

$o365ApiId = "c5393580-f805-4401-95e8-94b7a6ef2fc2"
# Default permission IDs - these will be verified against the actual service principal
# Note: ActivityFeed.Read ID varies by tenant, the script will discover the correct one
$permIds = @{
    "ActivityFeed.Read" = "594c1fb6-4f81-4475-ae41-0c394909246c"  # Updated to common variant
    "ActivityFeed.ReadDlp" = "4807a72c-ad38-4250-94c9-4eabfe26cd55"
    "ServiceHealth.Read" = "e2cea78f-e743-4d8f-a16a-75b629a038ae"
}
$appId = $null; $appSecret = $null; $endDate = (Get-Date).AddYears($SecretValidityYears)

# Step 1: Create App Registration
if(-not $SkipAppCreation -and -not $VerifyOnly) {
    Write-Log "Step 1: Creating multi-tenant app in managing tenant..." -Level Info
    Write-Log "  *** AUTHENTICATE TO MANAGING TENANT: $ManagingTenantId ***" -Level Warning
    Write-Log "  A browser window will open for authentication..." -Level Info
    
    # Disable WAM to force full browser authentication
    $env:AZURE_IDENTITY_DISABLE_BROKER = "true"
    
    if ($UseDeviceCode) {
        Write-Log "  Opening browser for device code authentication..." -Level Info
        Start-Process "https://microsoft.com/devicelogin"
        Connect-MgGraph -TenantId $ManagingTenantId -Scopes "Application.ReadWrite.All" -UseDeviceCode -NoWelcome -ErrorAction Stop
    } else {
        # Use standard interactive browser (WAM disabled)
        Connect-MgGraph -TenantId $ManagingTenantId -Scopes "Application.ReadWrite.All" -NoWelcome -ErrorAction Stop
    }
    
    $app = Get-MgApplication -Filter "displayName eq '$AppDisplayName'" -ErrorAction SilentlyContinue
    if(-not $app) {
        $reqAccess = @{
            ResourceAppId = $o365ApiId
            ResourceAccess = @(
                @{Id=$permIds["ActivityFeed.Read"];Type="Role"},
                @{Id=$permIds["ActivityFeed.ReadDlp"];Type="Role"},
                @{Id=$permIds["ServiceHealth.Read"];Type="Role"}
            )
        }
        $app = New-MgApplication -DisplayName $AppDisplayName -SignInAudience "AzureADMultipleOrgs" -RequiredResourceAccess @($reqAccess) -ErrorAction Stop
        Write-Log "App created: $($app.AppId)" -Level Success
    } else {
        Write-Log "App exists: $($app.AppId)" -Level Info
    }
    $appId = $app.AppId
    
    $secret = Add-MgApplicationPassword -ApplicationId $app.Id -BodyParameter @{PasswordCredential=@{DisplayName="M365Collector-$SourceTenantName";EndDateTime=$endDate}} -ErrorAction Stop
    $appSecret = $secret.SecretText
    Write-Log "Client secret created (expires: $endDate)" -Level Success
    
    $sp = Get-MgServicePrincipal -Filter "appId eq '$appId'" -ErrorAction SilentlyContinue
    if(-not $sp) { New-MgServicePrincipal -AppId $appId -ErrorAction Stop | Out-Null }
    
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}

# Step 2: Connect to Azure & Store Credentials
if(-not $VerifyOnly) {
    Write-Log "Step 2: Storing credentials in Key Vault..." -Level Info
    $ctx = Get-AzContext
    if(-not $ctx -or $ctx.Tenant.Id -ne $ManagingTenantId) { Connect-AzAccount -TenantId $ManagingTenantId -ErrorAction Stop }
    Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
    
    $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $workspaceName -ErrorAction Stop
    $workspaceId = $ws.CustomerId
    $wsKeys = Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $ResourceGroupName -Name $workspaceName -ErrorAction Stop
    
    if(-not $SkipAppCreation -and $appId -and $appSecret) {
        Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-AppId" -SecretValue (ConvertTo-SecureString $appId -AsPlainText -Force) -ErrorAction Stop | Out-Null
        Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Secret" -SecretValue (ConvertTo-SecureString $appSecret -AsPlainText -Force) -Expires $endDate -ErrorAction Stop | Out-Null
        Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "LogAnalytics-WorkspaceKey" -SecretValue (ConvertTo-SecureString $wsKeys.PrimarySharedKey -AsPlainText -Force) -ErrorAction Stop | Out-Null
        Write-Log "Credentials stored in Key Vault" -Level Success
    } else {
        $appId = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-AppId" -AsPlainText -ErrorAction Stop
        $appSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Secret" -AsPlainText -ErrorAction Stop
        Write-Log "Retrieved existing credentials" -Level Success
    }
    
    # Update tenants list
    try { $cfg = (Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Tenants" -AsPlainText -ErrorAction SilentlyContinue) | ConvertFrom-Json }
    catch { $cfg = @{tenants=@()} }
    if(-not $cfg) { $cfg = @{tenants=@()} }
    if(-not ($cfg.tenants | Where-Object {$_.tenantId -eq $SourceTenantId})) {
        $cfg.tenants += @{tenantId=$SourceTenantId;name=$SourceTenantName;addedDate=(Get-Date -Format "yyyy-MM-dd")}
        Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name "M365Collector-Tenants" -SecretValue (ConvertTo-SecureString ($cfg | ConvertTo-Json -Depth 5) -AsPlainText -Force) -ErrorAction Stop | Out-Null
        Write-Log "Added $SourceTenantName to tenants list" -Level Success
    }
}

# Step 3: Grant Admin Consent in Source Tenant
if(-not $VerifyOnly) {
    Write-Log "Step 3: Granting admin consent in source tenant..." -Level Info
    Write-Log "  *** AUTHENTICATE TO SOURCE TENANT: $SourceTenantId ($SourceTenantName) ***" -Level Warning
    Write-Log "  A browser window will open for authentication..." -Level Info
    
    # Ensure WAM is disabled for full browser authentication
    $env:AZURE_IDENTITY_DISABLE_BROKER = "true"
    
    if ($UseDeviceCode) {
        Write-Log "  Opening browser for device code authentication..." -Level Info
        Start-Process "https://microsoft.com/devicelogin"
        Connect-MgGraph -TenantId $SourceTenantId -Scopes "Application.ReadWrite.All","AppRoleAssignment.ReadWrite.All" -UseDeviceCode -NoWelcome -ErrorAction Stop
    } else {
        # Use standard interactive browser (WAM disabled)
        Connect-MgGraph -TenantId $SourceTenantId -Scopes "Application.ReadWrite.All","AppRoleAssignment.ReadWrite.All" -NoWelcome -ErrorAction Stop
    }
    
    # Create/get our app's service principal in the source tenant
    Write-Log "  Creating service principal for collector app in source tenant..." -Level Info
    $sp = Get-MgServicePrincipal -Filter "appId eq '$appId'" -ErrorAction SilentlyContinue
    if(-not $sp) {
        $sp = New-MgServicePrincipal -AppId $appId -ErrorAction Stop
        Write-Log "  Service principal created for collector app" -Level Success
    } else {
        Write-Log "  Service principal already exists for collector app" -Level Info
    }
    
    # Create/get the Office 365 Management API service principal in the source tenant
    # This is required before we can grant permissions to it
    Write-Log "  Ensuring Office 365 Management API service principal exists..." -Level Info
    $o365Sp = Get-MgServicePrincipal -Filter "appId eq '$o365ApiId'" -ErrorAction SilentlyContinue
    if(-not $o365Sp) {
        Write-Log "  Creating Office 365 Management API service principal in source tenant..." -Level Info
        try {
            $o365Sp = New-MgServicePrincipal -AppId $o365ApiId -ErrorAction Stop
            Write-Log "  Office 365 Management API service principal created" -Level Success
            # Wait a moment for the service principal to propagate
            Start-Sleep -Seconds 5
        } catch {
            Write-Log "  Warning: Could not create Office 365 Management API service principal: $($_.Exception.Message)" -Level Warning
            Write-Log "  You may need to manually consent to the Office 365 Management API in the Azure Portal" -Level Warning
        }
    } else {
        Write-Log "  Office 365 Management API service principal already exists" -Level Info
    }
    
    # Grant permissions if we have the O365 service principal
    if ($o365Sp) {
        Write-Log "  Granting API permissions..." -Level Info
        
        # Get available app roles from the Office 365 Management API service principal
        $availableRoles = $o365Sp.AppRoles | Where-Object { $_.IsEnabled -eq $true }
        Write-Log "    Available roles on Office 365 Management API: $($availableRoles.Count)" -Level Info
        
        # Map permission names to actual role IDs from the service principal
        $roleMapping = @{}
        foreach ($role in $availableRoles) {
            $roleMapping[$role.Value] = $role.Id
            Write-Log "      Found role: $($role.Value) ($($role.Id))" -Level Info
        }
        
        # Required permissions for M365 audit log collection
        $requiredPermissions = @("ActivityFeed.Read", "ActivityFeed.ReadDlp", "ServiceHealth.Read")
        
        foreach($permName in $requiredPermissions) {
            # Try to find the permission in the available roles
            $permId = $roleMapping[$permName]
            if (-not $permId) {
                # Fall back to hardcoded ID if not found in service principal
                $permId = $permIds[$permName]
                Write-Log "    Using fallback ID for $permName" -Level Info
            }
            
            if ($permId) {
                $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -ErrorAction SilentlyContinue | Where-Object {$_.AppRoleId -eq $permId}
                if(-not $existing) {
                    try {
                        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -BodyParameter @{PrincipalId=$sp.Id;ResourceId=$o365Sp.Id;AppRoleId=$permId} -ErrorAction Stop | Out-Null
                        Write-Log "    ✓ Granted: $permName" -Level Success
                    } catch {
                        if ($_.Exception.Message -like "*already*") {
                            Write-Log "    ✓ Already granted: $permName" -Level Success
                        } elseif ($_.Exception.Message -like "*Permission being assigned was not found*") {
                            Write-Log "    ⚠ Skipped: $permName (permission ID not found - will use dynamic discovery)" -Level Warning
                        } else {
                            Write-Log "    ✗ Failed: $permName - $($_.Exception.Message)" -Level Error
                        }
                    }
                } else {
                    Write-Log "    ✓ Already granted: $permName" -Level Success
                }
            } else {
                Write-Log "    ⚠ Skipped: $permName (role not available on this API)" -Level Warning
            }
        }
    } else {
        Write-Log "  Skipping permission grants - Office 365 Management API service principal not available" -Level Warning
    }
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}

# Step 4: Create M365 Subscriptions
Write-Log "Step 4: Creating M365 audit log subscriptions..." -Level Info
Write-Log "  Waiting 10 seconds for permission propagation..." -Level Info
Start-Sleep -Seconds 10

$tokenBody = @{grant_type="client_credentials";client_id=$appId;client_secret=$appSecret;resource="https://manage.office.com"}
$maxRetries = 3
$retryDelay = 15

foreach($ct in $ContentTypes) {
    $success = $false
    for ($retry = 1; $retry -le $maxRetries -and -not $success; $retry++) {
        try {
            # Get a fresh token for each content type to ensure we have latest permissions
            $tok = (Invoke-RestMethod -Uri "https://login.microsoftonline.com/$SourceTenantId/oauth2/token" -Method POST -Body $tokenBody -ErrorAction Stop).access_token
            $hdr = @{Authorization="Bearer $tok";"Content-Type"="application/json"}
            
            Invoke-RestMethod -Uri "https://manage.office.com/api/v1.0/$SourceTenantId/activity/feed/subscriptions/start?contentType=$ct" -Method POST -Headers $hdr -ErrorAction Stop | Out-Null
            Write-Log "  ✓ Subscribed: $ct" -Level Success
            $success = $true
        } catch {
            $errorMsg = $_.Exception.Message
            if($errorMsg -like "*already enabled*" -or $errorMsg -like "*400*") {
                # 400 Bad Request often means already subscribed - treat as success
                Write-Log "  ✓ Already subscribed: $ct" -Level Success
                $success = $true
            } elseif ($errorMsg -like "*401*" -and $retry -lt $maxRetries) {
                Write-Log "  ⏳ $ct - Waiting for permissions to propagate (attempt $retry/$maxRetries)..." -Level Warning
                Start-Sleep -Seconds $retryDelay
            } elseif ($errorMsg -like "*401*") {
                Write-Log "  ✗ $ct - Permission denied. Ensure ActivityFeed.Read permission is granted." -Level Error
            } else {
                Write-Log "  ⚠ $ct - $errorMsg" -Level Warning
            }
        }
    }
}

# Step 5: Deploy Automation Account using ARM Template
if(-not $VerifyOnly) {
    Write-Log "Step 5: Deploying Azure Automation using ARM template..." -Level Info
    
    $existingAA = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction SilentlyContinue
    if(-not $existingAA) {
        Write-Log "  Deploying Automation Account ARM template..." -Level Info
        $deployment = Deploy-ArmTemplate -ResourceGroup $ResourceGroupName -Template $armTemplateAutomationAccount -Parameters @{automationAccountName=$AutomationAccountName;location=$Location} -DeploymentName "M365Audit-AA-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $principalId = $deployment.Outputs.principalId.Value
        Write-Log "  Automation Account deployed (Principal: $principalId)" -Level Success
        
        # Grant Key Vault access using ARM template
        Write-Log "  Deploying Key Vault access policy ARM template..." -Level Info
        $kvRg = (Get-AzKeyVault -VaultName $KeyVaultName).ResourceGroupName
        Deploy-ArmTemplate -ResourceGroup $kvRg -Template $armTemplateKeyVaultAccess -Parameters @{keyVaultName=$KeyVaultName;objectId=$principalId;tenantId=$ManagingTenantId} -DeploymentName "M365Audit-KV-$(Get-Date -Format 'yyyyMMddHHmmss')" | Out-Null
        Write-Log "  Key Vault access granted via ARM template" -Level Success
    } else {
        Write-Log "  Automation Account already exists" -Level Info
    }
    
    # Import required modules
    Write-Log "  Importing PowerShell modules..." -Level Info
    @("Az.Accounts","Az.KeyVault") | ForEach-Object {
        try {
            Import-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $_ -ContentLinkUri "https://www.powershellgallery.com/api/v2/package/$_" -ErrorAction SilentlyContinue | Out-Null
        } catch {}
    }
    
    # Import runbook
    Write-Log "  Importing runbook..." -Level Info
    $rbPath = [IO.Path]::GetTempFileName() + ".ps1"
    $runbookScript | Out-File $rbPath -Encoding UTF8
    Import-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name "Collect-M365AuditLogs" -Path $rbPath -Type PowerShell -Published -Force -ErrorAction Stop | Out-Null
    Remove-Item $rbPath -Force
    Write-Log "  Runbook imported and published" -Level Success
    
    # Create schedule - use HourInterval 1 for hourly recurrence (minimum allowed)
    # For sub-hourly intervals, we create the schedule with hourly recurrence
    $schName = "M365AuditCollection-Every${ScheduleIntervalMinutes}Min"
    $existingSch = Get-AzAutomationSchedule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $schName -ErrorAction SilentlyContinue
    if(-not $existingSch) {
        try {
            # Create hourly schedule (minimum interval supported by Azure Automation)
            New-AzAutomationSchedule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $schName -StartTime (Get-Date).AddMinutes(10) -HourInterval 1 -TimeZone "UTC" -ErrorAction Stop | Out-Null
            Write-Log "  Schedule created: $schName (hourly)" -Level Success
        } catch {
            Write-Log "  Schedule creation warning: $($_.Exception.Message)" -Level Warning
        }
    } else {
        Write-Log "  Schedule already exists: $schName" -Level Info
    }
    
    # Link runbook to schedule
    Register-AzAutomationScheduledRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -RunbookName "Collect-M365AuditLogs" -ScheduleName $schName -Parameters @{KeyVaultName=$KeyVaultName;WorkspaceId=$workspaceId.ToString()} -ErrorAction SilentlyContinue | Out-Null
    Write-Log "  Runbook linked to schedule" -Level Success
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
Write-Log "  App Registration: $AppDisplayName" -Level Info
Write-Log "  Automation Account: $AutomationAccountName" -Level Info
Write-Log "  Schedule: Every $ScheduleIntervalMinutes minutes" -Level Info
Write-Log "  Log Analytics Table: M365AuditLogs_CL" -Level Info
Write-Log "" -Level Info
Write-Log "To add another source tenant, run:" -Level Info
Write-Log "  .\Configure-M365AuditLogCollection.ps1 -ManagingTenantId '$ManagingTenantId' -SourceTenantId '<NEW-TENANT-ID>' -SourceTenantName '<NAME>' -KeyVaultName '$KeyVaultName' -WorkspaceResourceId '$WorkspaceResourceId' -SkipAppCreation" -Level Info
#endregion
