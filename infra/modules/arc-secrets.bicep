targetScope = 'resourceGroup'

param arcKeyVaultName string

@secure()
param githubAppId string

@secure()
param githubAppInstallationId string

@secure()
param githubAppPrivateKey string

resource arcKeyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: arcKeyVaultName
}

resource githubAppIdSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: arcKeyVault
  name: 'github-app-id'
  properties: {
    value: githubAppId
    contentType: 'text/plain'
  }
}

resource githubAppInstallationIdSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: arcKeyVault
  name: 'github-app-installation-id'
  properties: {
    value: githubAppInstallationId
    contentType: 'text/plain'
  }
}

resource githubAppPrivateKeySecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: arcKeyVault
  name: 'github-app-private-key'
  properties: {
    value: githubAppPrivateKey
    contentType: 'application/x-pem-file'
  }
}
