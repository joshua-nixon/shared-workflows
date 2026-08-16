param(
  [Parameter(Mandatory)]
  [string]$DeployablesJson,

  [Parameter(Mandatory)]
  [string]$ChangedFilesJson,

  [Parameter(Mandatory)]
  [string]$GitHubSHA,

  [Parameter(Mandatory)]
  [string]$GitHubRefName,

  [Parameter(Mandatory)]
  [string]$ContainerRegistry,

  [Parameter(Mandatory)]
  [string]$GitHubEventName,

  [Parameter(Mandatory)]
  [string]$EnvironmentsJson
)

function Write-KeyValue {
    param([string]$Key, [string]$Value)

    Write-Host ("{0,-20} : {1}" -f $Key, $Value)
}

function Get-TestProjects {
  param([psobject]$Project)

  if ($Project.PSObject.Properties.Name -contains 'testProjects') {
      return $Project.testProjects | ForEach-Object {
        [pscustomobject]@{
          name = [System.IO.Path]::GetFileNameWithoutExtension($_)
          path = $_
        }
      }
  }

  return
}

function Create-ProposedImage {
  param([psobject]$Project)

  # Random suffix, so tags of different images are not identical
  $randomSuffix = '{0:D5}' -f (Get-Random -Minimum 0 -Maximum 5000)

  return ("{0}/{1}:{2}-{3}-{4}-{5}" -f $ContainerRegistry, $Project.name, $branchName, $timestamp, $shortSha, $randomSuffix)
}

function Get-DockerfilePath {
    param([psobject]$Project)

    $projectDirectory = Split-Path -Path $Project.path -Parent

    return Join-Path -Path $projectDirectory -ChildPath "Dockerfile"
}

function Test-ProjectChanged {
    param([psobject]$Paths, [string[]]$ChangedFiles)

    foreach ($relatedPath in $Paths) {
        if ($ChangedFiles | Where-Object { $_ -like $relatedPath }) {
            return $true
        }
    }

    return $false
}

function Get-ProjectRelatedPaths {
  param([psobject]$Project)

  $projectDirectory = Split-Path -Path $Project.path -Parent
  $relatedPaths     = @(
    "$projectDirectory/*"
  )

  if ($Project.PSObject.Properties.Name -contains 'relatedPaths') {
    $relatedPaths += $Project.relatedPaths
  }

  return $relatedPaths
}

function Get-DeployableEnvironments {
  return @( 
    $EnvironmentsJson `
      | ConvertFrom-Json `
      | Where-Object { $_.deploy } `
      | ForEach-Object { [pscustomobject]@{ name = $_.name } } 
  )
}

function Get-ProjectMetadata {
  $result = @()

  foreach ($project in $projects) {
      $deployable       = $deployables | Where-Object { $_.name -eq $project.name } | Select-Object -First 1 
      $projectPath      = $project.path
      $name             = [System.IO.Path]::GetFileNameWithoutExtension($projectPath)
      $build            = $deployable.build
      $eventName        = $project.name
      $dockerfilePath   = Get-DockerfilePath $project
      $relatedPaths     = Get-ProjectRelatedPaths $project
      $hasChanged       = Test-ProjectChanged $relatedPaths $changedFiles
      $testProjects     = @(Get-TestProjects $project)
      $context          = $project.context
      $proposedImage    = Create-ProposedImage $project
      $runTests         = $build -or ($GitHubEventName -ne "workflow_dispatch")   

      $result += [pscustomobject]@{
        build           = $build
        changed         = $hasChanged
        name            = $name
        projectPath     = $projectPath
        eventName       = $eventName
        dockerfilePath  = $dockerfilePath
        testProjects    = $testProjects
        context         = $context  
        proposedImage   = $proposedImage
        runTests        = $runTests
      }    
  }

  return $result
}

function Get-BuildableProjectsMetadata {
  return @( 
      $projectMetadata `
        | Where-Object { $_.build } `
        | ForEach-Object {
          [pscustomobject]@{
            name           = $_.name
            context        = $_.context
            dockerfilePath = $_.dockerfilePath
            proposedImage  = $_.proposedImage
          }
        }
      )
}

function Get-TestableProjectsMetadata {
  return @( 
    $projectMetadata `
      | Where-Object { $_.runTests } `
      | ForEach-Object { $_.testProjects } `
      | Sort-Object -Property path -Unique
    )
}

function Read-MetadataFile {
  $valuesJson = yq eval -o=json -c 'explode(.) | (.. | select(tag == "!!seq")) |= flatten' "./.github/project-metadata.yaml"

  return $valuesJson | ConvertFrom-Json
}

$changedFilesJson   = $ChangedFilesJson -replace '\\"', '"' # Normalise the json array
$metadata             = Read-MetadataFile 
$deployables        = @( $DeployablesJson | ConvertFrom-Json )
$projects           = @( $metadata.projects | Where-Object { $_.name -in $deployables.name } )
$changedFiles       = @( $changedFilesJson | ConvertFrom-Json )
$shortSha           = $GitHubSHA.Substring(0, 7)
$timestamp          = Get-Date -Format "yyyyMMdd-HHmmss"
$branchName         = ($GitHubRefName.ToLowerInvariant() -replace '[^a-z0-9_.-]', '-').Trim('-.')
$environments       = Get-DeployableEnvironments
$projectMetadata    = Get-ProjectMetadata
$buildableProjects  = Get-BuildableProjectsMetadata
$testProjects       = Get-TestableProjectsMetadata

$payload = [pscustomobject]@{
  buildable        = $buildableProjects
  environments     = $environments
  testProjects     = $testProjects
  hasAnyBuildable  = ($buildableProjects.Count -gt 0)
  hasAnyTestable   = ($testProjects.Count -gt 0)
  hasAnyDeployable = (($buildableProjects.Count -gt 0) -and ($environments.Count -gt 0))
}


ConvertTo-Json -InputObject $payload -Compress -Depth 10  # Pass the json back to the caller