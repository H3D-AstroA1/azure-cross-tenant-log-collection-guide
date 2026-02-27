<#
.SYNOPSIS
    Helper script to connect to a source tenant and assign roles to policy managed identities.

.DESCRIPTION
    Wraps Configure-VMDiagnosticLogs.ps1 -AssignRolesAsSourceAdmin so a source tenant admin
    can run a single command that connects to the source tenant and assigns roles.

.PARAMETER TenantId
    Source tenant ID where the VMs are located.

.PARAMETER SubscriptionIds
    Subscription IDs in the source tenant to process.

.PARAMETER PolicyAssignmentPrefix
    Optional policy assignment name prefix to filter assignments.

.PARAMETER DataCollectionRuleName
    Optional DCR name used to grant Monitoring Contributor on the DCR.

.PARAMETER SkipRemediation
    Skip creating remediation tasks for existing non-compliant VMs.

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$PolicyAssignmentPrefix,

    [Parameter(Mandatory = $false)]
    [string]$DataCollectionRuleName,

    [Parameter(Mandatory = $false)]
    [switch]$SkipRemediation
)

$ErrorActionPreference = 'Stop'

Write-Host "Connecting to source tenant: $TenantId" -ForegroundColor Cyan
Connect-AzAccount -TenantId $TenantId

$connectedContext = Get-AzContext -ErrorAction SilentlyContinue
if ($connectedContext) {
    Write-Host "Connected tenant: $($connectedContext.Tenant.Id)" -ForegroundColor Green
}

$scriptPath = Join-Path $PSScriptRoot 'Configure-VMDiagnosticLogs.ps1'
if (-not (Test-Path -Path $scriptPath)) {
    throw "Configure-VMDiagnosticLogs.ps1 not found at $scriptPath"
}

$invokeParams = @{
    AssignRolesAsSourceAdmin = $true
    SubscriptionIds = $SubscriptionIds
}

if ($PolicyAssignmentPrefix) {
    $invokeParams.PolicyAssignmentPrefix = $PolicyAssignmentPrefix
}

if ($DataCollectionRuleName) {
    $invokeParams.DataCollectionRuleName = $DataCollectionRuleName
}

if ($SkipRemediation) {
    $invokeParams.SkipRemediation = $true
}

& $scriptPath @invokeParams
