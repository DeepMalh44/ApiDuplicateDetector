@description('The location for all resources')
param location string = resourceGroup().location

@description('The name of the Function App')
param functionAppName string

@description('The name of the Storage Account')
param storageAccountName string

@description('The name of the Cosmos DB account')
param cosmosDbName string

@description('The VNet name')
param vnetName string = 'vnet-api-duplicate-detector-${uniqueString(resourceGroup().id)}'

@description('The VNet address space')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('The Function App integration subnet address prefix')
param functionSubnetPrefix string = '10.0.1.0/24'

@description('The Private Endpoint subnet address prefix')
param privateEndpointSubnetPrefix string = '10.0.2.0/24'

// ==========================================
// VIRTUAL NETWORK
// ==========================================

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-function-integration'
        properties: {
          addressPrefix: functionSubnetPrefix
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ==========================================
// PRIVATE DNS ZONES
// ==========================================

// Cosmos DB Private DNS Zone
resource cosmosDbPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.documents.azure.com'
  location: 'global'
}

resource cosmosDbDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: cosmosDbPrivateDnsZone
  name: '${vnetName}-cosmosdb-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// Storage Blob Private DNS Zone
resource storageBlobPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.core.windows.net'
  location: 'global'
}

resource storageBlobDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: storageBlobPrivateDnsZone
  name: '${vnetName}-blob-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// Storage Queue Private DNS Zone
resource storageQueuePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.queue.core.windows.net'
  location: 'global'
}

resource storageQueueDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: storageQueuePrivateDnsZone
  name: '${vnetName}-queue-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// Storage Table Private DNS Zone
resource storageTablePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.table.core.windows.net'
  location: 'global'
}

resource storageTableDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: storageTablePrivateDnsZone
  name: '${vnetName}-table-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// Storage File Private DNS Zone (needed for Function App)
resource storageFilePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.file.core.windows.net'
  location: 'global'
}

resource storageFileDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: storageFilePrivateDnsZone
  name: '${vnetName}-file-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// ==========================================
// REFERENCE EXISTING RESOURCES
// ==========================================

resource existingFunctionApp 'Microsoft.Web/sites@2023-01-01' existing = {
  name: functionAppName
}

resource existingStorageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource existingCosmosDb 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' existing = {
  name: cosmosDbName
}

// ==========================================
// PRIVATE ENDPOINTS - COSMOS DB
// ==========================================

resource cosmosDbPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-${cosmosDbName}'
  location: location
  properties: {
    subnet: {
      id: vnet.properties.subnets[1].id // snet-private-endpoints
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${cosmosDbName}-connection'
        properties: {
          privateLinkServiceId: existingCosmosDb.id
          groupIds: [
            'Sql'
          ]
        }
      }
    ]
  }
}

resource cosmosDbPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: cosmosDbPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'cosmosdb'
        properties: {
          privateDnsZoneId: cosmosDbPrivateDnsZone.id
        }
      }
    ]
  }
}

// ==========================================
// PRIVATE ENDPOINTS - STORAGE (Blob)
// ==========================================

resource storageBlobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-${storageAccountName}-blob'
  location: location
  properties: {
    subnet: {
      id: vnet.properties.subnets[1].id
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${storageAccountName}-blob-connection'
        properties: {
          privateLinkServiceId: existingStorageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource storageBlobPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: storageBlobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: storageBlobPrivateDnsZone.id
        }
      }
    ]
  }
}

// ==========================================
// PRIVATE ENDPOINTS - STORAGE (Queue)
// ==========================================

resource storageQueuePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-${storageAccountName}-queue'
  location: location
  properties: {
    subnet: {
      id: vnet.properties.subnets[1].id
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${storageAccountName}-queue-connection'
        properties: {
          privateLinkServiceId: existingStorageAccount.id
          groupIds: [
            'queue'
          ]
        }
      }
    ]
  }
}

resource storageQueuePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: storageQueuePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'queue'
        properties: {
          privateDnsZoneId: storageQueuePrivateDnsZone.id
        }
      }
    ]
  }
}

// ==========================================
// PRIVATE ENDPOINTS - STORAGE (Table)
// ==========================================

resource storageTablePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-${storageAccountName}-table'
  location: location
  properties: {
    subnet: {
      id: vnet.properties.subnets[1].id
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${storageAccountName}-table-connection'
        properties: {
          privateLinkServiceId: existingStorageAccount.id
          groupIds: [
            'table'
          ]
        }
      }
    ]
  }
}

resource storageTablePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: storageTablePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'table'
        properties: {
          privateDnsZoneId: storageTablePrivateDnsZone.id
        }
      }
    ]
  }
}

// ==========================================
// PRIVATE ENDPOINTS - STORAGE (File)
// ==========================================

resource storageFilePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: 'pe-${storageAccountName}-file'
  location: location
  properties: {
    subnet: {
      id: vnet.properties.subnets[1].id
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${storageAccountName}-file-connection'
        properties: {
          privateLinkServiceId: existingStorageAccount.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

resource storageFilePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-05-01' = {
  parent: storageFilePrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'file'
        properties: {
          privateDnsZoneId: storageFilePrivateDnsZone.id
        }
      }
    ]
  }
}

// ==========================================
// FUNCTION APP VNET INTEGRATION
// ==========================================

resource functionAppVnetIntegration 'Microsoft.Web/sites/networkConfig@2023-01-01' = {
  name: '${functionAppName}/virtualNetwork'
  properties: {
    subnetResourceId: vnet.properties.subnets[0].id // snet-function-integration
    swiftSupported: true
  }
}

// Add app settings for VNet routing
resource functionAppVnetSettings 'Microsoft.Web/sites/config@2023-01-01' = {
  name: '${functionAppName}/web'
  properties: {
    vnetRouteAllEnabled: true // Route all outbound traffic through VNet
  }
  dependsOn: [
    functionAppVnetIntegration
  ]
}

// ==========================================
// OUTPUTS
// ==========================================

output vnetId string = vnet.id
output vnetName string = vnet.name
output functionSubnetId string = vnet.properties.subnets[0].id
output privateEndpointSubnetId string = vnet.properties.subnets[1].id
output cosmosDbPrivateEndpointId string = cosmosDbPrivateEndpoint.id
output storageBlobPrivateEndpointId string = storageBlobPrivateEndpoint.id
