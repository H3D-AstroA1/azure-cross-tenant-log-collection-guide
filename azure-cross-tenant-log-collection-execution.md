# Azure Cross-Tenant Log Collection - Execution Scripts

This document contains Python scripts for automating the Azure cross-tenant log collection setup process. These scripts complement the main guide ([azure-cross-tenant-log-collection-guide.md](azure-cross-tenant-log-collection-guide.md)).

---

## Table of Contents

1. [Important: Where to Run These Scripts](#important-where-to-run-these-scripts)
2. [Prerequisites](#prerequisites)
3. [Step 0: Register Resource Providers](#step-0-register-resource-providers)
4. [Step 1: Create Security Group and Log Analytics Workspace](#step-1-create-security-group-and-log-analytics-workspace)
5. [Step 2: Deploy Azure Lighthouse](#step-2-deploy-azure-lighthouse)

---

## Important: Where to Run These Scripts

> ⚠️ **CRITICAL**: These scripts must be run from the **SOURCE/CUSTOMER TENANT** (the tenant where the resources exist that you want to collect logs from).

### Cross-Tenant Architecture Overview

In a cross-tenant log collection scenario, there are two tenants:

| Tenant | Role | Example | What Runs Here |
|--------|------|---------|----------------|
| **Source Tenant** | Customer/Resource Owner | Atevet17 | ✅ **Run these scripts here** |
| **Managing Tenant** | MSP/Security Team | Atevet12 | Log Analytics Workspace, Sentinel |

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SOURCE TENANT (Atevet17)                         │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  📜 Run these scripts here:                                      │   │
│  │     • register_managed_services.py                               │   │
│  │     • Azure Lighthouse ARM template deployment                   │   │
│  │     • Diagnostic settings configuration                          │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                  │
│  │ Subscription │  │ Subscription │  │ Subscription │                  │
│  │      A       │  │      B       │  │      C       │                  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘                  │
│         │                 │                 │                           │
│         └─────────────────┼─────────────────┘                           │
│                           │                                             │
│                           │ Logs flow via                               │
│                           │ Azure Lighthouse                            │
│                           ▼                                             │
└─────────────────────────────────────────────────────────────────────────┘
                            │
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      MANAGING TENANT (Atevet12)                         │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │  Log Analytics Workspace  ──────►  Microsoft Sentinel            │  │
│  │  (Receives logs)                   (Security monitoring)         │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Why Run from the Source Tenant?

The `register_managed_services.py` script registers the `Microsoft.ManagedServices` resource provider on subscriptions. This is a **prerequisite for Azure Lighthouse** and must be done on the **source tenant's subscriptions** (where the resources exist).

### Authentication Requirements

When running from the source tenant, you need:

| Requirement | Details |
|-------------|---------|
| **Role** | Owner or Contributor on the source subscriptions |
| **Permission** | `Microsoft.ManagedServices/register/action` |
| **Authentication** | Azure CLI, Service Principal, or Managed Identity |

### Step-by-Step Execution

1. **Authenticate to the SOURCE tenant** (e.g., Atevet17):
   ```bash
   az login --tenant <SOURCE-TENANT-ID>
   ```

2. **Verify you're in the correct tenant**:
   ```bash
   az account show --query tenantId -o tsv
   ```

3. **Run the script**:
   ```bash
   python register_managed_services.py --tenant-id <SOURCE-TENANT-ID>
   ```

---

## Prerequisites

### Python Environment Setup

```bash
# Create a virtual environment (recommended)
python -m venv azure-log-collection-env
source azure-log-collection-env/bin/activate  # Linux/Mac
# or
azure-log-collection-env\Scripts\activate  # Windows

# Install required packages
pip install azure-identity azure-mgmt-resource azure-mgmt-subscription
```

### Required Python Packages

```
azure-identity>=1.12.0
azure-mgmt-resource>=23.0.0
azure-mgmt-subscription>=3.0.0
```

Save as `requirements.txt` and install with:
```bash
pip install -r requirements.txt
```

### Authentication

The scripts use `DefaultAzureCredential` which supports multiple authentication methods:

1. **Azure CLI** (recommended for development): Run `az login --tenant <tenant-id>` first
2. **Environment Variables**: Set `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`
3. **Managed Identity**: When running in Azure (VMs, Functions, etc.)
4. **VS Code**: If signed into Azure in VS Code

---

## Step 0: Register Resource Providers

This script checks and registers the `Microsoft.ManagedServices` resource provider across all subscriptions in a tenant. This is required before deploying Azure Lighthouse.

### Script: `register_managed_services.py`

```python
#!/usr/bin/env python3
"""
Azure Resource Provider Registration Script
============================================
Registers Microsoft.ManagedServices across all subscriptions in a tenant.

This script is used as Step 0 in the Azure Cross-Tenant Log Collection setup.
It ensures the Microsoft.ManagedServices resource provider is registered in
all subscriptions before deploying Azure Lighthouse.

Usage:
    python register_managed_services.py --tenant-id <tenant-id>
    python register_managed_services.py --tenant-id <tenant-id> --check-only
    python register_managed_services.py --subscription-ids <sub1> <sub2>
"""

import argparse
import sys
import time
from typing import List, Optional, Dict, Any

try:
    from azure.identity import DefaultAzureCredential, InteractiveBrowserCredential
    from azure.mgmt.resource import ResourceManagementClient
    from azure.mgmt.subscription import SubscriptionClient
    from azure.core.exceptions import HttpResponseError, ClientAuthenticationError
except ImportError:
    print("Error: Required Azure SDK packages not installed.")
    print("Please run: pip install azure-identity azure-mgmt-resource azure-mgmt-subscription")
    sys.exit(1)


# Constants
PROVIDER_NAMESPACE = "Microsoft.ManagedServices"
REGISTRATION_TIMEOUT = 300  # 5 minutes
POLL_INTERVAL = 10  # seconds


class Colors:
    """ANSI color codes for terminal output."""
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    RESET = '\033[0m'
    BOLD = '\033[1m'


def print_status(message: str, status: str = "info") -> None:
    """Print a colored status message."""
    colors = {
        "success": Colors.GREEN,
        "error": Colors.RED,
        "warning": Colors.YELLOW,
        "info": Colors.BLUE,
        "header": Colors.CYAN + Colors.BOLD
    }
    color = colors.get(status, Colors.RESET)
    print(f"{color}{message}{Colors.RESET}")


def get_credential(tenant_id: Optional[str] = None) -> DefaultAzureCredential:
    """
    Get Azure credential for authentication.
    
    Args:
        tenant_id: Optional tenant ID to authenticate against
        
    Returns:
        DefaultAzureCredential instance
    """
    kwargs = {}
    if tenant_id:
        kwargs['additionally_allowed_tenants'] = [tenant_id]
        # For cross-tenant scenarios, we may need to specify the tenant
        kwargs['exclude_shared_token_cache_credential'] = True
    
    return DefaultAzureCredential(**kwargs)


def get_subscriptions(credential: DefaultAzureCredential, 
                      tenant_id: Optional[str] = None) -> List[Dict[str, str]]:
    """
    Get all subscriptions accessible to the authenticated user.
    
    Args:
        credential: Azure credential
        tenant_id: Optional tenant ID to filter subscriptions
        
    Returns:
        List of subscription dictionaries with 'id', 'name', and 'tenant_id'
    """
    subscription_client = SubscriptionClient(credential)
    subscriptions = []
    
    try:
        for sub in subscription_client.subscriptions.list():
            sub_info = {
                'id': sub.subscription_id,
                'name': sub.display_name,
                'tenant_id': sub.tenant_id,
                'state': sub.state
            }
            
            # Filter by tenant if specified
            if tenant_id is None or sub.tenant_id == tenant_id:
                if sub.state == 'Enabled':
                    subscriptions.append(sub_info)
                else:
                    print_status(f"  Skipping {sub.display_name} (state: {sub.state})", "warning")
                    
    except HttpResponseError as e:
        print_status(f"Error listing subscriptions: {e.message}", "error")
        raise
        
    return subscriptions


def check_provider_status(credential: DefaultAzureCredential, 
                          subscription_id: str) -> str:
    """
    Check the registration status of Microsoft.ManagedServices.
    
    Args:
        credential: Azure credential
        subscription_id: Subscription ID to check
        
    Returns:
        Registration state: 'Registered', 'NotRegistered', 'Registering', etc.
    """
    resource_client = ResourceManagementClient(credential, subscription_id)
    
    try:
        provider = resource_client.providers.get(PROVIDER_NAMESPACE)
        return provider.registration_state
    except HttpResponseError as e:
        if e.status_code == 404:
            return "NotRegistered"
        raise


def register_provider(credential: DefaultAzureCredential, 
                      subscription_id: str) -> bool:
    """
    Register the Microsoft.ManagedServices resource provider.
    
    Args:
        credential: Azure credential
        subscription_id: Subscription ID to register in
        
    Returns:
        True if registration was initiated successfully
    """
    resource_client = ResourceManagementClient(credential, subscription_id)
    
    try:
        resource_client.providers.register(PROVIDER_NAMESPACE)
        return True
    except HttpResponseError as e:
        print_status(f"    Error registering provider: {e.message}", "error")
        return False


def wait_for_registration(credential: DefaultAzureCredential, 
                          subscription_id: str,
                          timeout: int = REGISTRATION_TIMEOUT) -> bool:
    """
    Wait for the resource provider registration to complete.
    
    Args:
        credential: Azure credential
        subscription_id: Subscription ID
        timeout: Maximum time to wait in seconds
        
    Returns:
        True if registration completed successfully
    """
    start_time = time.time()
    
    while time.time() - start_time < timeout:
        status = check_provider_status(credential, subscription_id)
        
        if status == "Registered":
            return True
        elif status in ["NotRegistered", "Unregistered"]:
            # Registration failed or was cancelled
            return False
        
        # Still registering, wait and check again
        time.sleep(POLL_INTERVAL)
    
    # Timeout reached
    return False


def process_subscription(credential: DefaultAzureCredential,
                         subscription: Dict[str, str],
                         check_only: bool = False) -> Dict[str, Any]:
    """
    Process a single subscription - check and optionally register the provider.
    
    Args:
        credential: Azure credential
        subscription: Subscription info dictionary
        check_only: If True, only check status without registering
        
    Returns:
        Result dictionary with status and details
    """
    sub_id = subscription['id']
    sub_name = subscription['name']
    
    result = {
        'subscription_id': sub_id,
        'subscription_name': sub_name,
        'initial_status': None,
        'final_status': None,
        'action_taken': None,
        'success': False,
        'error': None
    }
    
    try:
        # Check current status
        status = check_provider_status(credential, sub_id)
        result['initial_status'] = status
        
        if status == "Registered":
            print_status(f"  ✓ {sub_name}: Already registered", "success")
            result['final_status'] = status
            result['action_taken'] = "none"
            result['success'] = True
            
        elif status == "Registering":
            print_status(f"  ⟳ {sub_name}: Registration in progress, waiting...", "info")
            if wait_for_registration(credential, sub_id):
                print_status(f"    ✓ Registration completed", "success")
                result['final_status'] = "Registered"
                result['action_taken'] = "waited"
                result['success'] = True
            else:
                print_status(f"    ✗ Registration timed out", "error")
                result['final_status'] = check_provider_status(credential, sub_id)
                result['action_taken'] = "waited"
                result['success'] = False
                
        elif check_only:
            print_status(f"  ○ {sub_name}: Not registered (check-only mode)", "warning")
            result['final_status'] = status
            result['action_taken'] = "check_only"
            result['success'] = True
            
        else:
            print_status(f"  → {sub_name}: Registering...", "info")
            if register_provider(credential, sub_id):
                if wait_for_registration(credential, sub_id):
                    print_status(f"    ✓ Successfully registered", "success")
                    result['final_status'] = "Registered"
                    result['action_taken'] = "registered"
                    result['success'] = True
                else:
                    print_status(f"    ✗ Registration timed out", "error")
                    result['final_status'] = check_provider_status(credential, sub_id)
                    result['action_taken'] = "registered"
                    result['success'] = False
            else:
                result['final_status'] = status
                result['action_taken'] = "failed"
                result['success'] = False
                
    except HttpResponseError as e:
        print_status(f"  ✗ {sub_name}: Error - {e.message}", "error")
        result['error'] = str(e.message)
        result['success'] = False
        
    except ClientAuthenticationError as e:
        print_status(f"  ✗ {sub_name}: Authentication error - {e.message}", "error")
        result['error'] = str(e.message)
        result['success'] = False
        
    return result


def print_summary(results: List[Dict[str, Any]]) -> None:
    """Print a summary table of all results."""
    print_status("\n" + "=" * 70, "header")
    print_status("SUMMARY", "header")
    print_status("=" * 70, "header")
    
    # Count statistics
    total = len(results)
    registered = sum(1 for r in results if r['final_status'] == 'Registered')
    failed = sum(1 for r in results if not r['success'])
    already_registered = sum(1 for r in results if r['action_taken'] == 'none')
    newly_registered = sum(1 for r in results if r['action_taken'] == 'registered' and r['success'])
    
    print(f"\nTotal subscriptions processed: {total}")
    print_status(f"  ✓ Registered: {registered}", "success")
    print_status(f"    - Already registered: {already_registered}", "info")
    print_status(f"    - Newly registered: {newly_registered}", "info")
    if failed > 0:
        print_status(f"  ✗ Failed: {failed}", "error")
    
    # Print detailed table
    print("\n" + "-" * 70)
    print(f"{'Subscription':<40} {'Status':<15} {'Action':<15}")
    print("-" * 70)
    
    for r in results:
        name = r['subscription_name'][:38] + '..' if len(r['subscription_name']) > 40 else r['subscription_name']
        status = r['final_status'] or 'Error'
        action = r['action_taken'] or 'error'
        
        if r['success']:
            print(f"{name:<40} {status:<15} {action:<15}")
        else:
            print_status(f"{name:<40} {status:<15} {action:<15}", "error")
    
    print("-" * 70)


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Register Microsoft.ManagedServices resource provider across Azure subscriptions.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Register for all subscriptions in a specific tenant
  python register_managed_services.py --tenant-id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

  # Check status only (don't register)
  python register_managed_services.py --tenant-id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx --check-only

  # Register for specific subscriptions only
  python register_managed_services.py --subscription-ids sub-id-1 sub-id-2

  # Use interactive browser authentication
  python register_managed_services.py --tenant-id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx --interactive
        """
    )
    
    parser.add_argument(
        '--tenant-id',
        help='Azure tenant ID (GUID) to process subscriptions for'
    )
    
    parser.add_argument(
        '--subscription-ids',
        nargs='+',
        help='Specific subscription IDs to process (space-separated)'
    )
    
    parser.add_argument(
        '--check-only',
        action='store_true',
        help='Only check registration status, do not register'
    )
    
    parser.add_argument(
        '--interactive',
        action='store_true',
        help='Use interactive browser authentication'
    )
    
    parser.add_argument(
        '--timeout',
        type=int,
        default=REGISTRATION_TIMEOUT,
        help=f'Timeout in seconds for registration (default: {REGISTRATION_TIMEOUT})'
    )
    
    args = parser.parse_args()
    
    # Print header
    print_status("\n" + "=" * 70, "header")
    print_status("Azure Resource Provider Registration Script", "header")
    print_status(f"Provider: {PROVIDER_NAMESPACE}", "header")
    print_status("=" * 70 + "\n", "header")
    
    # Get credential
    try:
        if args.interactive:
            print_status("Using interactive browser authentication...", "info")
            credential = InteractiveBrowserCredential(tenant_id=args.tenant_id)
        else:
            print_status("Authenticating with DefaultAzureCredential...", "info")
            credential = get_credential(args.tenant_id)
    except Exception as e:
        print_status(f"Authentication failed: {e}", "error")
        print_status("\nTip: Try running 'az login --tenant <tenant-id>' first, or use --interactive flag", "warning")
        sys.exit(1)
    
    # Get subscriptions
    print_status("\nDiscovering subscriptions...", "info")
    
    if args.subscription_ids:
        # Use specified subscription IDs
        subscriptions = [{'id': sub_id, 'name': sub_id, 'tenant_id': args.tenant_id} 
                        for sub_id in args.subscription_ids]
        print_status(f"Processing {len(subscriptions)} specified subscription(s)", "info")
    else:
        # Discover all subscriptions
        subscriptions = get_subscriptions(credential, args.tenant_id)
        if not subscriptions:
            print_status("No accessible subscriptions found.", "warning")
            if args.tenant_id:
                print_status(f"Make sure you have access to subscriptions in tenant: {args.tenant_id}", "warning")
            sys.exit(1)
        print_status(f"Found {len(subscriptions)} subscription(s)", "success")
    
    # Process each subscription
    print_status("\nProcessing subscriptions...\n", "info")
    results = []
    
    for subscription in subscriptions:
        result = process_subscription(
            credential, 
            subscription, 
            check_only=args.check_only
        )
        results.append(result)
    
    # Print summary
    print_summary(results)
    
    # Exit with appropriate code
    failed_count = sum(1 for r in results if not r['success'])
    if failed_count > 0:
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
```

### Usage Examples

#### Check and Register All Subscriptions in a Tenant

```bash
# First, authenticate to the target tenant
az login --tenant "<Atevet17-Tenant-ID>"

# Run the script
python register_managed_services.py --tenant-id "<Atevet17-Tenant-ID>"
```

**Expected Output:**
```
======================================================================
Azure Resource Provider Registration Script
Provider: Microsoft.ManagedServices
======================================================================

Authenticating with DefaultAzureCredential...
Discovering subscriptions...
Found 3 subscription(s)

Processing subscriptions...

  ✓ Production-Subscription: Already registered
  → Development-Subscription: Registering...
    ✓ Successfully registered
  → Test-Subscription: Registering...
    ✓ Successfully registered

======================================================================
SUMMARY
======================================================================

Total subscriptions processed: 3
  ✓ Registered: 3
    - Already registered: 1
    - Newly registered: 2

----------------------------------------------------------------------
Subscription                             Status          Action         
----------------------------------------------------------------------
Production-Subscription                  Registered      none           
Development-Subscription                 Registered      registered     
Test-Subscription                        Registered      registered     
----------------------------------------------------------------------
```

#### Check Status Only (No Registration)

```bash
python register_managed_services.py --tenant-id "<Atevet17-Tenant-ID>" --check-only
```

#### Process Specific Subscriptions

```bash
python register_managed_services.py --subscription-ids "sub-id-1" "sub-id-2" "sub-id-3"
```

#### Use Interactive Browser Authentication

```bash
python register_managed_services.py --tenant-id "<Atevet17-Tenant-ID>" --interactive
```

### Troubleshooting

#### Authentication Errors

**Error:** `ClientAuthenticationError: DefaultAzureCredential failed to retrieve a token`

**Solution:**
1. Run `az login --tenant <tenant-id>` to authenticate via Azure CLI
2. Or use `--interactive` flag for browser-based authentication
3. Or set environment variables: `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`

#### Permission Errors

**Error:** `AuthorizationFailed: The client does not have authorization to perform action 'Microsoft.Resources/subscriptions/providers/register/action'`

**Solution:**
- You need **Owner** or **Contributor** role on the subscription
- Or a custom role with `Microsoft.Resources/subscriptions/providers/register/action` permission

#### No Subscriptions Found

**Error:** `No accessible subscriptions found`

**Solution:**
1. Verify you're authenticated to the correct tenant
2. Check that your account has access to subscriptions in that tenant
3. Ensure subscriptions are in 'Enabled' state

---

## Step 1: Create Security Group and Log Analytics Workspace

*Coming soon: Python scripts for creating the security group and Log Analytics workspace.*

---

## Step 2: Deploy Azure Lighthouse

*Coming soon: Python scripts for deploying Azure Lighthouse registration definitions and assignments.*

---

## Additional Resources

- [Main Guide: Azure Cross-Tenant Log Collection](azure-cross-tenant-log-collection-guide.md)
- [Azure SDK for Python Documentation](https://docs.microsoft.com/en-us/azure/developer/python/sdk/azure-sdk-overview)
- [Azure Identity Library](https://docs.microsoft.com/en-us/python/api/overview/azure/identity-readme)
- [Azure Resource Management Library](https://docs.microsoft.com/en-us/python/api/overview/azure/mgmt-resource-readme)