targetScope = 'resourceGroup'

param location string
param aksIdentityName string
param runnerIdentityName string
param credentialSyncIdentityName string
param tags object

resource aksIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: aksIdentityName
  location: location
  tags: tags
}

resource runnerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: runnerIdentityName
  location: location
  tags: tags
}

resource credentialSyncIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: credentialSyncIdentityName
  location: location
  tags: tags
}

output aksIdentityResourceId string = aksIdentity.id
output aksIdentityPrincipalId string = aksIdentity.properties.principalId
output runnerIdentityName string = runnerIdentity.name
output runnerIdentityClientId string = runnerIdentity.properties.clientId
output runnerIdentityPrincipalId string = runnerIdentity.properties.principalId
output credentialSyncIdentityName string = credentialSyncIdentity.name
output credentialSyncIdentityClientId string = credentialSyncIdentity.properties.clientId
output credentialSyncIdentityPrincipalId string = credentialSyncIdentity.properties.principalId
