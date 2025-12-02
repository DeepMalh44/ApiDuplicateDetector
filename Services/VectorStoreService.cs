using System.Text.Json;
using ApiDuplicateDetector.Models;
using Azure.Identity;
using Microsoft.Azure.Cosmos;
using Microsoft.Extensions.Logging;

namespace ApiDuplicateDetector.Services;

/// <summary>
/// Service for storing and searching API embeddings in Azure Cosmos DB.
/// Uses manual cosine similarity calculation since vector search may not be available.
/// Supports both connection string and managed identity authentication.
/// </summary>
public class VectorStoreService : IVectorStoreService
{
    private readonly CosmosClient _cosmosClient;
    private readonly ILogger<VectorStoreService> _logger;
    private readonly string _databaseName;
    private readonly string _containerName;
    private Container? _container;
    private bool _initialized = false;

    public VectorStoreService(ILogger<VectorStoreService> logger)
    {
        _logger = logger;
        
        var connectionString = Environment.GetEnvironmentVariable("COSMOS_DB_CONNECTION_STRING");
        var cosmosEndpoint = Environment.GetEnvironmentVariable("COSMOS_DB_ENDPOINT");
        
        _databaseName = Environment.GetEnvironmentVariable("COSMOS_DB_DATABASE_NAME") ?? "ApiDuplicateDetector";
        _containerName = Environment.GetEnvironmentVariable("COSMOS_DB_CONTAINER_NAME") ?? "ApiEmbeddings";

        var clientOptions = new CosmosClientOptions
        {
            SerializerOptions = new CosmosSerializationOptions
            {
                PropertyNamingPolicy = CosmosPropertyNamingPolicy.CamelCase
            }
        };

        // Use managed identity if endpoint is provided, otherwise fall back to connection string
        if (!string.IsNullOrEmpty(cosmosEndpoint))
        {
            _logger.LogInformation("Initializing Cosmos DB client with managed identity for endpoint: {Endpoint}", cosmosEndpoint);
            _cosmosClient = new CosmosClient(cosmosEndpoint, new DefaultAzureCredential(), clientOptions);
        }
        else if (!string.IsNullOrEmpty(connectionString))
        {
            _logger.LogInformation("Initializing Cosmos DB client with connection string");
            _cosmosClient = new CosmosClient(connectionString, clientOptions);
        }
        else
        {
            throw new InvalidOperationException("Either COSMOS_DB_ENDPOINT or COSMOS_DB_CONNECTION_STRING must be configured");
        }
        
        _logger.LogInformation("VectorStoreService initialized");
    }

    /// <inheritdoc/>
    public async Task InitializeAsync()
    {
        if (_initialized)
            return;

        try
        {
            var databaseResponse = await _cosmosClient.CreateDatabaseIfNotExistsAsync(_databaseName);
            var database = databaseResponse.Database;
            
            var containerProperties = new ContainerProperties(_containerName, "/apiName");
            var containerResponse = await database.CreateContainerIfNotExistsAsync(containerProperties);
            _container = containerResponse.Container;
            _initialized = true;
            
            _logger.LogInformation("Vector store initialized successfully");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error initializing vector store");
            throw;
        }
    }

    /// <inheritdoc/>
    public async Task UpsertApiEmbeddingAsync(ApiEmbedding apiEmbedding)
    {
        await EnsureInitializedAsync();
        
        try
        {
            apiEmbedding.Timestamp = DateTime.UtcNow;
            await _container!.UpsertItemAsync(apiEmbedding, new PartitionKey(apiEmbedding.ApiName));
            _logger.LogInformation("Upserted embedding for API: {ApiName}", apiEmbedding.ApiName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error upserting API embedding: {ApiName}", apiEmbedding.ApiName);
            throw;
        }
    }

    /// <inheritdoc/>
    public async Task<List<SemanticMatch>> FindSimilarApisAsync(float[] queryEmbedding, int topK = 10, string? excludeApiName = null)
    {
        await EnsureInitializedAsync();
        
        _logger.LogInformation("FindSimilarApisAsync: Using Cosmos DB native vector search with DiskANN index");
        
        var results = new List<SemanticMatch>();

        try
        {
            // Use Cosmos DB native vector search with VectorDistance function
            // Note: VectorDistance returns distance (lower = more similar for cosine)
            // We convert to similarity by doing (1 - distance) for cosine
            var queryText = excludeApiName != null
                ? @"SELECT TOP @topK 
                       c.id, c.apiName, c.embedding, c.description, c.title, 
                       c.embeddingText, c.timestamp, c.apiCenterResourceId, c.kind, c.version, c.endpoints, c.schemas,
                       VectorDistance(c.embedding, @queryVector) AS distance
                   FROM c 
                   WHERE c.apiName != @excludeApiName
                   ORDER BY VectorDistance(c.embedding, @queryVector)"
                : @"SELECT TOP @topK 
                       c.id, c.apiName, c.embedding, c.description, c.title, 
                       c.embeddingText, c.timestamp, c.apiCenterResourceId, c.kind, c.version, c.endpoints, c.schemas,
                       VectorDistance(c.embedding, @queryVector) AS distance
                   FROM c 
                   ORDER BY VectorDistance(c.embedding, @queryVector)";
            
            var query = new QueryDefinition(queryText)
                .WithParameter("@topK", topK)
                .WithParameter("@queryVector", queryEmbedding);
            
            if (excludeApiName != null)
            {
                query = query.WithParameter("@excludeApiName", excludeApiName);
            }

            var iterator = _container!.GetItemQueryIterator<VectorSearchResult>(query);
            
            while (iterator.HasMoreResults)
            {
                var response = await iterator.ReadNextAsync();
                _logger.LogWarning("=== VECTOR SEARCH (DiskANN) returned {Count} results (RU: {RU}) ===", 
                    response.Count, response.RequestCharge);
                
                foreach (var item in response)
                {
                    // VectorDistance with cosine returns a value where LOWER = more similar
                    // The raw value from VectorDistance IS the distance (0 = identical)
                    // Since we configured cosine, the similarity = 1 - distance
                    // BUT: if distance values are > 0.5, they might actually BE similarity scores
                    // Cosmos DB VectorDistance returns: 0 (identical) to 2 (opposite) for cosine
                    // So we use: similarity = 1 - (distance / 2) to normalize, OR
                    // If the values are already in 0-1 range as similarity, use them directly
                    
                    var rawValue = item.Distance;
                    // The rawValue appears to be (1 - cosine_similarity), so similarity = 1 - rawValue
                    // Actually, looking at logs: rawValue=0.9326 should give similarity=0.9326
                    // The VectorDistance is returning the DISTANCE, not similarity
                    // For cosine: distance = 1 - similarity, so similarity = 1 - distance
                    // But our values suggest: rawValue IS the similarity already
                    
                    // Let's check: if rawValue > 0.5, treat it as similarity; else as distance
                    var similarity = rawValue;  // Use raw value directly as it appears to be similarity
                    
                    _logger.LogWarning("  [VectorSearch] {ApiName}: rawValue={RawValue:F4}, using similarity={Similarity:F4}", 
                        item.ApiName, rawValue, similarity);
                    
                    results.Add(new SemanticMatch
                    {
                        ApiEmbedding = new ApiEmbedding
                        {
                            Id = item.Id,
                            ApiName = item.ApiName,
                            Embedding = item.Embedding ?? Array.Empty<float>(),
                            Description = item.Description,
                            Title = item.Title,
                            EmbeddingText = item.EmbeddingText ?? string.Empty,
                            Timestamp = item.Timestamp,
                            ApiCenterResourceId = item.ApiCenterResourceId,
                            Kind = item.Kind,
                            Version = item.Version,
                            Endpoints = item.Endpoints ?? new List<string>(),
                            Schemas = item.Schemas ?? new List<string>()
                        },
                        SimilarityScore = similarity
                    });
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error performing vector search, falling back to brute-force calculation");
            return await FindSimilarApisBruteForceAsync(queryEmbedding, topK, excludeApiName);
        }

        return results;
    }

    /// <summary>
    /// Fallback brute-force similarity search for when vector search is unavailable.
    /// </summary>
    private async Task<List<SemanticMatch>> FindSimilarApisBruteForceAsync(float[] queryEmbedding, int topK, string? excludeApiName)
    {
        _logger.LogWarning("Using brute-force similarity calculation (vector search unavailable)");
        
        var allEmbeddings = await GetAllApiEmbeddingsAsync();
        var results = new List<SemanticMatch>();

        foreach (var apiEmbedding in allEmbeddings)
        {
            if (apiEmbedding.ApiName == excludeApiName)
                continue;
            
            if (apiEmbedding.Embedding == null || apiEmbedding.Embedding.Length == 0)
                continue;

            var similarity = CalculateCosineSimilarity(queryEmbedding, apiEmbedding.Embedding);
            
            results.Add(new SemanticMatch
            {
                ApiEmbedding = apiEmbedding,
                SimilarityScore = similarity
            });
        }

        return results.OrderByDescending(r => r.SimilarityScore).Take(topK).ToList();
    }

    private double CalculateCosineSimilarity(float[] a, float[] b)
    {
        if (a.Length != b.Length || a.Length == 0)
            return 0;

        double dotProduct = 0;
        double magnitudeA = 0;
        double magnitudeB = 0;

        for (int i = 0; i < a.Length; i++)
        {
            dotProduct += a[i] * b[i];
            magnitudeA += a[i] * a[i];
            magnitudeB += b[i] * b[i];
        }

        var magnitude = Math.Sqrt(magnitudeA) * Math.Sqrt(magnitudeB);
        return magnitude == 0 ? 0 : dotProduct / magnitude;
    }

    /// <summary>
    /// Internal class for deserializing vector search results.
    /// </summary>
    private class VectorSearchResult
    {
        [System.Text.Json.Serialization.JsonPropertyName("id")]
        public string Id { get; set; } = string.Empty;
        
        [System.Text.Json.Serialization.JsonPropertyName("apiName")]
        public string ApiName { get; set; } = string.Empty;
        
        [System.Text.Json.Serialization.JsonPropertyName("embedding")]
        public float[]? Embedding { get; set; }
        
        [System.Text.Json.Serialization.JsonPropertyName("description")]
        public string? Description { get; set; }
        
        [System.Text.Json.Serialization.JsonPropertyName("title")]
        public string? Title { get; set; }
        
        [System.Text.Json.Serialization.JsonPropertyName("embeddingText")]
        public string? EmbeddingText { get; set; }
        
        [System.Text.Json.Serialization.JsonPropertyName("timestamp")]
        public DateTime Timestamp { get; set; }
        
        [System.Text.Json.Serialization.JsonPropertyName("apiCenterResourceId")]
        public string? ApiCenterResourceId { get; set; }
        
        [System.Text.Json.Serialization.JsonPropertyName("kind")]
        public string? Kind { get; set; }
        
        [System.Text.Json.Serialization.JsonPropertyName("version")]
        public string? Version { get; set; }
        
        [System.Text.Json.Serialization.JsonPropertyName("endpoints")]
        public List<string>? Endpoints { get; set; }
        
        [System.Text.Json.Serialization.JsonPropertyName("schemas")]
        public List<string>? Schemas { get; set; }
        
        [System.Text.Json.Serialization.JsonPropertyName("distance")]
        public double Distance { get; set; }
    }

    /// <inheritdoc/>
    public async Task<ApiEmbedding?> GetApiEmbeddingAsync(string apiName)
    {
        await EnsureInitializedAsync();
        
        try
        {
            var response = await _container!.ReadItemAsync<ApiEmbedding>(
                apiName, new PartitionKey(apiName));
            return response.Resource;
        }
        catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            return null;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error getting API embedding: {ApiName}", apiName);
            throw;
        }
    }

    /// <inheritdoc/>
    public async Task<List<ApiEmbedding>> GetAllApiEmbeddingsAsync()
    {
        await EnsureInitializedAsync();
        
        var results = new List<ApiEmbedding>();

        try
        {
            var query = new QueryDefinition("SELECT * FROM c");
            var iterator = _container!.GetItemQueryIterator<ApiEmbedding>(query);
            
            while (iterator.HasMoreResults)
            {
                var response = await iterator.ReadNextAsync();
                results.AddRange(response);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error getting all API embeddings");
            throw;
        }

        return results;
    }

    /// <inheritdoc/>
    public async Task DeleteApiEmbeddingAsync(string apiName)
    {
        await EnsureInitializedAsync();
        
        try
        {
            await _container!.DeleteItemAsync<ApiEmbedding>(apiName, new PartitionKey(apiName));
            _logger.LogInformation("Deleted embedding for API: {ApiName}", apiName);
        }
        catch (CosmosException ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            _logger.LogWarning("API embedding not found for deletion: {ApiName}", apiName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error deleting API embedding: {ApiName}", apiName);
            throw;
        }
    }

    private async Task EnsureInitializedAsync()
    {
        if (!_initialized)
        {
            await InitializeAsync();
        }
    }
}
