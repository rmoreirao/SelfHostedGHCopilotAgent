targetScope = 'resourceGroup'

param oidcIssuerUrl string
param runnerIdentityName string
param credentialSyncIdentityName string

resource runnerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: runnerIdentityName
}

resource credentialSyncIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: credentialSyncIdentityName
}

resource runnerFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: runnerIdentity
  name: 'arc-runner'
  properties: {
    issuer: oidcIssuerUrl
    subject: 'system:serviceaccount:arc-runners:arc-runner'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

resource secretSyncFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: credentialSyncIdentity
  name: 'arc-secret-sync'
  properties: {
    issuer: oidcIssuerUrl
    subject: 'system:serviceaccount:arc-runners:arc-secret-sync'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}
