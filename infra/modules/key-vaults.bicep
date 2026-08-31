targetScope = 'resourceGroup'

param location string
param arcKeyVaultName string
param validationKeyVaultName string
param vnetId string
param privateEndpointSubnetId string
param runnerIdentityPrincipalId string
param credentialSyncIdentityPrincipalId string
param logAnalyticsWorkspaceId string
param tags object

var validationSecretName = 'private-access-marker'
var keyVaultSecretsUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

resource arcKeyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: arcKeyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    sku: {
      family: 'A'
      name: 'standard'
    }
  }
}

resource validationKeyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: validationKeyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    sku: {
      family: 'A'
      name: 'standard'
    }
  }
}

resource validationSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = {
  parent: validationKeyVault
  name: validationSecretName
  properties: {
    value: 'copilot-aks-private-access-ok'
    contentType: 'text/plain'
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: tags
}

resource privateDnsVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: 'copilot-poc-vnet'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource arcKeyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${arcKeyVaultName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'arc-vault'
        properties: {
          privateLinkServiceId: arcKeyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

resource arcKeyVaultPrivateDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: arcKeyVaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    privateDnsVnetLink
  ]
}

resource validationKeyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${validationKeyVaultName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'validation-vault'
        properties: {
          privateLinkServiceId: validationKeyVault.id
          groupIds: [
            'vault'
          ]
        }
      }
    ]
  }
}

resource validationKeyVaultPrivateDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: validationKeyVaultPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vault'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    privateDnsVnetLink
  ]
}

resource arcVaultSecretReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(arcKeyVault.id, credentialSyncIdentityPrincipalId, keyVaultSecretsUserRoleId)
  scope: arcKeyVault
  properties: {
    principalId: credentialSyncIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleId
  }
}

resource validationVaultSecretReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(validationKeyVault.id, runnerIdentityPrincipalId, keyVaultSecretsUserRoleId)
  scope: validationKeyVault
  properties: {
    principalId: runnerIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleId
  }
}

resource arcVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: arcKeyVault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'audit'
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

resource validationVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: validationKeyVault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'audit'
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

output arcKeyVaultName string = arcKeyVault.name
output validationKeyVaultName string = validationKeyVault.name
output validationKeyVaultUrl string = validationKeyVault.properties.vaultUri
output validationSecretName string = validationSecret.name
