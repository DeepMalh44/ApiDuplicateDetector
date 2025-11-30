# API Duplicate Detector for Azure API Center

An Azure Function that automatically detects duplicate APIs when they are registered in Azure API Center. It uses Event Grid triggers to monitor API definition changes and compares APIs using weighted similarity scoring.

## Features

- **Event-Driven Detection**: Automatically triggered when APIs are added or updated in API Center
- **Weighted Similarity Scoring**: Compares APIs using multiple factors:
  - Path Similarity (40%) - Compares API endpoints and routes
  - Schema Similarity (25%) - Compares request/response schemas
  - Name Similarity (20%) - Compares API titles and names
  - Description Similarity (15%) - Compares API descriptions
- **Azure Monitor Alerts**: Sends email notifications when duplicates are detected
- **Optional Semantic Analysis**: Supports Azure OpenAI embeddings for enhanced similarity detection
- **Cosmos DB Vector Store**: Stores API embeddings for semantic search (optional)

## Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────────────┐
│  Azure API      │────▶│  Event Grid  │────▶│  Azure Function     │
│  Center         │     │  System Topic│     │  (Duplicate         │
│                 │     │              │     │   Detector)         │
└─────────────────┘     └──────────────┘     └──────────┬──────────┘
                                                        │
                                                        ▼
                                             ┌─────────────────────┐
                                             │  Application        │
                                             │  Insights           │
                                             └──────────┬──────────┘
                                                        │
                                                        ▼
                                             ┌─────────────────────┐
                                             │  Azure Monitor      │
                                             │  Alert Rule         │
                                             └──────────┬──────────┘
                                                        │
                                                        ▼
                                             ┌─────────────────────┐
                                             │  Email Notification │
                                             └─────────────────────┘
```

## Prerequisites

- Azure subscription
- Azure API Center instance
- Azure CLI installed
- .NET 8.0 SDK

## Deployment

### 1. Deploy Infrastructure

```bash
# Login to Azure
az login

# Deploy the Bicep template
az deployment group create \
  --resource-group <your-resource-group> \
  --template-file infra/api-duplicate-detector.bicep \
  --parameters apiCenterName=<your-api-center-name> \
               alertEmail=<your-email>
```

### 2. Deploy the Function

```bash
# Build and publish
dotnet publish -c Release -o ./publish

# Create deployment package
cd publish && zip -r ../deploy.zip . && cd ..

# Deploy to Azure
az functionapp deployment source config-zip \
  --resource-group <your-resource-group> \
  --name <function-app-name> \
  --src deploy.zip
```

### 3. Configure Event Grid Subscription

```bash
# Create Event Grid subscription
az eventgrid system-topic event-subscription create \
  --name api-duplicate-detector-subscription \
  --system-topic-name <api-center-topic-name> \
  --resource-group <your-resource-group> \
  --endpoint-type azurefunction \
  --endpoint /subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Web/sites/<func-name>/functions/ApiDuplicateDetector \
  --included-event-types Microsoft.ApiCenter.ApiDefinitionAdded Microsoft.ApiCenter.ApiDefinitionUpdated
```

## Configuration

| Setting | Description | Default |
|---------|-------------|---------|
| `SIMILARITY_THRESHOLD` | Minimum similarity score to flag as duplicate (0.0-1.0) | 0.7 |
| `API_CENTER_NAME` | Name of the Azure API Center | Required |
| `AZURE_OPENAI_ENDPOINT` | Azure OpenAI endpoint (enables semantic analysis) | - |
| `AZURE_OPENAI_EMBEDDING_MODEL` | Azure OpenAI embedding model name | text-embedding-ada-002 |
| `COSMOS_DB_ENDPOINT` | Cosmos DB endpoint for vector storage (uses managed identity) | - |
| `COSMOS_DB_DATABASE_NAME` | Cosmos DB database name | ApiDuplicateDetector |
| `COSMOS_DB_CONTAINER_NAME` | Cosmos DB container name | ApiEmbeddings |

## Managed Identity & RBAC

The Function App uses **System-Assigned Managed Identity** for secure, keyless authentication to all Azure services. The following RBAC roles are required:

| Resource | Role | Purpose |
|----------|------|---------|
| Storage Account | Storage Blob Data Owner | Function App file storage |
| Storage Account | Storage Queue Data Contributor | Trigger queue access |
| Storage Account | Storage Table Data Contributor | Durable functions state |
| API Center | Azure API Center Data Reader | Read API definitions |
| Resource Group | Contributor | Export API specifications (ARM operations) |
| Azure OpenAI | Cognitive Services OpenAI User | Generate embeddings |
| Cosmos DB (Control Plane) | Cosmos DB Account Contributor | Account management |
| Cosmos DB (Data Plane) | Cosmos DB Built-in Data Contributor | Read/write API embeddings |

> **Note**: Cosmos DB is configured with `disableLocalAuth: true` to enforce AAD-only authentication. The `Cosmos DB Built-in Data Contributor` SQL role (`00000000-0000-0000-0000-000000000002`) is required for data plane operations.

## How It Works

1. **API Registration**: When an API definition is added or updated in API Center, an Event Grid event is fired
2. **Event Processing**: The Azure Function receives the event and retrieves the API specification
3. **Similarity Analysis**: The function compares the new API against all existing APIs using:
   - Structural analysis of paths, methods, and schemas
   - Optional semantic analysis using Azure OpenAI embeddings
4. **Duplicate Detection**: If similarity exceeds the threshold, it's flagged as a potential duplicate
5. **Alerting**: A `DuplicateApiDetected` log is written to Application Insights
6. **Notification**: Azure Monitor scheduled query rule detects the log and sends an email alert

## Sample Alert

When duplicates are detected, you'll receive an alert like:

```
DuplicateApiDetected: API 'petmanagementv2' has 2 potential duplicates. 
Highest similarity: 65 %. APIs: petstoreapi, petregistryapi
```

## Project Structure

```
├── Functions/
│   └── ApiDuplicateDetectorFunction.cs  # Main Azure Function
├── Models/
│   ├── ApiCenterEventData.cs            # Event Grid event model
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
│   └── api-duplicate-detector.bicep     # Infrastructure as Code
├── .github/workflows/
│   └── deploy-duplicate-detector.yml    # CI/CD pipeline
├── Program.cs                           # Function host configuration
└── host.json                            # Function host settings
```

## License

MIT License
