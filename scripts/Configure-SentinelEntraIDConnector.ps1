<#
.SYNOPSIS
    Configures Microsoft Sentinel Entra ID data connector for cross-tenant log collection.

.DESCRIPTION
    This script enables the Microsoft Sentinel Azure Active Directory (Entra ID) data connector
    to collect logs from a SOURCE tenant into a Sentinel workspace in the MANAGING tenant.
    
    IMPORTANT: Unlike diagnostic settings, Sentinel data connectors are configured FROM the
    MANAGING tenant, which may avoid the LinkedAuthorizationFailed cross-tenant API limitation.
    
    The script:
    1. Connects to the MANAGING tenant where Sentinel is deployed
    2. Verifies Sentinel is enabled on the workspace
    3. Lists available data connector types
    4. Attempts to enable the Azure AD data connector
    5. Provides Portal instructions if API approach requires consent

.PARAMETER ManagingTenantId
    The Tenant ID of the managing tenant (where Sentinel workspace exists).

.PARAMETER SourceTenantId
    The Tenant ID of the source tenant (where Entra ID logs originate).

.PARAMETER SourceTenantName
    A friendly name for the source tenant.

.PARAMETER WorkspaceResourceId
    The full resource ID of the Log Analytics workspace with Sentinel enabled.

.EXAMPLE
    .\Configure-SentinelEntraIDConnector.ps1 `
        -ManagingTenantId "8d788dbd-cd1c-4e00-b371-3933a12c0f7d" `
        -SourceTenantId "3cd87a41-1f61-4aef-a212-cefdecd9a2d1" `
        -SourceTenantName "DefenderATEVET17" `
        -WorkspaceResourceId "/subscriptions/97a0811f-fec4-470d-8fb8-7f9be05fcc6d/resourceGroups/rg-central-logging-for-atevet17-TD/providers/Microsoft.OperationalInsights/workspaces/law-central-logging-for-atevet17-TD"

.NOTES
    Author: Azure Cross-Tenant Log Collection Guide
    Version: 1.0
    
    Prerequisites:
    - Microsoft Sentinel must be enabled on the Log Analytics workspace
    - User must have Contributor or Microsoft Sentinel Contributor role on the workspace
    - User must have Global Administrator or Security Administrator in the SOURCE tenant
      (for initial consent/authorization)
    
    Key Advantage:
    - This approach configures the connector FROM the managing tenant
    - May avoid the LinkedAuthorizationFailed error that affects diagnostic settings
    - Uses Sentinel's built-in cross-tenant capabilities
    
    Data Connector Types:
    - AzureActiveDirectory: Sign-in and Audit logs
    - AzureActiveDirectoryIdentityProtection: Risk events (requires P2)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ManagingTenantId,
    [Parameter(Mandatory)][string]$SourceTenantId,
    [Parameter(Mandatory)][string]$SourceTenantName,
    [Parameter(Mandatory)][string]$WorkspaceResourceId
)

#region Helper Functions
function Write-Log([string]$Message, [string]$Level="Info") {
    $colors = @{Info="Cyan";Success="Green";Warning="Yellow";Error="Red"}
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message" -ForegroundColor $colors[$Level]
}
#endregion

#region Main Script
Write-Log "========================================" -Level Info
Write-Log "Configure Sentinel Entra ID Data Connector" -Level Info
Write-Log "========================================" -Level Info
Write-Log "" -Level Info

# Parse workspace resource ID
if($WorkspaceResourceId -match "/subscriptions/([^/]+)/resourceGroups/([^/]+)/.*workspaces/([^/]+)") {
    $subscriptionId = $Matches[1]
    $resourceGroupName = $Matches[2]
    $workspaceName = $Matches[3]
} else {
    Write-Log "Invalid workspace resource ID format" -Level Error
    exit 1
}

Write-Log "Configuration:" -Level Info
Write-Log "  Managing Tenant: $ManagingTenantId" -Level Info
Write-Log "  Source Tenant: $SourceTenantId ($SourceTenantName)" -Level Info
Write-Log "  Workspace: $workspaceName" -Level Info
Write-Log "  Subscription: $subscriptionId" -Level Info
Write-Log "" -Level Info

Write-Log "+======================================================================+" -Level Info
Write-Log "|  SENTINEL DATA CONNECTOR APPROACH                                    |" -Level Info
Write-Log "+======================================================================+" -Level Info
Write-Log "" -Level Info
Write-Log "Unlike diagnostic settings, Sentinel data connectors are configured" -Level Info
Write-Log "FROM the MANAGING tenant. This may avoid cross-tenant API limitations." -Level Info
Write-Log "" -Level Info

#region Step 1: Connect to Managing Tenant
Write-Log "========================================================================" -Level Info
Write-Log "Step 1: Connecting to MANAGING tenant" -Level Info
Write-Log "========================================================================" -Level Info
Write-Log "" -Level Info

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if(-not $ctx -or $ctx.Tenant.Id -ne $ManagingTenantId) {
    Write-Log "Connecting to managing tenant..." -Level Info
    Connect-AzAccount -TenantId $ManagingTenantId -ErrorAction Stop
}

Set-AzContext -SubscriptionId $subscriptionId -TenantId $ManagingTenantId -ErrorAction Stop | Out-Null
$ctx = Get-AzContext
Write-Log "  [OK] Connected to managing tenant" -Level Success
Write-Log "    Account: $($ctx.Account.Id)" -Level Info
Write-Log "    Subscription: $($ctx.Subscription.Name)" -Level Info
Write-Log "" -Level Info
#endregion

#region Step 2: Verify Sentinel is Enabled
Write-Log "========================================================================" -Level Info
Write-Log "Step 2: Verifying Microsoft Sentinel is enabled" -Level Info
Write-Log "========================================================================" -Level Info
Write-Log "" -Level Info

# Check if Sentinel solution is installed
$sentinelSolutionPath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.OperationsManagement/solutions/SecurityInsights($workspaceName)?api-version=2015-11-01-preview"

try {
    $sentinelResponse = Invoke-AzRestMethod -Path $sentinelSolutionPath -Method GET -ErrorAction Stop
    
    if($sentinelResponse.StatusCode -eq 200) {
        Write-Log "  [OK] Microsoft Sentinel is enabled on the workspace" -Level Success
    } else {
        Write-Log "  [!] Microsoft Sentinel may not be enabled" -Level Warning
        Write-Log "    Status: $($sentinelResponse.StatusCode)" -Level Warning
        Write-Log "    You may need to enable Sentinel first" -Level Warning
    }
} catch {
    Write-Log "  [!] Could not verify Sentinel status: $($_.Exception.Message)" -Level Warning
    Write-Log "    Continuing anyway - the connector API will fail if Sentinel is not enabled" -Level Warning
}
Write-Log "" -Level Info
#endregion

#region Step 3: List Available Data Connector Definitions
Write-Log "========================================================================" -Level Info
Write-Log "Step 3: Listing available data connector definitions" -Level Info
Write-Log "========================================================================" -Level Info
Write-Log "" -Level Info

$definitionsPath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights/dataConnectorDefinitions?api-version=2024-01-01-preview"

try {
    $definitionsResponse = Invoke-AzRestMethod -Path $definitionsPath -Method GET -ErrorAction Stop
    
    if($definitionsResponse.StatusCode -eq 200) {
        $definitions = ($definitionsResponse.Content | ConvertFrom-Json).value
        
        # Filter for Azure AD related definitions
        $aadDefinitions = $definitions | Where-Object { $_.name -like "*AzureActiveDirectory*" -or $_.name -like "*AAD*" -or $_.name -like "*Entra*" }
        
        if($aadDefinitions -and $aadDefinitions.Count -gt 0) {
            Write-Log "Found Azure AD related connector definitions:" -Level Info
            foreach($def in $aadDefinitions) {
                Write-Log "  - $($def.name)" -Level Info
                Write-Log "    Kind: $($def.kind)" -Level Info
            }
        } else {
            Write-Log "No Azure AD connector definitions found in response" -Level Info
            Write-Log "Total definitions found: $($definitions.Count)" -Level Info
        }
    } else {
        Write-Log "  Could not list definitions: $($definitionsResponse.StatusCode)" -Level Warning
    }
} catch {
    Write-Log "  Could not list definitions: $($_.Exception.Message)" -Level Warning
}
Write-Log "" -Level Info
#endregion

#region Step 4: Check Existing Data Connectors
Write-Log "========================================================================" -Level Info
Write-Log "Step 4: Checking existing data connectors" -Level Info
Write-Log "========================================================================" -Level Info
Write-Log "" -Level Info

$connectorsPath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights/dataConnectors?api-version=2023-02-01"

try {
    $connectorsResponse = Invoke-AzRestMethod -Path $connectorsPath -Method GET -ErrorAction Stop
    
    if($connectorsResponse.StatusCode -eq 200) {
        $connectors = ($connectorsResponse.Content | ConvertFrom-Json).value
        
        Write-Log "Found $($connectors.Count) existing data connector(s):" -Level Info
        
        # Filter for Azure AD connectors
        $aadConnectors = $connectors | Where-Object { $_.kind -eq "AzureActiveDirectory" -or $_.kind -like "*AAD*" }
        
        if($aadConnectors -and $aadConnectors.Count -gt 0) {
            Write-Log "" -Level Info
            Write-Log "Azure AD connectors:" -Level Info
            foreach($conn in $aadConnectors) {
                Write-Log "  - $($conn.name)" -Level Info
                Write-Log "    Kind: $($conn.kind)" -Level Info
                if($conn.properties.tenantId) {
                    Write-Log "    Tenant: $($conn.properties.tenantId)" -Level Info
                    
                    if($conn.properties.tenantId -eq $SourceTenantId) {
                        Write-Log "    --> This is for the target source tenant!" -Level Success
                    }
                }
            }
        } else {
            Write-Log "  No Azure AD data connectors currently configured" -Level Info
        }
        
        # Show all connector kinds for reference
        Write-Log "" -Level Info
        Write-Log "All connector kinds in use:" -Level Info
        $connectors | Group-Object kind | ForEach-Object {
            Write-Log "  - $($_.Name): $($_.Count)" -Level Info
        }
    }
} catch {
    Write-Log "  Could not list existing connectors: $($_.Exception.Message)" -Level Warning
}
Write-Log "" -Level Info
#endregion

#region Step 5: Attempt to Create Azure AD Data Connector
Write-Log "========================================================================" -Level Info
Write-Log "Step 5: Attempting to create Azure AD data connector" -Level Info
Write-Log "========================================================================" -Level Info
Write-Log "" -Level Info

# Generate a unique connector ID
$connectorId = "AzureActiveDirectory-$($SourceTenantName -replace '[^a-zA-Z0-9]','')"

Write-Log "Connector Configuration:" -Level Info
Write-Log "  Connector ID: $connectorId" -Level Info
Write-Log "  Source Tenant: $SourceTenantId" -Level Info
Write-Log "" -Level Info

# Try different API versions and body formats
$apiVersions = @(
    "2023-02-01",
    "2022-12-01-preview",
    "2021-10-01-preview",
    "2024-01-01-preview"
)

# Body format 1: Standard Azure AD connector
$connectorBody1 = @{
    kind = "AzureActiveDirectory"
    properties = @{
        tenantId = $SourceTenantId
        dataTypes = @{
            alerts = @{
                state = "Enabled"
            }
        }
    }
} | ConvertTo-Json -Depth 10

# Body format 2: With explicit data types
$connectorBody2 = @{
    kind = "AzureActiveDirectory"
    properties = @{
        tenantId = $SourceTenantId
        dataTypes = @{
            signinLogs = @{
                state = "Enabled"
            }
            auditLogs = @{
                state = "Enabled"
            }
        }
    }
} | ConvertTo-Json -Depth 10

# Body format 3: Minimal
$connectorBody3 = @{
    kind = "AzureActiveDirectory"
    properties = @{
        tenantId = $SourceTenantId
    }
} | ConvertTo-Json -Depth 10

$bodies = @(
    @{Name="Standard with alerts"; Body=$connectorBody1},
    @{Name="With explicit data types"; Body=$connectorBody2},
    @{Name="Minimal"; Body=$connectorBody3}
)

$success = $false

foreach($apiVersion in $apiVersions) {
    if($success) { break }
    
    foreach($bodyConfig in $bodies) {
        if($success) { break }
        
        $connectorPath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/providers/Microsoft.SecurityInsights/dataConnectors/$connectorId`?api-version=$apiVersion"
        
        Write-Log "Trying API version: $apiVersion" -Level Info
        Write-Log "  Body format: $($bodyConfig.Name)" -Level Info
        
        try {
            if($PSCmdlet.ShouldProcess($connectorId, "Create Sentinel Data Connector")) {
                $createResponse = Invoke-AzRestMethod -Path $connectorPath -Method PUT -Payload $bodyConfig.Body -ErrorAction Stop
                
                Write-Log "  Response Status: $($createResponse.StatusCode)" -Level Info
                
                if($createResponse.StatusCode -in @(200, 201)) {
                    $success = $true
                    Write-Log "" -Level Success
                    Write-Log "+======================================================================+" -Level Success
                    Write-Log "|  SUCCESS! Sentinel data connector created                           |" -Level Success
                    Write-Log "+======================================================================+" -Level Success
                    Write-Log "" -Level Success
                    Write-Log "  Connector ID: $connectorId" -Level Info
                    Write-Log "  API Version: $apiVersion" -Level Info
                    Write-Log "  Source Tenant: $SourceTenantName ($SourceTenantId)" -Level Info
                    Write-Log "" -Level Info
                    break
                } else {
                    $responseContent = $createResponse.Content
                    
                    # Parse error for details
                    try {
                        $errorObj = $responseContent | ConvertFrom-Json
                        $errorMessage = $errorObj.error.message
                        $errorCode = $errorObj.error.code
                        Write-Log "    Error: $errorCode - $errorMessage" -Level Warning
                    } catch {
                        Write-Log "    Response: $responseContent" -Level Warning
                    }
                }
            }
        } catch {
            Write-Log "    Exception: $($_.Exception.Message)" -Level Warning
        }
        
        Write-Log "" -Level Info
    }
}

if(-not $success) {
    Write-Log "========================================================================" -Level Warning
    Write-Log "API-based connector creation did not succeed" -Level Warning
    Write-Log "========================================================================" -Level Warning
    Write-Log "" -Level Info
    Write-Log "This is expected for cross-tenant scenarios. The Sentinel Azure AD" -Level Info
    Write-Log "data connector requires OAuth consent from the source tenant, which" -Level Info
    Write-Log "must be done interactively through the Azure Portal." -Level Info
}
#endregion

#region Step 6: Portal Instructions
Write-Log "" -Level Info
Write-Log "========================================================================" -Level Info
Write-Log "Step 6: Azure Portal Configuration (Recommended)" -Level Info
Write-Log "========================================================================" -Level Info
Write-Log "" -Level Info

$portalUrl = "https://portal.azure.com/#view/Microsoft_Azure_Security_Insights/MainMenuBlade/~/0/id/%2Fsubscriptions%2F$subscriptionId%2FresourceGroups%2F$resourceGroupName%2Fproviders%2FMicrosoft.OperationalInsights%2Fworkspaces%2F$workspaceName"

Write-Log "To configure the Azure AD data connector via Portal:" -Level Info
Write-Log "" -Level Info
Write-Log "  1. Open Microsoft Sentinel:" -Level Info
Write-Log "     $portalUrl" -Level Info
Write-Log "" -Level Info
Write-Log "  2. Navigate to: Configuration -> Data connectors" -Level Info
Write-Log "" -Level Info
Write-Log "  3. Search for: Microsoft Entra ID (formerly Azure Active Directory)" -Level Info
Write-Log "" -Level Info
Write-Log "  4. Click Open connector page" -Level Info
Write-Log "" -Level Info
Write-Log "  5. Under Configuration, you will see options to connect:" -Level Info
Write-Log "     - Sign-in logs (requires P1 or P2 license)" -Level Info
Write-Log "     - Audit logs (free)" -Level Info
Write-Log "     - Non-interactive user sign-in logs (P1)" -Level Info
Write-Log "     - Service principal sign-in logs (P1)" -Level Info
Write-Log "     - Managed identity sign-in logs (P1)" -Level Info
Write-Log "     - Provisioning logs (P1)" -Level Info
Write-Log "" -Level Info
Write-Log "  6. Click Connect for each log type you want to enable" -Level Info
Write-Log "" -Level Info
Write-Log "  IMPORTANT FOR CROSS-TENANT:" -Level Info
Write-Log "  ----------------------------" -Level Warning
Write-Log "  The Azure AD connector in Sentinel connects to the tenant where" -Level Warning
Write-Log "  the current user is authenticated. To collect logs from the" -Level Warning
Write-Log "  SOURCE tenant ($SourceTenantName), you need to:" -Level Warning
Write-Log "" -Level Info
Write-Log "  Option A: Use Diagnostic Settings (Portal method)" -Level Info
Write-Log "    - Sign in to the SOURCE tenant as Global Admin" -Level Info
Write-Log "    - Configure diagnostic settings to send to the workspace" -Level Info
Write-Log "    - This is the approach documented in Step 6 of the guide" -Level Info
Write-Log "" -Level Info
Write-Log "  Option B: Use Azure Lighthouse" -Level Info
Write-Log "    - Delegate the source tenant Entra ID to the managing tenant" -Level Info
Write-Log "    - Then configure the connector from the managing tenant" -Level Info
Write-Log "" -Level Info
#endregion

#region Step 7: Check for Identity Protection Connector
Write-Log "========================================================================" -Level Info
Write-Log "Step 7: Azure AD Identity Protection Connector (P2 Required)" -Level Info
Write-Log "========================================================================" -Level Info
Write-Log "" -Level Info

Write-Log "If the source tenant has Entra ID P2 licenses, you can also enable" -Level Info
Write-Log "the Identity Protection connector for risk events:" -Level Info
Write-Log "" -Level Info
Write-Log "  - RiskyUsers" -Level Info
Write-Log "  - UserRiskEvents" -Level Info
Write-Log "  - RiskyServicePrincipals" -Level Info
Write-Log "  - ServicePrincipalRiskEvents" -Level Info
Write-Log "" -Level Info
Write-Log "This connector is separate from the main Azure AD connector and" -Level Info
Write-Log "can be found in Sentinel under Microsoft Entra ID Identity Protection" -Level Info
Write-Log "" -Level Info
#endregion

#region Summary
Write-Log "" -Level Info
Write-Log "========================================" -Level Info
Write-Log "SUMMARY" -Level Info
Write-Log "========================================" -Level Info
Write-Log "" -Level Info

if($success) {
    Write-Log "[OK] Sentinel Azure AD data connector was created successfully!" -Level Success
    Write-Log "" -Level Info
} else {
    Write-Log "The Sentinel data connector approach has the same limitation as" -Level Warning
    Write-Log "diagnostic settings for cross-tenant scenarios:" -Level Warning
    Write-Log "" -Level Info
    Write-Log "  - The Azure AD connector connects to the CURRENT tenant" -Level Info
    Write-Log "  - Cross-tenant requires OAuth consent from the source tenant" -Level Info
    Write-Log "  - This consent must be done interactively via Portal" -Level Info
    Write-Log "" -Level Info
}

Write-Log "RECOMMENDED APPROACH FOR CROSS-TENANT ENTRA ID LOGS:" -Level Info
Write-Log "----------------------------------------------------" -Level Info
Write-Log "" -Level Info
Write-Log "  1. Sign in to the SOURCE tenant ($SourceTenantName) as Global Admin" -Level Info
Write-Log "" -Level Info
Write-Log "  2. Go to: Entra ID -> Monitoring -> Diagnostic settings" -Level Info
Write-Log "" -Level Info
Write-Log "  3. Add diagnostic setting with:" -Level Info
Write-Log "     - Name: Send-to-$workspaceName" -Level Info
Write-Log "     - Select all log categories" -Level Info
Write-Log "     - Destination: Log Analytics workspace" -Level Info
Write-Log "     - Subscription: (select the managing tenant subscription)" -Level Info
Write-Log "     - Workspace: $workspaceName" -Level Info
Write-Log "" -Level Info
Write-Log "  4. Click Save" -Level Info
Write-Log "" -Level Info
Write-Log "This Portal-based approach works because the Azure Portal handles" -Level Info
Write-Log "the cross-tenant authorization internally." -Level Info
Write-Log "" -Level Info

Write-Log "Verification query (run in Log Analytics after configuration):" -Level Info
Write-Log "" -Level Info
Write-Log "  SigninLogs" -Level Info
Write-Log "  | where TimeGenerated > ago(1h)" -Level Info
Write-Log "  | where AADTenantId == [YOUR_TENANT_ID]" -Level Info
Write-Log "  | summarize count() by ResultType, AppDisplayName" -Level Info
Write-Log "  | order by count_ desc" -Level Info
Write-Log "" -Level Info
Write-Log "Replace [YOUR_TENANT_ID] with: $SourceTenantId" -Level Info
Write-Log "" -Level Info
#endregion
