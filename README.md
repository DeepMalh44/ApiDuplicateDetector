# API Duplicate Detector for Azure API Center

An Azure Function that automatically detects duplicate APIs when they are registered in Azure API Center. It uses semantic analysis with Azure OpenAI embeddings and Cosmos DB vector search to find similar APIs and sends email alerts when duplicates are detected.

## Features

- **Event-Driven Detection**: Automatically triggered when APIs are added in API Center via Event Grid
- **Semantic Analysis**: Uses Azure OpenAI `text-embedding-ada-002` to generate API embeddings
- **Vector Search**: Stores embeddings in Cosmos DB for efficient similarity search
- **Email Alerts**: Sends email notifications when duplicates are detected (>80% similarity)
- **Managed Identity**: All services use System-Assigned Managed Identity (no connection strings or API keys)
- **One-Command Deployment**: Complete infrastructure and code deployment with a single PowerShell command

## Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────────────┐
│  Azure API      │────▶│  Event Grid  │────▶│  Azure Function     │
│  Center         │     │  Subscription│     │  (Duplicate         │
│                 │     │              │     │   Detector)         │
└─────────────────┘     └──────────────┘     └──────────┬──────────┘
                                                        │
                        ┌───────────────────────────────┼───────────────────────────────┐
                        │                               │                               │
                        ▼                               ▼                               ▼
             ┌─────────────────────┐      ┌─────────────────────┐      ┌─────────────────────┐
             │  Azure OpenAI       │      │  Cosmos DB          │      │  Azure Monitor      │
             │  (Embeddings)       │      │  (Vector Store)     │      │  (Email Alerts)     │
             └─────────────────────┘      └─────────────────────┘      └─────────────────────┘
```

## Prerequisites

- Azure subscription
- Azure CLI installed and logged in
- .NET 8.0 SDK
- PowerShell 7+

## Quick Start - One Command Deployment

Deploy everything with a single command:

```powershell
# Clone the repository
git clone https://github.com/DeepMalh44/ApiDuplicateDetector.git
cd ApiDuplicateDetector

# Deploy (creates all resources including API Center if needed)
.\infra\deploy.ps1 -ResourceGroupName "my-resource-group" `
                   -ApiCenterName "my-api-center" `
                   -EnableSemanticAnalysis $true
```

### Deployment Parameters

| Parameter | Required | Description | Default |
|-----------|----------|-------------|---------|
| `ResourceGroupName` | Yes | Azure resource group name | - |
| `ApiCenterName` | Yes | Azure API Center name | - |
| `EnableSemanticAnalysis` | No | Enable Azure OpenAI + Cosmos DB | `$true` |
| `AlertEmailAddress` | No | Email for duplicate alerts | Current user's email |
| `Location` | No | Azure region | `eastus` |
| `OpenAiLocation` | No | Azure OpenAI region (use different region if quota exceeded) | Same as Location |

### Example with Custom Options

```powershell
.\infra\deploy.ps1 -ResourceGroupName "rg-api-governance" `
                   -ApiCenterName "apic-enterprise" `
                   -EnableSemanticAnalysis $true `
                   -AlertEmailAddress "api-team@company.com" `
                   -Location "eastus" `
                   -OpenAiLocation "westus"  # Use different region for OpenAI quota
```

## What Gets Deployed

The deployment script creates:

| Resource | Description |
|----------|-------------|
| **Function App** | .NET 8 Isolated worker on Elastic Premium (EP1) |
| **Storage Account** | Function App storage with managed identity auth |
| **Application Insights** | Logging and monitoring |
| **Log Analytics Workspace** | Query-based alerting |
| **Azure OpenAI** | `text-embedding-ada-002` model for embeddings |
| **Cosmos DB** | Vector store for API embeddings (AAD-only auth) |
| **Action Group** | Email notification target |
| **Scheduled Query Rule** | Monitors for duplicate detection logs |
| **Event Grid Subscription** | Triggers function on API registration |

## How It Works

1. **API Registration**: When an API definition is added to API Center, Event Grid fires an event
2. **Function Trigger**: The Azure Function receives the event and retrieves the OpenAPI specification
3. **Embedding Generation**: Azure OpenAI generates a vector embedding from the API spec
4. **Similarity Search**: The embedding is compared against existing APIs in Cosmos DB
5. **Duplicate Detection**: If similarity exceeds 80%, the API is flagged as a potential duplicate
6. **Email Alert**: Azure Monitor detects the `DuplicateApiDetected` log and sends an email

## Sample Alert Email

When duplicates are detected, you'll receive an email like:

```
Subject: API Duplicate Detection Alert

DuplicateApiDetected: API 'Pet Management API v2' is 87.5% similar to existing API 
'Pet Store API'. Consider reviewing for potential consolidation.

Similar APIs found:
- Pet Store API (87.5% similarity)
- Pet Registry API (82.3% similarity)
```

## Security - Managed Identity

All services use **System-Assigned Managed Identity** for authentication. No connection strings or API keys are stored.

### RBAC Roles Assigned

| Resource | Role | Purpose |
|----------|------|---------|
| Storage Account | Storage Blob Data Owner | Function App storage |
| Storage Account | Storage Queue Data Contributor | Queue triggers |
| Storage Account | Storage Table Data Contributor | Durable functions |
| API Center | Azure API Center Data Reader | Read API definitions |
| Resource Group | Contributor | Export API specifications |
| Azure OpenAI | Cognitive Services OpenAI User | Generate embeddings |
| Cosmos DB | Cosmos DB Built-in Data Contributor | Read/write embeddings |

> **Note**: Cosmos DB uses `disableLocalAuth: true` to enforce AAD-only authentication.

## Configuration

Environment variables are automatically configured during deployment:

| Setting | Description |
|---------|-------------|
| `API_CENTER_NAME` | Azure API Center name |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID |
| `RESOURCE_GROUP_NAME` | Resource group name |
| `AZURE_OPENAI_ENDPOINT` | Azure OpenAI endpoint |
| `AZURE_OPENAI_EMBEDDING_MODEL` | Embedding model deployment name |
| `COSMOS_DB_ENDPOINT` | Cosmos DB endpoint |
| `COSMOS_DB_DATABASE_NAME` | Database name (`ApiDuplicateDetector`) |
| `COSMOS_DB_CONTAINER_NAME` | Container name (`ApiEmbeddings`) |
| `SIMILARITY_THRESHOLD` | Detection threshold (`0.8`) |

## Testing

Register sample APIs to test duplicate detection:

```powershell
# Register first API
az apic api register --resource-group "my-rg" `
                     --service-name "my-apic" `
                     --api-location "samples/pet-paradise-api.yaml"

# Register similar API (should trigger alert)
az apic api register --resource-group "my-rg" `
                     --service-name "my-apic" `
                     --api-location "samples/critter-catalog-api.yaml"
```

Check your email in ~1 minute for the duplicate detection alert.

## Project Structure

```
├── Functions/
│   └── ApiDuplicateDetectorFunction.cs  # Main Azure Function
├── Models/
│   ├── ApiCenterEventData.cs            # Event Grid event model
│   ├── ApiEmbedding.cs                  # Cosmos DB embedding model
│   ├── ApiInfo.cs                       # API information model
│   ├── ApiSimilarityResult.cs           # Similarity result model
│   └── DuplicateDetectionReport.cs      # Detection report model
├── Services/
│   ├── ApiCenterService.cs              # API Center interactions
│   ├── ApiSimilarityService.cs          # Similarity calculations
│   ├── EmbeddingService.cs              # Azure OpenAI embeddings
│   ├── NotificationService.cs           # Logging/notifications
│   └── VectorStoreService.cs            # Cosmos DB vector store
├── infra/
│   ├── api-duplicate-detector.bicep     # Infrastructure as Code
│   └── deploy.ps1                       # One-command deployment script
├── samples/                             # Sample OpenAPI specs for testing
├── Program.cs                           # Function host configuration
└── host.json                            # Function host settings
```

## Troubleshooting

### OpenAI Quota Error
If you get `InsufficientQuota` error, use a different region:
```powershell
.\infra\deploy.ps1 ... -OpenAiLocation "westus"
```

### Function Not Triggering
Check Event Grid subscription status:
```powershell
az eventgrid event-subscription show --name "api-duplicate-detector-subscription" `
    --source-resource-id "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ApiCenter/services/{apic}"
```

### View Logs
```powershell
az monitor app-insights query --app "{app-insights-name}" -g "{rg}" `
    --analytics-query "traces | where timestamp > ago(30m) | order by timestamp desc"
```

## License

MIT License
