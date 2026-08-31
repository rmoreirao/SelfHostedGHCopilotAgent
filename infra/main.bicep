targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'westeurope'

@description('Resource group containing the proof of concept.')
param resourceGroupName string = 'rg-copilot-aks-poc-weu'

@description('Repository in OWNER/REPO format.')
param githubRepository string = 'rmoreirao/SelfHostedGHCopilotAgent'

@description('Kubernetes minor version. Pass an empty string to use the AKS default.')
param kubernetesVersion string = '1.35'

@description('Microsoft Entra object ID that receives AKS RBAC Cluster Admin.')
param deployerObjectId string = deployer().objectId

@description('ARC runner scale-set name used by GitHub workflows.')
param runnerScaleSetName string = 'copilot-aks-poc'

@description('Maximum number of ephemeral runner pods.')
@minValue(1)
@maxValue(10)
param maxRunners int = 3

var commonTags = {
  application: 'self-hosted-github-copilot-agent'
  environment: 'poc'
  managedBy: 'bicep'
  repository: githubRepository
}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: location
  tags: commonTags
}

module platform './modules/platform.bicep' = {
  name: 'copilot-aks-platform'
  scope: resourceGroup
  params: {
    location: location
    githubRepository: githubRepository
    kubernetesVersion: kubernetesVersion
    deployerObjectId: deployerObjectId
    runnerScaleSetName: runnerScaleSetName
    maxRunners: maxRunners
    tags: commonTags
  }
}

output resourceGroupName string = resourceGroup.name
output aksName string = platform.outputs.aksName
output arcKeyVaultName string = platform.outputs.arcKeyVaultName
output validationKeyVaultName string = platform.outputs.validationKeyVaultName
output validationKeyVaultUrl string = platform.outputs.validationKeyVaultUrl
output validationSecretName string = platform.outputs.validationSecretName
output runnerIdentityClientId string = platform.outputs.runnerIdentityClientId
output secretSyncIdentityClientId string = platform.outputs.secretSyncIdentityClientId
output tenantId string = tenant().tenantId
output runnerScaleSetName string = runnerScaleSetName
output maxRunners int = maxRunners
output firewallPublicIp string = platform.outputs.firewallPublicIp
output logAnalyticsWorkspaceId string = platform.outputs.logAnalyticsWorkspaceId
