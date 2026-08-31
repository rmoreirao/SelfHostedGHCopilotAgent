targetScope = 'resourceGroup'

param location string
param vnetName string
param firewallName string
param firewallPolicyName string
param firewallPublicIpName string
param routeTableName string
param logAnalyticsWorkspaceId string
param tags object

var vnetAddressPrefix = '10.42.0.0/16'
var aksSubnetName = 'snet-aks'
var aksSubnetPrefix = '10.42.0.0/22'
var firewallSubnetName = 'AzureFirewallSubnet'
var firewallSubnetPrefix = '10.42.4.0/26'
var privateEndpointSubnetName = 'snet-private-endpoints'
var privateEndpointSubnetPrefix = '10.42.5.0/24'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource firewallSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: firewallSubnetName
  properties: {
    addressPrefix: firewallSubnetPrefix
  }
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: privateEndpointSubnetName
  properties: {
    addressPrefix: privateEndpointSubnetPrefix
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

resource firewallPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: firewallPublicIpName
  location: location
  zones: [
    '1'
    '2'
    '3'
  ]
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource firewallPolicy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: firewallPolicyName
  location: location
  tags: tags
  properties: {
    sku: {
      tier: 'Standard'
    }
    threatIntelMode: 'Alert'
    dnsSettings: {
      enableProxy: true
    }
  }
}

resource firewallRuleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: firewallPolicy
  name: 'poc-egress'
  properties: {
    priority: 100
    ruleCollections: [
      {
        name: 'allow-platform-network'
        priority: 100
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            name: 'allow-control-plane-tunnels'
            ruleType: 'NetworkRule'
            sourceAddresses: [
              aksSubnetPrefix
            ]
            destinationAddresses: [
              'AzureCloud.WestEurope'
            ]
            ipProtocols: [
              'TCP'
              'UDP'
            ]
            destinationPorts: [
              '1194'
              '9000'
            ]
          }
          {
            name: 'allow-azure-dns'
            ruleType: 'NetworkRule'
            sourceAddresses: [
              aksSubnetPrefix
            ]
            destinationAddresses: [
              '168.63.129.16'
            ]
            ipProtocols: [
              'TCP'
              'UDP'
            ]
            destinationPorts: [
              '53'
            ]
          }
          {
            name: 'allow-azure-monitor'
            ruleType: 'NetworkRule'
            sourceAddresses: [
              aksSubnetPrefix
            ]
            destinationAddresses: [
              'AzureMonitor'
            ]
            ipProtocols: [
              'TCP'
            ]
            destinationPorts: [
              '443'
            ]
          }
        ]
      }
      {
        name: 'allow-platform-applications'
        priority: 200
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: {
          type: 'Allow'
        }
        rules: [
          {
            name: 'allow-aks-platform'
            ruleType: 'ApplicationRule'
            sourceAddresses: [
              aksSubnetPrefix
            ]
            fqdnTags: [
              'AzureKubernetesService'
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
          }
          {
            name: 'allow-github-actions-and-copilot'
            ruleType: 'ApplicationRule'
            sourceAddresses: [
              aksSubnetPrefix
            ]
            targetFqdns: [
              'github.com'
              'api.github.com'
              '*.github.com'
              '*.actions.githubusercontent.com'
              'codeload.github.com'
              'results-receiver.actions.githubusercontent.com'
              '*.blob.core.windows.net'
              '*.core.windows.net'
              'objects.githubusercontent.com'
              'objects-origin.githubusercontent.com'
              'github-releases.githubusercontent.com'
              'github-registry-files.githubusercontent.com'
              'release-assets.githubusercontent.com'
              'github-cloud.githubusercontent.com'
              'github-cloud.s3.amazonaws.com'
              '*.githubassets.com'
              '*.githubusercontent.com'
              '*.pkg.github.com'
              'pkg-containers.githubusercontent.com'
              'ghcr.io'
              'mcr.microsoft.com'
              '*.data.mcr.microsoft.com'
              'api.snapcraft.io'
              'uploads.github.com'
              'user-images.githubusercontent.com'
              'api.githubcopilot.com'
              '*.githubcopilot.com'
              '*.business.githubcopilot.com'
              '*.enterprise.githubcopilot.com'
              'copilot-proxy.githubusercontent.com'
              'copilot-telemetry.githubusercontent.com'
              'origin-tracker.githubusercontent.com'
              'default.exp-tas.com'
              'api.individual.githubcopilot.com'
              'api.business.githubcopilot.com'
              'api.enterprise.githubcopilot.com'
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
          }
          {
            name: 'allow-identity-and-observability'
            ruleType: 'ApplicationRule'
            sourceAddresses: [
              aksSubnetPrefix
            ]
            targetFqdns: [
              'login.microsoftonline.com'
              '*.ods.opinsights.azure.com'
              '*.oms.opinsights.azure.com'
              '*.monitoring.azure.com'
              'dc.services.visualstudio.com'
              '*.in.applicationinsights.azure.com'
            ]
            protocols: [
              {
                protocolType: 'Https'
                port: 443
              }
            ]
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: firewallName
  location: location
  zones: [
    '1'
    '2'
    '3'
  ]
  tags: tags
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
    firewallPolicy: {
      id: firewallPolicy.id
    }
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          subnet: {
            id: firewallSubnet.id
          }
          publicIPAddress: {
            id: firewallPublicIp.id
          }
        }
      }
    ]
  }
  dependsOn: [
    firewallRuleCollectionGroup
  ]
}

resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: routeTableName
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
  }
}

resource defaultRoute 'Microsoft.Network/routeTables/routes@2024-05-01' = {
  parent: routeTable
  name: 'default-via-firewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: firewall.properties.ipConfigurations[0].properties.privateIPAddress
  }
}

resource aksSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: vnet
  name: aksSubnetName
  properties: {
    addressPrefix: aksSubnetPrefix
    routeTable: {
      id: routeTable.id
    }
  }
  dependsOn: [
    defaultRoute
  ]
}

resource firewallDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: firewall
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output aksSubnetId string = aksSubnet.id
output aksSubnetName string = aksSubnet.name
output privateEndpointSubnetId string = privateEndpointSubnet.id
output routeTableId string = routeTable.id
output routeTableName string = routeTable.name
output firewallPublicIp string = firewallPublicIp.properties.ipAddress
output firewallPrivateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
