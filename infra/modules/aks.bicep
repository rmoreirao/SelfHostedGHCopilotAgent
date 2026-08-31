targetScope = 'resourceGroup'

param location string
param aksName string
param kubernetesVersion string
param aksSubnetId string
param aksIdentityResourceId string
param logAnalyticsWorkspaceId string
param maxRunners int
param tags object

var kubernetesVersionProperty = empty(kubernetesVersion) ? null : kubernetesVersion

resource aks 'Microsoft.ContainerService/managedClusters@2024-10-01' = {
  name: aksName
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: 'Standard'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aksIdentityResourceId}': {}
    }
  }
  properties: {
    kubernetesVersion: kubernetesVersionProperty
    dnsPrefix: aksName
    enableRBAC: true
    disableLocalAccounts: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      tenantID: tenant().tenantId
    }
    apiServerAccessProfile: {
      enablePrivateCluster: false
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
      imageCleaner: {
        enabled: true
        intervalHours: 48
      }
    }
    agentPoolProfiles: [
      {
        name: 'system'
        count: 2
        minCount: 2
        maxCount: 3
        enableAutoScaling: true
        vmSize: 'Standard_D2s_v6'
        osType: 'Linux'
        osSKU: 'Ubuntu'
        type: 'VirtualMachineScaleSets'
        mode: 'System'
        vnetSubnetID: aksSubnetId
        maxPods: 50
        nodeLabels: {
          workload: 'system'
        }
        upgradeSettings: {
          maxSurge: '33%'
        }
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
      outboundType: 'userDefinedRouting'
      loadBalancerSku: 'standard'
      podCidr: '10.244.0.0/16'
      serviceCidr: '10.43.0.0/16'
      dnsServiceIP: '10.43.0.10'
    }
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
          useAADAuth: 'true'
        }
      }
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: {
          enableSecretRotation: 'true'
          rotationPollInterval: '2m'
        }
      }
    }
  }
}

resource runnerPool 'Microsoft.ContainerService/managedClusters/agentPools@2024-10-01' = {
  parent: aks
  name: 'runners'
  properties: {
    count: 0
    minCount: 0
    maxCount: maxRunners
    enableAutoScaling: true
    vmSize: 'Standard_D4s_v6'
    osType: 'Linux'
    osSKU: 'Ubuntu'
    type: 'VirtualMachineScaleSets'
    mode: 'User'
    vnetSubnetID: aksSubnetId
    maxPods: 20
    scaleDownMode: 'Delete'
    nodeLabels: {
      workload: 'arc-runner'
    }
    nodeTaints: [
      'workload=arc-runner:NoSchedule'
    ]
    upgradeSettings: {
      maxSurge: '33%'
    }
  }
}

resource aksDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: aks
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

output aksName string = aks.name
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
output runnerPoolName string = runnerPool.name
