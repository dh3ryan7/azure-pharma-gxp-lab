// =============================================================================
//  Optional add-on: Azure Bastion + a Windows "GxP server" for secure remote
//  QC-analyst access. Deploy this AFTER main.bicep, into the same resource group.
//
//  An analyst signs in (Entra ID + MFA) and RDPs into the server through Bastion
//  in the browser - no public IP on the server, no VPN. Only the screen travels;
//  the regulated data never leaves the VNet. (This is the cloud-native "RDP".)
//
//  COST WARNING: Azure Bastion (~$140/mo) and the VM are NOT free. Deploy to demo,
//  then delete the resource group (or this deployment's resources) when done.
//
//  Deploy:
//    az deployment group create -g rg-pharma-lab -f bastion-gxp-server.bicep \
//      --parameters adminPassword='<Strong-P@ssw0rd-12+chars>'
// =============================================================================

param location string = resourceGroup().location
param vnetName string = 'vnet-pharma'
param serverSubnetName string = 'snet-qc'          // GxP server lives in the QC zone
param serverName string = 'vm-gxp-qc'
param serverVmSize string = 'Standard_B2s'         // adjust to a size your subscription has quota for
param adminUsername string = 'gxpadmin'

@secure()
param adminPassword string

var bastionSubnetCidr = '10.30.10.0/26'

// --- existing network (created by main.bicep) ------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: vnetName
}
resource bastionSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: 'AzureBastionSubnet'
}
resource serverSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: serverSubnetName
}
resource nsgQc 'Microsoft.Network/networkSecurityGroups@2023-09-01' existing = {
  name: 'nsg-qc'
}

// --- allow Bastion -> GxP server on RDP/SSH (above the deny-all rule) -------
resource allowBastion 'Microsoft.Network/networkSecurityGroups/securityRules@2023-09-01' = {
  parent: nsgQc
  name: 'allow-bastion-to-gxp'
  properties: {
    priority: 90
    direction: 'Inbound'
    access: 'Allow'
    protocol: 'Tcp'
    sourceAddressPrefix: bastionSubnetCidr
    sourcePortRange: '*'
    destinationAddressPrefix: '*'
    destinationPortRanges: [ '3389', '22' ]
  }
}

// --- Azure Bastion (public IP + host) --------------------------------------
resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'pip-bastion'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: 'bastion-pharma'
  location: location
  sku: { name: 'Standard' }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ipcfg'
        properties: {
          subnet: { id: bastionSubnet.id }
          publicIPAddress: { id: bastionPip.id }
        }
      }
    ]
  }
}

// --- the GxP server (no public IP - reachable only via Bastion) ------------
resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${serverName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: serverSubnet.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource server 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: serverName
  location: location
  tags: {
    Department: 'QC'
    GxP: 'true'
    role: 'analyst-workstation'
  }
  properties: {
    hardwareProfile: { vmSize: serverVmSize }
    osProfile: {
      computerName: serverName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
  }
}

output bastionHost string = bastion.name
output gxpServer string = server.name
output connectVia string = 'Azure portal -> ${serverName} -> Connect -> Bastion (sign in with the admin credentials)'
