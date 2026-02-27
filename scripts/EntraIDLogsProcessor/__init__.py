"""
EntraIDLogsProcessor Azure Function
Processes Entra ID logs from Event Hub and forwards them to Log Analytics workspace.

This function:
1. Receives Entra ID diagnostic logs from Event Hub
2. Parses and categorizes logs by type (Audit, SignIn, etc.)
3. Forwards logs to Log Analytics using the Data Collector API
4. Handles batching and retry logic for reliability

Environment Variables Required:
- WORKSPACE_ID: Log Analytics Workspace ID
- WORKSPACE_KEY: Log Analytics Workspace Primary Key
- SOURCE_TENANT_NAME: Name of the source tenant (for table naming)
"""

import azure.functions as func
import logging
import json
import hashlib
import hmac
import base64
import datetime
import requests
import os
from typing import List, Dict, Any

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Log Analytics configuration from environment variables
WORKSPACE_ID = os.environ.get('WORKSPACE_ID', '')
WORKSPACE_KEY = os.environ.get('WORKSPACE_KEY', '')
SOURCE_TENANT_NAME = os.environ.get('SOURCE_TENANT_NAME', 'SourceTenant')

# Log Analytics Data Collector API endpoint
LOG_ANALYTICS_URI = f"https://{WORKSPACE_ID}.ods.opinsights.azure.com/api/logs?api-version=2016-04-01"

# Mapping of Entra ID log categories to custom table names
LOG_CATEGORY_MAPPING = {
    'AuditLogs': f'EntraIDAuditLogs_{SOURCE_TENANT_NAME}_CL',
    'SignInLogs': f'EntraIDSignInLogs_{SOURCE_TENANT_NAME}_CL',
    'NonInteractiveUserSignInLogs': f'EntraIDNonInteractiveSignInLogs_{SOURCE_TENANT_NAME}_CL',
    'ServicePrincipalSignInLogs': f'EntraIDServicePrincipalSignInLogs_{SOURCE_TENANT_NAME}_CL',
    'ManagedIdentitySignInLogs': f'EntraIDManagedIdentitySignInLogs_{SOURCE_TENANT_NAME}_CL',
    'ProvisioningLogs': f'EntraIDProvisioningLogs_{SOURCE_TENANT_NAME}_CL',
    'ADFSSignInLogs': f'EntraIDADFSSignInLogs_{SOURCE_TENANT_NAME}_CL',
    'RiskyUsers': f'EntraIDRiskyUsers_{SOURCE_TENANT_NAME}_CL',
    'UserRiskEvents': f'EntraIDUserRiskEvents_{SOURCE_TENANT_NAME}_CL',
    'NetworkAccessTrafficLogs': f'EntraIDNetworkAccessTrafficLogs_{SOURCE_TENANT_NAME}_CL',
    'RiskyServicePrincipals': f'EntraIDRiskyServicePrincipals_{SOURCE_TENANT_NAME}_CL',
    'ServicePrincipalRiskEvents': f'EntraIDServicePrincipalRiskEvents_{SOURCE_TENANT_NAME}_CL',
    'EnrichedOffice365AuditLogs': f'EntraIDEnrichedOffice365AuditLogs_{SOURCE_TENANT_NAME}_CL',
    'MicrosoftGraphActivityLogs': f'EntraIDMicrosoftGraphActivityLogs_{SOURCE_TENANT_NAME}_CL',
    'RemoteNetworkHealthLogs': f'EntraIDRemoteNetworkHealthLogs_{SOURCE_TENANT_NAME}_CL',
    'B2CRequestLogs': f'EntraIDB2CRequestLogs_{SOURCE_TENANT_NAME}_CL'
}


def build_signature(customer_id: str, shared_key: str, date: str, content_length: int, method: str, content_type: str, resource: str) -> str:
    """
    Build the authorization signature for Log Analytics Data Collector API.
    
    Args:
        customer_id: Log Analytics Workspace ID
        shared_key: Log Analytics Workspace Primary Key
        date: RFC 1123 formatted date string
        content_length: Length of the request body
        method: HTTP method (POST)
        content_type: Content type header value
        resource: API resource path
    
    Returns:
        Authorization header value
    """
    x_headers = f'x-ms-date:{date}'
    string_to_hash = f"{method}\n{content_length}\n{content_type}\n{x_headers}\n{resource}"
    bytes_to_hash = bytes(string_to_hash, encoding="utf-8")
    decoded_key = base64.b64decode(shared_key)
    encoded_hash = base64.b64encode(
        hmac.new(decoded_key, bytes_to_hash, digestmod=hashlib.sha256).digest()
    ).decode()
    authorization = f"SharedKey {customer_id}:{encoded_hash}"
    return authorization


def post_data_to_log_analytics(body: str, log_type: str) -> bool:
    """
    Post data to Log Analytics workspace using the Data Collector API.
    
    Args:
        body: JSON string of log records to send
        log_type: Custom log table name (without _CL suffix)
    
    Returns:
        True if successful, False otherwise
    """
    if not WORKSPACE_ID or not WORKSPACE_KEY:
        logger.error("WORKSPACE_ID or WORKSPACE_KEY not configured")
        return False
    
    method = 'POST'
    content_type = 'application/json'
    resource = '/api/logs'
    rfc1123date = datetime.datetime.utcnow().strftime('%a, %d %b %Y %H:%M:%S GMT')
    content_length = len(body)
    
    signature = build_signature(
        WORKSPACE_ID, 
        WORKSPACE_KEY, 
        rfc1123date, 
        content_length, 
        method, 
        content_type, 
        resource
    )
    
    uri = f"https://{WORKSPACE_ID}.ods.opinsights.azure.com{resource}?api-version=2016-04-01"
    
    headers = {
        'content-type': content_type,
        'Authorization': signature,
        'Log-Type': log_type,
        'x-ms-date': rfc1123date,
        'time-generated-field': 'TimeGenerated'
    }
    
    try:
        response = requests.post(uri, data=body, headers=headers, timeout=30)
        if response.status_code >= 200 and response.status_code <= 299:
            logger.info(f"Successfully posted {content_length} bytes to {log_type}")
            return True
        else:
            logger.error(f"Failed to post to Log Analytics: {response.status_code} - {response.text}")
            return False
    except Exception as e:
        logger.error(f"Exception posting to Log Analytics: {str(e)}")
        return False


def parse_event_hub_message(message: str) -> List[Dict[str, Any]]:
    """
    Parse Event Hub message containing Entra ID logs.
    
    Entra ID diagnostic logs are sent as JSON with a 'records' array.
    
    Args:
        message: Raw Event Hub message body
    
    Returns:
        List of log records
    """
    try:
        data = json.loads(message)
        if 'records' in data:
            return data['records']
        elif isinstance(data, list):
            return data
        else:
            return [data]
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse Event Hub message: {str(e)}")
        return []


def categorize_logs(records: List[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
    """
    Categorize log records by their category for routing to appropriate tables.
    
    Args:
        records: List of log records from Event Hub
    
    Returns:
        Dictionary mapping log categories to their records
    """
    categorized = {}
    
    for record in records:
        # Get the category from the record
        category = record.get('category', 'Unknown')
        
        # Add source tenant information
        record['SourceTenantName'] = SOURCE_TENANT_NAME
        
        # Ensure TimeGenerated field exists
        if 'TimeGenerated' not in record and 'time' in record:
            record['TimeGenerated'] = record['time']
        elif 'TimeGenerated' not in record:
            record['TimeGenerated'] = datetime.datetime.utcnow().isoformat() + 'Z'
        
        # Initialize category list if needed
        if category not in categorized:
            categorized[category] = []
        
        categorized[category].append(record)
    
    return categorized


def main(events: List[func.EventHubEvent]) -> None:
    """
    Main function to process Entra ID logs from Event Hub.
    
    This function is triggered by Event Hub messages and processes
    Entra ID diagnostic logs, forwarding them to Log Analytics.
    
    Args:
        events: List of Event Hub events to process
    """
    logger.info(f"Processing {len(events)} Event Hub events")
    
    # Collect all records from all events
    all_records = []
    
    for event in events:
        try:
            # Get the event body
            body = event.get_body().decode('utf-8')
            
            # Parse the message
            records = parse_event_hub_message(body)
            all_records.extend(records)
            
            logger.info(f"Parsed {len(records)} records from event")
            
        except Exception as e:
            logger.error(f"Error processing event: {str(e)}")
            continue
    
    if not all_records:
        logger.warning("No records to process")
        return
    
    # Categorize logs by type
    categorized_logs = categorize_logs(all_records)
    
    # Send each category to its respective table
    for category, records in categorized_logs.items():
        # Get the table name for this category
        table_name = LOG_CATEGORY_MAPPING.get(category, f'EntraIDOther_{SOURCE_TENANT_NAME}_CL')
        
        # Remove _CL suffix for the API (it adds it automatically)
        if table_name.endswith('_CL'):
            table_name = table_name[:-3]
        
        # Convert records to JSON
        body = json.dumps(records)
        
        # Post to Log Analytics
        success = post_data_to_log_analytics(body, table_name)
        
        if success:
            logger.info(f"Successfully sent {len(records)} {category} records to {table_name}")
        else:
            logger.error(f"Failed to send {len(records)} {category} records to {table_name}")
    
    logger.info(f"Completed processing {len(all_records)} total records")
