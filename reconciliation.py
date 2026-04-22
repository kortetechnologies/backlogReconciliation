# RECONCILE AWARDED NOT TRANSFERRED SALES LIST WITH BACKLOG TO CREATE CLEAN SOURCE OF TRUTH FOR CURRENT BACKLOG

# IMPORTS
import io
import os
import requests
import pandas as pd
from azure.storage.fileshare import ShareFileClient

AUTH = (os.environ.get('API_AUTH_USER', 'brandon-svc'), os.environ['API_AUTH_PASSWORD'])

# API calls to get WIP, Backlog, and Salesforce data, with error handling
wip_resp = requests.get('https://korteapim.azure-api.net/korteapi/Viewpoint/JCMonthlyStatusCurrent', auth=AUTH)
backlog_resp = requests.get('https://korteapim.azure-api.net/korteapi/intranet/backlogactual', auth=AUTH)
salesforce_resp = requests.get('https://korteapim.azure-api.net/korteapi/salesforce/getOpportunities', auth=AUTH)

wip_resp.raise_for_status()
backlog_resp.raise_for_status()
salesforce_resp.raise_for_status()

wip_json = wip_resp.json()
backlog_json = backlog_resp.json()
salesforce_json = salesforce_resp.json()

wip_df = pd.json_normalize(wip_json if isinstance(wip_json, list) else wip_json.get('value', wip_json))
backlog_df = pd.json_normalize(backlog_json if isinstance(backlog_json, list) else backlog_json.get('value', backlog_json))
sf_df = pd.json_normalize(salesforce_json if isinstance(salesforce_json, list) else salesforce_json.get('value', salesforce_json))

# For understanding of data structure only
# pd.DataFrame(sorted(sf_df.columns), columns=['column_name']).to_csv('sf_columns.csv', index=False)
# pd.DataFrame(sorted(backlog_df.columns), columns=['column_name']).to_csv('backlog_columns.csv', index=False)
# pd.DataFrame(sorted(wip_df.columns), columns=['column_name']).to_csv('wip_columns.csv', index=False)

# Filter awarded not transferred opportunities from Salesforce data
notTransferred_df = sf_df[['jobNum__c', 'name', 'amount_TKC__c', 'gross_Profit__c', 'pillar__c', 'stageName', 'transfered__c']].copy()
notTransferred_df = notTransferred_df[notTransferred_df['stageName'] == 'Awarded Won']
notTransferred_df = notTransferred_df[notTransferred_df['transfered__c'] == False]

# Rename backlog_df columns
backlog_df = backlog_df.rename(columns={
    'backlog': 'Volume',
    'contract': 'Contract',
    'description': 'Job Name',
    'balGP': 'Gross Profit',
    'pillar': 'Pillar',
})
backlog_df['Contract'] = backlog_df['Contract'].str.rstrip('-')
backlog_df['Transfer Status'] = 'Transferred'

# Rename notTransferred_df columns
notTransferred_df = notTransferred_df.drop(columns=['stageName'])
notTransferred_df = notTransferred_df.rename(columns={
    'amount_TKC__c': 'Volume',
    'jobNum__c': 'Contract',
    'name': 'Job Name',
    'gross_Profit__c': 'Gross Profit',
    'pillar__c': 'Pillar',
    'transfered__c': 'Transfer Status',
})
notTransferred_df['Transfer Status'] = 'Not Transferred'

# Remap pillar names to make clean, universal list
PILLAR_MAP = {
    'US Postal Service': 'USPS',
    'St. Louis Metro': 'STL',
    'St. Louis': 'STL',
    'Las Vegas Metro': 'LV',
    'Las Vegas': 'LV',
    'Distribution Centers': 'DC',
    'Distribution Center': 'DC',
    'Government': 'GOV',
    'Healthcare': 'HC',
    'Other': 'OTH',
}
backlog_df['Pillar'] = backlog_df['Pillar'].replace(PILLAR_MAP)
notTransferred_df['Pillar'] = notTransferred_df['Pillar'].replace(PILLAR_MAP)

# Drop backlog rows that are superseded by notTransferred, then concat
dropped = backlog_df['Contract'].notna() & backlog_df['Contract'].ne('') & backlog_df['Contract'].isin(notTransferred_df['Contract'])
partialBacklog_df = backlog_df[dropped].copy()
partialBacklog_df.to_csv('partialBacklog.csv', index=False)

notTransferred_df['sort'] = 1

reconciliation_df = pd.concat([
    backlog_df[~dropped],
    notTransferred_df,
], ignore_index=True)

# Summarize reconciliation results
print(f"Rows dropped from backlog:       {dropped.sum()}")
print(f"Rows added from notTransferred:  {len(notTransferred_df)}")
print(f"Final reconciliation row count:  {len(reconciliation_df)}")

# Prepare WIP lookup: Contract, Cost to Date, Profit to Date
wip_lookup = wip_df[['contract', 'actualcosttodate', 'profittodate']].copy()
wip_lookup = wip_lookup.rename(columns={
    'contract': 'Contract',
    'actualcosttodate': 'Cost to Date',
    'profittodate': 'Profit to Date',
})
wip_lookup['Contract'] = wip_lookup['Contract'].str.rstrip('-')

# Subtract recognized WIP from Volume and Gross Profit for Not Transferred rows
reconciliation_df = reconciliation_df.merge(wip_lookup, on='Contract', how='left')
mask = reconciliation_df['Transfer Status'] == 'Not Transferred'
reconciliation_df.loc[mask, 'Volume'] = reconciliation_df.loc[mask, 'Volume'] - reconciliation_df.loc[mask, 'Cost to Date'].fillna(0)
reconciliation_df.loc[mask, 'Gross Profit'] = reconciliation_df.loc[mask, 'Gross Profit'] - reconciliation_df.loc[mask, 'Profit to Date'].fillna(0)
reconciliation_df = reconciliation_df.drop(columns=['Cost to Date', 'Profit to Date'])

# Sanity check backlog total
print(f"Total Volume: {reconciliation_df[reconciliation_df['sort'] == 1]['Volume'].sum():,.0f}")

# Write CSV to in-memory buffer and upload to Azure File Share
csv_buffer = io.BytesIO()
reconciliation_df.to_csv(csv_buffer, index=False)
csv_bytes = csv_buffer.getvalue()

conn_str = os.environ['AZURE_STORAGE_CONNECTION_STRING']
file_client = ShareFileClient.from_connection_string(
    conn_str,
    share_name='backlog',
    file_path='reconciliation.csv',
)
file_client.upload_file(csv_bytes)
print("Uploaded reconciliation.csv to tkcdatalake/backlog/")