@description('The location for all resources')
param location string = resourceGroup().location

@description('The name of the API Center instance')
param apiCenterName string

@description('The name of the Function App')
param functionAppName string = 'func-api-duplicate-detector-${uniqueString(resourceGroup().id)}'

@description('The name of the Storage Account')
param storageAccountName string = 'stfunc${uniqueString(resourceGroup().id)}'

@description('The name of the Application Insights instance')
param appInsightsName string = 'appi-api-duplicate-detector-${uniqueString(resourceGroup().id)}'

@description('The similarity threshold for duplicate detection (0.0 to 1.0)')
param similarityThreshold string = '0.7'

@description('The webhook URL for notifications (Teams/Slack)')
@secure()
param notificationWebhookUrl string = ''

@description('Enable semantic similarity analysis using Azure OpenAI')
param enableSemanticAnalysis bool = false

@description('The name of the Azure OpenAI resource (required if enableSemanticAnalysis is true)')
param openAiName string = 'openai-api-detector-${uniqueString(resourceGroup().id)}'

@description('The name of the Cosmos DB account (required if enableSemanticAnalysis is true)')
param cosmosDbName string = 'cosmos-api-detector-${uniqueString(resourceGroup().id)}'

@description('The location for Azure OpenAI (may differ from main location due to availability)')
param openAiLocation string = 'eastus'

@description('The location for Cosmos DB (may differ from main location due to availability)')
param cosmosDbLocation string = 'westus2'

// Storage Account for Function App - Using Managed Identity
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false  // Enforce managed identity authentication
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

// Application Insights for monitoring
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Request_Source: 'rest'
  }
}

// App Service Plan (Premium for better cold start)
resource hostingPlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${functionAppName}-plan'
  location: location
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
    family: 'EP'
  }
  kind: 'elastic'
  properties: {
    maximumElasticWorkerCount: 20
    reserved: true
  }
}

// Function App with Managed Identity for storage
resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: hostingPlan.id
    reserved: true
    siteConfig: {
      linuxFxVersion: 'DOTNET-ISOLATED|8.0'
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'dotnet-isolated'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'API_CENTER_SUBSCRIPTION_ID'
          value: subscription().subscriptionId
        }
        {
          name: 'API_CENTER_RESOURCE_GROUP'
          value: resourceGroup().name
        }
        {
          name: 'API_CENTER_NAME'
          value: apiCenterName
        }
        {
          name: 'SIMILARITY_THRESHOLD'
          value: similarityThreshold
        }
        {
          name: 'NOTIFICATION_WEBHOOK_URL'
          value: notificationWebhookUrl
        }
        {
          name: 'ENABLE_SEMANTIC_ANALYSIS'
          value: string(enableSemanticAnalysis)
        }
      ]
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
    httpsOnly: true
  }
}

// Add semantic analysis app settings using siteConfig slot settings (conditional)
// Uses managed identity for both Azure OpenAI and Cosmos DB (no API keys or connection strings)
resource functionAppSemanticSettings 'Microsoft.Web/sites/config@2023-01-01' = if (enableSemanticAnalysis) {
  parent: functionApp
  name: 'appsettings'
  properties: {
    AzureWebJobsStorage__accountName: storageAccount.name
    FUNCTIONS_EXTENSION_VERSION: '~4'
    FUNCTIONS_WORKER_RUNTIME: 'dotnet-isolated'
    APPINSIGHTS_INSTRUMENTATIONKEY: appInsights.properties.InstrumentationKey
    APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.properties.ConnectionString
    API_CENTER_SUBSCRIPTION_ID: subscription().subscriptionId
    API_CENTER_RESOURCE_GROUP: resourceGroup().name
    API_CENTER_NAME: apiCenterName
    SIMILARITY_THRESHOLD: similarityThreshold
    NOTIFICATION_WEBHOOK_URL: notificationWebhookUrl
    ENABLE_SEMANTIC_ANALYSIS: 'true'
    // Azure OpenAI settings - uses DefaultAzureCredential (managed identity)
    AZURE_OPENAI_ENDPOINT: 'https://${openAiName}.openai.azure.com/'
    AZURE_OPENAI_EMBEDDING_MODEL: 'text-embedding-ada-002'
    // Cosmos DB settings - uses DefaultAzureCredential (managed identity) with COSMOS_DB_ENDPOINT
    // Note: COSMOS_DB_CONNECTION_STRING is not used when disableLocalAuth is true
    COSMOS_DB_ENDPOINT: 'https://${cosmosDbName}.documents.azure.com:443/'
    COSMOS_DB_DATABASE_NAME: 'ApiDuplicateDetector'
    COSMOS_DB_CONTAINER_NAME: 'ApiEmbeddings'
  }
}

// Storage Blob Data Owner role for Function App
resource storageBlobOwnerRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'Storage Blob Data Owner')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Queue Data Contributor role for Function App
resource storageQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'Storage Queue Data Contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Table Data Contributor role for Function App
resource storageTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'Storage Table Data Contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ==========================================
// SEMANTIC ANALYSIS RESOURCES (Conditional)
// ==========================================

// Azure OpenAI for embedding generation
resource openAiAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = if (enableSemanticAnalysis) {
  name: openAiName
  location: openAiLocation
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: openAiName
    publicNetworkAccess: 'Enabled'
  }
}

// Deploy text-embedding-ada-002 model for embeddings
resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (enableSemanticAnalysis) {
  parent: openAiAccount
  name: 'text-embedding-ada-002'
  sku: {
    name: 'Standard'
    capacity: 120
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-ada-002'
      version: '2'
    }
  }
}

// Azure Cosmos DB for vector storage
// Uses AAD-only authentication (disableLocalAuth: true) for enhanced security
resource cosmosDbAccount 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = if (enableSemanticAnalysis) {
  name: cosmosDbName
  location: cosmosDbLocation
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true  // Enforce AAD-only authentication
    publicNetworkAccess: 'Enabled'  // Required for Function App access (use private endpoints for production)
    locations: [
      {
        locationName: cosmosDbLocation
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
  }
}

// Cosmos DB Database
resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = if (enableSemanticAnalysis) {
  parent: cosmosDbAccount
  name: 'ApiDuplicateDetector'
  properties: {
    resource: {
      id: 'ApiDuplicateDetector'
    }
  }
}

// Cosmos DB Container for API Embeddings
resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = if (enableSemanticAnalysis) {
  parent: cosmosDatabase
  name: 'ApiEmbeddings'
  properties: {
    resource: {
      id: 'ApiEmbeddings'
      partitionKey: {
        paths: [
          '/apiName'
        ]
        kind: 'Hash'
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        automatic: true
        includedPaths: [
          {
            path: '/*'
          }
        ]
        excludedPaths: [
          {
            path: '/embedding/*'
          }
        ]
      }
    }
  }
}

// Role assignment for Function App to access Cosmos DB (control plane - for management operations)
resource cosmosDbContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableSemanticAnalysis) {
  name: guid(cosmosDbAccount.id, functionApp.id, 'Cosmos DB Contributor')
  scope: cosmosDbAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5bd9cd88-fe45-4216-938b-f97437e15450')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Cosmos DB Built-in Data Contributor role for data plane operations (read/write data)
// This is required when using AAD-only authentication (disableLocalAuth: true)
// Role ID: 00000000-0000-0000-0000-000000000002 is the built-in "Cosmos DB Built-in Data Contributor"
resource cosmosDbDataContributorRole 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = if (enableSemanticAnalysis) {
  parent: cosmosDbAccount
  name: guid(cosmosDbAccount.id, functionApp.id, 'Cosmos DB Data Contributor')
  properties: {
    roleDefinitionId: '${cosmosDbAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    principalId: functionApp.identity.principalId
    scope: cosmosDbAccount.id
  }
}

// Role assignment for Function App to access Azure OpenAI
resource openAiUserRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableSemanticAnalysis) {
  name: guid(openAiAccount.id, functionApp.id, 'Cognitive Services OpenAI User')
  scope: openAiAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Reference to existing API Center
resource apiCenter 'Microsoft.ApiCenter/services@2024-03-01' existing = {
  name: apiCenterName
}

// Role assignment for Function App to read from API Center
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(apiCenter.id, functionApp.id, 'Azure API Center Data Reader')
  scope: apiCenter
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'c7244dfb-f447-457d-b2ba-3999044d1706')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Contributor role on resource group for API Center ARM operations (required for ExportSpecification)
resource resourceGroupContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, functionApp.id, 'Contributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Event Grid System Topic for API Center
resource eventGridTopic 'Microsoft.EventGrid/systemTopics@2023-12-15-preview' = {
  name: '${apiCenterName}-events'
  location: location
  properties: {
    source: apiCenter.id
    topicType: 'Microsoft.ApiCenter.Services'
  }
}

// Event Grid Subscription - Uses Azure Function destination (no webhook validation issues)
resource eventGridSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-12-15-preview' = {
  parent: eventGridTopic
  name: 'api-duplicate-detector-subscription'
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '${functionApp.id}/functions/ApiDuplicateDetector'
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.ApiCenter.ApiDefinitionAdded'
      ]
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

// Email address for notifications
@description('Email address for duplicate API detection alerts')
param alertEmailAddress string = 'ketaanhshah@microsoft.com'

// Action Group for email notifications
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-api-duplicate-alerts'
  location: 'global'
  properties: {
    groupShortName: 'APIDupAlert'
    enabled: true
    emailReceivers: [
      {
        name: 'API Admin Email'
        emailAddress: alertEmailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

// Scheduled Query Rule Alert for Duplicate API Detection
resource duplicateApiAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-duplicate-api-detected'
  location: location
  properties: {
    displayName: 'Duplicate API Detected Alert'
    description: 'Triggers when a potential duplicate API is detected in API Center'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    scopes: [
      appInsights.id
    ]
    targetResourceTypes: [
      'microsoft.insights/components'
    ]
    windowSize: 'PT5M'
    criteria: {
      allOf: [
        {
          query: 'traces | where message contains "DuplicateApiDetected"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: false
    actions: {
      actionGroups: [
        actionGroup.id
      ]
      customProperties: {
        AlertType: 'DuplicateAPIDetection'
        Source: 'API Center Duplicate Detector'
      }
    }
  }
}
// Outputs
output functionAppName string = functionApp.name
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output functionAppPrincipalId string = functionApp.identity.principalId
output eventGridTopicName string = eventGridTopic.name
output appInsightsName string = appInsights.name
output storageAccountName string = storageAccount.name

// Semantic analysis outputs (conditional)
output openAiEndpoint string = enableSemanticAnalysis ? 'https://${openAiName}.openai.azure.com/' : ''
output openAiResourceName string = enableSemanticAnalysis ? openAiName : ''
output cosmosDbEndpoint string = enableSemanticAnalysis ? 'https://${cosmosDbName}.documents.azure.com:443/' : ''
output cosmosDbResourceName string = enableSemanticAnalysis ? cosmosDbName : ''
output semanticAnalysisEnabled bool = enableSemanticAnalysis
