<#
.SYNOPSIS
    Configures Microsoft 365 audit log collection using embedded ARM templates.

.DESCRIPTION
    Step 7 of the Azure Cross-Tenant Log Collection Guide. Uses ARM templates for:
    - Azure Automation Account with Managed Identity
    - Key Vault access policies
    - Runbook deployment and scheduling

.PARAMETER ManagingTenantId
    The Tenant ID of the managing tenant.

.PARAMETER SourceTenantId
    The Tenant ID of the source tenant.

.PARAMETER SourceTenantName
    A friendly name for the source tenant.

.PARAMETER KeyVaultName
    The name of the Key Vault in the managing tenant.

.PARAMETER WorkspaceResourceId
    The full resource ID of the Log Analytics workspace.

.EXAMPLE
    .\Configure-M365AuditLogCollection.ps1 -ManagingTenantId "<ID>" -SourceTenantId "<ID>" -SourceTenantName "Atevet17" -KeyVaultName "kv-central" -WorkspaceResourceId "/subscriptions/.../workspaces/law-central"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ManagingTenantId,
    [Parameter(Mandatory)][string]$SourceTenantId,
    [Parameter(Mandatory)][string]$SourceTenantName,
    [Parameter(Mandatory)][string]$KeyVaultName,
    [Parameter(Mandatory)][string]$WorkspaceResourceId,
    [string]$ResourceGroupName,
    [string]$Location = "uksouth",
    [string]$AppDisplayName = "M365-AuditLogs-Collector",
    [string]$AutomationAccountName = "aa-m365-audit-collector",
    [string[]]$ContentTypes = @("Audit.AzureActiveDirectory","Audit.Exchange","Audit.SharePoint","Audit.General","DLP.All"),
    [int]$SecretValidityYears = 1,
    [int]$ScheduleIntervalMinutes = 30,
    [switch]$SkipAppCreation,
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
$permIds = @{
    "ActivityFeed.Read" = "594c1fb6-4f81-4f82-b6fd-d5b5a0e7e4a6"
    "ActivityFeed.ReadDlp" = "4807a72c-ad38-4250-94c9-4eabfe26cd55"
    "ServiceHealth.Read" = "e2cea78f-e743-4d8f-a16a-75b629a038ae"
}
$appId = $null; $appSecret = $null; $endDate = (Get-Date).AddYears($SecretValidityYears)

# Step 1: Create App Registration
if(-not $SkipAppCreation -and -not $VerifyOnly) {
    Write-Log "Step 1: Creating multi-tenant app in managing tenant..." -Level Info
    Connect-MgGraph -TenantId $ManagingTenantId -Scopes "Application.ReadWrite.All" -NoWelcome -ErrorAction Stop
    
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
    Connect-MgGraph -TenantId $SourceTenantId -Scopes "Application.ReadWrite.All","AppRoleAssignment.ReadWrite.All" -NoWelcome -ErrorAction Stop
    
    $sp = Get-MgServicePrincipal -Filter "appId eq '$appId'" -ErrorAction SilentlyContinue
    if(-not $sp) { $sp = New-MgServicePrincipal -AppId $appId -ErrorAction Stop }
    
    $o365Sp = Get-MgServicePrincipal -Filter "appId eq '$o365ApiId'" -ErrorAction Stop
    foreach($permName in $permIds.Keys) {
        $permId = $permIds[$permName]
        $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -ErrorAction SilentlyContinue | Where-Object {$_.AppRoleId -eq $permId}
        if(-not $existing) {
            New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -BodyParameter @{PrincipalId=$sp.Id;ResourceId=$o365Sp.Id;AppRoleId=$permId} -ErrorAction Stop | Out-Null
            Write-Log "  Granted: $permName" -Level Success
        }
    }
    Disconnect-MgGraph -ErrorAction SilentlyContinue
}

# Step 4: Create M365 Subscriptions
Write-Log "Step 4: Creating M365 audit log subscriptions..." -Level Info
$tokenBody = @{grant_type="client_credentials";client_id=$appId;client_secret=$appSecret;resource="https://manage.office.com"}
$tok = (Invoke-RestMethod -Uri "https://login.microsoftonline.com/$SourceTenantId/oauth2/token" -Method POST -Body $tokenBody -ErrorAction Stop).access_token
$hdr = @{Authorization="Bearer $tok";"Content-Type"="application/json"}

foreach($ct in $ContentTypes) {
    try {
        Invoke-RestMethod -Uri "https://manage.office.com/api/v1.0/$SourceTenantId/activity/feed/subscriptions/start?contentType=$ct" -Method POST -Headers $hdr -ErrorAction Stop | Out-Null
        Write-Log "  Subscribed: $ct" -Level Success
    } catch {
        if($_.Exception.Message -like "*already enabled*") { Write-Log "  Already subscribed: $ct" -Level Info }
        else { Write-Log "  $ct - $($_.Exception.Message)" -Level Warning }
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
    
    # Create schedule
    $schName = "M365AuditCollection-Every${ScheduleIntervalMinutes}Min"
    $existingSch = Get-AzAutomationSchedule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $schName -ErrorAction SilentlyContinue
    if(-not $existingSch) {
        New-AzAutomationSchedule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $schName -StartTime (Get-Date).AddMinutes(10) -HourInterval 0 -MinuteInterval $ScheduleIntervalMinutes -TimeZone "UTC" -ErrorAction Stop | Out-Null
        Write-Log "  Schedule created: $schName" -Level Success
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
