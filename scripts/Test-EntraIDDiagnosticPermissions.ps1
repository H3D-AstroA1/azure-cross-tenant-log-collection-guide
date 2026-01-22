<#
.SYNOPSIS
    Tests permissions for Entra ID diagnostic settings configuration.

.DESCRIPTION
    This script tests whether the current user has the required permissions
    to configure Entra ID diagnostic settings. It helps diagnose 401 Unauthorized
    errors before attempting to create diagnostic settings.

.PARAMETER TenantId
    The Tenant ID to test permissions against.

.EXAMPLE
    .\Test-EntraIDDiagnosticPermissions.ps1 -TenantId "<TENANT-ID>"

.NOTES
    Author: Azure Cross-Tenant Log Collection Guide
    Version: 1.0
#>

param(
    [Parameter(Mandatory)][string]$TenantId
)

function Write-Log([string]$Message, [string]$Level="Info") {
    $colors = @{Info="Cyan";Success="Green";Warning="Yellow";Error="Red"}
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message" -ForegroundColor $colors[$Level]
}

Write-Log "========================================" -Level Info
Write-Log "Test Entra ID Diagnostic Permissions" -Level Info
Write-Log "========================================" -Level Info
Write-Log "" -Level Info

# Step 1: Check Azure connection
Write-Log "Step 1: Checking Azure connection..." -Level Info

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if(-not $ctx) {
    Write-Log "Not connected to Azure. Connecting..." -Level Warning
    Connect-AzAccount -TenantId $TenantId -ErrorAction Stop
    $ctx = Get-AzContext
}

if($ctx.Tenant.Id -ne $TenantId) {
    Write-Log "Switching to tenant $TenantId..." -Level Warning
    Connect-AzAccount -TenantId $TenantId -ErrorAction Stop
    $ctx = Get-AzContext
}

Write-Log "  Account: $($ctx.Account.Id)" -Level Info
Write-Log "  Tenant: $($ctx.Tenant.Id)" -Level Info
Write-Log "" -Level Info

# Step 2: Get subscriptions
Write-Log "Step 2: Checking subscriptions in tenant..." -Level Info
$subs = Get-AzSubscription -TenantId $TenantId -ErrorAction SilentlyContinue
if($subs -and $subs.Count -gt 0) {
    Write-Log "  ✓ Found $($subs.Count) subscription(s)" -Level Success
    $sub = $subs | Select-Object -First 1
    Set-AzContext -SubscriptionId $sub.Id -TenantId $TenantId | Out-Null
    Write-Log "  Using subscription: $($sub.Name)" -Level Info
} else {
    Write-Log "  ⚠ No subscriptions found" -Level Warning
    Write-Log "    This may cause issues with API calls" -Level Warning
}
Write-Log "" -Level Info

# Step 3: Test Entra ID diagnostic settings API
Write-Log "Step 3: Testing Entra ID diagnostic settings API..." -Level Info
Write-Log "  API: GET /providers/microsoft.aadiam/diagnosticSettings" -Level Info
Write-Log "" -Level Info

$apiPath = "/providers/microsoft.aadiam/diagnosticSettings?api-version=2017-04-01"

try {
    $response = Invoke-AzRestMethod -Path $apiPath -Method GET -ErrorAction Stop
    
    Write-Log "  HTTP Status: $($response.StatusCode)" -Level Info
    
    if($response.StatusCode -eq 200) {
        Write-Log "" -Level Success
        Write-Log "╔══════════════════════════════════════════════════════════════════════╗" -Level Success
        Write-Log "║  SUCCESS! You have permission to access Entra ID diagnostic settings ║" -Level Success
        Write-Log "╚══════════════════════════════════════════════════════════════════════╝" -Level Success
        Write-Log "" -Level Success
        
        $settings = ($response.Content | ConvertFrom-Json).value
        if($settings -and $settings.Count -gt 0) {
            Write-Log "Existing diagnostic settings:" -Level Info
            foreach($s in $settings) {
                Write-Log "  - $($s.name)" -Level Info
            }
        } else {
            Write-Log "No existing diagnostic settings found (this is normal)" -Level Info
        }
        
        Write-Log "" -Level Info
        Write-Log "You can proceed with configuring Entra ID diagnostic settings." -Level Success
        Write-Log "Run: .\Configure-EntraIDDiagnosticSettings.ps1" -Level Info
        
    } elseif($response.StatusCode -eq 401) {
        Write-Log "" -Level Error
        Write-Log "╔══════════════════════════════════════════════════════════════════════╗" -Level Error
        Write-Log "║  401 UNAUTHORIZED - PERMISSION DENIED                                ║" -Level Error
        Write-Log "╚══════════════════════════════════════════════════════════════════════╝" -Level Error
        Write-Log "" -Level Error
        Write-Log "Your account does NOT have permission to access Entra ID diagnostic settings." -Level Error
        Write-Log "" -Level Error
        Write-Log "Required roles (one of):" -Level Warning
        Write-Log "  - Global Administrator" -Level Info
        Write-Log "  - Security Administrator" -Level Info
        Write-Log "" -Level Warning
        Write-Log "To fix this:" -Level Warning
        Write-Log "" -Level Info
        Write-Log "  1. Check your Entra ID roles:" -Level Info
        Write-Log "     https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RolesAndAdministrators" -Level Info
        Write-Log "" -Level Info
        Write-Log "  2. If using PIM (Privileged Identity Management):" -Level Info
        Write-Log "     - Go to: https://portal.azure.com/#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/aadmigratedroles" -Level Info
        Write-Log "     - Activate your Global Administrator or Security Administrator role" -Level Info
        Write-Log "     - Wait a few minutes for activation to propagate" -Level Info
        Write-Log "     - Re-run this test" -Level Info
        Write-Log "" -Level Info
        Write-Log "  3. If you don't have the required role:" -Level Info
        Write-Log "     - Contact your tenant administrator" -Level Info
        Write-Log "     - Request Global Administrator or Security Administrator role" -Level Info
        Write-Log "" -Level Error
        
        # Try to get more details about the error
        try {
            $errorContent = $response.Content | ConvertFrom-Json
            if($errorContent.error.message) {
                Write-Log "Error details: $($errorContent.error.message)" -Level Error
            }
        } catch {}
        
    } elseif($response.StatusCode -eq 403) {
        Write-Log "" -Level Error
        Write-Log "╔══════════════════════════════════════════════════════════════════════╗" -Level Error
        Write-Log "║  403 FORBIDDEN - ACCESS DENIED                                       ║" -Level Error
        Write-Log "╚══════════════════════════════════════════════════════════════════════╝" -Level Error
        Write-Log "" -Level Error
        Write-Log "Your account is authenticated but access is forbidden." -Level Error
        Write-Log "This may indicate a conditional access policy or other restriction." -Level Error
        
    } else {
        Write-Log "  Unexpected status code: $($response.StatusCode)" -Level Warning
        Write-Log "  Response: $($response.Content)" -Level Warning
    }
    
} catch {
    Write-Log "  ✗ Exception: $($_.Exception.Message)" -Level Error
}

Write-Log "" -Level Info
Write-Log "========================================" -Level Info
Write-Log "Test Complete" -Level Info
Write-Log "========================================" -Level Info
