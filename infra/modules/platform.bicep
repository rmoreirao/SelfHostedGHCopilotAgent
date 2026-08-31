targetScope = 'resourceGroup'

param location string
param githubRepository string
param kubernetesVersion string
param deployerObjectId string
param runnerScaleSetName string
param maxRunners int
param tags object

var suffix = uniqueString(subscription().subscriptionId, resourceGroup().id, githubRepository)
var names = {
  aks: 'aks-copilot-poc-${suffix}'
  firewall: 'afw-copilot-poc-${suffix}'
  firewallPolicy: 'afwp-copilot-poc-${suffix}'
  firewallPublicIp: 'pip-afw-copilot-poc-${suffix}'
  logAnalytics: 'log-copilot-poc-${suffix}'
  routeTable: 'rt-copilot-poc-${suffix}'
  vnet: 'vnet-copilot-poc-${suffix}'
  aksIdentity: 'id-aks-copilot-poc-${suffix}'
  runnerIdentity: 'id-runner-copilot-poc-${suffix}'
  credentialSyncIdentity: 'id-arcsync-copilot-poc-${suffix}'
  arcVault: take('kvarc${suffix}', 24)
  validationVault: take('kvagent${suffix}', 24)
}

module monitoring './monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    workspaceName: names.logAnalytics
    tags: tags
  }
}

module identities './identities.bicep' = {
  name: 'identities'
  params: {
    location: location
    aksIdentityName: names.aksIdentity
    runnerIdentityName: names.runnerIdentity
    credentialSyncIdentityName: names.credentialSyncIdentity
    tags: tags
  }
}

module network './network.bicep' = {
  name: 'network'
  params: {
    location: location
    vnetName: names.vnet
    firewallName: names.firewall
    firewallPolicyName: names.firewallPolicy
    firewallPublicIpName: names.firewallPublicIp
    routeTableName: names.routeTable
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceResourceId
    tags: tags
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: names.vnet
}

resource aksSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-aks'
}

resource routeTable 'Microsoft.Network/routeTables@2024-05-01' existing = {
  name: names.routeTable
}

var networkContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4d97b98b-1d4f-4787-a291-c67834d212e7'
)

resource aksSubnetNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aksSubnet.id, resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', names.aksIdentity), networkContributorRoleId)
  scope: aksSubnet
  properties: {
    principalId: identities.outputs.aksIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: networkContributorRoleId
  }
  dependsOn: [
    network
  ]
}

resource routeTableNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(routeTable.id, resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', names.aksIdentity), networkContributorRoleId)
  scope: routeTable
  properties: {
    principalId: identities.outputs.aksIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: networkContributorRoleId
  }
  dependsOn: [
    network
  ]
}

module keyVaults './key-vaults.bicep' = {
  name: 'key-vaults'
  params: {
    location: location
    arcKeyVaultName: names.arcVault
    validationKeyVaultName: names.validationVault
    vnetId: network.outputs.vnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    runnerIdentityPrincipalId: identities.outputs.runnerIdentityPrincipalId
    credentialSyncIdentityPrincipalId: identities.outputs.credentialSyncIdentityPrincipalId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceResourceId
    tags: tags
  }
}

module aks './aks.bicep' = {
  name: 'aks'
  params: {
    location: location
    aksName: names.aks
    kubernetesVersion: kubernetesVersion
    aksSubnetId: network.outputs.aksSubnetId
    aksIdentityResourceId: identities.outputs.aksIdentityResourceId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceResourceId
    maxRunners: maxRunners
    tags: tags
  }
  dependsOn: [
    aksSubnetNetworkContributor
    routeTableNetworkContributor
    keyVaults
  ]
}

module federation './federation.bicep' = {
  name: 'workload-identity-federation'
  params: {
    oidcIssuerUrl: aks.outputs.oidcIssuerUrl
    runnerIdentityName: identities.outputs.runnerIdentityName
    credentialSyncIdentityName: identities.outputs.credentialSyncIdentityName
  }
}

resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-10-01' existing = {
  name: names.aks
}

var aksRbacClusterAdminRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'
)

resource deployerAksAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceId('Microsoft.ContainerService/managedClusters', names.aks), deployerObjectId, aksRbacClusterAdminRoleId)
  scope: aksCluster
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: aksRbacClusterAdminRoleId
  }
  dependsOn: [
    aks
  ]
}

output aksName string = aks.outputs.aksName
output arcKeyVaultName string = keyVaults.outputs.arcKeyVaultName
output validationKeyVaultName string = keyVaults.outputs.validationKeyVaultName
output validationKeyVaultUrl string = keyVaults.outputs.validationKeyVaultUrl
output validationSecretName string = keyVaults.outputs.validationSecretName
output runnerIdentityClientId string = identities.outputs.runnerIdentityClientId
output secretSyncIdentityClientId string = identities.outputs.credentialSyncIdentityClientId
output firewallPublicIp string = network.outputs.firewallPublicIp
output logAnalyticsWorkspaceId string = monitoring.outputs.workspaceResourceId
output runnerScaleSetName string = runnerScaleSetName
output maxRunners int = maxRunners
