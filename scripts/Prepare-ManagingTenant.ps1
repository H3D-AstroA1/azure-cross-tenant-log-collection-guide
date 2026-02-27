<#
.SYNOPSIS
    Prepares the managing tenant for Azure cross-tenant log collection.

.DESCRIPTION
    This script is used as Step 1 in the Azure Cross-Tenant Log Collection setup.
    It creates the necessary resources in the managing tenant (Atevet12):
    - Security group for delegated access
    - Resource group for centralized logging
    - Log Analytics workspace to receive logs
    - Key Vault for tracking configured tenants and storing credentials
    
    The Key Vault is used to:
    - Track which source tenants have been configured for log collection
    - Store credentials for M365 audit log collection (Step 7)
    - Store any other secrets needed for cross-tenant operations
    
    The script outputs all required IDs needed for the Azure Lighthouse deployment.

.PARAMETER TenantId
    The Azure tenant ID (GUID) of the managing tenant.

.PARAMETER SubscriptionId
    The subscription ID where the Log Analytics workspace and Key Vault will be created.

.PARAMETER SecurityGroupName
    Name of the security group to create. Default: "Lighthouse-CrossTenant-Admins"

.PARAMETER SecurityGroupDescription
    Description for the security group. Default: "Users with delegated access to customer tenants"

.PARAMETER ResourceGroupName
    Name of the resource group to create. Default: "rg-central-logging"

.PARAMETER WorkspaceName
    Name of the Log Analytics workspace. Default: "law-central-logging"

.PARAMETER KeyVaultName
    Name of the Key Vault to create for tracking configured tenants and storing credentials.
    Azure Key Vault names have a strict limit: 3-24 characters, alphanumeric and hyphens only.
    Default: "kv-central-logging"

.PARAMETER Location
    Azure region for resources. Default: "westus2"

.PARAMETER SkipGroupCreation
    Skip security group creation if it already exists.

.PARAMETER SkipWorkspaceCreation
    Skip workspace creation if it already exists.

.PARAMETER GroupMembers
    Array of user principal names (UPNs) or object IDs to add to the security group.
    Example: @("user1@domain.com", "user2@domain.com")

.EXAMPLE
    .\Prepare-ManagingTenant.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"

.EXAMPLE
    .\Prepare-ManagingTenant.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" -SecurityGroupName "Lighthouse-Atevet17-Admins" -WorkspaceName "law-central-atevet12"

.EXAMPLE
    .\Prepare-ManagingTenant.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SubscriptionId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" -GroupMembers @("admin@contoso.com", "analyst@contoso.com")

.NOTES
    Author: Cross-Tenant Log Collection Guide
    Requires: Az.Accounts, Az.Resources, Az.OperationalInsights, Az.KeyVault, Microsoft.Graph modules
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$SecurityGroupName = "Atevet17-Management-Group",

    [Parameter(Mandatory = $false)]
    [string]$SecurityGroupDescription = "Atevet17 Management Group",

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = "rg-atevet17-central-logging",

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceName = "law-atevet17-central-logging",

    [Parameter(Mandatory = $false)]
    [string]$KeyVaultName = "kv-atevet17-logging",

    [Parameter(Mandatory = $false)]
    [string]$Location = "westus2",

    [Parameter(Mandatory = $false)]
    [switch]$SkipGroupCreation,

    [Parameter(Mandatory = $false)]
    [switch]$SkipWorkspaceCreation,

    [Parameter(Mandatory = $false)]
    [string[]]$GroupMembers = @()
)

# Color functions for output
function Write-Success { param($Message) Write-Host $Message -ForegroundColor Green }
function Write-ErrorMsg { param($Message) Write-Host $Message -ForegroundColor Red }
function Write-Warning { param($Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Info { param($Message) Write-Host $Message -ForegroundColor Cyan }
function Write-Header { param($Message) Write-Host $Message -ForegroundColor Cyan -BackgroundColor DarkBlue }

# Results object to store all IDs
$results = @{
    TenantId = $TenantId
    SubscriptionId = $SubscriptionId
    SecurityGroupId = $null
    SecurityGroupName = $SecurityGroupName
    ResourceGroupName = $ResourceGroupName
    WorkspaceName = $WorkspaceName
    WorkspaceId = $null
    WorkspaceResourceId = $null
    WorkspaceCustomerId = $null
    KeyVaultName = $KeyVaultName
    KeyVaultId = $null
    KeyVaultUri = $null
    Location = $Location
    GroupMembersAdded = @()
    GroupMembersFailed = @()
    Success = $true
    Errors = @()
}

# Main script execution
Write-Host ""
Write-Header "======================================================================"
Write-Header "        Prepare Managing Tenant for Cross-Tenant Log Collection       "
Write-Header "======================================================================"
Write-Host ""

#region Check Azure Connection
Write-Info "Checking Azure connection..."

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Warning "Not connected to Azure. Attempting to connect..."
    try {
        Connect-AzAccount -TenantId $TenantId -ErrorAction Stop | Out-Null
        $context = Get-AzContext
    }
    catch {
        Write-ErrorMsg "Failed to connect to Azure: $($_.Exception.Message)"
        Write-Host ""
        Write-Info "Please run: Connect-AzAccount -TenantId '$TenantId'"
        exit 1
    }
}

# Verify we're in the correct tenant
if ($context.Tenant.Id -ne $TenantId) {
    Write-Warning "Currently connected to tenant: $($context.Tenant.Id)"
    Write-Warning "Switching to tenant: $TenantId"
    try {
        Connect-AzAccount -TenantId $TenantId -ErrorAction Stop | Out-Null
        $context = Get-AzContext
    }
    catch {
        Write-ErrorMsg "Failed to switch tenant: $($_.Exception.Message)"
        exit 1
    }
}

Write-Success "Connected as: $($context.Account.Id)"
Write-Success "Tenant: $($context.Tenant.Id)"
Write-Host ""
#endregion

#region Set Subscription Context
Write-Info "Setting subscription context..."
try {
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Success "Subscription: $SubscriptionId"
}
catch {
    Write-ErrorMsg "Failed to set subscription context: $($_.Exception.Message)"
    $results.Success = $false
    $results.Errors += "Failed to set subscription: $($_.Exception.Message)"
    exit 1
}
Write-Host ""
#endregion

#region Create Security Group
if (-not $SkipGroupCreation) {
    Write-Info "Creating security group: $SecurityGroupName"
    Write-Info "  (This requires Microsoft Graph permissions)"
    Write-Host ""
    
    # Check if Microsoft.Graph module is available
    $graphModule = Get-Module -ListAvailable Microsoft.Graph.Groups -ErrorAction SilentlyContinue
    
    if ($graphModule) {
        try {
            # Connect to Microsoft Graph
            # Note: User.Read.All is required to look up users by Object ID or search for guest users
            Write-Info "Connecting to Microsoft Graph..."
            Connect-MgGraph -TenantId $TenantId -Scopes "User.Read.All", "Group.ReadWrite.All" -NoWelcome -ErrorAction Stop
            
            # Check if group already exists - use explicit error handling to ensure we detect existing groups
            Write-Info "  Checking if security group already exists..."
            $existingGroup = $null
            
            try {
                # Use -ConsistencyLevel eventual for better search results
                # Filter for exact match on displayName
                $existingGroups = Get-MgGroup -Filter "displayName eq '$SecurityGroupName'" -ConsistencyLevel eventual -ErrorAction Stop
                
                # If multiple groups returned, find exact match
                if ($existingGroups) {
                    $existingGroup = $existingGroups | Where-Object { $_.DisplayName -eq $SecurityGroupName } | Select-Object -First 1
                }
            }
            catch {
                # If the filter fails, try getting all groups and filtering locally (fallback for older Graph API versions)
                Write-Warning "  Filter query failed, trying alternative lookup method..."
                try {
                    $allGroups = Get-MgGroup -All -ErrorAction Stop
                    $existingGroup = $allGroups | Where-Object { $_.DisplayName -eq $SecurityGroupName } | Select-Object -First 1
                }
                catch {
                    Write-Warning "  Could not query existing groups: $($_.Exception.Message)"
                }
            }
            
            if ($existingGroup) {
                Write-Warning "Security group '$SecurityGroupName' already exists"
                $results.SecurityGroupId = [string]$existingGroup.Id
                Write-Success "  Group ID: $($existingGroup.Id)"
            }
            else {
                Write-Info "  Security group does not exist, creating new group..."
                
                # Create the security group
                $groupParams = @{
                    DisplayName = $SecurityGroupName
                    Description = $SecurityGroupDescription
                    MailEnabled = $false
                    SecurityEnabled = $true
                    MailNickname = ($SecurityGroupName -replace '[^a-zA-Z0-9]', '').ToLower()
                }
                
                $newGroup = New-MgGroup @groupParams -ErrorAction Stop
                $results.SecurityGroupId = [string]$newGroup.Id
                Write-Success "  Created security group successfully"
                Write-Success "  Group ID: $($newGroup.Id)"
            }
        }
        catch {
            Write-ErrorMsg "Failed to create security group: $($_.Exception.Message)"
            Write-Warning "You may need to create the security group manually via Azure Portal:"
            Write-Warning "  1. Go to Azure Active Directory > Groups > New group"
            Write-Warning "  2. Group type: Security"
            Write-Warning "  3. Group name: $SecurityGroupName"
            Write-Warning "  4. Note the Object ID after creation"
            $results.Errors += "Security group creation failed: $($_.Exception.Message)"
        }
    }
    else {
        Write-Warning "Microsoft.Graph module not installed."
        Write-Warning "To install: Install-Module Microsoft.Graph -Scope CurrentUser"
        Write-Host ""
        Write-Warning "Alternative: Create the security group manually via Azure Portal:"
        Write-Warning "  1. Go to Azure Active Directory > Groups > New group"
        Write-Warning "  2. Group type: Security"
        Write-Warning "  3. Group name: $SecurityGroupName"
        Write-Warning "  4. Description: $SecurityGroupDescription"
        Write-Warning "  5. Note the Object ID after creation"
        
        # Try using Az module as fallback
        Write-Host ""
        Write-Info "Attempting to use Az module to create group..."
        try {
            $existingGroup = Get-AzADGroup -DisplayName $SecurityGroupName -ErrorAction SilentlyContinue
            
            if ($existingGroup) {
                Write-Warning "Security group '$SecurityGroupName' already exists"
                $results.SecurityGroupId = $existingGroup.Id
                Write-Success "  Group ID: $($existingGroup.Id)"
            }
            else {
                $newGroup = New-AzADGroup -DisplayName $SecurityGroupName `
                    -Description $SecurityGroupDescription `
                    -MailNickname ($SecurityGroupName -replace '[^a-zA-Z0-9]', '').ToLower() `
                    -SecurityEnabled `
                    -ErrorAction Stop
                
                $results.SecurityGroupId = $newGroup.Id
                Write-Success "  Created security group successfully"
                Write-Success "  Group ID: $($newGroup.Id)"
            }
        }
        catch {
            Write-ErrorMsg "Failed to create security group with Az module: $($_.Exception.Message)"
            $results.Errors += "Security group creation failed: $($_.Exception.Message)"
        }
    }
}
else {
    Write-Info "Skipping security group creation (--SkipGroupCreation specified)"
    Write-Warning "You will need to provide the security group Object ID manually"
}
Write-Host ""
#endregion

#region Add Members to Security Group
if ($GroupMembers.Count -gt 0 -and $results.SecurityGroupId) {
    Write-Info "Adding members to security group..."
    Write-Host ""
    
    foreach ($member in $GroupMembers) {
        try {
            # Try to resolve the user (could be UPN or Object ID)
            $user = $null
            
            # Check if it's a GUID (Object ID)
            if ($member -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                # It's an Object ID - try to find user or guest
                if ($graphModule) {
                    $user = Get-MgUser -UserId $member -ErrorAction SilentlyContinue
                }
                else {
                    $user = Get-AzADUser -ObjectId $member -ErrorAction SilentlyContinue
                }
            }
            else {
                # It's a UPN - could be a regular user or a guest user
                if ($graphModule) {
                    # First try direct lookup
                    $user = Get-MgUser -UserId $member -ErrorAction SilentlyContinue
                    
                    # If not found, try searching for guest users
                    # Guest users have UPN format: user_domain.com#EXT#@tenant.onmicrosoft.com
                    # But their mail or otherMails may contain the original email
                    if (-not $user) {
                        Write-Info "  Searching for user as potential guest: $member"
                        # Search by mail property (works for guests)
                        $user = Get-MgUser -Filter "mail eq '$member'" -ErrorAction SilentlyContinue | Select-Object -First 1
                        
                        # If still not found, try searching by userPrincipalName pattern for guests
                        if (-not $user) {
                            # Convert user@domain.com to user_domain.com#EXT# pattern
                            $guestUpnPattern = ($member -replace '@', '_') + "#EXT#"
                            $user = Get-MgUser -Filter "startswith(userPrincipalName, '$guestUpnPattern')" -ErrorAction SilentlyContinue | Select-Object -First 1
                        }
                    }
                }
                else {
                    # Using Az module
                    $user = Get-AzADUser -UserPrincipalName $member -ErrorAction SilentlyContinue
                    
                    # If not found, try searching for guest users
                    if (-not $user) {
                        Write-Info "  Searching for user as potential guest: $member"
                        # Search by mail property
                        $user = Get-AzADUser -Filter "mail eq '$member'" -ErrorAction SilentlyContinue | Select-Object -First 1
                        
                        # If still not found, try the guest UPN pattern
                        if (-not $user) {
                            $guestUpnPattern = ($member -replace '@', '_') + "#EXT#"
                            $user = Get-AzADUser -Filter "startswith(userPrincipalName, '$guestUpnPattern')" -ErrorAction SilentlyContinue | Select-Object -First 1
                        }
                    }
                }
            }
            
            if (-not $user) {
                Write-ErrorMsg "  [X] User not found: $member"
                Write-ErrorMsg "      If this is a guest user, ensure they have been invited to this tenant."
                Write-ErrorMsg "      Guest users can be added by their Object ID from this tenant."
                $results.GroupMembersFailed += $member
                continue
            }
            
            $userId = if ($graphModule) { $user.Id } else { $user.Id }
            
            # Check if user is already a member
            # Ensure SecurityGroupId is a string (not an array)
            $groupId = [string]$results.SecurityGroupId
            
            $isMember = $false
            if ($graphModule) {
                $existingMembers = Get-MgGroupMember -GroupId $groupId -ErrorAction SilentlyContinue
                $isMember = $existingMembers.Id -contains $userId
            }
            else {
                $existingMembers = Get-AzADGroupMember -GroupObjectId $groupId -ErrorAction SilentlyContinue
                $isMember = $existingMembers.Id -contains $userId
            }
            
            if ($isMember) {
                Write-Warning "  [~] Already a member: $member"
                $results.GroupMembersAdded += $member
                continue
            }
            
            # Add user to group
            # Use the groupId variable we already defined above
            if ($graphModule) {
                $memberRef = @{
                    "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$userId"
                }
                New-MgGroupMemberByRef -GroupId $groupId -BodyParameter $memberRef -ErrorAction Stop
            }
            else {
                Add-AzADGroupMember -TargetGroupObjectId $groupId -MemberObjectId $userId -ErrorAction Stop
            }
            
            Write-Success "  [+] Added: $member"
            $results.GroupMembersAdded += $member
        }
        catch {
            Write-ErrorMsg "  [X] Failed to add $member : $($_.Exception.Message)"
            $results.GroupMembersFailed += $member
            $results.Errors += "Failed to add member $member : $($_.Exception.Message)"
        }
    }
    Write-Host ""
}
elseif ($GroupMembers.Count -gt 0 -and -not $results.SecurityGroupId) {
    Write-Warning "Cannot add members: Security group ID not available"
    Write-Warning "Create the group first or provide the group Object ID"
}
#endregion

#region Create Resource Group
if (-not $SkipWorkspaceCreation) {
    Write-Info "Creating resource group: $ResourceGroupName"
    
    try {
        $existingRg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
        
        if ($existingRg) {
            Write-Warning "Resource group '$ResourceGroupName' already exists in $($existingRg.Location)"
            $results.Location = $existingRg.Location
        }
        else {
            $newRg = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop
            Write-Success "  Created resource group in $Location"
        }
    }
    catch {
        Write-ErrorMsg "Failed to create resource group: $($_.Exception.Message)"
        $results.Success = $false
        $results.Errors += "Resource group creation failed: $($_.Exception.Message)"
    }
}
Write-Host ""
#endregion

#region Create Log Analytics Workspace
if (-not $SkipWorkspaceCreation) {
    Write-Info "Creating Log Analytics workspace: $WorkspaceName"
    
    try {
        $existingWorkspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction SilentlyContinue
        
        if ($existingWorkspace) {
            Write-Warning "Log Analytics workspace '$WorkspaceName' already exists"
            $workspace = $existingWorkspace
        }
        else {
            $workspace = New-AzOperationalInsightsWorkspace `
                -ResourceGroupName $ResourceGroupName `
                -Name $WorkspaceName `
                -Location $results.Location `
                -Sku "PerGB2018" `
                -ErrorAction Stop
            
            Write-Success "  Created Log Analytics workspace"
        }
        
        $results.WorkspaceId = $workspace.ResourceId
        $results.WorkspaceResourceId = $workspace.ResourceId
        $results.WorkspaceCustomerId = $workspace.CustomerId
        
        Write-Success "  Workspace Resource ID: $($workspace.ResourceId)"
        Write-Success "  Workspace Customer ID: $($workspace.CustomerId)"
    }
    catch {
        Write-ErrorMsg "Failed to create Log Analytics workspace: $($_.Exception.Message)"
        $results.Success = $false
        $results.Errors += "Workspace creation failed: $($_.Exception.Message)"
    }
}
else {
    Write-Info "Skipping workspace creation (--SkipWorkspaceCreation specified)"
    
    # Try to get existing workspace
    try {
        $existingWorkspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroupName -Name $WorkspaceName -ErrorAction SilentlyContinue
        if ($existingWorkspace) {
            $results.WorkspaceId = $existingWorkspace.ResourceId
            $results.WorkspaceResourceId = $existingWorkspace.ResourceId
            $results.WorkspaceCustomerId = $existingWorkspace.CustomerId
            Write-Success "Found existing workspace: $WorkspaceName"
        }
    }
    catch {
        Write-Warning "Could not find existing workspace"
    }
}
Write-Host ""
#endregion

#region Create Key Vault
Write-Info "Creating Key Vault: $KeyVaultName"

try {
    # First, check if Key Vault already exists in the resource group
    $existingKv = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    
    if ($existingKv) {
        Write-Warning "Key Vault '$KeyVaultName' already exists"
        $keyVault = $existingKv
    }
    else {
        # Check if Key Vault exists but was soft-deleted (globally unique names are reserved even after deletion)
        Write-Info "  Checking for soft-deleted Key Vault..."
        $deletedKv = $null
        try {
            $deletedKv = Get-AzKeyVault -VaultName $KeyVaultName -Location $results.Location -InRemovedState -ErrorAction SilentlyContinue
        }
        catch {
            # InRemovedState parameter might not be supported in older versions
            Write-Warning "  Could not check for soft-deleted vaults (older Az.KeyVault module)"
        }
        
        if ($deletedKv) {
            Write-Warning "  Key Vault '$KeyVaultName' was previously deleted and is in soft-deleted state"
            Write-Info "  Attempting to recover the soft-deleted Key Vault..."
            
            try {
                # Recover the soft-deleted Key Vault
                Undo-AzKeyVaultRemoval -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -Location $results.Location -ErrorAction Stop
                
                # Wait for recovery to complete
                Write-Info "  Waiting for Key Vault recovery to complete..."
                Start-Sleep -Seconds 10
                
                # Get the recovered Key Vault
                $keyVault = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
                Write-Success "  ✓ Key Vault recovered successfully"
            }
            catch {
                Write-ErrorMsg "  Failed to recover Key Vault: $($_.Exception.Message)"
                Write-Warning "  You may need to purge the deleted Key Vault first:"
                Write-Warning "    Remove-AzKeyVault -VaultName '$KeyVaultName' -Location '$($results.Location)' -InRemovedState -Force"
                Write-Warning "  Or wait for the retention period to expire (default: 90 days)"
                $results.Errors += "Key Vault recovery failed: $($_.Exception.Message)"
                throw $_
            }
        }
        else {
            # Key Vault doesn't exist and isn't soft-deleted - create new one
            # Try to create Key Vault with RBAC authorization first
            # If the parameter is not supported, fall back to vault access policy mode
            $keyVaultCreated = $false
            
            # First attempt: Try with -EnableRbacAuthorization parameter
            try {
                Write-Info "  Attempting to create Key Vault with RBAC authorization..."
                $keyVault = New-AzKeyVault `
                    -VaultName $KeyVaultName `
                    -ResourceGroupName $ResourceGroupName `
                    -Location $results.Location `
                    -EnabledForDeployment `
                    -EnabledForTemplateDeployment `
                    -EnableRbacAuthorization `
                    -ErrorAction Stop
                
                $keyVaultCreated = $true
                Write-Success "  Created Key Vault with RBAC authorization"
            }
            catch {
                $errorMessage = $_.Exception.Message
                
                # Check if the error is specifically about the EnableRbacAuthorization parameter
                if ($errorMessage -like "*EnableRbacAuthorization*" -or $errorMessage -like "*parameter name*") {
                    Write-Warning "  -EnableRbacAuthorization parameter not supported by current Az.KeyVault module"
                    Write-Warning "  Falling back to vault access policy mode..."
                    
                    # Second attempt: Create without RBAC parameter
                    try {
                        $keyVault = New-AzKeyVault `
                            -VaultName $KeyVaultName `
                            -ResourceGroupName $ResourceGroupName `
                            -Location $results.Location `
                            -EnabledForDeployment `
                            -EnabledForTemplateDeployment `
                            -ErrorAction Stop
                        
                        $keyVaultCreated = $true
                        Write-Success "  Created Key Vault with vault access policy mode"
                        Write-Info "  To enable RBAC authorization later:"
                        Write-Info "    1. Go to Azure Portal > Key Vault > Access configuration"
                        Write-Info "    2. Select 'Azure role-based access control'"
                        Write-Info "    3. Or update Az.KeyVault module: Update-Module -Name Az.KeyVault -Force"
                    }
                    catch {
                        # Check if this is a soft-delete conflict that we missed
                        if ($_.Exception.Message -like "*already in use*" -or $_.Exception.Message -like "*soft delete*" -or $_.Exception.Message -like "*recoverable state*") {
                            Write-ErrorMsg "  Key Vault name '$KeyVaultName' is reserved by a soft-deleted vault"
                            Write-Warning "  To resolve this, either:"
                            Write-Warning "    1. Purge the deleted vault: Remove-AzKeyVault -VaultName '$KeyVaultName' -Location '$($results.Location)' -InRemovedState -Force"
                            Write-Warning "    2. Use a different Key Vault name with -KeyVaultName parameter"
                            Write-Warning "    3. Wait for the retention period to expire (default: 90 days)"
                        }
                        throw $_
                    }
                }
                # Check if this is a name conflict (soft-delete or cross-tenant)
                elseif ($errorMessage -like "*already in use*" -or $errorMessage -like "*soft delete*" -or $errorMessage -like "*recoverable state*" -or $errorMessage -like "*VaultAlreadyExists*") {
                    Write-ErrorMsg "  Key Vault name '$KeyVaultName' is globally reserved"
                    Write-Host ""
                    Write-WarningMsg "  ╔══════════════════════════════════════════════════════════════════════╗"
                    Write-WarningMsg "  ║  IMPORTANT: Azure Key Vault names are GLOBALLY UNIQUE across ALL    ║"
                    Write-WarningMsg "  ║  of Azure, not just within your tenant or subscription.             ║"
                    Write-WarningMsg "  ╚══════════════════════════════════════════════════════════════════════╝"
                    Write-Host ""
                    Write-Info "  This error can occur if:"
                    Write-Host "    1. The Key Vault was soft-deleted in THIS tenant (can be recovered or purged)"
                    Write-Host "    2. The Key Vault name is used in a DIFFERENT tenant (cannot be detected)"
                    Write-Host "    3. The Key Vault name is reserved by another Azure customer"
                    Write-Host ""
                    Write-Info "  To resolve this, try ONE of these options:"
                    Write-Host ""
                    Write-Host "    Option A: Check for soft-deleted vault in THIS tenant:"
                    Write-Host "      Get-AzKeyVault -VaultName '$KeyVaultName' -Location '$($results.Location)' -InRemovedState"
                    Write-Host ""
                    Write-Host "    Option B: Purge the soft-deleted vault (if found in Option A):"
                    Write-Host "      Remove-AzKeyVault -VaultName '$KeyVaultName' -Location '$($results.Location)' -InRemovedState -Force"
                    Write-Host ""
                    Write-Host "    Option C: Use a different Key Vault name (RECOMMENDED if vault is in another tenant):"
                    Write-Host "      .\Prepare-ManagingTenant.ps1 ... -KeyVaultName 'kv-logs-$((Get-Random -Maximum 9999))'"
                    Write-Host ""
                    Write-Host "    Option D: If you created the vault in another tenant, delete it there first:"
                    Write-Host "      Connect-AzAccount -TenantId '<OTHER-TENANT-ID>'"
                    Write-Host "      Remove-AzKeyVault -VaultName '$KeyVaultName' -ResourceGroupName '<RG-NAME>'"
                    Write-Host "      Remove-AzKeyVault -VaultName '$KeyVaultName' -Location '<LOCATION>' -InRemovedState -Force"
                    Write-Host ""
                    throw $_
                }
                else {
                    # Re-throw if it's a different error
                    throw $_
                }
            }
        }
    }
    
    $results.KeyVaultId = $keyVault.ResourceId
    $results.KeyVaultUri = $keyVault.VaultUri
    
    Write-Success "  Key Vault Resource ID: $($keyVault.ResourceId)"
    Write-Success "  Key Vault URI: $($keyVault.VaultUri)"
    
    # Assign Key Vault Secrets Officer role to the security group
    # This ensures all group members can write secrets in subsequent steps (e.g., Step 6, Step 7)
    if ($results.SecurityGroupId) {
        Write-Info "  Assigning Key Vault Secrets Officer role to security group..."
        try {
            # Ensure SecurityGroupId is a string (not an array)
            $groupId = [string]$results.SecurityGroupId
            
            # Check if role assignment already exists for the security group
            $existingAssignment = Get-AzRoleAssignment `
                -ObjectId $groupId `
                -RoleDefinitionName "Key Vault Secrets Officer" `
                -Scope $keyVault.ResourceId `
                -ErrorAction SilentlyContinue
            
            if ($existingAssignment) {
                Write-Warning "  Key Vault Secrets Officer role already assigned to security group"
            }
            else {
                New-AzRoleAssignment `
                    -ObjectId $groupId `
                    -RoleDefinitionName "Key Vault Secrets Officer" `
                    -Scope $keyVault.ResourceId `
                    -ErrorAction Stop | Out-Null
                
                Write-Success "  ✓ Key Vault Secrets Officer role assigned to security group '$SecurityGroupName'"
                Write-Info "    (All group members can now write secrets in Step 6 and Step 7)"
            }
        }
        catch {
            Write-Warning "  Could not assign Key Vault Secrets Officer role to security group: $($_.Exception.Message)"
            Write-Warning "  You may need to manually assign this role before running Step 6"
            Write-Info "  To assign manually, run:"
            Write-Info "    New-AzRoleAssignment -ObjectId '$($results.SecurityGroupId)' -RoleDefinitionName 'Key Vault Secrets Officer' -Scope '$($keyVault.ResourceId)'"
        }
    }
    else {
        Write-Warning "  Security group not available - skipping Key Vault role assignment"
        Write-Warning "  You will need to manually assign Key Vault Secrets Officer role to users who need to run Step 6 or Step 7"
        Write-Info "  To assign manually, run:"
        Write-Info "    New-AzRoleAssignment -ObjectId '<security-group-or-user-object-id>' -RoleDefinitionName 'Key Vault Secrets Officer' -Scope '$($keyVault.ResourceId)'"
    }
}
catch {
    Write-ErrorMsg "Failed to create Key Vault: $($_.Exception.Message)"
    $results.Errors += "Key Vault creation failed: $($_.Exception.Message)"
}
Write-Host ""
#endregion

#region Output Summary
Write-Host ""
Write-Header "======================================================================"
Write-Header "                              SUMMARY                                 "
Write-Header "======================================================================"
Write-Host ""

if ($results.Success -and $results.Errors.Count -eq 0) {
    Write-Success "All resources created successfully!"
}
elseif ($results.Errors.Count -gt 0) {
    Write-Warning "Completed with some issues:"
    foreach ($error in $results.Errors) {
        Write-ErrorMsg "  - $error"
    }
}
Write-Host ""

Write-Info "=== Required IDs for Azure Lighthouse Deployment ==="
Write-Host ""
Write-Host "Managing Tenant ID:        $($results.TenantId)"
Write-Host "Subscription ID:           $($results.SubscriptionId)"
if ($results.SecurityGroupId) {
    Write-Host "Security Group Object ID:  $($results.SecurityGroupId)"
}
else {
    Write-Warning "Security Group Object ID:  <CREATE MANUALLY AND NOTE THE ID>"
}
Write-Host "Resource Group Name:       $($results.ResourceGroupName)"
Write-Host "Workspace Name:            $($results.WorkspaceName)"
if ($results.WorkspaceResourceId) {
    Write-Host "Workspace Resource ID:     $($results.WorkspaceResourceId)"
}
Write-Host "Key Vault Name:            $($results.KeyVaultName)"
if ($results.KeyVaultId) {
    Write-Host "Key Vault Resource ID:     $($results.KeyVaultId)"
    Write-Host "Key Vault URI:             $($results.KeyVaultUri)"
}
Write-Host "Location:                  $($results.Location)"
Write-Host ""

if ($results.GroupMembersAdded.Count -gt 0) {
    Write-Info "Group Members Added:"
    foreach ($member in $results.GroupMembersAdded) {
        Write-Success "  - $member"
    }
    Write-Host ""
}

if ($results.GroupMembersFailed.Count -gt 0) {
    Write-Warning "Group Members Failed:"
    foreach ($member in $results.GroupMembersFailed) {
        Write-ErrorMsg "  - $member"
    }
    Write-Host ""
}

# Output as JSON for easy copying
Write-Info "=== JSON Output (for automation) ==="
Write-Host ""
$jsonOutput = @{
    managingTenantId = $results.TenantId
    subscriptionId = $results.SubscriptionId
    securityGroupObjectId = $results.SecurityGroupId
    resourceGroupName = $results.ResourceGroupName
    workspaceName = $results.WorkspaceName
    workspaceResourceId = $results.WorkspaceResourceId
    workspaceCustomerId = $results.WorkspaceCustomerId
    keyVaultName = $results.KeyVaultName
    keyVaultResourceId = $results.KeyVaultId
    keyVaultUri = $results.KeyVaultUri
    location = $results.Location
    groupMembersAdded = $results.GroupMembersAdded
    groupMembersFailed = $results.GroupMembersFailed
} | ConvertTo-Json -Depth 2

Write-Host $jsonOutput
Write-Host ""

# Output the Lighthouse parameters template
Write-Info "=== Lighthouse Parameters Template ==="
Write-Host ""
Write-Host @"
Update your lighthouse-parameters-definition.json with these values:

{
  "managedByTenantId": {
    "value": "$($results.TenantId)"
  },
  "authorizations": {
    "value": [
      {
        "principalId": "$($results.SecurityGroupId)",
        "roleDefinitionId": "acdd72a7-3385-48ef-bd42-f606fba81ae7",
        "principalIdDisplayName": "$SecurityGroupName"
      },
      {
        "principalId": "$($results.SecurityGroupId)",
        "roleDefinitionId": "b24988ac-6180-42a0-ab88-20f7382dd24c",
        "principalIdDisplayName": "$SecurityGroupName"
      },
      {
        "principalId": "$($results.SecurityGroupId)",
        "roleDefinitionId": "43d0d8ad-25c7-4714-9337-8ba259a9fe05",
        "principalIdDisplayName": "$SecurityGroupName"
      },
      {
        "principalId": "$($results.SecurityGroupId)",
        "roleDefinitionId": "73c42c96-874c-492b-b04d-ab87d138a893",
        "principalIdDisplayName": "$SecurityGroupName"
      }
    ]
  }
}
"@
Write-Host ""

Write-Info "=== Next Steps ==="
Write-Host ""
Write-Host "1. Add users to the security group '$SecurityGroupName'"
Write-Host "2. Update the Lighthouse parameters file with the values above"
Write-Host "3. Run the Azure Lighthouse deployment in the SOURCE tenant"
Write-Host "4. Configure diagnostic settings to send logs to the workspace"
Write-Host "5. Use the Key Vault '$KeyVaultName' to track configured tenants"
Write-Host ""
#endregion

# Return results object
return $results