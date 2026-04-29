// main.bicep — Azure OT Lab (GRFICSv3 + Armis)
// Deploys a single Ubuntu 22.04 VM with nested virtualisation support
// for running Docker-based ICS simulation and the Armis collector KVM VM.
//
// Deploy:
//   az group create -n ot-lab-rg -l eastus
//   az deployment group create -g ot-lab-rg -f main.bicep \
//     -p adminUsername=labadmin \
//        adminPublicKey="$(cat ~/.ssh/id_rsa.pub)"

@description('VM administrator username')
param adminUsername string

@description('SSH public key for VM access')
param adminPublicKey string

@description('Azure region')
param location string = resourceGroup().location

@description('Prefix for all resource names')
param labName string = 'ot-lab'

@description('VM size — must support nested virtualisation (Dv3/Dv4/Ev3/Ev4 family).')
@allowed([
  'Standard_D4s_v3'
  'Standard_D8s_v3'
  'Standard_D4s_v4'
  'Standard_D8s_v4'
  'Standard_D4ds_v5'
  'Standard_D8ds_v5'
])
param vmSize string = 'Standard_D4s_v3'

@description('OS disk size in GB. Armis QCOW2 is ~7 GB; Docker images ~20 GB.')
param osDiskSizeGB int = 256

// ── Networking ───────────────────────────────────────────────────────────────

resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: '${labName}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/16'] }
    subnets: [
      {
        name: 'lab-subnet'
        properties: { addressPrefix: '10.0.1.0/24' }
      }
    ]
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: '${labName}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'SSH'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'ScadaLTS-HMI'
        properties: {
          priority: 200
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '6081'
        }
      }
      {
        name: 'EngineeringWS'
        properties: {
          priority: 210
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '6080'
        }
      }
      {
        name: 'OpenPLC'
        properties: {
          priority: 220
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '8080'
        }
      }
      {
        name: 'Caldera-C2'
        properties: {
          priority: 230
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '8888'
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: '${labName}-pip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: { domainNameLabel: '${labName}-${uniqueString(resourceGroup().id)}' }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: '${labName}-nic'
  location: location
  properties: {
    networkSecurityGroup: { id: nsg.id }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: '${vnet.id}/subnets/lab-subnet' }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
  }
}

// ── Virtual Machine ───────────────────────────────────────────────────────────

resource vm 'Microsoft.Compute/virtualMachines@2023-07-01' = {
  name: '${labName}-vm'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: '${labName}-vm'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGB
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
    userData: loadFileAsBase64('cloud-init.yml')
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────

output publicIpAddress string = publicIp.properties.ipAddress
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.ipAddress}'
output fqdn string = publicIp.properties.dnsSettings.fqdn
output labUrls object = {
  hmi: 'http://${publicIp.properties.ipAddress}:6081'
  ews: 'http://${publicIp.properties.ipAddress}:6080'
  openplc: 'http://${publicIp.properties.ipAddress}:8080'
  caldera: 'http://${publicIp.properties.ipAddress}:8888'
}
