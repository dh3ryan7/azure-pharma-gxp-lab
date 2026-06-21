// =============================================================================
//  Azure GxP Pharmaceutical Infrastructure  -  main.bicep
//  Resource-group-scoped deployment of a segmented small-pharma environment:
//  shared tiers + QA/QC/MFG/PKG departments, hardened storage, Key Vault,
//  Log Analytics and a data-store lock. (No VMs - free/near-zero cost.)
//
//  Deploy:
//    az group create -n rg-pharma-lab -l eastus
//    az deployment group create -g rg-pharma-lab -f main.bicep
// =============================================================================

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Unique suffix for globally-unique names (storage, Key Vault).')
param suffix string = uniqueString(resourceGroup().id)

var tags = {
  env: 'lab'
  industry: 'pharma'
  compliance: 'GxP'
  dataClassification: 'Confidential'
  costCenter: 'RND'
}

var saDataName = 'stpharmadata${substring(suffix, 0, 8)}'
var saAuditName = 'stpharmaaudit${substring(suffix, 0, 6)}'
var kvName = 'kv-pharma-${substring(suffix, 0, 8)}'
var mgmtCidr = '10.30.5.0/24'

// ---------------------------------------------------------------------------
//  Application Security Groups (referenced by NSG rules instead of IPs)
// ---------------------------------------------------------------------------
resource asgWeb 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = { name: 'asg-web', location: location, tags: tags }
resource asgApp 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = { name: 'asg-app', location: location, tags: tags }
resource asgDb 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = { name: 'asg-db', location: location, tags: tags }
resource asgResearch 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = { name: 'asg-research', location: location, tags: tags }
resource asgQa 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = { name: 'asg-qa', location: location, tags: tags }
resource asgQc 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = { name: 'asg-qc', location: location, tags: tags }
resource asgMfg 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = { name: 'asg-mfg', location: location, tags: tags }
resource asgPkg 'Microsoft.Network/applicationSecurityGroups@2023-09-01' = { name: 'asg-pkg', location: location, tags: tags }

var denyVnet = {
  name: 'deny-vnet'
  properties: {
    priority: 4000
    direction: 'Inbound'
    access: 'Deny'
    protocol: '*'
    sourceAddressPrefix: 'VirtualNetwork'
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRange: '*'
  }
}

// ---------------------------------------------------------------------------
//  Network Security Groups (one per subnet) with segmentation rules
// ---------------------------------------------------------------------------
resource nsgCorp 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-corp'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-https-in'
        properties: {
          priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp'
          sourceAddressPrefix: 'Internet', sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: asgWeb.id } ]
          destinationPortRanges: [ '443' ]
        }
      }
    ]
  }
}

resource nsgApp 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-app'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-web-to-app'
        properties: {
          priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourcePortRange: '*'
          sourceApplicationSecurityGroups: [ { id: asgWeb.id } ]
          destinationApplicationSecurityGroups: [ { id: asgApp.id } ]
          destinationPortRanges: [ '8443' ]
        }
      }
    ]
  }
}

resource nsgData 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-data'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-app-to-sql'
        properties: {
          priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourcePortRange: '*'
          sourceApplicationSecurityGroups: [ { id: asgApp.id } ]
          destinationApplicationSecurityGroups: [ { id: asgDb.id } ]
          destinationPortRanges: [ '1433' ]
        }
      }
      {
        name: 'deny-other-to-data'
        properties: {
          priority: 200, direction: 'Inbound', access: 'Deny', protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: asgDb.id } ]
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgResearch 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-research'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-mgmt-only'
        properties: {
          priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp'
          sourceAddressPrefix: mgmtCidr, sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: asgResearch.id } ]
          destinationPortRanges: [ '22', '3389' ]
        }
      }
      denyVnet
    ]
  }
}

resource nsgMgmt 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-mgmt'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-ssh-rdp-in'
        properties: {
          priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork', sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [ '22', '3389' ]
        }
      }
    ]
  }
}

resource nsgQa 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-qa'
  location: location
  tags: union(tags, { Department: 'QA', GxP: 'true', area: 'Quality' })
  properties: {
    securityRules: [
      {
        name: 'allow-mgmt'
        properties: {
          priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp'
          sourceAddressPrefix: mgmtCidr, sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: asgQa.id } ]
          destinationPortRanges: [ '22', '3389' ]
        }
      }
      denyVnet
    ]
  }
}

resource nsgQc 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-qc'
  location: location
  tags: union(tags, { Department: 'QC', GxP: 'true', area: 'Quality' })
  properties: {
    securityRules: [
      {
        name: 'allow-qa-oversight'
        properties: {
          priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourcePortRange: '*'
          sourceApplicationSecurityGroups: [ { id: asgQa.id } ]
          destinationApplicationSecurityGroups: [ { id: asgQc.id } ]
          destinationPortRanges: [ '443' ]
        }
      }
      {
        name: 'allow-mgmt'
        properties: {
          priority: 110, direction: 'Inbound', access: 'Allow', protocol: 'Tcp'
          sourceAddressPrefix: mgmtCidr, sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: asgQc.id } ]
          destinationPortRanges: [ '22', '3389' ]
        }
      }
      denyVnet
    ]
  }
}

resource nsgMfg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-mfg'
  location: location
  tags: union(tags, { Department: 'MFG', GxP: 'true', area: 'Operations' })
  properties: {
    securityRules: [
      {
        name: 'allow-qa-oversight'
        properties: {
          priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourcePortRange: '*'
          sourceApplicationSecurityGroups: [ { id: asgQa.id } ]
          destinationApplicationSecurityGroups: [ { id: asgMfg.id } ]
          destinationPortRanges: [ '443' ]
        }
      }
      {
        name: 'allow-qc-testing'
        properties: {
          priority: 110, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourcePortRange: '*'
          sourceApplicationSecurityGroups: [ { id: asgQc.id } ]
          destinationApplicationSecurityGroups: [ { id: asgMfg.id } ]
          destinationPortRanges: [ '8443' ]
        }
      }
      {
        name: 'allow-pkg-integration'
        properties: {
          priority: 120, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourcePortRange: '*'
          sourceApplicationSecurityGroups: [ { id: asgPkg.id } ]
          destinationApplicationSecurityGroups: [ { id: asgMfg.id } ]
          destinationPortRanges: [ '8443' ]
        }
      }
      {
        name: 'allow-mgmt'
        properties: {
          priority: 130, direction: 'Inbound', access: 'Allow', protocol: 'Tcp'
          sourceAddressPrefix: mgmtCidr, sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: asgMfg.id } ]
          destinationPortRanges: [ '22', '3389' ]
        }
      }
      denyVnet
    ]
  }
}

resource nsgPkg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-pkg'
  location: location
  tags: union(tags, { Department: 'PKG', GxP: 'true', area: 'Operations' })
  properties: {
    securityRules: [
      {
        name: 'allow-qa-oversight'
        properties: {
          priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourcePortRange: '*'
          sourceApplicationSecurityGroups: [ { id: asgQa.id } ]
          destinationApplicationSecurityGroups: [ { id: asgPkg.id } ]
          destinationPortRanges: [ '443' ]
        }
      }
      {
        name: 'allow-mfg-integration'
        properties: {
          priority: 110, direction: 'Inbound', access: 'Allow', protocol: 'Tcp', sourcePortRange: '*'
          sourceApplicationSecurityGroups: [ { id: asgMfg.id } ]
          destinationApplicationSecurityGroups: [ { id: asgPkg.id } ]
          destinationPortRanges: [ '8443' ]
        }
      }
      {
        name: 'allow-mgmt'
        properties: {
          priority: 120, direction: 'Inbound', access: 'Allow', protocol: 'Tcp'
          sourceAddressPrefix: mgmtCidr, sourcePortRange: '*'
          destinationApplicationSecurityGroups: [ { id: asgPkg.id } ]
          destinationPortRanges: [ '22', '3389' ]
        }
      }
      denyVnet
    ]
  }
}

// ---------------------------------------------------------------------------
//  Virtual network with segmented subnets (each bound to its NSG)
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-pharma'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ '10.30.0.0/16' ] }
    subnets: [
      { name: 'snet-corp', properties: { addressPrefix: '10.30.1.0/24', networkSecurityGroup: { id: nsgCorp.id } } }
      { name: 'snet-app', properties: { addressPrefix: '10.30.2.0/24', networkSecurityGroup: { id: nsgApp.id } } }
      { name: 'snet-data', properties: { addressPrefix: '10.30.3.0/24', networkSecurityGroup: { id: nsgData.id } } }
      { name: 'snet-research', properties: { addressPrefix: '10.30.4.0/24', networkSecurityGroup: { id: nsgResearch.id } } }
      { name: 'snet-mgmt', properties: { addressPrefix: '10.30.5.0/24', networkSecurityGroup: { id: nsgMgmt.id } } }
      { name: 'snet-qa', properties: { addressPrefix: '10.30.6.0/24', networkSecurityGroup: { id: nsgQa.id } } }
      { name: 'snet-qc', properties: { addressPrefix: '10.30.7.0/24', networkSecurityGroup: { id: nsgQc.id } } }
      { name: 'snet-mfg', properties: { addressPrefix: '10.30.8.0/24', networkSecurityGroup: { id: nsgMfg.id } } }
      { name: 'snet-pkg', properties: { addressPrefix: '10.30.9.0/24', networkSecurityGroup: { id: nsgPkg.id } } }
    ]
  }
}

// ---------------------------------------------------------------------------
//  Compliance-hardened storage + GxP record containers
// ---------------------------------------------------------------------------
resource saData 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: saDataName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource saDataBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: saData
  name: 'default'
  properties: {
    isVersioningEnabled: true
    deleteRetentionPolicy: { enabled: true, days: 30 }
    containerDeleteRetentionPolicy: { enabled: true, days: 30 }
  }
}

resource dataContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = [for c in [
  'research-data', 'clinical-trials', 'qa-records', 'qc-test-results', 'mfg-batch-records', 'pkg-labeling'
]: {
  parent: saDataBlob
  name: c
}]

resource saAudit 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: saAuditName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource auditBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: saAudit
  name: 'default'
}

resource auditContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: auditBlob
  name: 'audit-logs'
}

// CanNotDelete lock on the regulated data store
resource dataLock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: 'protect-research-data'
  scope: saData
  properties: {
    level: 'CanNotDelete'
    notes: 'Protect GxP records from accidental deletion'
  }
}

// ---------------------------------------------------------------------------
//  Key Vault (secrets / CMK) + Log Analytics (central audit)
// ---------------------------------------------------------------------------
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
  }
}

resource law 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'law-pharma'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

output dataStorageAccount string = saData.name
output auditStorageAccount string = saAudit.name
output keyVaultName string = kv.name
output logAnalyticsWorkspace string = law.name
