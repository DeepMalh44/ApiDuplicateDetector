using System.Text.Json.Serialization;

namespace ApiDuplicateDetector.Models;

/// <summary>
/// Represents an API with its vector embedding stored in Cosmos DB.
/// This model enables semantic similarity search using vector search.
/// Uses System.Text.Json attributes for Cosmos DB SDK compatibility.
/// </summary>
public class ApiEmbedding
{
    /// <summary>
    /// Unique identifier (API name used as partition key).
    /// </summary>
    [JsonPropertyName("id")]
    public string Id { get; set; } = string.Empty;
    
    /// <summary>
    /// The API name (used as partition key).
    /// </summary>
    [JsonPropertyName("apiName")]
    public string ApiName { get; set; } = string.Empty;
    
    /// <summary>
    /// The API title.
    /// </summary>
    [JsonPropertyName("title")]
    public string? Title { get; set; }
    
    /// <summary>
    /// The API description.
    /// </summary>
    [JsonPropertyName("description")]
    public string? Description { get; set; }
    
    /// <summary>
    /// The API kind (rest, graphql, grpc, etc.).
    /// </summary>
    [JsonPropertyName("kind")]
    public string? Kind { get; set; }
    
    /// <summary>
    /// The API version.
    /// </summary>
    [JsonPropertyName("version")]
    public string? Version { get; set; }
    
    /// <summary>
    /// Combined text representation of the API for embedding generation.
    /// Includes title, description, endpoints, and schemas.
    /// </summary>
    [JsonPropertyName("embeddingText")]
    public string EmbeddingText { get; set; } = string.Empty;
    
    /// <summary>
    /// The vector embedding of the API (1536 dimensions for text-embedding-ada-002).
    /// </summary>
    [JsonPropertyName("embedding")]
    public float[] Embedding { get; set; } = Array.Empty<float>();
    
    /// <summary>
    /// List of endpoint paths for quick reference.
    /// </summary>
    [JsonPropertyName("endpoints")]
    public List<string> Endpoints { get; set; } = new();
    
    /// <summary>
    /// List of schema names for quick reference.
    /// </summary>
    [JsonPropertyName("schemas")]
    public List<string> Schemas { get; set; } = new();
    
    /// <summary>
    /// Timestamp when the embedding was created/updated.
    /// </summary>
    [JsonPropertyName("timestamp")]
    public DateTime Timestamp { get; set; } = DateTime.UtcNow;
    
    /// <summary>
    /// Resource ID from API Center.
    /// </summary>
    [JsonPropertyName("apiCenterResourceId")]
    public string? ApiCenterResourceId { get; set; }
}

/// <summary>
/// Represents a semantic similarity match result from vector search.
/// </summary>
public class SemanticMatch
{
    /// <summary>
    /// The matching API embedding.
    /// </summary>
    public ApiEmbedding ApiEmbedding { get; set; } = new();
    
    /// <summary>
    /// Cosine similarity score (0.0 to 1.0, higher = more similar).
    /// </summary>
    public double SimilarityScore { get; set; }
}
