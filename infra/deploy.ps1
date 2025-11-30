<#
.SYNOPSIS
    Deploys the API Duplicate Detector solution to Azure.

.DESCRIPTION
    This script deploys the complete API Duplicate Detector solution including:
    - Infrastructure (Bicep): Function App, Storage, App Insights, Event Grid, Cosmos DB, Azure OpenAI
    - Function App code deployment
    - All RBAC role assignments for managed identity

.PARAMETER ResourceGroupName
    The name of the resource group to deploy to.

.PARAMETER ApiCenterName
    The name of the existing Azure API Center instance.

.PARAMETER Location
    The Azure region for deployment. Defaults to 'eastus'.

.PARAMETER EnableSemanticAnalysis
    Enable semantic analysis with Azure OpenAI and Cosmos DB. Defaults to $true.

.PARAMETER AlertEmailAddress
    Email address for duplicate detection alerts. Defaults to current user's email.

.PARAMETER OpenAiLocation
    Location for Azure OpenAI resource. Defaults to 'eastus'.

.PARAMETER CosmosDbLocation
    Location for Cosmos DB resource. Defaults to 'westus2'.

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName "rg-api-detector" -ApiCenterName "my-api-center"

.EXAMPLE
    .\deploy.ps1 -ResourceGroupName "rg-api-detector" -ApiCenterName "my-api-center" -EnableSemanticAnalysis $true -AlertEmailAddress "admin@contoso.com"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$ApiCenterName,
    
    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",
    
    [Parameter(Mandatory = $false)]
    [bool]$EnableSemanticAnalysis = $true,
    
    [Parameter(Mandatory = $false)]
    [string]$AlertEmailAddress = "",
    
    [Parameter(Mandatory = $false)]
    [string]$OpenAiLocation = "eastus",
    
    [Parameter(Mandatory = $false)]
    [string]$CosmosDbLocation = "westus2"
)

$ErrorActionPreference = "Stop"

# Get script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "API Duplicate Detector Deployment" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get current user email if not provided
if ([string]::IsNullOrEmpty($AlertEmailAddress)) {
    $AlertEmailAddress = (az ad signed-in-user show --query mail -o tsv 2>$null)
    if ([string]::IsNullOrEmpty($AlertEmailAddress)) {
        $AlertEmailAddress = (az ad signed-in-user show --query userPrincipalName -o tsv 2>$null)
    }
    Write-Host "Using email for alerts: $AlertEmailAddress" -ForegroundColor Yellow
}

# Step 1: Verify prerequisites
Write-Host ""
Write-Host "Step 1: Verifying prerequisites..." -ForegroundColor Yellow

# Check Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI is not installed. Please install it from https://docs.microsoft.com/cli/azure/install-azure-cli"
}

# Check .NET SDK
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw ".NET SDK is not installed. Please install .NET 8.0 SDK from https://dotnet.microsoft.com/download"
}

# Check Azure login
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "Not logged in to Azure. Running 'az login'..." -ForegroundColor Yellow
    az login
    $account = az account show | ConvertFrom-Json
}
Write-Host "Logged in as: $($account.user.name)" -ForegroundColor Green
Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Green

# Verify resource group exists
$rgExists = az group exists --name $ResourceGroupName
if ($rgExists -eq "false") {
    Write-Host "Creating resource group: $ResourceGroupName in $Location" -ForegroundColor Yellow
    az group create --name $ResourceGroupName --location $Location | Out-Null
}
Write-Host "Resource group: $ResourceGroupName" -ForegroundColor Green

# Verify API Center exists
$apiCenter = az apic show --name $ApiCenterName --resource-group $ResourceGroupName 2>$null | ConvertFrom-Json
if (-not $apiCenter) {
    throw "API Center '$ApiCenterName' not found in resource group '$ResourceGroupName'. Please create it first."
}
Write-Host "API Center: $ApiCenterName" -ForegroundColor Green

Write-Host "Prerequisites verified!" -ForegroundColor Green

# Step 2: Deploy Bicep infrastructure
Write-Host ""
Write-Host "Step 2: Deploying infrastructure (Bicep)..." -ForegroundColor Yellow

$bicepPath = Join-Path $scriptDir "api-duplicate-detector.bicep"
if (-not (Test-Path $bicepPath)) {
    throw "Bicep template not found at: $bicepPath"
}

$deploymentName = "api-duplicate-detector-$(Get-Date -Format 'yyyyMMddHHmmss')"
$deploymentOutput = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $bicepPath `
    --name $deploymentName `
    --parameters apiCenterName=$ApiCenterName `
                 enableSemanticAnalysis=$EnableSemanticAnalysis `
                 alertEmailAddress=$AlertEmailAddress `
                 openAiLocation=$OpenAiLocation `
                 cosmosDbLocation=$CosmosDbLocation `
    --query "properties.outputs" -o json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    throw "Bicep deployment failed!"
}

$functionAppName = $deploymentOutput.functionAppName.value
$storageAccountName = $deploymentOutput.storageAccountName.value

Write-Host "Infrastructure deployed!" -ForegroundColor Green
Write-Host "  Function App: $functionAppName" -ForegroundColor Cyan
Write-Host "  Storage Account: $storageAccountName" -ForegroundColor Cyan
if ($EnableSemanticAnalysis) {
    Write-Host "  Azure OpenAI: $($deploymentOutput.openAiResourceName.value)" -ForegroundColor Cyan
    Write-Host "  Cosmos DB: $($deploymentOutput.cosmosDbResourceName.value)" -ForegroundColor Cyan
}

# Step 3: Build the Function App
Write-Host ""
Write-Host "Step 3: Building Function App..." -ForegroundColor Yellow

Push-Location $projectRoot
try {
    $publishPath = Join-Path $projectRoot "publish"
    if (Test-Path $publishPath) {
        Remove-Item -Path $publishPath -Recurse -Force
    }
    
    dotnet publish -c Release -o $publishPath
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed!"
    }
    Write-Host "Function App built successfully!" -ForegroundColor Green
}
finally {
    Pop-Location
}

# Step 4: Deploy the Function App
Write-Host ""
Write-Host "Step 4: Deploying Function App code..." -ForegroundColor Yellow

$zipPath = Join-Path $projectRoot "deploy.zip"
if (Test-Path $zipPath) {
    Remove-Item -Path $zipPath -Force
}

# Create zip file
Compress-Archive -Path (Join-Path $publishPath "*") -DestinationPath $zipPath -Force

# Deploy
az functionapp deployment source config-zip `
    --resource-group $ResourceGroupName `
    --name $functionAppName `
    --src $zipPath

if ($LASTEXITCODE -ne 0) {
    throw "Function App deployment failed!"
}

Write-Host "Function App code deployed!" -ForegroundColor Green

# Step 5: Restart Function App to apply settings
Write-Host ""
Write-Host "Step 5: Restarting Function App..." -ForegroundColor Yellow

az functionapp restart --name $functionAppName --resource-group $ResourceGroupName
Start-Sleep -Seconds 10

Write-Host "Function App restarted!" -ForegroundColor Green

# Step 6: Verify deployment
Write-Host ""
Write-Host "Step 6: Verifying deployment..." -ForegroundColor Yellow

$functions = az functionapp function list --name $functionAppName --resource-group $ResourceGroupName -o json | ConvertFrom-Json
if ($functions.Count -gt 0) {
    Write-Host "Functions deployed: $($functions.Count)" -ForegroundColor Green
    foreach ($func in $functions) {
        Write-Host "  - $($func.name.Split('/')[-1])" -ForegroundColor Cyan
    }
} else {
    Write-Host "Warning: No functions found. The app may still be warming up." -ForegroundColor Yellow
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Deployment Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Resources deployed:" -ForegroundColor Yellow
Write-Host "  Resource Group:    $ResourceGroupName" -ForegroundColor White
Write-Host "  Function App:      $functionAppName" -ForegroundColor White
Write-Host "  Function URL:      https://$functionAppName.azurewebsites.net" -ForegroundColor White
Write-Host "  Storage Account:   $storageAccountName" -ForegroundColor White
Write-Host "  API Center:        $ApiCenterName" -ForegroundColor White
Write-Host "  Alert Email:       $AlertEmailAddress" -ForegroundColor White

if ($EnableSemanticAnalysis) {
    Write-Host ""
    Write-Host "Semantic Analysis enabled:" -ForegroundColor Yellow
    Write-Host "  Azure OpenAI:      $($deploymentOutput.openAiResourceName.value)" -ForegroundColor White
    Write-Host "  Cosmos DB:         $($deploymentOutput.cosmosDbResourceName.value)" -ForegroundColor White
}

Write-Host ""
Write-Host "Authentication:" -ForegroundColor Yellow
Write-Host "  All services use Managed Identity (no keys or connection strings)" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Register an API in API Center to test duplicate detection" -ForegroundColor White
Write-Host "  2. Check Application Insights for function logs" -ForegroundColor White
Write-Host "  3. Monitor your email for duplicate detection alerts" -ForegroundColor White
Write-Host ""
